// The loader is the only thing that touches a file, and it runs off the audio thread. Chunks come from a pool allocated once, so loading never grows
// memory, and a track longer than the pool plays by keeping only what a DJ can reach.
#include "Source.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

namespace dex {

// MARK: Loader

class Loader {
public:
    Loader(uint32_t chunkFrames, uint32_t chunksPerDeck, bool threaded, std::atomic<uint64_t> *sequence,
           std::atomic<double> *playheads, std::atomic<uint64_t> *applied)
        : chunkFrames(chunkFrames), sequence(sequence), playheads(playheads), applied(applied) {
        chunkShift = 0;
        while ((1u << chunkShift) < chunkFrames) ++chunkShift;
        for (int d = 0; d < 2; ++d) {
            Deck &deck = decks[d];
            deck.chunks.resize(chunksPerDeck);
            for (auto &chunk : deck.chunks) {
                chunk.samples[0] = new float[chunkFrames];
                chunk.samples[1] = new float[chunkFrames];
            }
            for (auto &chunk : deck.chunks) deck.free.push_back(&chunk);
            deck.retired.reserve(chunksPerDeck);
        }
        if (threaded) thread = std::thread([this] { run(); });
    }
    ~Loader() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            quit = true;
        }
        wake.notify_all();
        if (thread.joinable()) thread.join();
        for (auto &deck : decks) {
            for (auto &chunk : deck.chunks) { delete[] chunk.samples[0]; delete[] chunk.samples[1]; }
            if (deck.track) destroy(deck.track);
            for (Track *t : deck.oldTracks) destroy(t);
        }
    }

    Track *open(int d, const DexTrackSource &source, double position) {
        Track *track = new Track();
        track->source = source;
        track->frames = source.frames;
        track->rate = source.sampleRate;
        track->chunkFrames = chunkFrames;
        track->chunkShift = chunkShift;
        track->chunkCount = source.frames <= 0 ? 0 : ((source.frames - 1) >> chunkShift) + 1;
        track->table = new std::atomic<Chunk *>[(size_t)track->chunkCount + 1];
        for (int64_t i = 0; i <= track->chunkCount; ++i) track->table[i].store(nullptr, std::memory_order_relaxed);
        track->wantStamp = new uint32_t[(size_t)track->chunkCount + 1]();
        track->retryAt = new int64_t[(size_t)track->chunkCount + 1]();
        {
            std::lock_guard<std::mutex> lock(mutex);
            Deck &deck = decks[d];
            track->generation = ++deck.generation;
            if (deck.track) deck.oldTracks.push_back(deck.track);
            deck.track = track;
            deck.hint = position;
            deck.hasHint = true;
            deck.hotspots.clear();
            deck.reach.clear();
            deck.readFailures.store(0, std::memory_order_relaxed);
        }
        wake.notify_all();
        return track;
    }

    void close(int d) {
        std::lock_guard<std::mutex> lock(mutex);
        Deck &deck = decks[d];
        ++deck.generation;
        if (deck.track) deck.oldTracks.push_back(deck.track);
        deck.track = nullptr;
        deck.hotspots.clear();
        deck.reach.clear();
    }
    uint64_t latestGeneration(int d) {
        std::lock_guard<std::mutex> lock(mutex);
        return decks[d].generation;
    }

    void setHotspots(int d, const double *frames, uint32_t count) {
        { std::lock_guard<std::mutex> lock(mutex); decks[d].hotspots.assign(frames, frames + count); }
        wake.notify_all();
    }
    void setReach(int d, const double *offsets, uint32_t count) {
        { std::lock_guard<std::mutex> lock(mutex); decks[d].reach.assign(offsets, offsets + count); }
        wake.notify_all();
    }
    void hint(int d, double frame) {
        { std::lock_guard<std::mutex> lock(mutex); decks[d].hint = frame; decks[d].hasHint = true; }
        wake.notify_all();
    }

    void stopThread() {
        { std::lock_guard<std::mutex> lock(mutex); quit = true; }
        wake.notify_all();
        if (thread.joinable()) thread.join();
    }

    bool pumpOnce() {
        std::lock_guard<std::mutex> pumpLock(pumpMutex);
        bool worked = false;
        for (int d = 0; d < 2; ++d) worked = pass(d) || worked;
        return worked;
    }
    uint64_t resident(int d) { return decks[d].residentCount.load(std::memory_order_relaxed); }
    uint64_t readFailures(int d) { return decks[d].readFailures.load(std::memory_order_relaxed); }

private:
    struct Deck {
        std::vector<Chunk> chunks;
        std::vector<Chunk *> free, retired;
        Track *track = nullptr;
        std::vector<Track *> oldTracks;
        std::vector<double> hotspots, reach;
        double hint = 0;
        bool hasHint = false;
        uint64_t generation = 0;
        uint32_t stamp = 0;
        uint64_t clock = 0;
        std::atomic<uint64_t> residentCount{0};
        std::atomic<uint64_t> readFailures{0};
    };

    /// How long a chunk whose read failed is left alone before the next try.
    static constexpr int64_t kRetryMs = 250;
    static int64_t nowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    void destroy(Track *track) {
        if (track->source.release) track->source.release(track->source.context);
        delete[] track->table;
        delete[] track->wantStamp;
        delete[] track->retryAt;
        delete track;
    }

    /// A chunk taken out of the table may still be being read by the render running at that
    /// moment. It can be reused once that render has finished: the sequence is odd during a
    /// render, so any later value means it's over.
    bool safeToReuse(uint64_t seenAt) const {
        if ((seenAt & 1) == 0) return true;
        return sequence->load(std::memory_order_acquire) != seenAt;
    }

    void reclaim(Deck &deck, int d) {
        for (size_t i = 0; i < deck.retired.size();) {
            Chunk *chunk = deck.retired[i];
            if (safeToReuse(chunk->retiredAtSeq)) {
                chunk->owner = nullptr;
                chunk->index = -1;
                deck.free.push_back(chunk);
                deck.retired[i] = deck.retired.back();
                deck.retired.pop_back();
            } else ++i;
        }
        // Old tracks: once the loop has moved past them and no render can still hold them.
        uint64_t appliedGeneration = applied[d].load(std::memory_order_acquire);
        for (size_t i = 0; i < deck.oldTracks.size();) {
            Track *track = deck.oldTracks[i];
            if (track->generation >= appliedGeneration) { ++i; continue; }
            for (auto &chunk : deck.chunks) {
                if (chunk.owner == track && chunk.index >= 0) {
                    track->table[chunk.index].store(nullptr, std::memory_order_release);
                    chunk.retiredAtSeq = sequence->load(std::memory_order_acquire);
                    chunk.index = -2;
                    deck.retired.push_back(&chunk);
                }
            }
            bool stillHeld = false;
            for (Chunk *chunk : deck.retired) if (chunk->owner == track) stillHeld = true;
            if (stillHeld) { ++i; continue; }
            destroy(track);
            deck.oldTracks[i] = deck.oldTracks.back();
            deck.oldTracks.pop_back();
        }
    }

    /// One decode at most, the most urgent thing missing. True if it did anything.
    bool pass(int d) {
        Deck &deck = decks[d];
        Track *track;
        std::vector<int64_t> &wanted = wantedScratch;
        wanted.clear();
        {
            std::lock_guard<std::mutex> lock(mutex);
            reclaim(deck, d);
            track = deck.track;
            if (!track || track->chunkCount == 0) { publishResident(deck); return false; }
            const double seconds = track->rate;
            const double head = playheads[d].load(std::memory_order_relaxed);
            ++deck.stamp;
            // In order of urgency: just ahead of the playhead, the pending jump, a little behind
            // the playhead, then what the DJ can reach by hand, then further ahead.
            addRange(wanted, *track, deck.stamp, head - 0.25 * seconds, head + 4 * seconds);
            if (deck.hasHint) addRange(wanted, *track, deck.stamp, deck.hint - 1.0 * seconds, deck.hint + 4 * seconds);
            addRange(wanted, *track, deck.stamp, head - 2 * seconds, head);
            for (double offset : deck.reach) addRange(wanted, *track, deck.stamp, head + offset - 1.0 * seconds, head + offset + 3 * seconds);
            for (double spot : deck.hotspots) addRange(wanted, *track, deck.stamp, spot - 1.0 * seconds, spot + 3 * seconds);
            addRange(wanted, *track, deck.stamp, head, head + 10 * seconds);
        }
        const size_t capacity = deck.chunks.size();
        size_t considered = std::min(wanted.size(), capacity);
        const int64_t now = nowMs();
        for (size_t i = 0; i < considered; ++i) {
            int64_t index = wanted[i];
            if (track->table[index].load(std::memory_order_relaxed)) continue;
            if (track->retryAt[index] > now) continue;  // Its last read failed: not yet.
            Chunk *chunk = takeChunk(deck, *track);
            if (!chunk) { publishResident(deck); return false; }  // Waiting on a render to finish.
            if (!decode(*track, *chunk, index)) {
                // Audio that couldn't be read is missing, never silence: the chunk goes back
                // unused, so the loop waits for it as for any audio that isn't there yet.
                deck.free.push_back(chunk);
                track->retryAt[index] = now + kRetryMs;
                deck.readFailures.fetch_add(1, std::memory_order_relaxed);
                publishResident(deck);
                return true;
            }
            chunk->owner = track;
            chunk->index = index;
            chunk->lastWanted = ++deck.clock;
            track->table[index].store(chunk, std::memory_order_release);
            publishResident(deck);
            return true;
        }
        publishResident(deck);
        return false;
    }

    void publishResident(Deck &deck) {
        uint64_t count = 0;
        for (const auto &chunk : deck.chunks) if (chunk.index >= 0) ++count;
        deck.residentCount.store(count, std::memory_order_relaxed);
    }

    void addRange(std::vector<int64_t> &wanted, Track &track, uint32_t stamp, double from, double to) {
        int64_t first = std::max<int64_t>(0, (int64_t)std::floor(from)) >> chunkShift;
        int64_t last = std::min<int64_t>(track.frames - 1, (int64_t)std::ceil(to)) >> chunkShift;
        if (last < first) return;
        for (int64_t c = first; c <= last && c < track.chunkCount; ++c) {
            if (track.wantStamp[c] == stamp) continue;
            track.wantStamp[c] = stamp;
            wanted.push_back(c);
        }
    }

    Chunk *takeChunk(Deck &deck, Track &track) {
        if (!deck.free.empty()) {
            Chunk *chunk = deck.free.back();
            deck.free.pop_back();
            return chunk;
        }
        // Nothing free: the longest-unwanted chunk nobody wants now. Refresh what's wanted first.
        Chunk *victim = nullptr;
        for (auto &chunk : deck.chunks) {
            if (chunk.index < 0) continue;
            if (chunk.owner == &track && track.wantStamp[chunk.index] == deck.stamp) continue;
            if (!victim || chunk.lastWanted < victim->lastWanted) victim = &chunk;
        }
        if (!victim) return nullptr;
        victim->owner->table[victim->index].store(nullptr, std::memory_order_release);
        victim->retiredAtSeq = sequence->load(std::memory_order_acquire);
        victim->index = -2;
        deck.retired.push_back(victim);
        reclaim(deck, (int)(&deck - decks));
        if (deck.free.empty()) return nullptr;
        Chunk *chunk = deck.free.back();
        deck.free.pop_back();
        return chunk;
    }

    /// False if the read failed, with the chunk's contents then meaningless.
    bool decode(Track &track, Chunk &chunk, int64_t index) {
        int64_t frame = index << chunkShift;
        uint32_t wanted = (uint32_t)std::min<int64_t>(chunkFrames, track.frames - frame);
        int32_t read = track.source.read ? track.source.read(track.source.context, frame, wanted, chunk.samples[0], chunk.samples[1]) : -1;
        if (read < 0) return false;
        uint32_t got = std::min((uint32_t)read, wanted);
        if (got < chunkFrames) {
            std::memset(chunk.samples[0] + got, 0, sizeof(float) * (chunkFrames - got));
            std::memset(chunk.samples[1] + got, 0, sizeof(float) * (chunkFrames - got));
        }
        return true;
    }

    void run() {
        while (true) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (quit) return;
            }
            if (pumpOnce()) continue;
            std::unique_lock<std::mutex> lock(mutex);
            if (quit) return;
            // The loop can't signal, so the playhead is polled. 4 s are kept ahead of it.
            wake.wait_for(lock, std::chrono::milliseconds(10));
        }
    }

    uint32_t chunkFrames, chunkShift = 16;
    std::atomic<uint64_t> *sequence;
    std::atomic<double> *playheads;
    std::atomic<uint64_t> *applied;
    Deck decks[2];
    std::vector<int64_t> wantedScratch;
    std::mutex mutex, pumpMutex;
    std::condition_variable wake;
    bool quit = false;
    std::thread thread;
};

Loader *makeLoader(uint32_t chunkFrames, uint32_t chunksPerDeck, bool threaded, std::atomic<uint64_t> *sequence,
                   std::atomic<double> *playheads, std::atomic<uint64_t> *applied) {
    return new Loader(chunkFrames, chunksPerDeck, threaded, sequence, playheads, applied);
}
void destroyLoader(Loader *loader) { delete loader; }
Track *loaderOpen(Loader *loader, int deck, const DexTrackSource &source, double position) { return loader->open(deck, source, position); }
void loaderClose(Loader *loader, int deck) { loader->close(deck); }
void loaderSetHotspots(Loader *loader, int deck, const double *frames, uint32_t count) { loader->setHotspots(deck, frames, count); }
void loaderSetReach(Loader *loader, int deck, const double *offsets, uint32_t count) { loader->setReach(deck, offsets, count); }
void loaderHint(Loader *loader, int deck, double frame) { loader->hint(deck, frame); }
bool loaderPumpOnce(Loader *loader) { return loader->pumpOnce(); }
void loaderStopThread(Loader *loader) { loader->stopThread(); }
uint64_t loaderResident(Loader *loader, int deck) { return loader->resident(deck); }
uint64_t loaderReadFailures(Loader *loader, int deck) { return loader->readFailures(deck); }

}  // namespace dex
