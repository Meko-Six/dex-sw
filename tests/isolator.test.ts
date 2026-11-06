import { describe, expect, it } from 'vitest'
import {
  BUTTERWORTH_Q,
  ISO_HIGH_HZ,
  ISO_LOW_HZ,
  isolatorResponseDb,
  isolatorSections,
  webAudioQ
} from '../src/shared/isolator'

const SR = 48000
const UNITY = { low: 1, mid: 1, high: 1 }

/** 200 log-spaced frequencies from 20 Hz to 20 kHz. */
const SWEEP = Array.from({ length: 200 }, (_, i) => 20 * Math.pow(1000, i / 199))

describe('isolator', () => {
  it('sums flat with all three bands at unity', () => {
    for (const hz of SWEEP) {
      expect(Math.abs(isolatorResponseDb(UNITY, hz, SR))).toBeLessThan(0.01)
    }
  })

  it('stays flat at 44.1 kHz too', () => {
    for (const hz of SWEEP) {
      expect(Math.abs(isolatorResponseDb(UNITY, hz, 44100))).toBeLessThan(0.01)
    }
  })

  it('puts each crossover at -6 dB per side, as LR4 should', () => {
    expect(isolatorResponseDb({ low: 1, mid: 0, high: 0 }, ISO_LOW_HZ, SR)).toBeCloseTo(-6.02, 1)
    expect(isolatorResponseDb({ low: 0, mid: 0, high: 1 }, ISO_HIGH_HZ, SR)).toBeCloseTo(-6.02, 1)
  })

  it('kills the low band without touching mid and high', () => {
    const killed = { low: 0, mid: 1, high: 1 }
    expect(isolatorResponseDb(killed, 60, SR)).toBeLessThan(-40)
    expect(isolatorResponseDb(killed, 100, SR)).toBeLessThan(-25)
    for (const hz of [1000, 2000, 8000, 12000]) {
      expect(Math.abs(isolatorResponseDb(killed, hz, SR))).toBeLessThan(0.1)
    }
  })

  it('kills the mid band without touching low and high', () => {
    const killed = { low: 1, mid: 0, high: 1 }
    expect(isolatorResponseDb(killed, 1000, SR)).toBeLessThan(-35)
    for (const hz of [40, 60, 12000, 16000]) {
      expect(Math.abs(isolatorResponseDb(killed, hz, SR))).toBeLessThan(0.1)
    }
  })

  it('kills the high band without touching low and mid', () => {
    const killed = { low: 1, mid: 1, high: 0 }
    expect(isolatorResponseDb(killed, 12000, SR)).toBeLessThan(-45)
    for (const hz of [60, 100, 500, 1000]) {
      expect(Math.abs(isolatorResponseDb(killed, hz, SR))).toBeLessThan(0.1)
    }
  })

  it('applies a band gain inside its band', () => {
    // +6 dB on LOW, −12 dB on HIGH: deep inside each band the response is the gain.
    const gains = { low: 2, mid: 1, high: Math.pow(10, -12 / 20) }
    expect(isolatorResponseDb(gains, 40, SR)).toBeCloseTo(6.02, 0)
    expect(isolatorResponseDb(gains, 16000, SR)).toBeCloseTo(-12, 0)
    expect(Math.abs(isolatorResponseDb(gains, 1000, SR))).toBeLessThan(0.5)
  })

  it('gives Web Audio its Q in dB for low/high-pass and linear for all-pass', () => {
    const sections = isolatorSections()
    for (const section of [...sections.rest, ...sections.mid, ...sections.high, sections.low[0], sections.low[1]]) {
      expect(webAudioQ(section)).toBeCloseTo(20 * Math.log10(BUTTERWORTH_Q), 6)
      expect(webAudioQ(section)).toBeCloseTo(-3.0103, 3)
    }
    const allpass = sections.low[2]
    expect(allpass.type).toBe('allpass')
    expect(webAudioQ(allpass)).toBeCloseTo(BUTTERWORTH_Q, 6)
  })
})
