#ifndef DEX_ENGINE_SOURCE_H
#define DEX_ENGINE_SOURCE_H
// Audio data for the loop: a fixed pool of chunks, filled by the loader, and a table the
// loop reads without waiting. A missing chunk is never waited for: the reader says so.
#include "DexEngine.h"
#include <atomic>
#include <cstdint>
#include <cstring>

namespace dex {

struct Chunk {
    float *samples[2] = {nullptr, nullptr};
    int64_t index = -1;
    struct Track *owner = nullptr;
    uint64_t lastWanted = 0;
    uint64_t retiredAtSeq = 0;
};

/// One loaded file. The table is allocated before the loop ever sees the track.
struct Track {
    DexTrackSource source{};
    int64_t frames = 0;
    double rate = 48000;
    uint32_t chunkFrames = 65536, chunkShift = 16;
    int64_t chunkCount = 0;
    uint64_t generation = 0;
    std::atomic<Chunk *> *table = nullptr;
    // Loader only:
    uint32_t *wantStamp = nullptr;
    int64_t *retryAt = nullptr;  // per chunk: when a read that failed may be tried again, in ms

    /// Whether every frame of a range could be read. Frames outside the file count as ready:
    /// they are silence.
    bool ready(int64_t first, int64_t count) const {
        if (count <= 0) return true;
        int64_t last = first + count - 1;
        if (first < 0) first = 0;
        if (last >= frames) last = frames - 1;
        if (first > last) return true;
        for (int64_t c = first >> chunkShift; c <= last >> chunkShift; ++c)
            if (!table[c].load(std::memory_order_acquire)) return false;
        return true;
    }

    /// Copies a range, with silence outside the file and in any missing chunk. Returns false
    /// if a chunk was missing. Real-time safe.
    bool read(int64_t first, int count, float *left, float *right) const {
        bool complete = true;
        int done = 0;
        while (done < count) {
            int64_t frame = first + done;
            int run = count - done;
            if (frame < 0) {
                if (-frame < run) run = (int)-frame;
                std::memset(left + done, 0, sizeof(float) * (size_t)run);
                std::memset(right + done, 0, sizeof(float) * (size_t)run);
            } else if (frame >= frames) {
                std::memset(left + done, 0, sizeof(float) * (size_t)run);
                std::memset(right + done, 0, sizeof(float) * (size_t)run);
            } else {
                int64_t c = frame >> chunkShift;
                int64_t offset = frame - (c << chunkShift);
                if ((int64_t)chunkFrames - offset < run) run = (int)((int64_t)chunkFrames - offset);
                if (frames - frame < run) run = (int)(frames - frame);
                const Chunk *chunk = table[c].load(std::memory_order_acquire);
                if (chunk) {
                    std::memcpy(left + done, chunk->samples[0] + offset, sizeof(float) * (size_t)run);
                    std::memcpy(right + done, chunk->samples[1] + offset, sizeof(float) * (size_t)run);
                } else {
                    complete = false;
                    std::memset(left + done, 0, sizeof(float) * (size_t)run);
                    std::memset(right + done, 0, sizeof(float) * (size_t)run);
                }
            }
            done += run;
        }
        return complete;
    }
};

// MARK: Resampling

/// Half the width of the windowed-sinc kernel, in source frames at full bandwidth.
constexpr int kResampleHalfWidth = 24;

/// Builds the kernel tables once. Call off the audio thread before the first render.
void prepareResampler();

/// Writes `count` frames read from the track at source positions start + k * step, for any
/// sign of step, band-limited when faster than the source. `scratch` holds two buffers of
/// `scratchFrames`. Returns false if a chunk it needed was missing. Real-time safe.
bool resampleRead(const Track &track, double start, double step, int count, float *left, float *right,
                  float *const *scratch, int scratchFrames);

/// A stretcher's input: a run of frames at the output's rate, where feed index 0 is source
/// position `origin`. A voice has one for its whole life, so what it reads is contiguous and
/// feed index maps to source position by one straight line, even across a loop: a loop wrap
/// is a landing on a fresh voice, never a splice in a running one.
struct Feed {
    const Track *track = nullptr;
    double origin = 0;
    double ratio = 1;  // source frames per feed frame
    float *const *scratch = nullptr;
    int scratchFrames = 0;
    bool missing = false;

    double sourcePosition(double index) const { return origin + index * ratio; }
    void read(int64_t first, int count, float *left, float *right) {
        bool complete;
        if (ratio == 1.0) complete = track->read((int64_t)origin + first, count, left, right);
        else complete = resampleRead(*track, origin + (double)first * ratio, ratio, count, left, right, scratch, scratchFrames);
        if (!complete) missing = true;
    }
};

// MARK: Loader

class Loader;
Loader *makeLoader(uint32_t chunkFrames, uint32_t chunksPerDeck, bool threaded,
                   std::atomic<uint64_t> *renderSequence, std::atomic<double> *playheads, std::atomic<uint64_t> *appliedGenerations);
void destroyLoader(Loader *);
/// Creates a track and starts preparing it. Control thread.
Track *loaderOpen(Loader *, int deck, const DexTrackSource &source, double position);
/// Stops preparing whatever the deck had and forgets it once the loop has moved on. Control thread.
void loaderClose(Loader *, int deck);
void loaderSetHotspots(Loader *, int deck, const double *frames, uint32_t count);
void loaderSetReach(Loader *, int deck, const double *offsets, uint32_t count);
/// Asks for data around a source position right away, ahead of a jump command.
void loaderHint(Loader *, int deck, double frame);
bool loaderPumpOnce(Loader *);
/// Stops the loader's thread for good, leaving only pumping. Control thread.
void loaderStopThread(Loader *);
uint64_t loaderResident(Loader *, int deck);
/// Reads of the deck's current track that failed. Any thread.
uint64_t loaderReadFailures(Loader *, int deck);

}  // namespace dex
#endif
