#ifndef DEX_ENGINE_LIMITER_H
#define DEX_ENGINE_LIMITER_H
// The master limiter, as a plain call in the loop. A textbook look-ahead design: the gain each
// frame needs is held for the look-ahead, then smoothed over the same length, so it has reached
// that gain by the time the peak comes out of the delay. Under full scale it does nothing but
// delay. The look-ahead is known exactly and published, so nothing has to guess at it.
#include <algorithm>
#include <cmath>
#include <vector>

namespace dex {

class Limiter {
public:
    void configure(double rate) {
        length = std::max(8, (int)std::lround(0.002 * rate));
        delayLine[0].assign((size_t)length, 0);
        delayLine[1].assign((size_t)length, 0);
        needed.assign((size_t)length + 1, 1);
        smoothing.assign((size_t)length, 1);
        release = 1 - std::exp(-1 / (0.1 * rate));
        at = minAt = smoothAt = 0;
        smoothSum = length;
        held = 1;
    }
    int delay() const { return length; }
    /// Forgets what's in the delay and any gain reduction. No allocation.
    void reset() {
        std::fill(delayLine[0].begin(), delayLine[0].end(), 0.0f);
        std::fill(delayLine[1].begin(), delayLine[1].end(), 0.0f);
        std::fill(needed.begin(), needed.end(), 1.0f);
        std::fill(smoothing.begin(), smoothing.end(), 1.0f);
        at = minAt = smoothAt = overCountdown = 0;
        smoothSum = length;
        held = 1;
    }

    void process(float *left, float *right, int frames) {
        const int holdLength = length + 1;
        for (int k = 0; k < frames; ++k) {
            const float peak = std::max(std::fabs(left[k]), std::fabs(right[k]));
            needed[(size_t)minAt] = peak > ceiling ? ceiling / peak : 1.0f;
            minAt = minAt + 1 == holdLength ? 0 : minAt + 1;
            // The tightest gain anywhere in the window. A plain scan: the window is short and
            // this only has work to do while the signal is over full scale.
            float lowest = 1;
            if (peak > ceiling || overCountdown > 0) {
                for (int i = 0; i < holdLength; ++i) lowest = std::min(lowest, needed[(size_t)i]);
                overCountdown = peak > ceiling ? holdLength : overCountdown - 1;
            }
            held = lowest < held ? lowest : held + (lowest - held) * (float)release;
            if (1 - held < 1e-6f) held = 1;
            smoothSum += (double)held - smoothing[(size_t)smoothAt];
            smoothing[(size_t)smoothAt] = held;
            smoothAt = smoothAt + 1 == length ? 0 : smoothAt + 1;
            const float gain = held == 1 && smoothSum > length - 1e-3 ? (float)(smoothSum = length, 1.0) : (float)(smoothSum / length);
            const float outLeft = delayLine[0][(size_t)at], outRight = delayLine[1][(size_t)at];
            delayLine[0][(size_t)at] = left[k];
            delayLine[1][(size_t)at] = right[k];
            at = at + 1 == length ? 0 : at + 1;
            left[k] = outLeft * gain;
            right[k] = outRight * gain;
        }
    }

private:
    static constexpr float ceiling = 0.99f;
    int length = 96, at = 0, minAt = 0, smoothAt = 0, overCountdown = 0;
    float held = 1;
    double release = 0, smoothSum = 96;
    std::vector<float> delayLine[2], needed, smoothing;
};

}  // namespace dex
#endif
