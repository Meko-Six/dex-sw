// The resampler: a Kaiser-windowed sinc, read at any speed in either direction. Key lock off
// and scrubbing play through this, and a file at another sample rate comes through it on its way
// to the stretcher. The kernel is centred on the position, so it adds no delay.
#include "Source.h"
#include <algorithm>
#include <cmath>
#include <mutex>

namespace dex {

namespace {

constexpr int kPhases = 512;
constexpr int kTaps = kResampleHalfWidth * 2;
// A Kaiser-windowed sinc. |x| from 0 to the half width, in steps of 1 / kPhases.
float gFine[kResampleHalfWidth * kPhases + 2];
// The same, as ready-to-use rows: phase p is the kernel for a position p / kPhases past a frame.
float gRows[kPhases + 1][kTaps];
std::once_flag gKernelOnce;

double besselI0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 64; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

void buildKernel() {
    const double beta = 9.0, denominator = besselI0(beta);
    const int entries = kResampleHalfWidth * kPhases + 2;
    for (int i = 0; i < entries; ++i) {
        double x = (double)i / kPhases;
        double normal = x / kResampleHalfWidth;
        double window = normal < 1 ? besselI0(beta * std::sqrt(1 - normal * normal)) / denominator : 0;
        double sinc = x == 0 ? 1 : std::sin(M_PI * x) / (M_PI * x);
        gFine[i] = (float)(sinc * window);
    }
    for (int p = 0; p <= kPhases; ++p) {
        double fraction = (double)p / kPhases;
        for (int t = 0; t < kTaps; ++t) {
            double x = std::fabs((double)(t - kResampleHalfWidth + 1) - fraction);
            int i = (int)(x * kPhases + 0.5);
            gRows[p][t] = i < entries ? gFine[i] : 0;
        }
    }
}

inline float fineKernel(double x) {
    double index = x * kPhases;
    int i = (int)index;
    if (i >= kResampleHalfWidth * kPhases) return 0;
    float a = (float)(index - i);
    return gFine[i] + a * (gFine[i + 1] - gFine[i]);
}

}  // namespace

void prepareResampler() { std::call_once(gKernelOnce, buildKernel); }

bool resampleRead(const Track &track, double start, double step, int count, float *left, float *right,
                  float *const *scratch, int scratchFrames) {
    if (count <= 0) return true;
    const double magnitude = std::fabs(step);
    const double widen = magnitude > 1 ? magnitude : 1;
    const int half = (int)std::ceil(kResampleHalfWidth * widen) + 1;
    const double end = start + step * (count - 1);
    const int64_t first = (int64_t)std::floor(std::min(start, end)) - half;
    const int64_t last = (int64_t)std::ceil(std::max(start, end)) + half;
    const int64_t span = last - first + 1;
    if (span > scratchFrames) {
        int part = count / 2;
        if (part == 0) {  // A single frame wider than the scratch can't happen at any allowed speed.
            std::memset(left, 0, sizeof(float) * (size_t)count);
            std::memset(right, 0, sizeof(float) * (size_t)count);
            return true;
        }
        bool a = resampleRead(track, start, step, part, left, right, scratch, scratchFrames);
        bool b = resampleRead(track, start + step * part, step, count - part, left + part, right + part, scratch, scratchFrames);
        return a && b;
    }
    const bool complete = track.read(first, (int)span, scratch[0], scratch[1]);
    const float *sourceL = scratch[0], *sourceR = scratch[1];
    if (magnitude <= 1) {
        for (int k = 0; k < count; ++k) {
            const double position = start + step * k - (double)first;
            const int whole = (int)std::floor(position);
            const double phase = (position - whole) * kPhases;
            const int p = (int)phase;
            const float a = (float)(phase - p);
            const float *r0 = gRows[p], *r1 = gRows[p + 1];
            const float *inL = sourceL + whole - kResampleHalfWidth + 1, *inR = sourceR + whole - kResampleHalfWidth + 1;
            float sumL = 0, sumR = 0;
            for (int t = 0; t < kTaps; ++t) {
                const float c = r0[t] + a * (r1[t] - r0[t]);
                sumL += c * inL[t];
                sumR += c * inR[t];
            }
            left[k] = sumL;
            right[k] = sumR;
        }
    } else {
        // Faster than the source: the kernel widens by the speed, so its cutoff follows it down.
        const double scale = 1 / widen;
        const int reach = (int)std::floor(kResampleHalfWidth * widen);
        for (int k = 0; k < count; ++k) {
            const double position = start + step * k - (double)first;
            const int whole = (int)std::floor(position);
            const double fraction = position - whole;
            float sumL = 0, sumR = 0;
            for (int t = -reach + 1; t <= reach; ++t) {
                const float c = fineKernel(std::fabs((double)t - fraction) * scale);
                sumL += c * sourceL[whole + t];
                sumR += c * sourceR[whole + t];
            }
            left[k] = sumL * (float)scale;
            right[k] = sumR * (float)scale;
        }
    }
    return complete;
}

}  // namespace dex
