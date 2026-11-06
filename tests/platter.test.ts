import { describe, expect, it } from 'vitest'
import { platterBeatDelta } from '../src/shared/platter'

describe('platter calibration', () => {
  it('moves half a beat for a clockwise quarter-turn and back for its reverse', () => {
    expect(platterBeatDelta(-Math.PI / 2, 0)).toBeCloseTo(0.5)
    expect(platterBeatDelta(0, -Math.PI / 2)).toBeCloseTo(-0.5)
  })

  it('crosses the angular seam without jumping a revolution', () => {
    const radians = (deg: number) => deg * Math.PI / 180
    expect(platterBeatDelta(radians(179), radians(-179))).toBeCloseTo(2 / 180)
    expect(platterBeatDelta(radians(-179), radians(179))).toBeCloseTo(-2 / 180)
  })

  it('accumulates two beats per full turn across repeated revolutions', () => {
    let beats = 0
    for (let i = 0; i < 24; i++) {
      const from = Math.atan2(Math.sin(i * Math.PI / 4), Math.cos(i * Math.PI / 4))
      const to = Math.atan2(Math.sin((i + 1) * Math.PI / 4), Math.cos((i + 1) * Math.PI / 4))
      beats += platterBeatDelta(from, to)
    }
    expect(beats).toBeCloseTo(6)
  })
})
