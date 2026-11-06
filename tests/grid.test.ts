import { describe, expect, it } from 'vitest'
import {
  barSeconds,
  beatPhase,
  beatSeconds,
  beatTimeSec,
  doubleGrid,
  fitGrid,
  foldBpm,
  halveGrid,
  normalizeOffset,
  nudgeGrid,
  nextBarSec,
  nextBeatSec,
  quantizeSec,
  secToBeat,
  setGridBpm,
  setGridOffset
} from '../src/shared/grid'

const grid = { bpm: 128, offsetMs: 120, confidence: 0.9 }

describe('beat grid', () => {
  it('round-trips beats and seconds', () => {
    for (const beat of [0, 1, 7.5, 64]) {
      const sec = beatTimeSec(grid, beat)
      expect(secToBeat(grid, sec)).toBeCloseTo(beat, 9)
    }
  })

  it('reports phase in [0, 1)', () => {
    const phaseAtBeat = beatPhase(grid, beatTimeSec(grid, 12))
    expect(phaseAtBeat).toBeCloseTo(0, 6)
    const quarter = beatPhase(grid, beatTimeSec(grid, 12) + (60 / 128) * 0.25)
    expect(quarter).toBeCloseTo(0.25, 6)
  })

  it('finds the next beat and bar', () => {
    const now = beatTimeSec(grid, 5.25)
    expect(nextBeatSec(grid, now)).toBeCloseTo(beatTimeSec(grid, 6), 9)
    expect(nextBarSec(grid, now)).toBeCloseTo(beatTimeSec(grid, 8), 9)
  })

  it('quantises forward and backward', () => {
    const justAfterBeat = beatTimeSec(grid, 10) + 0.02
    expect(quantizeSec(grid, justAfterBeat, 'beat', 'nearest')).toBeCloseTo(beatTimeSec(grid, 10), 9)
    expect(quantizeSec(grid, justAfterBeat, 'bar', 'forward')).toBeCloseTo(beatTimeSec(grid, 12), 9)
    expect(quantizeSec(grid, justAfterBeat, 'bar', 'backward')).toBeCloseTo(beatTimeSec(grid, 8), 9)
  })

  it('fits a grid to jittered beats', () => {
    const bpm = 126.5
    const period = 60 / bpm
    const times: number[] = []
    let seed = 1234567
    const rand = () => {
      seed = (seed * 1664525 + 1013904223) % 4294967296
      return seed / 4294967296
    }
    for (let i = 0; i < 200; i++) times.push(3.2 + i * period + (rand() - 0.5) * 0.012)
    const fitted = fitGrid(times)
    expect(fitted.bpm).toBeCloseTo(bpm, 1)
    expect(fitted.residualSec).toBeLessThan(0.01)
    expect(fitted.beatCount).toBe(200)
    const offsetBeat = (fitted.offsetMs / 1000 - 3.2) / period
    expect(Math.abs(offsetBeat - Math.round(offsetBeat))).toBeLessThan(0.05)
  })

  it('drops outlier beats when fitting', () => {
    const period = 60 / 128
    const times: number[] = []
    for (let i = 0; i < 64; i++) times.push(i * period)
    times[30] = times[30] + period * 0.45
    const fitted = fitGrid(times)
    expect(fitted.bpm).toBeCloseTo(128, 2)
  })

  it('normalises offsets into one bar, not one beat', () => {
    const nudged = nudgeGrid(grid, -500)
    expect(nudged.offsetMs).toBeGreaterThanOrEqual(0)
    expect(nudged.offsetMs).toBeLessThan(barSeconds(grid) * 1000)
  })

  it('keeps the bar phase through a 1 ms nudge', () => {
    const barMs = barSeconds(grid) * 1000
    // An offset beyond one beat is how a grid records which beat is the downbeat.
    const shifted = setGridOffset(grid, beatSeconds(grid) * 1000 * 1.5)
    const nudged = nudgeGrid(shifted, 1)
    expect(nudged.offsetMs - shifted.offsetMs).toBeCloseTo(1, 9)
    expect(nudged.offsetMs).toBeLessThan(barMs)
  })

  it('computes a bar as four beats', () => {
    expect(barSeconds(grid)).toBeCloseTo((60 / 128) * 4, 9)
  })

  it('keeps the downbeat through a tempo trim', () => {
    const shifted = setGridOffset(grid, 1400)
    const retimed = setGridBpm(shifted, 128.1)
    // The new bar (1873.7 ms) still contains 1400 ms, so no fold is needed.
    expect(retimed.offsetMs).toBeCloseTo(1400, 9)
  })

  it('sets a raw offset and only folds it at the bar', () => {
    const barMs = barSeconds(grid) * 1000
    const rawMs = beatTimeSec(grid, 6) * 1000 + 137.5
    const raw = setGridOffset(grid, rawMs)
    expect(raw.offsetMs).toBeCloseTo(rawMs, 9)
    expect(raw.bpm).toBe(grid.bpm)
    // A drag that crosses a beat must not jump: the raw value is untouched.
    expect(raw.offsetMs).toBeGreaterThan(60000 / grid.bpm)
    const folded = normalizeOffset(raw.offsetMs, barMs)
    expect(folded).toBeGreaterThanOrEqual(0)
    expect(folded).toBeLessThan(barMs)
    // Folding any number of bars away lands on the same phase.
    expect(normalizeOffset(rawMs + barMs * 3, barMs)).toBeCloseTo(folded, 9)
  })

  it('folds tempos into the DJ range', () => {
    expect(foldBpm(64)).toBeCloseTo(128)
    expect(foldBpm(256)).toBeCloseTo(128)
    expect(foldBpm(174)).toBeCloseTo(174)
  })

  it('halves and doubles the tempo interpretation', () => {
    expect(doubleGrid(grid).bpm).toBeCloseTo(256)
    expect(halveGrid(grid).bpm).toBeCloseTo(64)
  })
})
