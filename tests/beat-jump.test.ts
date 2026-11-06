import { describe, expect, it } from 'vitest'
import {
  beatJump,
  DEFAULT_JUMP_BARS,
  JUMP_LENGTHS_BARS,
  jumpByBars,
  jumpToBarAt,
  moveLoopByBars,
  type JumpDeck
} from '../src/shared/beat-jump'
import { barSeconds, beatPhase, beatTimeSec, secToBeat } from '../src/shared/grid'
import { loopSeconds } from '../src/shared/loop'

// 138 BPM, downbeat at 0.35 s: one bar is 1.739… s.
const grid = { bpm: 138, offsetMs: 350, confidence: 0.9 }
const bar = barSeconds(grid)
const barLine = (n: number): number => beatTimeSec(grid, n * 4)
/** Position within the bar, 0 … 4 beats. */
const inBar = (sec: number): number => {
  const beats = secToBeat(grid, sec)
  return beats - Math.floor(beats / 4) * 4
}

const playing = (positionSec: number, extra: Partial<JumpDeck> = {}): JumpDeck => ({
  grid,
  positionSec,
  durationSec: 420,
  playing: true,
  ...extra
})
const paused = (positionSec: number, extra: Partial<JumpDeck> = {}): JumpDeck => ({ ...playing(positionSec, extra), playing: false })

describe('beat jump', () => {
  it('offers 1, 4, 16 and 32 bars and starts on 1', () => {
    expect([...JUMP_LENGTHS_BARS]).toEqual([1, 4, 16, 32])
    expect(DEFAULT_JUMP_BARS).toBe(1)
  })

  it('moves a playing deck by exactly the chosen number of bars, both ways', () => {
    const at = barLine(40) + 1.234
    for (const length of JUMP_LENGTHS_BARS) {
      const forward = beatJump(playing(at), length, 1)
      expect(forward.bars).toBe(length)
      expect(forward.sec - at).toBeCloseTo(length * bar, 9)
      const back = beatJump(playing(at), length, -1)
      expect(back.bars).toBe(-length)
      expect(at - back.sec).toBeCloseTo(length * bar, 9)
    }
  })

  it('keeps a playing deck at the same point in the bar and the beat', () => {
    const at = barLine(50) + 0.777
    for (const length of JUMP_LENGTHS_BARS) {
      for (const direction of [-1, 1] as const) {
        const { sec } = beatJump(playing(at), length, direction)
        expect(inBar(sec)).toBeCloseTo(inBar(at), 9)
        expect(beatPhase(grid, sec)).toBeCloseTo(beatPhase(grid, at), 9)
      }
    }
  })

  it('snaps a paused deck to the nearest bar line, then jumps whole bars', () => {
    // A little after bar 20: snaps back to it.
    expect(beatJump(paused(barLine(20) + 0.3), 1, 1).sec).toBeCloseTo(barLine(21), 9)
    expect(beatJump(paused(barLine(20) + 0.3), 4, -1).sec).toBeCloseTo(barLine(16), 9)
    // Most of the way to bar 21: snaps forward to it.
    expect(beatJump(paused(barLine(20) + 0.8 * bar), 1, 1).sec).toBeCloseTo(barLine(22), 9)
    expect(beatJump(paused(barLine(20) + 0.8 * bar), 16, -1).sec).toBeCloseTo(barLine(5), 9)
  })

  it('stops on a bar line rather than past 0:00, keeping the phase', () => {
    const at = barLine(2) + 0.5
    const result = beatJump(playing(at), 32, -1)
    expect(result.bars).toBe(-2)
    expect(result.sec).toBeCloseTo(barLine(0) + 0.5, 9)
    expect(result.sec).toBeGreaterThanOrEqual(0)
    expect(inBar(result.sec)).toBeCloseTo(inBar(at), 9)
  })

  it('stops short of the end by whole bars', () => {
    const durationSec = barLine(100) + 0.2
    const at = barLine(95) + 0.1
    const result = beatJump(playing(at, { durationSec }), 16, 1)
    expect(result.bars).toBe(5)
    expect(result.sec).toBeCloseTo(barLine(100) + 0.1, 9)
    expect(result.sec).toBeLessThanOrEqual(durationSec)
  })

  it('does not move when not even one bar fits', () => {
    const intro = playing(0.2)
    expect(beatJump(intro, 1, -1)).toEqual({ sec: 0.2, bars: 0 })
    const outro = playing(419.5)
    expect(beatJump(outro, 1, 1)).toEqual({ sec: 419.5, bars: 0 })
  })

  it('snaps a paused deck at 0:00 to the first bar line inside the track', () => {
    // The nearest bar line to 0.1 s is before 0:00, so the downbeat at 0.35 s is used.
    const result = beatJump(paused(0.1), 1, -1)
    expect(result.bars).toBe(0)
    expect(result.sec).toBeCloseTo(0.35, 9)
  })

  it('keeps a running loop inside the track as it moves', () => {
    // An 8-bar loop from bar 10; jumping back 16 bars only has room for 10.
    const loop = { startBeat: 40, lengthBeats: 32 }
    const at = barLine(12) + 0.4
    const result = beatJump(playing(at, { loop }), 16, -1)
    expect(result.bars).toBe(-10)
    const moved = moveLoopByBars(loop, result.bars)
    expect(loopSeconds(grid, moved).startSec).toBeCloseTo(barLine(0), 9)
    // The playhead lands inside the moved loop, at the same point in it.
    const { startSec, endSec } = loopSeconds(grid, moved)
    expect(result.sec).toBeGreaterThanOrEqual(startSec)
    expect(result.sec).toBeLessThan(endSec)
    expect(result.sec - startSec).toBeCloseTo(at - barLine(10), 9)
  })

  it('jumps by a signed count of bars', () => {
    expect(jumpByBars(playing(barLine(30)), -3).sec).toBeCloseTo(barLine(27), 9)
    expect(jumpByBars(playing(barLine(30)), 0)).toEqual({ sec: barLine(30), bars: 0 })
  })
})

describe('overview click', () => {
  it('takes a playing deck into the clicked bar at its own place in the bar', () => {
    const at = barLine(10) + 0.25 * bar
    const result = jumpToBarAt(playing(at), barLine(64) + 0.9 * bar)
    expect(result.bars).toBe(54)
    expect(result.sec).toBeCloseTo(barLine(64) + 0.25 * bar, 9)
  })

  it('goes back as well as forward', () => {
    const at = barLine(80) + 0.6 * bar
    const result = jumpToBarAt(playing(at), barLine(3) + 0.1)
    expect(result.bars).toBe(-77)
    expect(inBar(result.sec)).toBeCloseTo(inBar(at), 9)
  })

  it('does nothing when the click is in the bar already playing', () => {
    const at = barLine(10) + 0.25 * bar
    expect(jumpToBarAt(playing(at), barLine(10) + 0.8 * bar).bars).toBe(0)
  })

  it('puts a paused deck on the bar line nearest the click', () => {
    expect(jumpToBarAt(paused(barLine(2) + 0.1), barLine(40) + 0.3 * bar).sec).toBeCloseTo(barLine(40), 9)
    expect(jumpToBarAt(paused(barLine(2) + 0.1), barLine(40) + 0.7 * bar).sec).toBeCloseTo(barLine(41), 9)
  })
})
