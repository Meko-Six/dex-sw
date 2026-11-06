import { describe, expect, it } from 'vitest'
import { beatPhase, beatTimeSec, secToBeat } from '../src/shared/grid'
import {
  createLoop,
  createLoopAt,
  doubleLoop,
  halfLoop,
  resizeLoop,
  loopProgress,
  LOOP_LENGTHS_BEATS,
  loopSeconds,
  moveLoopToBeat,
  rollReleaseSec,
  stepLoopBeats
} from '../src/shared/loop'

const grid = { bpm: 128, offsetMs: 120, confidence: 0.9 }

describe('loops', () => {
  it('moves both loop ends to a beat while retaining its length', () => {
    const loop = { startBeat: 12, lengthBeats: 8 }
    expect(moveLoopToBeat(grid, loop, 15.6, 420)).toEqual({ startBeat: 16, lengthBeats: 8 })
    expect(moveLoopToBeat(grid, loop, 10.4, 420)).toEqual({ startBeat: 10, lengthBeats: 8 })
  })

  it('keeps the entire moved loop inside a file with a nonzero grid offset', () => {
    const loop = { startBeat: 12, lengthBeats: 8 }
    for (const requested of [-1000, 1000]) {
      const moved = moveLoopToBeat(grid, loop, requested, 10)
      const bounds = loopSeconds(grid, moved)
      expect(bounds.startSec).toBeGreaterThanOrEqual(0)
      expect(bounds.endSec).toBeLessThanOrEqual(10)
      expect(moved.lengthBeats).toBe(8)
      expect(Number.isInteger(moved.startBeat)).toBe(true)
    }
  })

  it('leaves an oversized loop unchanged if its full length cannot fit', () => {
    const loop = { startBeat: 0, lengthBeats: 64 }
    expect(moveLoopToBeat(grid, loop, 12, 2)).toBe(loop)
  })
  it('quantises the start to the next beat', () => {
    const region = createLoop(grid, beatTimeSec(grid, 5.25), 4, 'beat')
    expect(region.startBeat).toBe(6)
    expect(region.lengthBeats).toBe(4)
    const { startSec, endSec } = loopSeconds(grid, region)
    expect(startSec).toBeCloseTo(beatTimeSec(grid, 6), 9)
    expect(endSec).toBeCloseTo(beatTimeSec(grid, 10), 9)
  })

  it('quantises the start to the next bar', () => {
    const region = createLoop(grid, beatTimeSec(grid, 5.25), 16, 'bar')
    expect(region.startBeat).toBe(8)
  })

  it('keeps a zero-length correction when exactly on a beat', () => {
    const region = createLoop(grid, beatTimeSec(grid, 8), 4, 'beat')
    expect(region.startBeat).toBe(8)
  })

  it('expresses loop length in seconds from the grid', () => {
    const region = { startBeat: 8, lengthBeats: 4 }
    const { lengthSec } = loopSeconds(grid, region)
    expect(lengthSec).toBeCloseTo((4 * 60) / 128, 9)
  })

  it('halves and doubles without going out of bounds', () => {
    expect(halfLoop({ startBeat: 0, lengthBeats: 8 })).toEqual({ startBeat: 0, lengthBeats: 4 })
    expect(halfLoop({ startBeat: 0, lengthBeats: 1 })).toEqual({ startBeat: 0, lengthBeats: 1 })
  })

  it('shrinks around the playhead and grows from loop-in', () => {
    const four = { startBeat: 8, lengthBeats: 4 }
    expect(resizeLoop(four, 2, 9.5)).toEqual({ startBeat: 8, lengthBeats: 2 })
    expect(resizeLoop(four, 2, 10)).toEqual({ startBeat: 10, lengthBeats: 2 })
    expect(resizeLoop(four, 1, 11.9)).toEqual({ startBeat: 11, lengthBeats: 1 })
    expect(resizeLoop(four, 2, 14.5)).toEqual({ startBeat: 10, lengthBeats: 2 })
    expect(resizeLoop(four, 2, 7)).toEqual({ startBeat: 8, lengthBeats: 2 })
    expect(resizeLoop(four, 8, 11)).toEqual({ startBeat: 8, lengthBeats: 8 })
    expect(doubleLoop({ startBeat: 0, lengthBeats: 8 })).toEqual({ startBeat: 0, lengthBeats: 16 })
  })

  it('keeps phase continuous across the wrap for integer-beat loops', () => {
    // This is what makes a looped deck stay locked to the other deck.
    for (const lengthBeats of [1, 2, 4, 16]) {
      const region = { startBeat: 12, lengthBeats }
      const { startSec, endSec } = loopSeconds(grid, region)
      expect(beatPhase(grid, startSec)).toBeCloseTo(beatPhase(grid, endSec), 6)
    }
  })

  it('reports loop progress with wrap-around', () => {
    const region = { startBeat: 4, lengthBeats: 4 }
    const { startSec, lengthSec } = loopSeconds(grid, region)
    expect(loopProgress(grid, region, startSec)).toBeCloseTo(0, 6)
    expect(loopProgress(grid, region, startSec + lengthSec * 0.5)).toBeCloseTo(0.5, 5)
    expect(loopProgress(grid, region, startSec + lengthSec * 1.25)).toBeCloseTo(0.25, 5)
  })

  it('supports an immediate loop at a fractional position', () => {
    const region = createLoopAt(grid, beatTimeSec(grid, 9.5), 2)
    expect(region.startBeat).toBeCloseTo(9.5, 6)
  })

  it('drops back where the track would have been on roll release', () => {
    const anchor = 100
    expect(rollReleaseSec(anchor, 1.875, 1)).toBeCloseTo(101.875, 6)
    expect(rollReleaseSec(anchor, 1.875, 1.05)).toBeCloseTo(101.96875, 6)
  })

  it('never makes a loop shorter than one beat', () => {
    const region = createLoop(grid, beatTimeSec(grid, secToBeat(grid, beatTimeSec(grid, 2)) + 0.1), 1)
    expect(region.lengthBeats).toBeGreaterThanOrEqual(1)
  })
})

describe('loop stepper', () => {
  it('halves and doubles along the ladder', () => {
    expect(LOOP_LENGTHS_BEATS).toEqual([1, 2, 4, 8, 16, 32, 64])
    expect(stepLoopBeats(16, 1)).toBe(32)
    expect(stepLoopBeats(16, -1)).toBe(8)
    expect(stepLoopBeats(2, -1)).toBe(1)
  })

  it('holds at the ends', () => {
    expect(stepLoopBeats(1, -1)).toBe(1)
    expect(stepLoopBeats(64, 1)).toBe(64)
  })

  it('snaps an off-ladder length to the next step in the direction pressed', () => {
    expect(stepLoopBeats(6, 1)).toBe(8)
    expect(stepLoopBeats(6, -1)).toBe(4)
    expect(stepLoopBeats(128, -1)).toBe(64)
    expect(stepLoopBeats(128, 1)).toBe(64)
  })
})
