import { resampleLinear } from '../src/shared/detector'
import { describe, expect, it } from 'vitest'
import { analyzePower, energyColour, POWER_VERSION, powerAt, validPower } from '../src/shared/power'

const sr = 8000
const grid = { bpm: 120, offsetMs: 0, confidence: 1 }
/** Deterministic musical fixtures: pad, kick pulse, and denser kick/hat rhythm. */
function audio(kind: 'pad' | 'drums' | 'dense', seconds = 12, rate = sr): Float32Array {
  let seed = 1
  return Float32Array.from({ length: seconds * rate }, (_, i) => {
    const t = i / rate
    if (kind === 'pad') return 0.25 * Math.sin(t * 2 * Math.PI * 440)
    seed = (1664525 * seed + 1013904223) >>> 0
    const kickTime = t % 0.5
    const kick = Math.sin(2 * Math.PI * 65 * kickTime) * Math.exp(-kickTime * 28)
    const hatTime = (t + 0.25) % (kind === 'dense' ? 0.125 : 0.5)
    const hat = (seed / 2147483648 - 1) * Math.exp(-hatTime * 75)
    return 0.7 * kick + (kind === 'dense' ? 0.5 : 0.1) * hat
  })
}

describe('musical intensity', () => {
  it('distinguishes sustained, sparse, and dense rhythmic material on a shared scale', () => {
    const pad = analyzePower([audio('pad')], sr, grid)
    const drums = analyzePower([audio('drums')], sr, grid)
    const dense = analyzePower([audio('dense')], sr, grid)
    expect(drums.score).toBeGreaterThan(pad.score + 15)
    expect(dense.score).toBeGreaterThan(drums.score + 5)
  })

  it('is invariant to uniform gain, while LUFS still measures it', () => {
    const original = audio('dense')
    const full = analyzePower([original], sr, grid)
    const quiet = analyzePower([original.map((v) => v * 0.1)], sr, grid)
    expect(quiet.values).toEqual(full.values)
    expect(quiet.score).toBe(full.score)
    expect(quiet.lufs! - full.lufs!).toBeCloseTo(-20, 1)
    expect(full.version).toBe(POWER_VERSION)
  })

  it('preserves breakdown/drop differences rather than normalizing each bar', () => {
    const x = audio('dense', 16)
    for (let i = 4 * sr; i < 8 * sr; i++) x[i] *= 0.1
    const power = analyzePower([x], sr, grid)
    expect(powerAt(power, 5)).toBeLessThan(powerAt(power, 11) * 0.25)
    expect(powerAt(power, 7)).toBeLessThan(powerAt(power, 1) * 0.25)
  })

  it('does not let long silent padding erase a short musical passage', () => {
    const music = audio('dense', 4)
    const padded = new Float32Array(60 * sr)
    padded.set(music, 20 * sr)
    const plain = analyzePower([music], sr, grid)
    const power = analyzePower([padded], sr, grid)
    expect(powerAt(power, 21)).toBeCloseTo(powerAt(plain, 1), 2)
    expect(powerAt(power, 5)).toBe(0)
    expect(powerAt(power, 45)).toBe(0)
  })

  it('averages channel powers, so stereo phase cancellation cannot erase the curve', () => {
    const x = audio('dense')
    const same = analyzePower([x, x], sr, grid)
    const inverted = analyzePower([x, x.map((v) => -v)], sr, grid)
    expect(inverted.values).toEqual(same.values)
    expect(inverted.lufs).toBe(same.lufs)
  })

  it('uses absolute track time with partial bars and different sample rates', () => {
    const shiftedGrid = { ...grid, offsetMs: 500 }
    const a = analyzePower([audio('dense')], sr, shiftedGrid)
    const b = analyzePower([resampleLinear(audio('dense'), sr, 48000)], 48000, shiftedGrid)
    expect(a.startSec).toBe(-1.5)
    expect(a.barSec).toBe(2)
    expect(a.values.length).toBe(7)
    expect(Math.abs(a.score - b.score)).toBeLessThan(7)
    expect(analyzePower([audio('pad')], sr, grid).startSec).toBe(0)
  })

  it('keeps silence, empty and short files finite and JSON safe', () => {
    for (const channels of [[], [new Float32Array(sr)], [new Float32Array(10)]]) {
      const power = analyzePower(channels, sr, grid)
      expect(power.score).toBe(0)
      expect(power.values.every((v) => v === 0)).toBe(true)
      expect(JSON.parse(JSON.stringify(power))).toEqual(power)
      expect(validPower(power, power.durationSec)).toBe(true)
    }
    const short = analyzePower([Float32Array.of(0.1, -0.1)], sr, null)
    expect(short.values.every(Number.isFinite)).toBe(true)
  })

  it('checks cache version, duration and values, and clamps interpolated endpoints', () => {
    const power = analyzePower([audio('drums')], sr, grid)
    expect(validPower(power, 12)).toBe(true)
    expect(validPower({ ...power, version: -1 }, 12)).toBe(false)
    expect(validPower(power, 13)).toBe(false)
    expect(validPower({ ...power, values: [NaN] }, 12)).toBe(false)
    expect(powerAt({ ...power, values: [0.2, 0.8] }, 2)).toBeCloseTo(0.5)
    expect(powerAt(power, -100)).toBe(power.values[0])
    expect(powerAt(power, 1000)).toBe(power.values.at(-1))
    expect(energyColour(-1)).toEqual(energyColour(0))
    expect(energyColour(2)).toEqual(energyColour(1))
  })
})
