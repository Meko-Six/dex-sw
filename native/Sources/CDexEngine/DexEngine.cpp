// The real-time core. dex_engine_render is the one place anything audible happens. Everything
// under it is plain calls on memory set up in dex_engine_create: no allocation, locks, logging,
// file access or Swift. EngineRealtimeTests holds it to that.
//
// Three ideas carry the design:
//
// * A deck's position changes only here, and it is read back from whatever is producing the
//   audio, so it is what was played, never a prediction.
// * Every discontinuity is a landing: a voice is started at a chosen output frame, on a chosen
//   source frame, and a 10 ms fade hands over to it. Seeks, hot cues, bar jumps, loop wraps and
//   changes of key lock all go this way. A file is there to read ahead of the output, so a
//   stretcher can be primed within the block, and a landing has no delay to allow for.
// * A landing that isn't ready waits, with the outgoing audio still playing.
#include "DexEngine.h"
#include "Source.h"
#include "Stretch.h"
#include "Limiter.h"
#include <AudioToolbox/AudioToolbox.h>
extern "C" {
#include "DexMixer.h"
}
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <mach/mach_time.h>
#include <vector>

using namespace dex;

namespace {

constexpr double kFadeSeconds = 0.01;            // agreed: 10 ms on any playing change
constexpr double kScrubLimit = 8.0;              // agreed: ±8 source seconds per second
constexpr double kScrubSmoothSeconds = 0.005;
constexpr int kScrubQuantum = 64;
constexpr double kSteerSeconds = 0.5;            // agreed: how quickly a lock closes a small error
constexpr double kSteerLimit = 0.004;            // agreed: ±0.4%
constexpr double kRelockSeconds = 0.02;          // agreed: more than this is a real jump
constexpr double kRelockInterval = 0.25;
constexpr double kLockTempoRange = 0.16;         // agreed: ±16%
constexpr double kLevelGlideSeconds = 0.005;
constexpr int kCommandSlots = 1024;
constexpr int kScratchFrames = 1 << 17;
constexpr int kReadyMargin = 24000;              // audio past a landing that must be there already

enum CommandType {
    CmdLoad, CmdUnload, CmdPlay, CmdPause, CmdJump, CmdTempo, CmdKeyLock, CmdLoop, CmdGrid,
    CmdSync, CmdMaster, CmdPreview, CmdScrub, CmdScrubVelocity, CmdPark, CmdClearTails,
};

struct Command {
    uint64_t sequence;
    CommandType type;
    int deck;
    DexJump jump;
    bool hasJump;
    double a, b;
    bool flag;
    int64_t frame;
    Track *track;
    uint64_t generation;
};

/// One pending landing. Plain data, owned by the loop.
struct Landing {
    bool active = false;
    double position = 0;
    int64_t frame = -1;       // -1: as soon as possible
    bool fadeEnds = false;    // the fade finishes on `frame`, so an attack there is whole
    DexLatePolicy late = DEX_LATE_SLIDE;
    double period = 0;
    bool align = false;
    bool continuing = false;  // the target is wherever the deck has got to, when it lands
    bool wasLate = false;
    bool setLoop = false, loopActive = false;
    double loopIn = 0, loopOut = 0;
};

struct Slot {
    enum Mode { Idle, Direct, Stretched } mode = Idle;
    double position = 0;      // Direct: the source frame of the next output frame
    double landingError = 0;  // how far short of its target it really landed, under a frame
    Feed feed;
    std::unique_ptr<StretchVoice> stretch;
    double sourcePosition() const {
        return mode == Stretched ? feed.sourcePosition(stretch->position()) : position;
    }
};

struct Deck {
    int index = 0;
    Track *track = nullptr;
    uint64_t generation = 0;
    double ratio = 1;         // source frames per output frame at the track's own speed
    Slot slots[2];
    int active = -1;          // the voice that's coming up or playing
    int outgoing = -1;        // the voice fading away
    int clockSlot = -1;       // the voice whose position is the deck's; -1 means parked
    int64_t handoverFrame = -1;
    int fadeLength = 0, fadePosition = 0;
    double parked = 0;
    Landing pending, wrap;
    int64_t pauseFrame = -1;

    bool playing = false, keyLock = true, syncLocked = false, preview = false, scrubbing = false;
    bool wasPlayingBeforeScrub = false, ended = false, waitingForData = false, scrubFading = false;
    double tempo = 1, effectiveTempo = 1, steer = 0;
    double scrubVelocity = 0, scrubTarget = 0, scrubDamping = 0, scrubGain = 0;
    bool loopActive = false;
    double loopIn = 0, loopOut = 0;
    double firstBeat = 0, framesPerBeat = 0;
    double phaseErrorMs = 0;
    int64_t nextRelock = 0;

    double blockPosition = 0, blockStep = 0;   // as the block began, for the other deck to read
    bool landedThisBlock = false, starved = false, waitedThisBlock = false;

    int64_t lastLandingFrame = -1;
    double lastLandingPosition = 0;
    uint64_t landings = 0, lateLandings = 0, waitedBlocks = 0, starvedBlocks = 0, relocks = 0;

    float *bus[2] = {nullptr, nullptr};
    DexIsolatorState *isolator = nullptr;
    std::atomic<float> levelTarget{1}, crossfadeTarget{1};
    float gain = 1;
    // The cue taps wait out the limiter's look-ahead, so cue and master stay together.
    std::vector<float> cueDelay[2];
    int cueDelayAt = 0;
};

/// Single writer, single reader, neither ever waits: the writer fills a spare and swaps it in.
template <typename T>
class TripleBuffer {
public:
    T &spare() { return slots[writeIndex]; }
    void publish() {
        uint32_t previous = latest.exchange(writeIndex | kFresh, std::memory_order_acq_rel);
        writeIndex = previous & ~kFresh;
    }
    bool read(T &out) {
        if (latest.load(std::memory_order_acquire) & kFresh) {
            uint32_t previous = latest.exchange(readIndex, std::memory_order_acq_rel);
            readIndex = previous & ~kFresh;
            hasRead = true;
        }
        if (!hasRead) return false;
        out = slots[readIndex];
        return true;
    }
private:
    static constexpr uint32_t kFresh = 4;
    T slots[3]{};
    std::atomic<uint32_t> latest{2};
    uint32_t writeIndex = 0, readIndex = 1;
    bool hasRead = false;
};

}  // namespace

struct DexEngine {
    DexEngineConfig config{};
    double rate = 48000;
    int fadeFrames = 480;
    int maxFrames = 4096;
    double levelGlide = 0;

    Deck decks[2];
    int master = -1;
    uint64_t outputFrame = 0;

    // Commands: one producer, the loop consumes.
    std::unique_ptr<Command[]> commands;
    std::atomic<uint32_t> commandRead{0}, commandWrite{0};
    uint64_t nextSequence = 1;
    uint64_t confirmed = 0;

    TripleBuffer<DexEngineState> published;

    std::atomic<uint64_t> renderSequence{0};
    std::atomic<double> playheads[2];
    std::atomic<uint64_t> appliedGeneration[2];
    Loader *loader = nullptr;
    Track *controlTrack[2] = {nullptr, nullptr};
    uint64_t controlGeneration[2] = {0, 0};

    // Scratch for the loop. Single-threaded by nature.
    std::vector<float> scratchStore[2], voiceStore[2], masterStore[2];
    float *scratch[2] = {nullptr, nullptr};
    float *voice[2] = {nullptr, nullptr};
    float *masterBus[2] = {nullptr, nullptr};

    Limiter limiter;
    DexRouterState *router = nullptr;
    std::atomic<float> volumeTarget{1};
    float volume = 1;
    float masterPeak = 0, masterRms = 0;

    // Measuring the loop itself.
    bool sampleClock = false;
    double nextSampleTime = -1;
    uint64_t outputGaps = 0, renderTicks = 0, worstRenderTicks = 0;

    // Rendering

    double feedSpeed(const Deck &d) const { return d.effectiveTempo * (1 + d.steer); }
    double sourceStep(const Deck &d) const { return d.scrubbing || d.scrubFading ? d.scrubVelocity : feedSpeed(d) * d.ratio; }
    double clock(const Deck &d) const { return d.clockSlot >= 0 ? d.slots[d.clockSlot].sourcePosition() : d.parked; }

    static double beatPhase(const Deck &d, double position) {
        double beats = (position - d.firstBeat) / d.framesPerBeat;
        return beats - std::floor(beats);
    }

    /// How far b must move, in beats, to meet the master's phase, the short way round. A loop
    /// under a beat repeats inside the beat, so its grid is that much finer.
    double phaseError(const Deck &m, double masterPosition, const Deck &f, double followerPosition) const {
        double unit = 1;
        if (f.loopActive) unit = std::min(unit, (f.loopOut - f.loopIn) / f.framesPerBeat);
        if (m.loopActive) unit = std::min(unit, (m.loopOut - m.loopIn) / m.framesPerBeat);
        double beats = beatPhase(m, masterPosition) - beatPhase(f, followerPosition);
        return beats - unit * std::round(beats / unit);
    }

    void applyCommands() {
        uint32_t read = commandRead.load(std::memory_order_relaxed);
        const uint32_t write = commandWrite.load(std::memory_order_acquire);
        while (read != write) {
            apply(commands[read % kCommandSlots]);
            confirmed = commands[read % kCommandSlots].sequence;
            ++read;
        }
        commandRead.store(read, std::memory_order_release);
    }

    Landing landingFrom(const DexJump &jump) const {
        Landing l;
        l.active = true;
        l.position = jump.position;
        l.frame = jump.atFrame;
        l.fadeEnds = jump.fadeEndsAtLanding;
        l.late = jump.late;
        l.period = jump.latePeriodFrames;
        l.align = jump.alignToMaster;
        l.setLoop = jump.setLoop;
        l.loopActive = jump.loopActive;
        l.loopIn = jump.loopIn;
        l.loopOut = jump.loopOut;
        if (l.frame < 0) l.frame = (int64_t)outputFrame + (l.fadeEnds ? fadeFrames : 0);
        return l;
    }

    void installLoop(Deck &d, bool active, double in, double out) {
        d.loopActive = active && out > in;
        d.loopIn = in;
        d.loopOut = out;
        d.wrap.active = false;
    }

    void stopVoices(Deck &d) {
        d.slots[0].mode = d.slots[1].mode = Slot::Idle;
        d.active = d.outgoing = d.clockSlot = -1;
        d.fadeLength = d.fadePosition = 0;
        d.handoverFrame = -1;
    }

    void clearTails() {
        limiter.reset();
        for (Deck &d : decks) {
            dex_isolator_reset(d.isolator);
            for (auto &line : d.cueDelay) std::fill(line.begin(), line.end(), 0.0f);
        }
        dex_router_reset(router);
    }

    void apply(const Command &c) {
        if (c.type == CmdMaster) { master = c.deck; return; }
        if (c.type == CmdClearTails) { clearTails(); return; }
        Deck &d = decks[c.deck];
        switch (c.type) {
        case CmdLoad:
            stopVoices(d);
            d.track = c.track;
            d.generation = c.generation;
            d.ratio = c.track ? c.track->rate / rate : 1;
            d.parked = c.a;
            d.playing = d.scrubbing = d.preview = d.ended = d.loopActive = d.waitingForData = false;
            d.pending.active = d.wrap.active = false;
            d.pauseFrame = -1;
            d.scrubFading = false;
            d.framesPerBeat = 0;
            d.phaseErrorMs = d.steer = 0;
            appliedGeneration[d.index].store(c.generation, std::memory_order_release);
            break;
        case CmdUnload:
            stopVoices(d);
            d.track = nullptr;
            d.generation = c.generation;
            d.playing = d.scrubbing = d.preview = d.ended = d.loopActive = d.waitingForData = false;
            d.pending.active = d.wrap.active = false;
            d.pauseFrame = -1;
            d.framesPerBeat = 0;
            appliedGeneration[d.index].store(c.generation, std::memory_order_release);
            break;
        case CmdPlay: {
            if (!d.track) break;
            d.pauseFrame = -1;
            if (c.hasJump) d.pending = landingFrom(c.jump);
            else if (!d.playing) {
                DexJump here{};
                here.position = d.parked;
                here.atFrame = -1;
                d.pending = landingFrom(here);
            }
            d.playing = true;
            d.ended = false;
            break;
        }
        case CmdPark:
            stopVoices(d);
            d.parked = d.track ? std::min((double)d.track->frames, std::max(0.0, c.a)) : 0;
            d.playing = d.scrubbing = d.scrubFading = d.ended = d.waitingForData = false;
            d.pending.active = d.wrap.active = false;
            d.pauseFrame = -1;
            d.steer = 0;
            break;
        case CmdPause:
            if (!d.playing) break;
            d.pending.active = false;
            d.pauseFrame = c.frame < 0 ? (int64_t)outputFrame : c.frame;
            break;
        case CmdJump: {
            if (!d.track) break;
            if (d.playing || d.scrubbing) {
                d.pending = landingFrom(c.jump);
            } else {
                d.parked = std::min((double)d.track->frames, std::max(0.0, c.jump.position));
                d.ended = false;
                ++d.landings;
                d.lastLandingFrame = (int64_t)outputFrame;
                d.lastLandingPosition = d.parked;
                if (c.jump.setLoop) installLoop(d, c.jump.loopActive, c.jump.loopIn, c.jump.loopOut);
            }
            break;
        }
        case CmdTempo: d.tempo = c.a; break;
        case CmdKeyLock:
            if (d.keyLock != c.flag) {
                d.keyLock = c.flag;
                if (d.playing && !d.scrubbing && !d.pending.active && d.clockSlot >= 0) {
                    Landing l;
                    l.active = l.continuing = true;
                    l.frame = (int64_t)outputFrame;
                    d.pending = l;
                }
            }
            break;
        case CmdLoop: installLoop(d, c.flag, c.a, c.b); break;
        case CmdGrid: d.firstBeat = c.a; d.framesPerBeat = c.b; break;
        case CmdSync:
            d.syncLocked = c.flag;
            if (!c.flag) d.steer = 0;
            break;
        case CmdPreview: d.preview = c.flag; break;
        case CmdScrub:
            if (!d.track) break;
            if (c.flag && !d.scrubbing) {
                d.wasPlayingBeforeScrub = d.playing;
                d.scrubVelocity = d.playing ? feedSpeed(d) * d.ratio : 0;
                d.scrubGain = d.playing ? 1 : 0;
                d.scrubTarget = d.scrubVelocity;
                d.scrubDamping = 0;
                d.scrubbing = true;
                d.wrap.active = false;
                d.pauseFrame = -1;
                Landing l;
                l.active = l.continuing = true;
                l.frame = (int64_t)outputFrame;
                d.pending = l;
            } else if (!c.flag && d.scrubbing) {
                d.scrubbing = false;
                d.pending.active = d.wrap.active = false;
                d.playing = d.wasPlayingBeforeScrub;
                if (d.playing) {
                    Landing l;
                    l.active = l.continuing = true;
                    l.frame = (int64_t)outputFrame;
                    d.pending = l;
                } else if (d.clockSlot >= 0) {
                    // The platter stops where it lifts: the clock parks here and now, and what's
                    // still sounding runs out over the fade.
                    d.parked = clock(d);
                    d.clockSlot = -1;
                    d.handoverFrame = -1;
                    d.scrubFading = true;
                    d.pauseFrame = (int64_t)outputFrame;
                }
            }
            break;
        case CmdScrubVelocity:
            d.scrubTarget = std::max(-kScrubLimit, std::min(kScrubLimit, c.a)) * d.ratio;
            d.scrubDamping = c.b;
            break;
        case CmdMaster:
        case CmdClearTails: break;
        }
    }

    /// A locked deck takes the master's tempo and is steered onto its grid, from positions both
    /// read at the same moment. The master is never moved.
    void updateLocks(int frames) {
        for (Deck &f : decks) {
            f.effectiveTempo = f.tempo;
            if (f.index == master || !f.syncLocked || master < 0) { if (f.index == master) f.steer = 0; continue; }
            const Deck &m = decks[master];
            if (!f.track || !m.track || f.framesPerBeat <= 0 || m.framesPerBeat <= 0) { f.steer = 0; continue; }
            const double masterStep = m.tempo * m.ratio;
            const double wanted = masterStep / m.framesPerBeat * f.framesPerBeat / f.ratio;
            if (std::fabs(wanted - 1) > kLockTempoRange) { f.steer = 0; continue; }  // beyond this the grids can't lock
            f.effectiveTempo = wanted;
            if (!f.playing || !m.playing || f.scrubbing || m.scrubbing || m.preview) { f.steer = 0; continue; }
            const double step = wanted * f.ratio;
            const int64_t now = (int64_t)outputFrame;

            // A jump on the master lands with its follower's, if it moves the beat.
            if (m.pending.active && m.pending.frame >= 0 && !m.pending.continuing && !f.pending.active && f.fadeLength == 0) {
                const int64_t start = m.pending.fadeEnds ? m.pending.frame - fadeFrames : m.pending.frame;
                if (start < now + frames) {
                    const double followerAt = clock(f) + step * (double)(m.pending.frame - now);
                    const double beats = phaseError(m, m.pending.position, f, followerAt);
                    if (std::fabs(beats * f.framesPerBeat / (step * rate)) > kRelockSeconds) {
                        Landing l;
                        l.active = true;
                        l.position = followerAt + beats * f.framesPerBeat;
                        l.frame = m.pending.frame;
                        l.fadeEnds = m.pending.fadeEnds;
                        f.pending = l;
                        f.steer = 0;
                        ++f.relocks;
                        f.nextRelock = now + (int64_t)(kRelockInterval * rate);
                    }
                }
            }
            if (f.pending.active || f.wrap.active || f.fadeLength > 0 || m.fadeLength > 0 || m.pending.active) continue;
            if (f.clockSlot < 0 || m.clockSlot < 0) continue;
            const double beats = phaseError(m, clock(m), f, clock(f));
            const double seconds = beats * f.framesPerBeat / (step * rate);
            f.phaseErrorMs = seconds * 1000;
            if (std::fabs(seconds) > kRelockSeconds) {
                f.steer = 0;
                if (now >= f.nextRelock) {
                    f.nextRelock = now + (int64_t)(kRelockInterval * rate);
                    ++f.relocks;
                    Landing l;
                    l.active = true;
                    l.frame = now;
                    // Aim for where the master will be when the voice is up: `now` is this block.
                    l.position = clock(f) + beats * f.framesPerBeat;
                    f.pending = l;
                }
                continue;
            }
            f.steer = std::max(-kSteerLimit, std::min(kSteerLimit, seconds / kSteerSeconds));
        }
    }

    bool landingReady(const Deck &d, double position, bool stretched) const {
        const int behind = stretched ? d.slots[0].stretch->readBehind() : kResampleHalfWidth;
        const int ahead = stretched ? d.slots[0].stretch->readAhead() : kResampleHalfWidth;
        const double ratio = std::max(1.0, d.ratio);
        return d.track->ready((int64_t)std::floor(position - (behind + fadeFrames) * ratio),
                              (int64_t)((behind + fadeFrames + ahead + kReadyMargin) * ratio));
    }

    /// Where a deck will be at an output frame this block or soon after, allowing for a landing
    /// of its own that's due, or that started in this block's render already.
    double masterPositionAt(const Deck &m, int64_t frame) const {
        const double step = m.blockStep;
        if (m.pending.active && m.pending.frame >= 0) return m.pending.position + step * (double)(frame - m.pending.frame);
        if (m.landedThisBlock || m.lastLandingFrame >= (int64_t)outputFrame)
            return m.lastLandingPosition + step * (double)(frame - m.lastLandingFrame);
        return m.blockPosition + step * (double)(frame - (int64_t)outputFrame);
    }

    /// Starts a landing if its time has come. Returns true if it started.
    bool tryLand(Deck &d, Landing &l, int64_t now) {
        if (!l.active || !d.track) return false;
        if (d.fadeLength > 0) return false;  // a fade is running: this queues behind it
        const double step = sourceStep(d);
        int64_t frame = l.frame < 0 ? now + (l.fadeEnds ? fadeFrames : 0) : l.frame;
        int64_t start = l.fadeEnds ? frame - fadeFrames : frame;
        if (start > now) return false;
        if (start < now) {
            const int64_t behind = now - start;
            l.wasLate = true;
            switch (l.late) {
            case DEX_LATE_SLIDE: l.position += (double)behind * step; frame += behind; break;
            case DEX_LATE_HOLD: frame += behind; break;
            case DEX_LATE_PERIOD: {
                const double period = l.period > 0 ? l.period : (double)behind;
                const int64_t skips = (int64_t)std::ceil((double)behind / period);
                l.frame = frame + (int64_t)std::llround((double)skips * period);
                return false;
            }
            }
            l.frame = frame;
            start = now;
        }
        const int fade = fadeFrames;
        double target = l.continuing ? clock(d) + (l.fadeEnds ? fade * step : 0) : l.position;
        if (l.align && d.syncLocked && master >= 0 && master != d.index) {
            const Deck &m = decks[master];
            if (m.playing && !m.scrubbing && !m.preview && m.track && m.framesPerBeat > 0 && d.framesPerBeat > 0)
                target += phaseError(m, masterPositionAt(m, frame), d, target) * d.framesPerBeat;
        }
        const bool stretched = d.keyLock && !d.scrubbing;
        const double voiceStart = target - (l.fadeEnds ? fade * step : 0);
        if (!landingReady(d, voiceStart, stretched)) {
            l.wasLate = true;
            if (!d.waitedThisBlock) { d.waitedThisBlock = true; ++d.waitedBlocks; }
            return false;
        }

        const int previous = d.active;
        const int incoming = previous >= 0 ? 1 - previous : (d.outgoing >= 0 ? 1 - d.outgoing : 0);
        Slot &s = d.slots[incoming];
        if (stretched) {
            s.mode = Slot::Stretched;
            s.feed.track = d.track;
            s.feed.ratio = d.ratio;
            // At the same rate the feed copies whole frames, so it starts on one. The position
            // follows what was fed, so nothing is lost by it.
            s.feed.origin = d.ratio == 1.0 ? std::round(voiceStart) : voiceStart;
            s.feed.scratch = scratch;
            s.feed.scratchFrames = kScratchFrames;
            s.feed.missing = false;
            s.stretch->land(s.feed, feedSpeed(d));
            s.feed.missing = false;
            s.landingError = voiceStart - s.sourcePosition();
        } else {
            s.mode = Slot::Direct;
            s.position = voiceStart;
            s.landingError = 0;
        }
        d.outgoing = previous;
        d.active = incoming;
        d.fadeLength = fade;
        d.fadePosition = 0;
        if (previous >= 0 && d.clockSlot >= 0) {
            d.handoverFrame = frame;
        } else {
            d.clockSlot = incoming;
            d.handoverFrame = -1;
        }
        d.waitingForData = false;
        d.landedThisBlock = true;
        d.lastLandingFrame = frame;
        d.lastLandingPosition = target;
        ++d.landings;
        if (l.wasLate) ++d.lateLandings;
        if (l.setLoop) installLoop(d, l.loopActive, l.loopIn, l.loopOut);
        l.active = false;
        return true;
    }

    void scheduleWrap(Deck &d, int64_t now, int remaining) {
        if (!d.loopActive || !d.playing || d.scrubbing || d.wrap.active || d.clockSlot < 0 || d.fadeLength > 0) return;
        const double step = sourceStep(d);
        if (step <= 0) return;
        // A loop's timing runs from where each pass was meant to start, or a fraction of a frame
        // lost at each landing would build into drift over hundreds of short passes.
        const double position = clock(d) + d.slots[d.clockSlot].landingError;
        const double length = d.loopOut - d.loopIn;
        if (position >= d.loopOut) {  // Folded back in at once: the playhead was past the loop.
            d.wrap = Landing();
            d.wrap.active = true;
            d.wrap.frame = now;
            d.wrap.position = d.loopIn + std::fmod(position - d.loopIn, length);
            return;
        }
        if (position < d.loopIn - (double)fadeFrames * step * 2) return;  // Not in the loop yet.
        const double exact = (double)now + (d.loopOut - position) / step;
        const int64_t frame = (int64_t)std::ceil(exact);
        if (frame - fadeFrames >= now + remaining) return;
        if (d.pending.active && d.pending.frame >= 0) {
            const int64_t start = d.pending.fadeEnds ? d.pending.frame - fadeFrames : d.pending.frame;
            if (start <= frame - fadeFrames) return;  // The user's jump gets there first.
        }
        d.wrap = Landing();
        d.wrap.active = true;
        d.wrap.frame = frame;
        d.wrap.fadeEnds = true;
        d.wrap.position = d.loopIn + ((double)frame - exact) * step;
    }

    void startFadeOut(Deck &d) {
        if (d.active < 0) return;
        d.outgoing = d.active;
        d.active = -1;
        d.fadeLength = fadeFrames;
        d.fadePosition = 0;
    }

    void serviceEvents(Deck &d, int64_t now, int remaining) {
        if (d.handoverFrame >= 0 && now >= d.handoverFrame) {
            d.clockSlot = d.active;
            d.handoverFrame = -1;
        }
        if (d.pauseFrame >= 0 && now >= d.pauseFrame && d.fadeLength == 0) {
            d.pauseFrame = -1;
            d.playing = false;
            d.scrubbing = false;
            d.pending.active = d.wrap.active = false;
            if (d.clockSlot < 0 && !d.scrubFading) d.clockSlot = d.active;
            startFadeOut(d);
        }
        scheduleWrap(d, now, remaining);
        // Whichever is due first goes first; a fade from one holds the other back.
        if (d.wrap.active && d.pending.active && d.pending.frame >= 0 && d.pending.frame < d.wrap.frame) {
            if (tryLand(d, d.pending, now)) d.wrap.active = false;
            else tryLand(d, d.wrap, now);
        } else if (d.wrap.active) {
            tryLand(d, d.wrap, now);
            if (!d.wrap.active) tryLand(d, d.pending, now);
        } else if (tryLand(d, d.pending, now)) {
            d.wrap.active = false;
        }
    }

    int framesToNextEvent(const Deck &d, int64_t now, int remaining) const {
        int frames = remaining;
        const auto limit = [&](int64_t at) {
            if (at > now && at - now < frames) frames = (int)(at - now);
        };
        if (d.handoverFrame >= 0) limit(d.handoverFrame);
        if (d.pauseFrame >= 0) limit(d.pauseFrame);
        if (d.fadeLength > 0) limit(now + (d.fadeLength - d.fadePosition));
        const auto landingStart = [&](const Landing &l) {
            if (l.active && l.frame >= 0) limit(l.fadeEnds ? l.frame - fadeFrames : l.frame);
        };
        landingStart(d.pending);
        landingStart(d.wrap);
        if (d.scrubbing && frames > kScrubQuantum) frames = kScrubQuantum;
        return frames;
    }

    void renderSlot(Deck &d, Slot &s, float *left, float *right, int frames) {
        if (s.mode == Slot::Stretched) {
            s.stretch->render(s.feed, left, right, frames, feedSpeed(d));
            if (s.feed.missing) { d.starved = true; s.feed.missing = false; }
            return;
        }
        const double step = sourceStep(d);
        bool complete;
        if (step == 1.0 && s.position == std::floor(s.position)) complete = d.track->read((int64_t)s.position, frames, left, right);
        else complete = resampleRead(*d.track, s.position, step, frames, left, right, scratch, kScratchFrames);
        s.position += step * frames;
        if (d.scrubbing || d.scrubFading) {
            const double end = (double)d.track->frames;
            if (s.position < 0) { s.position = 0; d.scrubVelocity = d.scrubTarget = 0; }
            if (s.position > end) { s.position = end; d.scrubVelocity = d.scrubTarget = 0; }
        }
        if (!complete && (d.playing || d.scrubbing)) d.starved = true;
    }

    void renderSegment(Deck &d, int offset, int frames) {
        float *left = d.bus[0] + offset, *right = d.bus[1] + offset;
        std::memset(left, 0, sizeof(float) * (size_t)frames);
        std::memset(right, 0, sizeof(float) * (size_t)frames);
        const float startScrubGain = (float)d.scrubGain;
        const bool scrubSound = d.scrubbing || d.scrubFading;
        if (d.scrubbing) {
            const double seconds = frames / rate;
            d.scrubTarget *= std::exp(-d.scrubDamping * seconds);
            d.scrubVelocity += (d.scrubTarget - d.scrubVelocity) * (1 - std::exp(-seconds / kScrubSmoothSeconds));
            // A still platter is silent, and never leaves a level standing on the output.
            d.scrubGain = std::min(1.0, std::fabs(d.scrubVelocity) / 0.02);
        }
        const int order[2] = {d.outgoing, d.active};
        for (int which = 0; which < 2; ++which) {
            const int index = order[which];
            if (index < 0 || d.slots[index].mode == Slot::Idle) continue;
            renderSlot(d, d.slots[index], voice[0], voice[1], frames);
            if (d.fadeLength > 0) {
                for (int k = 0; k < frames; ++k) {
                    const float t = (float)(d.fadePosition + k + 1) / (float)d.fadeLength;
                    const float g = index == d.active ? t : 1 - t;
                    left[k] += voice[0][k] * g;
                    right[k] += voice[1][k] * g;
                }
            } else {
                for (int k = 0; k < frames; ++k) { left[k] += voice[0][k]; right[k] += voice[1][k]; }
            }
        }
        if (scrubSound) {
            const float end = (float)d.scrubGain;
            for (int k = 0; k < frames; ++k) {
                const float g = startScrubGain + (end - startScrubGain) * (float)(k + 1) / (float)frames;
                left[k] *= g;
                right[k] *= g;
            }
        }
        if (d.fadeLength > 0) {
            d.fadePosition += frames;
            if (d.fadePosition >= d.fadeLength) {
                const bool stopping = d.active < 0;
                if (stopping && d.clockSlot >= 0) { d.parked = d.slots[d.clockSlot].sourcePosition(); d.clockSlot = -1; }
                if (stopping) d.scrubFading = false;
                // A fade that ends on its landing hands the clock over now, before the voice goes,
                // even if that's on the last frame of a block.
                if (!stopping && d.handoverFrame >= 0) { d.clockSlot = d.active; d.handoverFrame = -1; }
                if (d.outgoing >= 0) d.slots[d.outgoing].mode = Slot::Idle;
                d.outgoing = -1;
                d.fadeLength = d.fadePosition = 0;
            }
        }
    }

    void renderDeck(Deck &d, int frames) {
        d.landedThisBlock = d.waitedThisBlock = false;
        d.starved = false;
        if (!d.track) {
            std::memset(d.bus[0], 0, sizeof(float) * (size_t)frames);
            std::memset(d.bus[1], 0, sizeof(float) * (size_t)frames);
            return;
        }
        int offset = 0;
        while (offset < frames) {
            const int64_t now = (int64_t)outputFrame + offset;
            serviceEvents(d, now, frames - offset);
            const int run = framesToNextEvent(d, now, frames - offset);
            renderSegment(d, offset, run);
            offset += run;
        }
        // The end of the track.
        if (d.playing && !d.scrubbing && d.clockSlot >= 0 && clock(d) >= (double)d.track->frames) {
            d.parked = (double)d.track->frames;
            stopVoices(d);
            d.playing = false;
            d.ended = true;
            d.pending.active = d.wrap.active = false;
        }
        // No data under the playhead: the one way to a gap. Hold the position and come back.
        if (d.starved && d.playing && !d.pending.active && d.clockSlot >= 0) {
            ++d.starvedBlocks;
            d.waitingForData = true;
            d.parked = clock(d);
            d.clockSlot = -1;
            d.handoverFrame = -1;
            d.wrap.active = false;
            startFadeOut(d);
            Landing l;
            l.active = true;
            l.position = d.parked;
            l.frame = -1;
            l.late = DEX_LATE_HOLD;
            l.wasLate = true;
            d.pending = l;
        }
    }

    /// Where effects will go: each deck's signal before its tone section, with what they need
    /// to follow the music. Nothing runs here yet.
    void runDeckInserts(Deck &, int) {}

    void publish(int frames, uint64_t hostTime) {
        DexEngineState &state = published.spare();
        state.outputFrame = outputFrame;
        state.blockFrames = (uint32_t)frames;
        state.hostTime = hostTime;
        state.sampleRate = rate;
        state.engineDelayFrames = (uint32_t)limiter.delay();
        state.confirmedCommand = confirmed;
        state.masterPeak = masterPeak;
        state.masterRms = masterRms;
        state.outputGaps = outputGaps;
        state.renderTicks = renderTicks;
        state.worstRenderTicks = worstRenderTicks;
        for (int i = 0; i < 2; ++i) {
            const Deck &d = decks[i];
            DexDeckState &out = state.deck[i];
            const double end = clock(d);
            out.position = d.blockPosition;
            out.positionEnd = end;
            out.speed = d.landedThisBlock ? d.blockStep : (end - d.blockPosition) / frames;
            out.tempo = d.effectiveTempo;
            out.steer = d.steer;
            out.phaseErrorMs = d.phaseErrorMs;
            out.loaded = d.track != nullptr;
            out.playing = d.playing;
            out.scrubbing = d.scrubbing;
            out.keyLock = d.keyLock;
            out.syncLocked = d.syncLocked;
            out.isMaster = master == i;
            out.loopActive = d.loopActive;
            out.landingPending = d.pending.active;
            out.ended = d.ended;
            out.waitingForData = d.waitingForData;
            out.loopIn = d.loopIn;
            out.loopOut = d.loopOut;
            out.lastLandingFrame = d.lastLandingFrame;
            out.lastLandingPosition = d.lastLandingPosition;
            out.landings = d.landings;
            out.lateLandings = d.lateLandings;
            out.waitedBlocks = d.waitedBlocks;
            out.starvedBlocks = d.starvedBlocks;
            out.relocks = d.relocks;
            out.chunksResident = loaderResident(loader, i);
        }
        published.publish();
    }

    void renderBlock(int frames, uint64_t hostTime, float *const *outputs, uint32_t channels, int outputOffset,
                     float *const *tapA, float *const *tapB) {
        renderSequence.fetch_add(1, std::memory_order_acq_rel);  // odd: chunks in use
        applyCommands();
        updateLocks(frames);
        for (Deck &d : decks) {
            d.blockPosition = clock(d);
            d.blockStep = d.playing || d.scrubbing ? sourceStep(d) : 0;
            playheads[d.index].store(d.blockPosition, std::memory_order_relaxed);
        }
        for (Deck &d : decks) {
            renderDeck(d, frames);
            runDeckInserts(d, frames);
        }

        std::memset(masterBus[0], 0, sizeof(float) * (size_t)frames);
        std::memset(masterBus[1], 0, sizeof(float) * (size_t)frames);
        for (Deck &d : decks) {
            AudioBufferList2 list;
            list.count = 2;
            list.buffers[0] = {1, (UInt32)(frames * sizeof(float)), d.bus[0]};
            list.buffers[1] = {1, (UInt32)(frames * sizeof(float)), d.bus[1]};
            dex_isolator_process(d.isolator, (UInt32)frames, reinterpret_cast<AudioBufferList *>(&list));
            float *const *tap = d.index == 0 ? tapA : tapB;
            if (tap) {
                std::memcpy(tap[0] + outputOffset, d.bus[0], sizeof(float) * (size_t)frames);
                std::memcpy(tap[1] + outputOffset, d.bus[1], sizeof(float) * (size_t)frames);
            }
            const float target = d.levelTarget.load(std::memory_order_relaxed) * d.crossfadeTarget.load(std::memory_order_relaxed);
            float gain = d.gain;
            const float glide = (float)levelGlide;
            for (int k = 0; k < frames; ++k) {
                gain += (target - gain) * glide;
                masterBus[0][k] += d.bus[0][k] * gain;
                masterBus[1][k] += d.bus[1][k] * gain;
            }
            d.gain = std::fabs(target - gain) < 1e-5f ? target : gain;
        }
        {
            const float target = volumeTarget.load(std::memory_order_relaxed);
            float gain = volume;
            const float glide = (float)levelGlide;
            for (int k = 0; k < frames; ++k) {
                gain += (target - gain) * glide;
                masterBus[0][k] *= gain;
                masterBus[1][k] *= gain;
            }
            volume = std::fabs(target - gain) < 1e-5f ? target : gain;
        }
        limiter.process(masterBus[0], masterBus[1], frames);
        float peak = 0, power = 0;
        for (int k = 0; k < frames; ++k) {
            peak = std::max(peak, std::max(std::fabs(masterBus[0][k]), std::fabs(masterBus[1][k])));
            power += masterBus[0][k] * masterBus[0][k] + masterBus[1][k] * masterBus[1][k];
        }
        masterPeak = peak;
        masterRms = std::sqrt(power / (float)(2 * frames));

        // The router takes it from here: the same split and 4-channel logic as the old graph.
        AudioBufferList *busMaster = dex_router_input(router, 0, (UInt32)frames);
        std::memcpy(busMaster->mBuffers[0].mData, masterBus[0], sizeof(float) * (size_t)frames);
        std::memcpy(busMaster->mBuffers[1].mData, masterBus[1], sizeof(float) * (size_t)frames);
        for (Deck &d : decks) {
            AudioBufferList *bus = dex_router_input(router, d.index + 1, (UInt32)frames);
            const int delay = limiter.delay();
            for (int c = 0; c < 2; ++c) {
                float *out = (float *)bus->mBuffers[c].mData;
                float *line = d.cueDelay[c].data();
                int at = d.cueDelayAt;
                for (int k = 0; k < frames; ++k) {
                    out[k] = line[at];
                    line[at] = d.bus[c][k];
                    at = at + 1 == delay ? 0 : at + 1;
                }
            }
            d.cueDelayAt = (d.cueDelayAt + frames) % delay;
        }
        const bool pulled[3] = {true, true, true};
        AudioBufferList8 output;
        output.count = channels < 8 ? channels : 8;
        for (UInt32 c = 0; c < output.count; ++c)
            output.buffers[c] = {1, (UInt32)(frames * sizeof(float)), outputs[c] + outputOffset};
        dex_router_process(router, (UInt32)frames, pulled, reinterpret_cast<AudioBufferList *>(&output));

        publish(frames, hostTime);
        outputFrame += (uint64_t)frames;
        renderSequence.fetch_add(1, std::memory_order_acq_rel);  // even: nothing in use
    }

    void renderOffset(uint32_t frames, uint64_t hostTime, float *const *outputs, uint32_t channels) {
        uint32_t done = 0;
        while (done < frames) {
            const uint32_t block = std::min<uint32_t>(frames - done, (uint32_t)maxFrames);
            const uint64_t ticks = (uint64_t)((double)done / rate * config.hostTicksPerSecond);
            renderBlock((int)block, hostTime + ticks, outputs, channels, (int)done, nullptr, nullptr);
            done += block;
        }
    }

    // AudioBufferList with room for its buffers, laid out as the real one is.
    struct AudioBufferList2 { UInt32 count; AudioBuffer buffers[2]; };
    struct AudioBufferList8 { UInt32 count; AudioBuffer buffers[8]; };

    uint64_t send(Command &command) {
        const uint32_t write = commandWrite.load(std::memory_order_relaxed);
        const uint32_t read = commandRead.load(std::memory_order_acquire);
        if (write - read >= kCommandSlots) return 0;
        command.sequence = nextSequence++;
        commands[write % kCommandSlots] = command;
        commandWrite.store(write + 1, std::memory_order_release);
        return command.sequence;
    }
};

static_assert(offsetof(AudioBufferList, mBuffers) == offsetof(DexEngine::AudioBufferList2, buffers), "layout");

// MARK: C API

static DexEngineConfig normalised(const DexEngineConfig *config) {
    DexEngineConfig c = *config;
    if (c.chunkFrames == 0) c.chunkFrames = 65536;
    if (c.chunksPerDeck == 0) c.chunksPerDeck = 64;
    if (c.maxFrames == 0) c.maxFrames = 4096;
    if (c.hostTicksPerSecond <= 0) {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        c.hostTicksPerSecond = 1e9 * (double)info.denom / (double)info.numer;
    }
    return c;
}

uint64_t dex_engine_required_bytes(const DexEngineConfig *config) {
    const DexEngineConfig c = normalised(config);
    return 2ull * c.chunksPerDeck * c.chunkFrames * 2ull * sizeof(float);
}

DexEngine *dex_engine_create(const DexEngineConfig *config) {
    prepareResampler();
    auto engine = std::make_unique<DexEngine>();
    DexEngine &e = *engine;
    e.config = normalised(config);
    e.rate = e.config.sampleRate;
    e.maxFrames = (int)e.config.maxFrames;
    e.fadeFrames = (int)std::lround(kFadeSeconds * e.rate);
    e.levelGlide = 1 - std::exp(-1 / (kLevelGlideSeconds * e.rate));
    e.commands.reset(new Command[kCommandSlots]);
    for (auto &p : e.playheads) p.store(0, std::memory_order_relaxed);
    for (auto &g : e.appliedGeneration) g.store(0, std::memory_order_relaxed);
    for (int c = 0; c < 2; ++c) {
        e.scratchStore[c].assign(kScratchFrames, 0);
        e.scratch[c] = e.scratchStore[c].data();
        e.voiceStore[c].assign((size_t)e.maxFrames, 0);
        e.voice[c] = e.voiceStore[c].data();
        e.masterStore[c].assign((size_t)e.maxFrames, 0);
        e.masterBus[c] = e.masterStore[c].data();
    }
    e.limiter.configure(e.rate);
    e.router = dex_router_create(e.rate, (UInt32)e.maxFrames);
    if (!e.router) return nullptr;
    for (int i = 0; i < 2; ++i) {
        Deck &d = e.decks[i];
        d.index = i;
        for (int v = 0; v < 2; ++v) d.slots[v].stretch.reset(makeBungeeVoice(e.rate));
        for (int c = 0; c < 2; ++c) {
            d.bus[c] = new float[(size_t)e.maxFrames]();
            d.cueDelay[c].assign((size_t)e.limiter.delay(), 0);
        }
        // The isolator's crossovers and the sweep's range, as in DexCore (Isolator, FilterSetting).
        d.isolator = dex_isolator_create(e.rate, 220, 3500, 20000, 120, 20, 9000);
        if (!d.isolator) return nullptr;
    }
    e.loader = makeLoader(e.config.chunkFrames, e.config.chunksPerDeck, e.config.loaderThread,
                          &e.renderSequence, e.playheads, e.appliedGeneration);
    return engine.release();
}

void dex_engine_destroy(DexEngine *engine) {
    if (!engine) return;
    destroyLoader(engine->loader);
    for (Deck &d : engine->decks) {
        delete[] d.bus[0];
        delete[] d.bus[1];
        dex_isolator_destroy(d.isolator);
    }
    dex_router_destroy(engine->router);
    delete engine;
}

void dex_engine_render_tapped(DexEngine *e, uint32_t frames, uint64_t hostTime, float *const *outputs, uint32_t channels,
                              float *const *tapA, float *const *tapB) {
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t block = std::min<uint32_t>(frames - done, (uint32_t)e->maxFrames);
        const uint64_t ticks = (uint64_t)((double)done / e->rate * e->config.hostTicksPerSecond);
        e->renderBlock((int)block, hostTime + ticks, outputs, channels, (int)done, tapA, tapB);
        done += block;
    }
}

void dex_engine_render(DexEngine *e, uint32_t frames, uint64_t hostTime, float *const *outputs, uint32_t channels) {
    dex_engine_render_tapped(e, frames, hostTime, outputs, channels, nullptr, nullptr);
}

void dex_engine_render_list(DexEngine *e, uint32_t frames, const AudioTimeStamp *time, AudioBufferList *output) {
    const uint64_t began = mach_absolute_time();
    uint64_t hostTime = began;
    if (e->sampleClock) hostTime = (uint64_t)(time->mSampleTime / e->rate * e->config.hostTicksPerSecond);
    else if (time->mFlags & kAudioTimeStampHostTimeValid) hostTime = time->mHostTime;
    if (time->mFlags & kAudioTimeStampSampleTimeValid) {
        if (e->nextSampleTime >= 0 && std::fabs(time->mSampleTime - e->nextSampleTime) > 0.5) ++e->outputGaps;
        e->nextSampleTime = time->mSampleTime + frames;
    }
    dex_router_prepare_output(e->router, frames, output);
    float *channels[8];
    const uint32_t count = std::min<uint32_t>(output->mNumberBuffers, 8);
    for (uint32_t c = 0; c < count; ++c) channels[c] = (float *)output->mBuffers[c].mData;
    e->renderOffset(frames, hostTime, channels, count);
    const uint64_t spent = mach_absolute_time() - began;
    e->renderTicks += spent;
    if (spent > e->worstRenderTicks) e->worstRenderTicks = spent;
}

uint32_t dex_engine_delay_frames(DexEngine *e) { return (uint32_t)e->limiter.delay(); }

void dex_engine_go_offline(DexEngine *e) {
    e->sampleClock = true;
    loaderStopThread(e->loader);
}

void dex_engine_set_hotspots(DexEngine *e, int deck, const double *frames, uint32_t count) { loaderSetHotspots(e->loader, deck, frames, count); }
void dex_engine_set_reach(DexEngine *e, int deck, const double *offsets, uint32_t count) { loaderSetReach(e->loader, deck, offsets, count); }
bool dex_engine_pump_loader_once(DexEngine *e) { return loaderPumpOnce(e->loader); }
void dex_engine_pump_loader(DexEngine *e) { while (loaderPumpOnce(e->loader)) {} }

bool dex_engine_is_ready(DexEngine *e, int deck, double frame) {
    Track *track = e->controlTrack[deck];
    if (!track) return false;
    const Deck &d = e->decks[deck];
    const int reach = d.slots[0].stretch->readBehind() + d.slots[0].stretch->readAhead() + kReadyMargin + e->fadeFrames;
    const double ratio = std::max(1.0, track->rate / e->rate);
    return track->ready((int64_t)std::floor(frame - (d.slots[0].stretch->readBehind() + e->fadeFrames) * ratio), (int64_t)(reach * ratio));
}

uint64_t dex_engine_load(DexEngine *e, int deck, const DexTrackSource *source, double position) {
    Track *track = loaderOpen(e->loader, deck, *source, position);
    e->controlTrack[deck] = track;
    Command c{};
    c.type = CmdLoad; c.deck = deck; c.track = track; c.a = position; c.generation = track->generation;
    return e->send(c);
}
uint64_t dex_engine_unload(DexEngine *e, int deck) {
    loaderClose(e->loader, deck);
    e->controlTrack[deck] = nullptr;
    Command c{};
    c.type = CmdUnload; c.deck = deck;
    c.generation = UINT64_MAX;  // Every track loaded so far can go.
    return e->send(c);
}
uint64_t dex_engine_play(DexEngine *e, int deck, const DexJump *from) {
    Command c{};
    c.type = CmdPlay; c.deck = deck;
    if (from) { c.jump = *from; c.hasJump = true; loaderHint(e->loader, deck, from->position); }
    return e->send(c);
}
uint64_t dex_engine_pause(DexEngine *e, int deck, int64_t atFrame) {
    Command c{};
    c.type = CmdPause; c.deck = deck; c.frame = atFrame;
    return e->send(c);
}
uint64_t dex_engine_park(DexEngine *e, int deck, double position) {
    loaderHint(e->loader, deck, position);
    Command c{};
    c.type = CmdPark; c.deck = deck; c.a = position;
    return e->send(c);
}
uint64_t dex_engine_clear_tails(DexEngine *e) {
    Command c{};
    c.type = CmdClearTails;
    return e->send(c);
}
uint64_t dex_engine_jump(DexEngine *e, int deck, const DexJump *jump) {
    loaderHint(e->loader, deck, jump->position);
    Command c{};
    c.type = CmdJump; c.deck = deck; c.jump = *jump; c.hasJump = true;
    return e->send(c);
}
uint64_t dex_engine_set_tempo(DexEngine *e, int deck, double tempo) {
    Command c{};
    c.type = CmdTempo; c.deck = deck; c.a = tempo;
    return e->send(c);
}
uint64_t dex_engine_set_key_lock(DexEngine *e, int deck, bool on) {
    Command c{};
    c.type = CmdKeyLock; c.deck = deck; c.flag = on;
    return e->send(c);
}
uint64_t dex_engine_set_loop(DexEngine *e, int deck, bool active, double loopIn, double loopOut) {
    if (active) loaderHint(e->loader, deck, loopIn);
    Command c{};
    c.type = CmdLoop; c.deck = deck; c.flag = active; c.a = loopIn; c.b = loopOut;
    return e->send(c);
}
uint64_t dex_engine_set_grid(DexEngine *e, int deck, double firstBeatFrame, double framesPerBeat) {
    Command c{};
    c.type = CmdGrid; c.deck = deck; c.a = firstBeatFrame; c.b = framesPerBeat;
    return e->send(c);
}
uint64_t dex_engine_set_sync(DexEngine *e, int deck, bool locked) {
    Command c{};
    c.type = CmdSync; c.deck = deck; c.flag = locked;
    return e->send(c);
}
uint64_t dex_engine_set_master(DexEngine *e, int deck) {
    Command c{};
    c.type = CmdMaster; c.deck = deck;
    return e->send(c);
}
uint64_t dex_engine_set_preview(DexEngine *e, int deck, bool holding) {
    Command c{};
    c.type = CmdPreview; c.deck = deck; c.flag = holding;
    return e->send(c);
}
uint64_t dex_engine_scrub(DexEngine *e, int deck, bool on) {
    Command c{};
    c.type = CmdScrub; c.deck = deck; c.flag = on;
    return e->send(c);
}
uint64_t dex_engine_scrub_velocity(DexEngine *e, int deck, double speed, double damping) {
    Command c{};
    c.type = CmdScrubVelocity; c.deck = deck; c.a = speed; c.b = damping;
    return e->send(c);
}

void dex_engine_set_fader(DexEngine *e, int deck, float level, float crossfadeGain) {
    e->decks[deck].levelTarget.store(level, std::memory_order_relaxed);
    e->decks[deck].crossfadeTarget.store(crossfadeGain, std::memory_order_relaxed);
}
void dex_engine_set_volume(DexEngine *e, float volume) { e->volumeTarget.store(volume, std::memory_order_relaxed); }
void dex_engine_set_tone(DexEngine *e, int deck, float low, float mid, float high, float trim) { dex_isolator_set(e->decks[deck].isolator, low, mid, high, trim); }
void dex_engine_set_sweep(DexEngine *e, int deck, float knob) { dex_isolator_set_sweep(e->decks[deck].isolator, knob); }
void dex_engine_set_route(DexEngine *e, int mode, float cueMix, float cueA, float cueB) { dex_router_set(e->router, mode, cueMix, cueA, cueB); }
void dex_engine_snap_levels(DexEngine *e) {
    for (Deck &d : e->decks) {
        d.gain = d.levelTarget.load(std::memory_order_relaxed) * d.crossfadeTarget.load(std::memory_order_relaxed);
        dex_isolator_snap(d.isolator);
    }
    e->volume = e->volumeTarget.load(std::memory_order_relaxed);
    dex_router_snap(e->router);
}

bool dex_engine_read_state(DexEngine *e, DexEngineState *state) { return e->published.read(*state); }

double dex_engine_position_at(const DexEngineState *state, int deck, uint64_t hostNow, double hostTicksPerSecond, double delaySeconds) {
    const DexDeckState &d = state->deck[deck];
    if (!d.playing && !d.scrubbing) return d.positionEnd;
    double seconds = ((double)hostNow - (double)state->hostTime) / hostTicksPerSecond;
    seconds -= delaySeconds + state->engineDelayFrames / state->sampleRate;
    // An engine that has stalled stops the display: no more than one block and a little past
    // the last block it really played.
    const double limit = state->blockFrames / state->sampleRate + 0.05;
    if (seconds > limit) seconds = limit;
    const double position = d.position + d.speed * seconds * state->sampleRate;
    return position < 0 ? 0 : position;
}

void dex_engine_stretcher_facts(DexEngine *e, DexStretcherFacts *facts) { e->decks[0].slots[0].stretch->facts(facts); }
const char *dex_engine_stretcher_name(DexEngine *e) { return e->decks[0].slots[0].stretch->name(); }
