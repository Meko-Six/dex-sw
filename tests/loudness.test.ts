import { describe, expect, it } from 'vitest'
import { analyzeLoudness, dbToLinear, gainForTarget, integratedLoudness } from '../src/shared/loudness'

const SR = 48_000

function sine(amplitude: number, seconds: number, sampleRate = SR, frequency = 997): Float32Array {
  const length = Math.floor(seconds * sampleRate)
  const out = new Float32Array(length)
  for (let i = 0; i < length; i++) {
    out[i] = Math.sin((2 * Math.PI * frequency * i) / sampleRate) * amplitude
  }
  return out
}

describe('integratedLoudness', () => {
  it('reads a full-scale 997 Hz sine at about -3 LUFS', () => {
    // BS.1770 reference behaviour: a 0 dBFS sine has -3.01 dB RMS, and the
    // K-weighting filter is 0 dB at this frequency.
    const value = integratedLoudness([sine(1, 5)], SR)
    expect(value).toBeGreaterThan(-3.6)
    expect(value).toBeLessThan(-2.4)
  })

  it('agrees with ffmpeg ebur128 on a stereo 0.5-amplitude 997 Hz sine', () => {
    // Reference: `ffmpeg -af ebur128` reports -6.0 LUFS for this exact signal
    // (stereo, both channels at 0.5, peak 0.5). Pinned so a filter or gating
    // regression cannot slip through unnoticed.
    const value = integratedLoudness([sine(0.5, 10), sine(0.5, 10)], SR)
    expect(value).toBeCloseTo(-6.02, 1)
  })

  it('tracks amplitude: halving the level drops 6 LU', () => {
    const loud = integratedLoudness([sine(0.4, 4)], SR)
    const quiet = integratedLoudness([sine(0.2, 4)], SR)
    expect(loud - quiet).toBeGreaterThan(5.8)
    expect(loud - quiet).toBeLessThan(6.3)
  })

  it('sums channels the way the standard expects', () => {
    // Two identical channels read ~3 LU higher than one, because power adds.
    const mono = integratedLoudness([sine(0.3, 4)], SR)
    const stereo = integratedLoudness([sine(0.3, 4), sine(0.3, 4)], SR)
    expect(stereo - mono).toBeGreaterThan(2.7)
    expect(stereo - mono).toBeLessThan(3.3)
  })

  it('returns -Infinity for silence', () => {
    expect(integratedLoudness([new Float32Array(SR * 2)], SR)).toBe(-Infinity)
  })

  it('gates out a quiet passage instead of averaging it in', () => {
    const loud = sine(0.3, 20)
    const quiet = sine(0.003, 10)
    const combined = new Float32Array(loud.length + quiet.length)
    combined.set(loud)
    combined.set(quiet, loud.length)
    const gated = integratedLoudness([combined], SR)
    const loudOnly = integratedLoudness([loud], SR)
    // The -40 LU passage is below the relative gate and must barely move the result.
    expect(Math.abs(gated - loudOnly)).toBeLessThan(1)
  })

  it('resamples other sample rates to the reference rate', () => {
    const value = integratedLoudness([sine(0.5, 4, 44_100)], 44_100)
    const reference = integratedLoudness([sine(0.5, 4, SR)], SR)
    expect(Math.abs(value - reference)).toBeLessThan(0.5)
  })
})

describe('analyzeLoudness', () => {
  it('suggests a gain toward the target and clamps it', () => {
    const report = analyzeLoudness([sine(0.1, 4)], SR, -10)
    expect(report.integratedLufs).toBeCloseTo(-23, 0)
    expect(report.gainDb).toBeGreaterThan(10)
    expect(report.gainDb).toBeLessThanOrEqual(12)
    expect(report.targetLufs).toBe(-10)
  })

  it('reports peak to loudness ratio for a heavily limited master', () => {
    const report = analyzeLoudness([sine(0.99, 4)], SR, -10)
    // A sine has a 3 dB crest factor, so peak-to-loudness is small.
    expect(report.peakToLoudnessDb).toBeLessThan(4)
    expect(report.peakDb).toBeCloseTo(-0.09, 1)
  })

  it('gives no gain for silence', () => {
    const report = analyzeLoudness([new Float32Array(SR)], SR, -10)
    expect(report.gainDb).toBe(0)
    expect(report.integratedLufs).toBe(-Infinity)
  })

  it('converts dB to linear gain', () => {
    expect(dbToLinear(0)).toBe(1)
    expect(dbToLinear(-6)).toBeCloseTo(0.501, 2)
    expect(gainForTarget(-14, -10)).toBe(4)
    expect(gainForTarget(-40, -10)).toBe(12)
  })
})
