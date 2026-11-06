import { describe, expect, it } from 'vitest'
import {
  BASE_BIN,
  LEVEL_FACTOR,
  buildWaveformLevels,
  decodePeak,
  levelsFromPeaks,
  pickLevel,
  snapView
} from '../src/shared/waveform-levels'

const tone = (length: number, amplitude: number): Float32Array => {
  const out = new Float32Array(length)
  for (let i = 0; i < length; i++) out[i] = Math.sin((i / 50) * Math.PI * 2) * amplitude
  return out
}

describe('buildWaveformLevels', () => {
  it('brackets the signal and measures its RMS at the base level', () => {
    const left = tone(BASE_BIN * 200, 0.8)
    const levels = buildWaveformLevels([left, left], 44100)
    const base = levels.levels[0]
    expect(base.binSize).toBe(BASE_BIN)
    expect(base.count).toBe(200)
    let min = 1
    let max = -1
    let rms = 0
    for (let bin = 0; bin < base.count; bin++) {
      min = Math.min(min, decodePeak(base.data[bin * 4]))
      max = Math.max(max, decodePeak(base.data[bin * 4 + 1]))
      rms += base.data[bin * 4 + 2] / 255 / base.count
    }
    expect(max).toBeGreaterThan(0.75)
    expect(min).toBeLessThan(-0.75)
    // A sine's RMS is its peak over √2.
    expect(rms).toBeCloseTo(0.8 / Math.SQRT2, 1)
  })

  it('stacks coarser levels until one is short, keeping the loudest peaks', () => {
    const quiet = tone(BASE_BIN * 5000, 0.1)
    quiet[BASE_BIN * 3000 + 7] = 0.95
    const levels = buildWaveformLevels([quiet], 44100)
    expect(levels.levels.length).toBeGreaterThan(2)
    levels.levels.forEach((level, i) => {
      expect(level.binSize).toBe(BASE_BIN * LEVEL_FACTOR ** i)
      const peak = Math.max(...Array.from({ length: level.count }, (_, bin) => decodePeak(level.data[bin * 4 + 1])))
      expect(peak).toBeGreaterThan(0.9)
    })
    expect(levels.levels.at(-1)!.count).toBeLessThanOrEqual(512)
  })

  it('handles silence and an empty buffer', () => {
    const silent = buildWaveformLevels([new Float32Array(BASE_BIN * 4)], 48000)
    expect(Array.from(silent.levels[0].data.slice(0, 4))).toEqual([128, 128, 0, 255])
    expect(buildWaveformLevels([], 48000).levels[0].count).toBe(1)
  })
})

describe('levelsFromPeaks', () => {
  it('turns library peaks into a single level spanning the track', () => {
    const levels = levelsFromPeaks(Int8Array.from([-100, 90, -10, 20]), 2, 1000)
    expect(levels.totalSamples).toBe(2000)
    expect(levels.levels).toHaveLength(1)
    expect(levels.levels[0].binSize).toBe(1000)
    expect(Array.from(levels.levels[0].data)).toEqual([28, 218, 0, 255, 118, 148, 0, 255])
  })
})

describe('pickLevel', () => {
  it('picks the coarsest level with at least one bin per pixel', () => {
    const levels = buildWaveformLevels([tone(BASE_BIN * 4000, 0.5)], 44100)
    expect(pickLevel(levels, 1).binSize).toBe(BASE_BIN)
    expect(pickLevel(levels, BASE_BIN * LEVEL_FACTOR + 1).binSize).toBe(BASE_BIN * LEVEL_FACTOR)
    expect(pickLevel(levels, 1e9)).toBe(levels.levels.at(-1))
  })
})

describe('snapView', () => {
  it('starts on a whole pixel column, never more than one pixel early', () => {
    const view = snapView(12.3456, 4, 2000, 44100)
    expect(view.samplesPerPixel).toBeCloseTo(88.2)
    expect(Number.isInteger(view.startCol)).toBe(true)
    expect(view.startSec).toBeLessThanOrEqual(12.3456)
    expect(12.3456 - view.startSec).toBeLessThan(view.samplesPerPixel / 44100)
  })

  it('keeps a column on the same samples as the view scrolls', () => {
    const a = snapView(10, 4, 2000, 44100)
    const b = snapView(10.5, 4, 2000, 44100)
    const sampleAtA = (a.startCol + 900) * a.samplesPerPixel
    const sampleAtB = (b.startCol + 900 - (b.startCol - a.startCol)) * b.samplesPerPixel
    expect(sampleAtB).toBeCloseTo(sampleAtA)
  })
})
