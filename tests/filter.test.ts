import { describe, expect, it } from 'vitest'
import {
  FILTER_FLAT_HZ,
  FILTER_HP_CEIL_HZ,
  FILTER_LP_FLOOR_HZ,
  filterSetting
} from '../src/shared/curves'

describe('filterSetting', () => {
  it('is transparent at the centre detent', () => {
    const setting = filterSetting(0)
    expect(setting.type).toBe('lowpass')
    expect(setting.frequency).toBe(FILTER_FLAT_HZ)
    expect(setting.q).toBeCloseTo(0.7, 5)
  })

  it('sweeps a low-pass down as the knob goes left', () => {
    expect(filterSetting(-1)).toMatchObject({ type: 'lowpass', frequency: FILTER_LP_FLOOR_HZ })
    const quarter = filterSetting(-0.25).frequency
    const threeQuarters = filterSetting(-0.75).frequency
    expect(quarter).toBeLessThan(FILTER_FLAT_HZ)
    expect(threeQuarters).toBeLessThan(quarter)
    expect(threeQuarters).toBeGreaterThan(FILTER_LP_FLOOR_HZ)
  })

  it('sweeps a high-pass up as the knob goes right', () => {
    expect(filterSetting(1)).toMatchObject({ type: 'highpass' })
    expect(filterSetting(1).frequency).toBeCloseTo(FILTER_HP_CEIL_HZ, 6)
    const quarter = filterSetting(0.25).frequency
    const threeQuarters = filterSetting(0.75).frequency
    expect(quarter).toBeLessThan(threeQuarters)
    expect(quarter).toBeGreaterThanOrEqual(20)
  })

  it('moves monotonically through the whole sweep', () => {
    let previous = filterSetting(-1).frequency
    for (let step = -0.95; step < 0; step += 0.05) {
      const next = filterSetting(step).frequency
      expect(next).toBeGreaterThan(previous)
      previous = next
    }
    // Crossing the detent swaps filter type; the sweep starts again from 20 Hz.
    expect(filterSetting(0.01).frequency).toBeLessThan(30)
  })

  it('clamps travel beyond the knob range', () => {
    expect(filterSetting(-4)).toEqual(filterSetting(-1))
    expect(filterSetting(4)).toEqual(filterSetting(1))
  })

  it('raises resonance away from the detent', () => {
    expect(filterSetting(-1).q).toBeGreaterThan(filterSetting(-0.2).q)
    expect(filterSetting(1).q).toBeGreaterThan(filterSetting(0.2).q)
  })
})
