#ifndef DEX_WAVEFORM_H
#define DEX_WAVEFORM_H
#include <stdint.h>
typedef struct DexWaveformState DexWaveformState;
typedef struct { float peak, rms, low, mid, high; } DexWaveBin;
DexWaveformState *dex_waveform_create(double sampleRate, unsigned channels, int64_t framesPerBin);
void dex_waveform_destroy(DexWaveformState *state);
unsigned dex_waveform_consume(DexWaveformState *state, const float *left, const float *right,
                             unsigned frames, DexWaveBin *bins, unsigned capacity);
unsigned dex_waveform_finish(DexWaveformState *state, DexWaveBin *bin);
#endif
