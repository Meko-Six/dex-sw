#ifndef DEX_ENGINE_H
#define DEX_ENGINE_H
// One audio loop owns everything audible. The device (or a test) asks for a block of
// output through dex_engine_render, and that one call produces it for both decks, the
// master and the cue. Everything else talks to it through bounded lock-free structures:
// commands in, published state out. See docs/ENGINE-REBUILD-SPEC.md.
//
// Threads:
//   render      dex_engine_render only. No allocation, locks, logging, file access or
//               Swift runtime work happens under it (EngineRealtimeTests checks).
//   control     one thread: every other call here, except where noted.
//   loader      a background thread the engine owns (or dex_engine_pump_loader in tests).
//               It calls DexTrackSource.read and nothing else outside the engine.
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DexEngine DexEngine;

typedef struct {
    double sampleRate;          // the output's rate
    uint32_t maxFrames;         // the largest block render will be asked for; larger ones are split
    uint32_t chunkFrames;       // frames in one cache chunk (a power of two); 0 means 65536
    uint32_t chunksPerDeck;     // how many chunks each deck may hold; 0 means 64
    bool loaderThread;          // false: nothing is read until dex_engine_pump_loader (offline tests)
    double hostTicksPerSecond;  // converts the host times given to render; 0 means mach_absolute_time's
} DexEngineConfig;

/// How late the output runs on the decks, for the limiter's look-ahead. It never changes.
uint32_t dex_engine_delay_frames(DexEngine *engine);
/// Bytes the engine allocates up front for audio data, for AudioMemoryBudget.
uint64_t dex_engine_required_bytes(const DexEngineConfig *config);
DexEngine *dex_engine_create(const DexEngineConfig *config);
void dex_engine_destroy(DexEngine *engine);

// MARK: The loop

/// Produces `frames` of output on each of `channels` buffers. `hostTime` is when the first
/// frame leaves the engine for the device.
void dex_engine_render(DexEngine *engine, uint32_t frames, uint64_t hostTime, float *const *outputs, uint32_t channels);
/// The same, also copying each deck's signal (after tone, before its fader) into tapA / tapB,
/// each two buffers of `frames` or NULL. For tests and offline clips.
void dex_engine_render_tapped(DexEngine *engine, uint32_t frames, uint64_t hostTime, float *const *outputs, uint32_t channels,
                              float *const *tapA, float *const *tapB);

/// The same, from a device's render callback: the time stamp gives the host time, and a jump in
/// its sample time is counted as a gap in the output. Real-time safe, with no Swift in it.
void dex_engine_render_list(DexEngine *engine, uint32_t frames, const AudioTimeStamp *time, AudioBufferList *output);
/// For offline rendering, before the first block: time follows the time stamp's sample time,
/// because there's no device running a host clock, and nothing is read until
/// dex_engine_pump_loader, because the loader thread is stopped for good.
void dex_engine_go_offline(DexEngine *engine);

// MARK: Audio data

/// Fills `left` and `right` with `count` frames from `frame`, returns how many it wrote. The
/// frames past that count are silence. Called on the loader thread only.
typedef uint32_t (*DexSourceRead)(void *context, int64_t frame, uint32_t count, float *left, float *right);
typedef struct {
    void *context;
    DexSourceRead read;
    void (*release)(void *context);  // optional; on the loader or control thread, once nothing can read it
    int64_t frames;
    double sampleRate;
} DexTrackSource;

/// What the deck should keep ready: absolute source frames (main cue, hot cues, loop points).
void dex_engine_set_hotspots(DexEngine *engine, int deck, const double *frames, uint32_t count);
/// What the deck should keep ready relative to the playhead, in source frames (bar-jump targets).
void dex_engine_set_reach(DexEngine *engine, int deck, const double *offsets, uint32_t count);
/// Runs the loader on this thread until it has nothing to do. Offline tests only.
void dex_engine_pump_loader(DexEngine *engine);
/// Lets a test run the loader in single steps: decodes at most one chunk. False when idle.
bool dex_engine_pump_loader_once(DexEngine *engine);
/// Whether a source position could be landed on right now. Control thread, for planning.
bool dex_engine_is_ready(DexEngine *engine, int deck, double frame);

// MARK: Commands
// Each returns a sequence number that the loop confirms in DexEngineState.confirmedCommand,
// or 0 when the queue is full (the command was not sent).

typedef enum {
    DEX_LATE_SLIDE = 0,   // land as soon as possible, on the source frame that keeps it in time
    DEX_LATE_HOLD = 1,    // land as soon as possible, on the source frame asked for
    DEX_LATE_PERIOD = 2,  // keep the source frame and wait whole periods, so the attack stays whole
} DexLatePolicy;

typedef struct {
    double position;       // the source frame heard at `atFrame`
    int64_t atFrame;       // the output frame to land on; negative means as soon as possible
    bool fadeEndsAtLanding;  // the 10 ms fade finishes at atFrame, so an attack there is whole
    DexLatePolicy late;
    double latePeriodFrames; // output frames, for DEX_LATE_PERIOD
    bool alignToMaster;    // a locked deck: move the target to the master's beat phase at atFrame
    bool setLoop;          // install the loop below with the jump, as one change
    bool loopActive;
    double loopIn, loopOut;
} DexJump;

uint64_t dex_engine_load(DexEngine *engine, int deck, const DexTrackSource *source, double position);
uint64_t dex_engine_unload(DexEngine *engine, int deck);
uint64_t dex_engine_play(DexEngine *engine, int deck, const DexJump *from); // from NULL: the parked position, at once
uint64_t dex_engine_pause(DexEngine *engine, int deck, int64_t atFrame);
/// Stops at once on this source frame with no fade, for an output that has stopped or is about
/// to: nothing from before may sound when it comes back.
uint64_t dex_engine_park(DexEngine *engine, int deck, double position);
/// Forgets everything still ringing in the tone sections, the limiter and the cue guard.
uint64_t dex_engine_clear_tails(DexEngine *engine);
uint64_t dex_engine_jump(DexEngine *engine, int deck, const DexJump *jump);
uint64_t dex_engine_set_tempo(DexEngine *engine, int deck, double tempo);
uint64_t dex_engine_set_key_lock(DexEngine *engine, int deck, bool on);
uint64_t dex_engine_set_loop(DexEngine *engine, int deck, bool active, double loopIn, double loopOut);
uint64_t dex_engine_set_grid(DexEngine *engine, int deck, double firstBeatFrame, double framesPerBeat);
uint64_t dex_engine_set_sync(DexEngine *engine, int deck, bool locked);
uint64_t dex_engine_set_master(DexEngine *engine, int deck); // -1: no master
uint64_t dex_engine_set_preview(DexEngine *engine, int deck, bool holding); // a held CUE: never a lock reference
/// Enters or leaves the audible scrub. Leaving resumes the deck if it was playing.
uint64_t dex_engine_scrub(DexEngine *engine, int deck, bool on);
/// While scrubbing: the source speed to play at, in source seconds per second (±8), with an
/// optional decay for a coast (per second; 0 holds the speed).
uint64_t dex_engine_scrub_velocity(DexEngine *engine, int deck, double sourceSecondsPerSecond, double damping);

// MARK: Levels
// Atomics, not commands: last write wins, and the loop glides to them.
void dex_engine_set_fader(DexEngine *engine, int deck, float level, float crossfadeGain);
void dex_engine_set_volume(DexEngine *engine, float volume);
void dex_engine_set_tone(DexEngine *engine, int deck, float low, float mid, float high, float trim);
void dex_engine_set_sweep(DexEngine *engine, int deck, float knob);
void dex_engine_set_route(DexEngine *engine, int mode, float cueMix, float cueA, float cueB);
/// Jumps all levels to their targets with no glide. Before the first block, or in a test.
void dex_engine_snap_levels(DexEngine *engine);

// MARK: Published state
// Each block publishes this without locks. Readers on one thread only.

typedef struct {
    double position;       // source frame leaving the deck at the first frame of the block
    double positionEnd;    // source frame due at the first frame of the next block
    double speed;          // real source frames per output frame, as played in this block
    double tempo;          // the speed asked for, after any lock, 1 is the track's own speed
    double steer;          // the lock's correction on top of tempo, as a fraction
    double phaseErrorMs;   // follower against master, as measured in this block
    bool loaded, playing, scrubbing, keyLock, syncLocked, isMaster, loopActive, landingPending, ended, waitingForData;
    double loopIn, loopOut;
    int64_t lastLandingFrame;  // the output frame of the last landing
    double lastLandingPosition;
    uint64_t landings;         // every landing, including loop wraps
    uint64_t lateLandings;     // landings that could not make their frame, because data or a fade held them up
    uint64_t waitedBlocks;     // blocks a landing spent waiting for data, with the outgoing audio still playing
    uint64_t starvedBlocks;    // blocks the playhead itself had no data: the only way to a gap
    uint64_t relocks;          // a follower re-landed on the master's grid
    uint64_t chunksResident;   // audio chunks in memory for this deck
} DexDeckState;

typedef struct {
    uint64_t outputFrame;      // the first output frame of the block
    uint32_t blockFrames;
    uint64_t hostTime;         // when that frame leaves the engine
    double sampleRate;
    uint32_t engineDelayFrames; // the master limiter's look-ahead: the output runs this late on the decks
    uint64_t confirmedCommand;
    float masterPeak;          // peak of the master after the limiter in this block
    float masterRms;           // RMS of the master after the limiter in this block
    uint64_t outputGaps;       // times the device's sample time jumped: audio that never went out
    uint64_t renderTicks;      // host ticks spent in render so far, for measuring CPU
    uint64_t worstRenderTicks; // the longest single render so far
    DexDeckState deck[2];
} DexEngineState;

/// Copies the newest published block. False if nothing has been rendered yet.
bool dex_engine_read_state(DexEngine *engine, DexEngineState *state);
/// Where a deck is at `hostNow` less `delaySeconds`, extrapolated from the block in `state`.
/// Stops advancing soon after the last block, so a stalled engine freezes the display.
double dex_engine_position_at(const DexEngineState *state, int deck, uint64_t hostNow, double hostTicksPerSecond, double delaySeconds);

// MARK: Stretcher facts, for measurement

typedef struct {
    int32_t inputLatencyFrames;   // read ahead of the time being processed
    int32_t outputLatencyFrames;  // written behind it
    int32_t primingOutputFrames;  // output computed and discarded when landing
    int32_t blockFrames, intervalFrames;
} DexStretcherFacts;
void dex_engine_stretcher_facts(DexEngine *engine, DexStretcherFacts *facts);
const char *dex_engine_stretcher_name(DexEngine *engine);

#ifdef __cplusplus
}
#endif
#endif
