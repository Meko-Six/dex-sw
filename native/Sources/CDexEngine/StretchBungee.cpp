// Bungee Basic (MPL-2.0) behind StretchVoice. It works grain by grain and stamps every output
// chunk with the input positions at its start and end, so its position is reported to us,
// not worked out. Grains don't line up with blocks, so finished frames wait in a small queue.
#include "Stretch.h"
#include "bungee/Bungee.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace dex {
namespace {

class BungeeVoice final : public StretchVoice {
public:
    explicit BungeeVoice(double sampleRate)
        : stretcher(Bungee::SampleRates{(int)sampleRate, (int)sampleRate}, 2) {
        const int input = stretcher.maxInputFrameCount() + 16;
        maxInput = input;
        grainInput.assign((size_t)input * 2, 0);
        queueCapacity = 1 << 15;
        for (auto &q : queue) q.assign((size_t)queueCapacity, 0);
        positions.assign((size_t)queueCapacity, 0);
        request = {};
        request.pitch = 1;
        request.resampleMode = resampleMode_autoOut;
    }

    void land(Feed &feed, double speed) override {
        // Output chunks are stamped with the requests of grains two back, so the ones from this
        // voice's last life have to go first. Empty grains do that, and cost almost nothing.
        Bungee::Request empty = request;
        empty.position = empty.speed = std::numeric_limits<double>::quiet_NaN();
        empty.reset = false;
        for (int guard = 0; guard < 8 && !stretcher.isFlushed(); ++guard) {
            stretcher.specifyGrain(empty, 0.0);
            stretcher.analyseGrain(grainInput.data(), maxInput);
            Bungee::OutputChunk ignored{};
            stretcher.synthesiseGrain(ignored);
        }
        request.position = 0;
        request.speed = speed;
        request.pitch = 1;
        request.reset = false;
        stretcher.preroll(request);
        queued = readIndex = 0;
        heard = 0;
        // Run grains until the queue holds the frame for feed index 0, dropping what's before it.
        for (int guard = 0; guard < 16; ++guard) {
            grain(feed, speed);
            dropBeforeZero();
            if (queued > 0) break;
        }
        heard = queued > 0 ? positions[(size_t)readIndex] : 0;
    }

    void render(Feed &feed, float *left, float *right, int count, double speed) override {
        int done = 0;
        while (done < count) {
            if (queued == 0) {
                compact();
                grain(feed, speed);
                if (queued == 0) {  // A grain with no output: keep time with silence.
                    std::fill(left + done, left + done + 1, 0.f);
                    std::fill(right + done, right + done + 1, 0.f);
                    heard += speed;
                    ++done;
                    continue;
                }
            }
            const int run = std::min(count - done, queued);
            std::copy_n(queue[0].data() + readIndex, run, left + done);
            std::copy_n(queue[1].data() + readIndex, run, right + done);
            heard = positions[(size_t)(readIndex + run - 1)] + lastStep;
            readIndex += run;
            queued -= run;
            done += run;
            if (queued > 0) heard = positions[(size_t)readIndex];
        }
    }

    double position() const override { return heard; }
    int readBehind() const override { return maxInput; }
    int readAhead() const override { return maxInput * 2; }
    void facts(DexStretcherFacts *facts) const override {
        facts->inputLatencyFrames = maxInput / 2;
        facts->outputLatencyFrames = 0;
        facts->primingOutputFrames = 0;
        facts->blockFrames = maxInput;
        facts->intervalFrames = hop;
    }
    const char *name() const override { return "Bungee Basic"; }

private:
    void compact() {
        if (readIndex == 0) return;
        for (auto &q : queue) std::copy_n(q.data() + readIndex, queued, q.data());
        std::copy_n(positions.data() + readIndex, queued, positions.data());
        readIndex = 0;
    }

    void grain(Feed &feed, double speed) {
        request.speed = speed;
        const Bungee::InputChunk chunk = stretcher.specifyGrain(request, 0.0);
        const int frames = chunk.end - chunk.begin;
        feed.read(chunk.begin, frames, grainInput.data(), grainInput.data() + maxInput);
        stretcher.analyseGrain(grainInput.data(), maxInput);
        Bungee::OutputChunk output{};
        stretcher.synthesiseGrain(output);
        stretcher.next(request);
        if (output.frameCount <= 0 || !output.request[0] || !output.request[1]) return;
        const double from = output.request[0]->position, to = output.request[1]->position;
        if (std::isnan(from) || std::isnan(to)) return;
        hop = output.frameCount;
        lastStep = (to - from) / output.frameCount;
        int at = readIndex + queued;
        if (at + output.frameCount > queueCapacity) { compact(); at = readIndex + queued; }
        const int room = std::min(output.frameCount, queueCapacity - at);
        std::copy_n(output.data, room, queue[0].data() + at);
        std::copy_n(output.data + output.channelStride, room, queue[1].data() + at);
        for (int k = 0; k < room; ++k) positions[(size_t)(at + k)] = from + k * lastStep;
        queued += room;
    }

    void dropBeforeZero() {
        while (queued > 0 && positions[(size_t)readIndex] < -1e-6) { ++readIndex; --queued; }
    }

    Bungee::Stretcher<Bungee::Basic> stretcher;
    Bungee::Request request{};
    std::vector<float> grainInput, queue[2];
    std::vector<double> positions;
    int maxInput = 0, queueCapacity = 0, queued = 0, readIndex = 0, hop = 0;
    double heard = 0, lastStep = 1;
};

}  // namespace

StretchVoice *makeBungeeVoice(double sampleRate) { return new BungeeVoice(sampleRate); }

}  // namespace dex
