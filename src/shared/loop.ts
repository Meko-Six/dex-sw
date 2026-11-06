import { BEATS_PER_BAR, type BeatGrid, beatSeconds, beatTimeSec, secToBeat } from './grid'

/**
 * A loop is stored in beats, never in seconds, so it survives tempo changes and
 * grid edits: a four-beat loop is always four beats, whatever you do to the
 * pitch fader.
 */
export interface LoopRegion {
  startBeat: number
  lengthBeats: number
}

/** Loop lengths the stepper walks through, in beats (1 beat … 16 bars). */
export const LOOP_LENGTHS_BEATS = [1, 2, 4, 8, 16, 32, 64]
export const MIN_LOOP_BEATS = 1
export const MAX_LOOP_BEATS = 256

/**
 * The next loop length on the stepper. Arrows halve or double; a length that
 * is not on the ladder (e.g. after a grid edit) snaps to the nearest step in
 * the direction pressed, and the ends of the ladder hold.
 */
export function stepLoopBeats(current: number, direction: -1 | 1): number {
  const steps = LOOP_LENGTHS_BEATS
  if (direction > 0) return steps.find((beats) => beats > current) ?? steps[steps.length - 1]
  for (let i = steps.length - 1; i >= 0; i--) if (steps[i] < current) return steps[i]
  return steps[0]
}

export function beatsToBars(beats: number): number {
  return beats / BEATS_PER_BAR
}

/**
 * Build a loop that starts on the next quantised boundary at or after `sec`.
 * The boundary is snapped against the grid, not against wall-clock time, so
 * looped decks stay phase-locked to each other.
 */
export function createLoop(
  grid: BeatGrid,
  sec: number,
  lengthBeats: number,
  quantize: 'beat' | 'bar' = 'beat'
): LoopRegion {
  const unit = quantize === 'bar' ? BEATS_PER_BAR : 1
  const b = secToBeat(grid, sec)
  const startBeat = Math.ceil(b / unit) * unit
  const length = Math.max(MIN_LOOP_BEATS, Math.round(lengthBeats))
  return { startBeat, lengthBeats: length }
}

/** Immediate loop (no quantisation) used by loop-roll and manual out points. */
export function createLoopAt(grid: BeatGrid, sec: number, lengthBeats: number): LoopRegion {
  const startBeat = secToBeat(grid, sec)
  return { startBeat, lengthBeats: Math.max(MIN_LOOP_BEATS, Math.round(lengthBeats)) }
}

export function loopSeconds(grid: BeatGrid, region: LoopRegion): { startSec: number; endSec: number; lengthSec: number } {
  const startSec = beatTimeSec(grid, region.startBeat)
  const lengthSec = region.lengthBeats * beatSeconds(grid)
  return { startSec, endSec: startSec + lengthSec, lengthSec }
}

/** Move the whole loop to the nearest beat that keeps both ends in the file. */
export function moveLoopToBeat(grid: BeatGrid, region: LoopRegion, startBeat: number, durationSec: number): LoopRegion {
  const first = Math.ceil(secToBeat(grid, 0) - 1e-9)
  const last = Math.floor(secToBeat(grid, durationSec) - region.lengthBeats + 1e-9)
  if (!Number.isFinite(startBeat) || last < first) return region
  return { ...region, startBeat: Math.max(first, Math.min(last, Math.round(startBeat))) }
}

export function halfLoop(region: LoopRegion): LoopRegion {
  return { ...region, lengthBeats: Math.max(MIN_LOOP_BEATS, Math.round(region.lengthBeats / 2)) }
}

/**
 * Shrinking keeps the window of the new length that holds `atBeat`, so the
 * playhead carries on: halving a 4-beat loop on beat 3 keeps beats 3–4.
 * Growing, or a loop the playhead has not reached yet, keeps loop-in.
 */
export function resizeLoop(region: LoopRegion, lengthBeats: number, atBeat: number): LoopRegion {
  const offset = atBeat - region.startBeat
  if (!(lengthBeats > 0 && lengthBeats < region.lengthBeats && offset >= 0 && Number.isFinite(offset))) {
    return { ...region, lengthBeats }
  }
  const last = Math.floor(region.lengthBeats / lengthBeats + 1e-9) - 1
  const window = Math.min(last, Math.floor((offset % region.lengthBeats) / lengthBeats + 1e-9))
  return { startBeat: region.startBeat + window * lengthBeats, lengthBeats }
}

export function doubleLoop(region: LoopRegion): LoopRegion {
  return { ...region, lengthBeats: Math.min(MAX_LOOP_BEATS, region.lengthBeats * 2) }
}

/** True when `sec` sits inside the loop window (before wrap-around). */
export function isInsideLoop(grid: BeatGrid, region: LoopRegion, sec: number): boolean {
  const { startSec, endSec } = loopSeconds(grid, region)
  return sec >= startSec && sec < endSec
}

/**
 * Where a loop-roll should drop playback when released: the position the track
 * would have reached had it kept playing through the loop.
 */
export function rollReleaseSec(anchorSec: number, elapsedSec: number, rate: number): number {
  return anchorSec + Math.max(0, elapsedSec) * rate
}

/** Fractional position through the loop, in [0, 1). */
export function loopProgress(grid: BeatGrid, region: LoopRegion, sec: number): number {
  const { startSec, lengthSec } = loopSeconds(grid, region)
  if (lengthSec <= 0) return 0
  const rel = (sec - startSec) % lengthSec
  return rel < 0 ? (rel + lengthSec) / lengthSec : rel / lengthSec
}
