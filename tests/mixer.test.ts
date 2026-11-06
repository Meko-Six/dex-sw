import { describe, expect, it } from 'vitest'
import { faderDb, faderGain, formatDb, linkedLow, lowSumDb, type LowChannel } from '../src/shared/mixer'

const full: LowChannel = { low: 1, lowKill: false, level: 1, trimDb: 0 }

describe('fader law', () => {
  it('hits the printed marks', () => {
    expect(faderDb(1)).toBe(0)
    expect(faderDb(0.8)).toBeCloseTo(-3, 6)
    expect(faderDb(0.6)).toBeCloseTo(-6, 6)
    expect(faderDb(0.4)).toBeCloseTo(-12, 6)
    expect(faderDb(0.2)).toBeCloseTo(-24, 6)
    expect(faderDb(0.03)).toBeCloseTo(-48, 6)
  })

  it('interpolates between marks and falls to silence at the foot', () => {
    expect(faderDb(0.7)).toBeCloseTo(-4.5, 6)
    expect(faderDb(0.01)).toBeLessThan(-48)
    expect(faderDb(0)).toBe(Number.NEGATIVE_INFINITY)
    expect(faderGain(0)).toBe(0)
    expect(faderGain(1)).toBe(1)
  })

  it('never rises as the fader comes down', () => {
    let previous = Number.POSITIVE_INFINITY
    for (let p = 1; p >= 0; p -= 0.01) {
      const db = faderDb(p)
      expect(db).toBeLessThanOrEqual(previous)
      previous = db
    }
  })

  it('formats dB the way the readouts print it', () => {
    expect(formatDb(0)).toBe('0.0')
    expect(formatDb(-3)).toBe('−3.0')
    expect(formatDb(1.44)).toBe('+1.4')
    expect(formatDb(Number.NEGATIVE_INFINITY)).toBe('−∞')
  })
})

describe('LOW Σ', () => {
  it('reads 0 dB for one full low alone and about +3 dB for two in the middle', () => {
    expect(lowSumDb(full, { ...full, lowKill: true }, 0)).toBeCloseTo(0, 6)
    expect(lowSumDb(full, full, 0.5)).toBeCloseTo(3.01, 2)
  })

  it('drops when one low is cut, and is silent when both are killed', () => {
    const cut = lowSumDb(full, { ...full, low: 0.4 }, 0.5)
    expect(cut).toBeLessThan(lowSumDb(full, full, 0.5))
    expect(lowSumDb({ ...full, lowKill: true }, { ...full, lowKill: true }, 0.5)).toBe(Number.NEGATIVE_INFINITY)
  })

  it('counts trim and LEVEL', () => {
    expect(lowSumDb({ ...full, trimDb: 6 }, { ...full, lowKill: true }, 0)).toBeCloseTo(6, 6)
    expect(lowSumDb({ ...full, level: 0.6 }, { ...full, lowKill: true }, 0)).toBeCloseTo(-6, 6)
  })
})

describe('LINK LOWS', () => {
  it('moves the other low the opposite way, within the travel', () => {
    expect(linkedLow(0.2, -0.3)).toBeCloseTo(0.5, 9)
    expect(linkedLow(0.9, -0.3)).toBe(1)
    expect(linkedLow(0.1, 0.3)).toBe(0)
  })
})
