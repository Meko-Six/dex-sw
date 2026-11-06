#ifndef DEX_ENGINE_STRETCH_H
#define DEX_ENGINE_STRETCH_H
// What the deck asks of a key-locked voice. Each implementation knows exactly which source
// position is leaving it, so nothing has to allow for a measured delay.
#include "DexEngine.h"
#include "Source.h"

namespace dex {

class StretchVoice {
public:
    virtual ~StretchVoice() {}
    /// Forgets everything and gets ready so the next frame rendered is feed index 0. All the
    /// audio it needs comes from the feed at once, so it costs CPU, not time.
    virtual void land(Feed &feed, double speed) = 0;
    /// Produces `count` frames at `speed` feed frames per output frame.
    virtual void render(Feed &feed, float *left, float *right, int count, double speed) = 0;
    /// The feed index of the next frame to be rendered. It describes what leaves the stretcher.
    virtual double position() const = 0;
    /// Feed frames it may read before or after its position. For checking a target is ready.
    virtual int readBehind() const = 0;
    virtual int readAhead() const = 0;
    virtual void facts(DexStretcherFacts *facts) const = 0;
    virtual const char *name() const = 0;
};

StretchVoice *makeBungeeVoice(double sampleRate);

}  // namespace dex
#endif
