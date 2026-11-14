#include "DexMixer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Mixer controls must be lock free");

// MARK: Biquads (RBJ cookbook, bilinear transform: Web Audio's formulas)

typedef struct { double b0, b1, b2, a1, a2; } Coefficients;
typedef struct { double z1, z2; } Section;
typedef struct { double a1, a2, a3, k; } SweepCoefficients;
enum { LOWPASS, HIGHPASS, ALLPASS };

static Coefficients design(int type, double hz, double q, double sampleRate) {
    double w0 = 2 * M_PI * hz / sampleRate, c = cos(w0), alpha = sin(w0) / (2 * q);
    double b0, b1, b2, a0 = 1 + alpha;
    if (type == LOWPASS) { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; }
    else if (type == HIGHPASS) { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; }
    else { b0 = 1 - alpha; b1 = -2 * c; b2 = 1 + alpha; }
    return (Coefficients){b0 / a0, b1 / a0, b2 / a0, -2 * c / a0, (1 - alpha) / a0};
}

static inline double run(const Coefficients *k, Section *s, double x) {
    double y = k->b0 * x + s->z1;
    s->z1 = k->b1 * x - k->a1 * y + s->z2;
    s->z2 = k->b2 * x - k->a2 * y;
    return y;
}

static void flush(Section *sections, int count) {
    // Decayed state would otherwise sink into denormals after a kill or silence.
    for (int i = 0; i < count; ++i) {
        if (fabs(sections[i].z1) < 1e-25) sections[i].z1 = 0;
        if (fabs(sections[i].z2) < 1e-25) sections[i].z2 = 0;
    }
}

/// One step of setTargetAtTime, settling exactly on the target once inside 1e-4.
/// A float near 1 stops moving well outside 1e-6, so a smaller window never lands.
static inline float glide(float value, float target, float k) {
    float next = value + (target - value) * k;
    return fabsf(target - next) < 1e-4f ? target : next;
}

static float smoothing(double seconds, double sampleRate) { return (float)(1 - exp(-1 / (seconds * sampleRate))); }

// MARK: Isolator

// LOW: LR4 low-pass at the low crossover, then the high crossover's all-pass.
// MID and HIGH share the LR4 high-pass at the low crossover, then split.
enum { LOW_0, LOW_1, LOW_AP, REST_0, REST_1, MID_0, MID_1, HIGH_0, HIGH_1, SECTIONS };

struct DexIsolatorState {
    _Atomic float target[4]; // low, mid, high, trim
    float value[4];
    float bandGlide, trimGlide;
    float wet, wetGlide; // 0 passes the input straight through, 1 is the summed bands
    Coefficients k[SECTIONS];
    Section s[2][SECTIONS];
    // The sweep: a low-pass then a high-pass, each parked at its transparent end
    // and always running, so nothing has to start up or switch type when it moves.
    _Atomic float sweepTarget; // the knob, −1 … 1
    _Atomic bool resetPending; // the render thread owns the history, so it clears it
    float sweepDepth[2], sweepDrawn[2], sweepWet[2];
    double rate, lowPassFlat, lowPassFloor, highPassFloor, highPassCeiling;
    SweepCoefficients sweepK[2];
    Section sweepS[2][2];
};

enum { SWEEP_LOW, SWEEP_HIGH };

/// Web Audio's response, as Electron's sweep has: Q is the resonance in dB.
static void designSweep(DexIsolatorState *st, int which) {
    double depth = st->sweepDepth[which], q = pow(10, (0.7 + 0.6 * depth) / 20);
    double hz = which == SWEEP_LOW ? st->lowPassFlat * pow(st->lowPassFloor / st->lowPassFlat, depth)
        : st->highPassFloor * pow(st->highPassCeiling / st->highPassFloor, depth);
    double g = tan(M_PI * hz / st->rate), k = 1 / q, a1 = 1 / (1 + g * (g + k));
    st->sweepK[which] = (SweepCoefficients){a1, g * a1, g * g * a1, k};
    st->sweepDrawn[which] = st->sweepDepth[which];
}

/// A trapezoidal state-variable filter: the same bilinear response as the RBJ
/// biquads, but its state stays valid while the cutoff moves, so a drag can't tick.
static inline double runSweep(const SweepCoefficients *c, Section *s, double x, bool highPass) {
    double v3 = x - s->z2, v1 = c->a1 * s->z1 + c->a2 * v3, v2 = s->z2 + c->a2 * s->z1 + c->a3 * v3;
    s->z1 = 2 * v1 - s->z1;
    s->z2 = 2 * v2 - s->z2;
    return highPass ? x - c->k * v1 - v2 : v2;
}

DexIsolatorState *dex_isolator_create(double rate, double lowHz, double highHz, double lowPassFlat, double lowPassFloor,
                                      double highPassFloor, double highPassCeiling) {
    DexIsolatorState *st = calloc(1, sizeof(*st));
    if (!st) return NULL;
    if (!atomic_is_lock_free(&st->target[0])) { free(st); return NULL; }
    const double q = M_SQRT1_2;
    st->k[LOW_0] = st->k[LOW_1] = design(LOWPASS, lowHz, q, rate);
    st->k[LOW_AP] = design(ALLPASS, highHz, q, rate);
    st->k[REST_0] = st->k[REST_1] = design(HIGHPASS, lowHz, q, rate);
    st->k[MID_0] = st->k[MID_1] = design(LOWPASS, highHz, q, rate);
    st->k[HIGH_0] = st->k[HIGH_1] = design(HIGHPASS, highHz, q, rate);
    // Electron's band gains glide with a 20 ms constant, its trim with 15 ms.
    st->bandGlide = smoothing(0.02, rate);
    st->trimGlide = smoothing(0.015, rate);
    st->wetGlide = smoothing(0.005, rate);
    for (int i = 0; i < 4; ++i) { atomic_init(&st->target[i], 1); st->value[i] = 1; }
    atomic_init(&st->sweepTarget, 0);
    atomic_init(&st->resetPending, false);
    st->rate = rate; st->lowPassFlat = lowPassFlat; st->lowPassFloor = lowPassFloor;
    st->highPassFloor = highPassFloor; st->highPassCeiling = highPassCeiling;
    designSweep(st, SWEEP_LOW); designSweep(st, SWEEP_HIGH);
    return st;
}

void dex_isolator_destroy(DexIsolatorState *st) { free(st); }

void dex_isolator_set(DexIsolatorState *st, float low, float mid, float high, float trim) {
    float values[4] = {low, mid, high, trim};
    for (int i = 0; i < 4; ++i) atomic_store_explicit(&st->target[i], values[i], memory_order_relaxed);
}

void dex_isolator_set_sweep(DexIsolatorState *st, float knob) {
    atomic_store_explicit(&st->sweepTarget, knob, memory_order_relaxed);
}

void dex_isolator_reset(DexIsolatorState *st) { atomic_store_explicit(&st->resetPending, true, memory_order_release); }

static inline bool bandsFlat(const DexIsolatorState *st) { return st->value[0] == 1 && st->value[1] == 1 && st->value[2] == 1; }

void dex_isolator_snap(DexIsolatorState *st) {
    // Control-thread only, before the unit renders (a new graph or a test).
    for (int i = 0; i < 4; ++i) st->value[i] = atomic_load_explicit(&st->target[i], memory_order_relaxed);
    st->wet = bandsFlat(st) ? 0 : 1;
    float knob = atomic_load_explicit(&st->sweepTarget, memory_order_relaxed);
    st->sweepDepth[SWEEP_LOW] = knob < 0 ? -knob : 0;
    st->sweepDepth[SWEEP_HIGH] = knob > 0 ? knob : 0;
    for (int i = 0; i < 2; ++i) { designSweep(st, i); st->sweepWet[i] = st->sweepDepth[i] > 0 ? 1 : 0; }
}

void dex_isolator_process(DexIsolatorState *st, UInt32 frames, AudioBufferList *audio) {
    if (atomic_exchange_explicit(&st->resetPending, false, memory_order_acquire)) {
        memset(st->s, 0, sizeof(st->s));
        memset(st->sweepS, 0, sizeof(st->sweepS));
    }
    float target[4];
    for (int i = 0; i < 4; ++i) target[i] = atomic_load_explicit(&st->target[i], memory_order_relaxed);
    float knob = atomic_load_explicit(&st->sweepTarget, memory_order_relaxed);
    float depthTarget[2] = {knob < 0 ? -knob : 0, knob > 0 ? knob : 0};
    UInt32 channels = audio->mNumberBuffers < 2 ? audio->mNumberBuffers : 2;
    for (UInt32 f = 0; f < frames; ++f) {
        for (int i = 0; i < 3; ++i) st->value[i] = glide(st->value[i], target[i], st->bandGlide);
        st->value[3] = glide(st->value[3], target[3], st->trimGlide);
        // The summed bands are flat in level but rotate the phase, which lifts a
        // kick's peaks by up to 5 dB, so flat bands stay out of the signal. They
        // keep running, ready to crossfade in as soon as a band moves.
        st->wet = glide(st->wet, bandsFlat(st) ? 0 : 1, st->wetGlide);
        for (int i = 0; i < 2; ++i) {
            st->sweepDepth[i] = glide(st->sweepDepth[i], depthTarget[i], st->bandGlide);
            st->sweepWet[i] = glide(st->sweepWet[i], st->sweepDepth[i] > 0 ? 1 : 0, st->wetGlide);
            // Control rate: the depth only moves about 1 % per block of this size.
            if (f % 32 == 0 && st->sweepDrawn[i] != st->sweepDepth[i]) designSweep(st, i);
        }
        for (UInt32 c = 0; c < channels; ++c) {
            float *samples = (float *)audio->mBuffers[c].mData;
            Section *s = st->s[c];
            const Coefficients *k = st->k;
            double x = (double)samples[f] * st->value[3];
            double low = run(&k[LOW_AP], &s[LOW_AP], run(&k[LOW_1], &s[LOW_1], run(&k[LOW_0], &s[LOW_0], x)));
            double rest = run(&k[REST_1], &s[REST_1], run(&k[REST_0], &s[REST_0], x));
            double mid = run(&k[MID_1], &s[MID_1], run(&k[MID_0], &s[MID_0], rest));
            double high = run(&k[HIGH_1], &s[HIGH_1], run(&k[HIGH_0], &s[HIGH_0], rest));
            double bands = st->value[0] * low + st->value[1] * mid + st->value[2] * high;
            double y = x + st->wet * (bands - x);
            y += st->sweepWet[SWEEP_LOW] * (runSweep(&st->sweepK[SWEEP_LOW], &st->sweepS[c][SWEEP_LOW], y, false) - y);
            y += st->sweepWet[SWEEP_HIGH] * (runSweep(&st->sweepK[SWEEP_HIGH], &st->sweepS[c][SWEEP_HIGH], y, true) - y);
            samples[f] = (float)y;
        }
    }
    for (UInt32 c = 0; c < channels; ++c) { flush(st->s[c], SECTIONS); flush(st->sweepS[c], 2); }
}

// MARK: Cue tap

struct DexCueTap {
    UInt32 capacity;
    _Atomic UInt32 waiting; // frames written and not yet read
    float *samples[2];
};

DexCueTap *dex_cue_tap_create(UInt32 maximumFrames) {
    DexCueTap *tap = calloc(1, sizeof(*tap));
    if (!tap) return NULL;
    tap->capacity = maximumFrames;
    atomic_init(&tap->waiting, 0);
    for (int c = 0; c < 2; ++c) tap->samples[c] = calloc(maximumFrames, sizeof(float));
    if (!tap->samples[0] || !tap->samples[1] || !atomic_is_lock_free(&tap->waiting)) { dex_cue_tap_destroy(tap); return NULL; }
    return tap;
}

void dex_cue_tap_destroy(DexCueTap *tap) {
    if (!tap) return;
    free(tap->samples[0]); free(tap->samples[1]); free(tap);
}

void dex_cue_tap_write(DexCueTap *tap, UInt32 frames, const AudioBufferList *audio) {
    if (frames > tap->capacity || audio->mNumberBuffers == 0) { atomic_store_explicit(&tap->waiting, 0, memory_order_relaxed); return; }
    for (UInt32 c = 0; c < 2; ++c) {
        const AudioBuffer *buffer = &audio->mBuffers[c < audio->mNumberBuffers ? c : audio->mNumberBuffers - 1];
        if (buffer->mData) memcpy(tap->samples[c], buffer->mData, frames * sizeof(float));
        else memset(tap->samples[c], 0, frames * sizeof(float));
    }
    atomic_store_explicit(&tap->waiting, frames, memory_order_relaxed);
}

void dex_cue_tap_reset(DexCueTap *tap) { atomic_store_explicit(&tap->waiting, 0, memory_order_relaxed); }

void dex_cue_tap_read(DexCueTap *tap, UInt32 frames, AudioBufferList *audio) {
    bool ready = atomic_exchange_explicit(&tap->waiting, 0, memory_order_relaxed) == frames;
    for (UInt32 c = 0; c < audio->mNumberBuffers; ++c) {
        float *out = (float *)audio->mBuffers[c].mData;
        if (!out) continue;
        if (ready) memcpy(out, tap->samples[c < 2 ? c : 1], frames * sizeof(float));
        else memset(out, 0, frames * sizeof(float));
    }
}

// MARK: Router

#define ROUTER_INPUTS 3
#define ROUTER_MAX_OUTPUTS 8

struct DexRouterState {
    _Atomic int mode;
    _Atomic float target[3]; // cue mix, cue A, cue B
    _Atomic float phonesTarget; // the headphones' level, a plain gain on the cue only
    float phones;
    _Atomic bool resetPending; // the render thread owns the peak guard, so it clears it
    _Atomic UInt32 pullFailures[ROUTER_INPUTS];
    float value[3];
    float mixGlide, cueGlide;
    float cueGain, cueRelease; // the cue's peak guard
    float folded; // split output: 0 is the stereo master, 1 is mono master and mono cue
    UInt32 maximumFrames;
    AudioBufferList *inputs[ROUTER_INPUTS];
    float *inputMemory;
    float *outputMemory;
};

DexRouterState *dex_router_create(double rate, UInt32 maximumFrames) {
    DexRouterState *st = calloc(1, sizeof(*st));
    if (!st) return NULL;
    st->maximumFrames = maximumFrames;
    st->inputMemory = calloc((size_t)maximumFrames * 2 * ROUTER_INPUTS, sizeof(float));
    st->outputMemory = calloc((size_t)maximumFrames * ROUTER_MAX_OUTPUTS, sizeof(float));
    bool ready = st->inputMemory && st->outputMemory && atomic_is_lock_free(&st->target[0]);
    for (int bus = 0; ready && bus < ROUTER_INPUTS; ++bus) {
        st->inputs[bus] = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
        ready = st->inputs[bus] != NULL;
    }
    if (!ready) { dex_router_destroy(st); return NULL; }
    atomic_init(&st->mode, DEX_ROUTE_SPLIT);
    atomic_init(&st->resetPending, false);
    for (int bus = 0; bus < ROUTER_INPUTS; ++bus) atomic_init(&st->pullFailures[bus], 0);
    // Electron's cue mix glides with a 20 ms constant, the deck cue taps 10 ms.
    st->mixGlide = smoothing(0.02, rate);
    st->cueGlide = smoothing(0.01, rate);
    st->cueGain = 1;
    st->cueRelease = smoothing(0.15, rate);
    float initial[3] = {0.85f, 0, 0};
    for (int i = 0; i < 3; ++i) { atomic_init(&st->target[i], initial[i]); st->value[i] = initial[i]; }
    atomic_init(&st->phonesTarget, 1.0f);
    st->phones = 1;
    return st;
}

void dex_router_destroy(DexRouterState *st) {
    if (!st) return;
    for (int bus = 0; bus < ROUTER_INPUTS; ++bus) free(st->inputs[bus]);
    free(st->inputMemory); free(st->outputMemory); free(st);
}

void dex_router_set(DexRouterState *st, int mode, float cueMix, float cueA, float cueB) {
    atomic_store_explicit(&st->mode, mode, memory_order_relaxed);
    float values[3] = {cueMix, cueA, cueB};
    for (int i = 0; i < 3; ++i) atomic_store_explicit(&st->target[i], values[i], memory_order_relaxed);
}

void dex_router_set_phones(DexRouterState *st, float level) {
    atomic_store_explicit(&st->phonesTarget, level, memory_order_relaxed);
}

void dex_router_snap(DexRouterState *st) {
    for (int i = 0; i < 3; ++i) st->value[i] = atomic_load_explicit(&st->target[i], memory_order_relaxed);
    st->phones = atomic_load_explicit(&st->phonesTarget, memory_order_relaxed);
    st->folded = st->value[1] > 0 || st->value[2] > 0 ? 1 : 0;
}

void dex_router_reset(DexRouterState *st) { atomic_store_explicit(&st->resetPending, true, memory_order_release); }

void dex_router_count_pull_failure(DexRouterState *st, int bus) {
    atomic_fetch_add_explicit(&st->pullFailures[bus], 1, memory_order_relaxed);
}

UInt32 dex_router_pull_failures(DexRouterState *st, int bus) {
    return atomic_load_explicit(&st->pullFailures[bus], memory_order_relaxed);
}

AudioBufferList *dex_router_input(DexRouterState *st, int bus, UInt32 frames) {
    AudioBufferList *list = st->inputs[bus];
    list->mNumberBuffers = 2;
    for (int c = 0; c < 2; ++c) {
        list->mBuffers[c].mNumberChannels = 1;
        list->mBuffers[c].mDataByteSize = frames * sizeof(float);
        list->mBuffers[c].mData = st->inputMemory + ((size_t)bus * 2 + c) * st->maximumFrames;
    }
    return list;
}

void dex_router_prepare_output(DexRouterState *st, UInt32 frames, AudioBufferList *output) {
    for (UInt32 c = 0; c < output->mNumberBuffers && c < ROUTER_MAX_OUTPUTS; ++c) {
        if (output->mBuffers[c].mData) continue;
        output->mBuffers[c].mData = st->outputMemory + (size_t)c * st->maximumFrames;
        output->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
}

static inline float sample(const AudioBufferList *list, bool pulled, UInt32 channel, UInt32 frame) {
    if (!pulled || list->mNumberBuffers == 0) return 0;
    UInt32 c = channel < list->mNumberBuffers ? channel : list->mNumberBuffers - 1;
    const float *data = (const float *)list->mBuffers[c].mData;
    return data ? data[frame] : 0;
}

void dex_router_process(DexRouterState *st, UInt32 frames, const bool *pulled, AudioBufferList *output) {
    if (atomic_exchange_explicit(&st->resetPending, false, memory_order_acquire)) st->cueGain = 1;
    int mode = atomic_load_explicit(&st->mode, memory_order_relaxed);
    float target[3];
    for (int i = 0; i < 3; ++i) target[i] = atomic_load_explicit(&st->target[i], memory_order_relaxed);
    float phonesTarget = atomic_load_explicit(&st->phonesTarget, memory_order_relaxed);
    UInt32 channels = output->mNumberBuffers;
    float foldTarget = target[1] > 0 || target[2] > 0 ? 1 : 0;
    const AudioBufferList *master = st->inputs[0], *a = st->inputs[1], *b = st->inputs[2];
    for (UInt32 f = 0; f < frames; ++f) {
        st->value[0] = glide(st->value[0], target[0], st->mixGlide);
        st->value[1] = glide(st->value[1], target[1], st->cueGlide);
        st->value[2] = glide(st->value[2], target[2], st->cueGlide);
        st->folded = glide(st->folded, foldTarget, st->cueGlide);
        float mix = st->value[0];
        float m[2], cue[2];
        for (UInt32 c = 0; c < 2; ++c) {
            m[c] = sample(master, pulled[0], c, f);
            float taps = st->value[1] * sample(a, pulled[1], c, f) + st->value[2] * sample(b, pulled[2], c, f);
            cue[c] = mix * taps + (1 - mix) * m[c];
        }
        // The cue skips the master limiter, so nothing else stops it clipping at
        // the output. Gain drops at once to hold the peak, then recovers slowly
        // enough not to ripple across a bass cycle. Below full scale it is unity.
        float cuePeak = fmaxf(fabsf(cue[0]), fabsf(cue[1]));
        st->cueGain = glide(st->cueGain, 1, st->cueRelease);
        if (cuePeak * st->cueGain > 1) st->cueGain = 1 / cuePeak;
        // PHONES turns the headphones down after the guard, so it never touches the master.
        st->phones = glide(st->phones, phonesTarget, st->mixGlide);
        cue[0] *= st->cueGain * st->phones; cue[1] *= st->cueGain * st->phones;
        for (UInt32 c = 0; c < channels; ++c) {
            float *out = (float *)output->mBuffers[c].mData;
            if (!out) continue;
            float value = 0;
            // Web Audio's speaker down-mix: mono is the mean of left and right.
            // Split only folds while a deck is on CUE: until then it is the stereo master.
            if (mode == DEX_ROUTE_SPLIT) {
                float side = c == 0 ? 0.5f * (m[0] + m[1]) : c == 1 ? 0.5f * (cue[0] + cue[1]) : 0;
                value = c < 2 ? m[c] + st->folded * (side - m[c]) : 0;
            } else value = c < 2 ? m[c] : c < 4 ? cue[c - 2] : 0;
            out[f] = value;
        }
    }
}
