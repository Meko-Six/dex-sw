import { barSeconds, BEATS_PER_BAR, type BeatGrid, quantizeSec, secToBeat } from './grid'
import { type LoopRegion, loopSeconds } from './loop'

/**
 * Beat jump: move the playhead by whole bars of the deck's own grid.
 *
 * A playing deck keeps its position inside the bar, so a deck synced to the
 * other one is still in phase when it lands. A paused deck snaps to the
 * nearest bar line first: that is where a cue goes.
 *
 * A running loop moves with the jump (the CDJ's loop move), so a jump never
 * throws the playhead out of its own loop.
 */

/** The lengths the jump selector offers, in bars. */
export const JUMP_LENGTHS_BARS = [1, 4, 16, 32] as const
export type JumpBars = (typeof JUMP_LENGTHS_BARS)[number]
export const DEFAULT_JUMP_BARS: JumpBars = 1

export interface JumpDeck {
  grid: BeatGrid
  positionSec: number
  durationSec: number
  playing: boolean
  /** A running loop; it moves with the jump, so it has to fit in the track too. */
  loop?: LoopRegion | null
}

export interface JumpResult {
  /** Where the playhead lands. */
  sec: number
  /** Whole bars moved, signed. Fewer than asked when the track runs out. */
  bars: number
}

/** The bar line nearest `sec` that lies inside the track. */
function nearestBarInTrack(grid: BeatGrid, sec: number, durationSec: number): number {
  const bar = barSeconds(grid)
  let snapped = quantizeSec(grid, sec, 'bar', 'nearest')
  while (snapped < 0) snapped += bar
  while (snapped > durationSec && snapped - bar >= 0) snapped -= bar
  return Math.min(durationSec, snapped)
}

/** Where a jump starts from: the playhead, or for a paused deck the nearest bar line. */
function jumpOrigin(deck: JumpDeck): number {
  return deck.playing ? deck.positionSec : nearestBarInTrack(deck.grid, deck.positionSec, deck.durationSec)
}

/**
 * Move by `bars` whole bars (signed) from the jump origin. Near either end of
 * the track it moves by as many whole bars as fit rather than stopping on
 * 0:00 or the end, which would throw a playing deck out of phase.
 */
export function jumpByBars(deck: JumpDeck, bars: number): JumpResult {
  const from = jumpOrigin(deck)
  const bar = barSeconds(deck.grid)
  const direction = Math.sign(bars)
  const wanted = Math.abs(Math.round(bars))
  if (direction === 0 || wanted === 0 || !(bar > 0)) return { sec: from, bars: 0 }

  const points = [from]
  if (deck.loop) {
    const { startSec, endSec } = loopSeconds(deck.grid, deck.loop)
    points.push(startSec, endSec)
  }
  let room = Number.POSITIVE_INFINITY
  for (const point of points) room = Math.min(room, direction > 0 ? deck.durationSec - point : point)
  const fit = Math.max(0, Math.min(wanted, Math.floor(room / bar + 1e-9)))
  if (fit === 0) return { sec: from, bars: 0 }
  return { sec: from + direction * fit * bar, bars: direction * fit }
}

/** The jump buttons: one press, one jump of `length` bars back (-1) or forward (+1). */
export function beatJump(deck: JumpDeck, length: number, direction: -1 | 1): JumpResult {
  return jumpByBars(deck, direction * length)
}

/**
 * A click on the overview: jump to the bar under the click. A playing deck
 * lands in that bar at its current position within the bar; a paused deck
 * lands on the bar line nearest the click.
 */
export function jumpToBarAt(deck: JumpDeck, targetSec: number): JumpResult {
  const barIndex = (sec: number): number => secToBeat(deck.grid, sec) / BEATS_PER_BAR
  const bars = deck.playing
    ? Math.floor(barIndex(targetSec)) - Math.floor(barIndex(deck.positionSec))
    : Math.round(barIndex(targetSec) - barIndex(jumpOrigin(deck)))
  return jumpByBars(deck, bars)
}

/** A loop region moved by whole bars. */
export function moveLoopByBars(loop: LoopRegion, bars: number): LoopRegion {
  return { ...loop, startBeat: loop.startBeat + bars * BEATS_PER_BAR }
}
