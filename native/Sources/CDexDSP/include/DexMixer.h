#ifndef DEX_MIXER_H
#define DEX_MIXER_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>

// The deck's three-band isolator (src/shared/isolator.ts): Linkwitz-Riley
// 24 dB/oct crossovers split LOW / MID / HIGH, each band gets a gain and the
// bands are summed, so unity is flat and a band at 0 is gone. The input trim
// runs first, as Electron's trim node does. Controls are single-writer atomics;
// the audio thread smooths towards them as Web Audio's setTargetAtTime does.
// With all three bands at unity the signal bypasses them, so flat is untouched.
// The one-knob sweep (FilterSetting) follows the bands: a resonant low-pass for
// knobs below 0, a resonant high-pass above, and out of the signal at 0.
typedef struct DexIsolatorState DexIsolatorState;
DexIsolatorState *dex_isolator_create(double sampleRate, double lowHz, double highHz, double lowPassFlat, double lowPassFloor,
                                      double highPassFloor, double highPassCeiling);
void dex_isolator_destroy(DexIsolatorState *state);
void dex_isolator_set(DexIsolatorState *state, float low, float mid, float high, float trim);
void dex_isolator_set_sweep(DexIsolatorState *state, float knob);
// Jump to the targets with no glide (a new graph, or a test's measurement).
void dex_isolator_snap(DexIsolatorState *state);
/// Clears the filters' history at the start of the next block. Any thread; the controls stay.
void dex_isolator_reset(DexIsolatorState *state);
void dex_isolator_process(DexIsolatorState *state, UInt32 frames, AudioBufferList *audio);

// The tone section's output for the cue bus, handed over within one render cycle:
// the isolator writes its block, then the router's cue input reads it, once.
typedef struct DexCueTap DexCueTap;
DexCueTap *dex_cue_tap_create(UInt32 maximumFrames);
void dex_cue_tap_destroy(DexCueTap *tap);
void dex_cue_tap_write(DexCueTap *tap, UInt32 frames, const AudioBufferList *audio);
/// Forgets the waiting block, so the next read is silence and never old audio.
void dex_cue_tap_reset(DexCueTap *tap);
// Silence unless a block of exactly `frames` is waiting.
void dex_cue_tap_read(DexCueTap *tap, UInt32 frames, AudioBufferList *audio);

// The output router (src/renderer/audio/routing.ts). Input 0 is the master,
// inputs 1 and 2 are the decks' pre-fader taps. The cue bus is the tapped decks
// blended with the master by the cue mix. SPLIT plays the stereo master until a
// deck is on CUE, then a mono master on the left and a mono cue on the right; 4-CH puts the master on 1/2 and the cue on 3/4.
// A peak guard holds the cue bus at full scale, which it only reaches when hot.
enum { DEX_ROUTE_SPLIT = 0, DEX_ROUTE_MULTICHANNEL = 1 };
typedef struct DexRouterState DexRouterState;
DexRouterState *dex_router_create(double sampleRate, UInt32 maximumFrames);
void dex_router_destroy(DexRouterState *state);
void dex_router_set(DexRouterState *state, int mode, float cueMix, float cueA, float cueB);
void dex_router_snap(DexRouterState *state);
/// Clears the cue's peak guard at the start of the next block. Any thread; the controls stay.
void dex_router_reset(DexRouterState *state);
void dex_router_count_pull_failure(DexRouterState *state, int bus);
/// How many pulls of `bus` have failed. Any thread.
UInt32 dex_router_pull_failures(DexRouterState *state, int bus);
// A two-channel scratch list for one input, sized for `frames`, to pull into.
AudioBufferList *dex_router_input(DexRouterState *state, int bus, UInt32 frames);
// Gives any output channel the host left without memory a scratch buffer.
void dex_router_prepare_output(DexRouterState *state, UInt32 frames, AudioBufferList *output);
// Mixes the pulled inputs into `output`, which may carry any channel count.
void dex_router_process(DexRouterState *state, UInt32 frames, const bool *pulled, AudioBufferList *output);
#endif
