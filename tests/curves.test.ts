import { describe, expect, it } from 'vitest'
import {
  crossfadeGains,
  dbToGain,
  eqDbFromKnob,
  EQ_KILL_DB,
  gainToDb,
  meterScale,
  ratioToSemitones
} from '../src/shared/curves'
import { computePeaks, toMono } from '../src/shared/dsp'

describe('crossfader', () => {
  it('is -3 dB per side at centre', () => {
    const [a, b] = crossfadeGains(0.5)
    expect(gainToDb(a)).toBeCloseTo(-3.01, 1)
    expect(gainToDb(b)).toBeCloseTo(-3.01, 1)
  })

  it('is fully open/closed at the ends', () => {
    expect(crossfadeGains(0)[0]).toBeCloseTo(1, 6)
    expect(crossfadeGains(0)[1]).toBeCloseTo(0, 6)
    expect(crossfadeGains(1)[1]).toBeCloseTo(1, 6)
    expect(crossfadeGains(1)[0]).toBeCloseTo(0, 6)
  })

  it('keeps constant power across the travel', () => {
    for (let x = 0; x <= 1; x += 0.05) {
      const [a, b] = crossfadeGains(x)
      expect(a * a + b * b).toBeCloseTo(1, 6)
    }
  })

  it('clamps out-of-range positions', () => {
    expect(crossfadeGains(-5)).toEqual(crossfadeGains(0))
    expect(crossfadeGains(5)).toEqual(crossfadeGains(1))
  })
})

describe('EQ law', () => {
  it('is unity at centre', () => {
    expect(eqDbFromKnob(0)).toBe(0)
  })

  it('kills at full left', () => {
    expect(eqDbFromKnob(-1)).toBe(EQ_KILL_DB)
  })

  it('is monotonic and bounded on the right', () => {
    let last = -Infinity
    for (let v = -1; v <= 1; v += 0.01) {
      const db = eqDbFromKnob(v)
      expect(db).toBeGreaterThanOrEqual(last - 1e-9)
      expect(db).toBeLessThanOrEqual(6)
      last = db
    }
  })

  it('converts dB and gain consistently', () => {
    expect(dbToGain(0)).toBeCloseTo(1, 9)
    expect(dbToGain(-6)).toBeCloseTo(0.501, 2)
    expect(gainToDb(dbToGain(-12))).toBeCloseTo(-12, 6)
  })
})

describe('meter and pitch helpers', () => {
  it('maps -60…0 dB to 0…1', () => {
    expect(meterScale(-60)).toBe(0)
    expect(meterScale(0)).toBe(1)
    expect(meterScale(-30)).toBeCloseTo(0.5, 6)
  })

  it('converts playback ratios to semitones', () => {
    expect(ratioToSemitones(1)).toBeCloseTo(0, 9)
    expect(ratioToSemitones(2)).toBeCloseTo(12, 6)
  })
})

describe('waveform peaks and mono downmix', () => {
  it('produces min/max pairs that bracket the signal', () => {
    const left = new Float32Array(1024)
    const right = new Float32Array(1024)
    for (let i = 0; i < 1024; i++) {
      left[i] = Math.sin((i / 1024) * Math.PI * 8) * 0.8
      right[i] = Math.cos((i / 1024) * Math.PI * 4) * 0.4
    }
    const peaks = computePeaks([left, right], 64)
    expect(peaks.bins.length).toBe(128)
    expect(peaks.binSize).toBe(16)
    let maxSeen = -1
    let minSeen = 1
    for (let i = 0; i < peaks.bins.length; i += 2) {
      minSeen = Math.min(minSeen, peaks.bins[i] / 127)
      maxSeen = Math.max(maxSeen, peaks.bins[i + 1] / 127)
    }
    expect(maxSeen).toBeGreaterThan(0.7)
    expect(minSeen).toBeLessThan(-0.7)
  })

  it('downmixes without touching the input', () => {
    const left = new Float32Array([1, 1, 1])
    const right = new Float32Array([0, 0, 0])
    const mono = toMono([left, right])
    expect(Array.from(mono)).toEqual([0.5, 0.5, 0.5])
    expect(Array.from(left)).toEqual([1, 1, 1])
  })
})
