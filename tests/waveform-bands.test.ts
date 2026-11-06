import { describe, expect, it } from 'vitest'
import { buildBandEnvelopes } from '../src/shared/waveform-bands'
import { buildWaveformLevels } from '../src/shared/waveform-levels'

const rate = 48000
const tone = (hz: number, sampleRate = rate): Float32Array => Float32Array.from({ length: sampleRate }, (_, i) => 0.5 * Math.sin(2 * Math.PI * hz * i / sampleRate))
function means(bytes: Uint8Array): number[] {
  // Ignore filter startup and use steady-state envelopes.
  const values = [0, 0, 0], first = Math.floor(bytes.length / 8 / 4)
  for (let i = first; i < bytes.length / 4; i++) for (let band = 0; band < 3; band++) values[band] += bytes[i * 4 + band] / (bytes.length / 4 - first)
  return values
}

describe('three-band waveform envelopes', () => {
  it.each([[65, 0], [1000, 1], [10000, 2]])('separates a %i Hz tone into band %i', (hz, band) => {
    const m = means(buildBandEnvelopes([tone(hz)], rate, 256, Math.ceil(rate / 256)))
    expect(m[band]).toBeGreaterThan(75)
    for (let b = 0; b < 3; b++) if (b !== band) expect(m[band]).toBeGreaterThan(m[b] * 5)
  })

  it('shows simultaneous bass, mids and highs instead of assigning a dominant color', () => {
    const low = tone(65), mid = tone(1000), high = tone(10000)
    const x = low.map((v, i) => (v + mid[i] + high[i]) / 3)
    const m = means(buildBandEnvelopes([x], rate, 256, Math.ceil(rate / 256)))
    expect(m.every((v) => v > 25)).toBe(true)
  })

  it('preserves timing and silence when short treble attacks are pooled at coarser zooms', () => {
    const x = new Float32Array(rate)
    const attack = tone(10000)
    x.set(attack.subarray(0, 300), rate / 2)
    const levels = buildWaveformLevels([x], rate)
    for (const level of levels.levels) {
      const bands = level.bands!
      const max = Math.max(...Array.from({ length: level.count }, (_, i) => bands[i * 4 + 2]))
      const at = Array.from({ length: level.count }, (_, i) => bands[i * 4 + 2]).indexOf(max)
      expect(max).toBeGreaterThan(0)
      expect(Math.abs(at * level.binSize - rate / 2)).toBeLessThan(level.binSize * 2)
      expect(Array.from(bands.slice(0, Math.floor(rate * 0.4 / level.binSize) * 4)).every((v) => v === 0)).toBe(true)
    }
  })

  it('pools band energy at overview scale instead of preserving a single hot peak', () => {
    const x = new Float32Array(32 * 4096)
    x[x.length / 2] = 1
    const levels = buildWaveformLevels([x], rate).levels
    const peak = (i: number): number => Math.max(...Array.from({ length: levels[i].count }, (_, bin) => levels[i].bands![bin * 4 + 2]))
    expect(peak(0)).toBeGreaterThan(0)
    expect(peak(1)).toBeLessThan(peak(0) * 0.8)
    expect(peak(2)).toBeLessThan(peak(1) * 0.8)
  })

  it('does not cancel opposite-phase stereo or change one channel when duplicated', () => {
    const x = tone(65), inverse = x.map((v) => -v)
    const mono = buildBandEnvelopes([x], rate, 256, Math.ceil(rate / 256))
    expect(buildBandEnvelopes([x, x], rate, 256, Math.ceil(rate / 256))).toEqual(mono)
    expect(buildBandEnvelopes([x, inverse], rate, 256, Math.ceil(rate / 256))).toEqual(mono)
  })

  it('keeps frequency-band levels consistent between 44.1 and 48 kHz', () => {
    for (const hz of [65, 1000, 10000]) {
      const a = means(buildBandEnvelopes([tone(hz, 44100)], 44100, 256, Math.ceil(44100 / 256)))
      const b = means(buildBandEnvelopes([tone(hz)], rate, 256, Math.ceil(rate / 256)))
      a.forEach((v, i) => expect(Math.abs(v - b[i])).toBeLessThan(4))
    }
  })

  it('handles silence, partial final bins, and empty buffers', () => {
    expect(Array.from(buildBandEnvelopes([new Float32Array(35)], rate, 32, 2))).toEqual(new Array(8).fill(0))
    expect(buildBandEnvelopes([], rate, 32, 1)).toEqual(new Uint8Array(4))
    const x = Float32Array.of(0, 0, 0, 0.5)
    const data = buildBandEnvelopes([x], rate, 3, 2)
    expect(data.slice(0, 4)).toEqual(new Uint8Array(4))
    expect(data[6]).toBeGreaterThan(0)
  })
})
