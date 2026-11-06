/**
 * Beat-grid maths. A grid is a constant-tempo model of a track:
 *
 *   beatTime(beat) = offsetMs/1000 + beat * 60/bpm
 *
 * Everything else in the app (grid lines, sync, loops, quantisation) is
 * derived from this one model, so there is a single source of truth for
 * where the beats are.
 */
export interface BeatGrid {
  bpm: number
  offsetMs: number
  confidence: number
}

export const MIN_BPM = 70
export const MAX_BPM = 180
export const BEATS_PER_BAR = 4

export function beatSeconds(grid: Pick<BeatGrid, 'bpm'>): number {
  return 60 / grid.bpm
}

export function beatTimeSec(grid: BeatGrid, beat: number): number {
  return grid.offsetMs / 1000 + beat * beatSeconds(grid)
}

/** Seconds in one bar. The app assumes 4/4, so this is four beats. */
export function barSeconds(grid: Pick<BeatGrid, 'bpm'>): number {
  return beatSeconds(grid) * BEATS_PER_BAR
}

export function secToBeat(grid: BeatGrid, sec: number): number {
  return (sec - grid.offsetMs / 1000) / beatSeconds(grid)
}

/** Fractional position within the current beat, in [0, 1). */
export function beatPhase(grid: BeatGrid, sec: number): number {
  const b = secToBeat(grid, sec)
  return b - Math.floor(b)
}

export function normalizeOffset(offsetMs: number, periodMs: number): number {
  const r = offsetMs % periodMs
  return r < 0 ? r + periodMs : r
}

export function nextBeatSec(grid: BeatGrid, sec: number): number {
  return beatTimeSec(grid, Math.floor(secToBeat(grid, sec)) + 1)
}

export function prevBeatSec(grid: BeatGrid, sec: number): number {
  return beatTimeSec(grid, Math.ceil(secToBeat(grid, sec)) - 1)
}

/** Most recent beat at or before `sec`. */
export function floorBeatSec(grid: BeatGrid, sec: number): number {
  return beatTimeSec(grid, Math.floor(secToBeat(grid, sec)))
}

export function nextBarSec(grid: BeatGrid, sec: number): number {
  const b = secToBeat(grid, sec)
  return beatTimeSec(grid, Math.ceil(b / BEATS_PER_BAR) * BEATS_PER_BAR)
}

/** Quantise a time to the grid, snapped forward (used for loop points). */
export function quantizeSec(
  grid: BeatGrid,
  sec: number,
  unit: 'beat' | 'bar' = 'beat',
  direction: 'nearest' | 'forward' | 'backward' = 'nearest'
): number {
  const b = secToBeat(grid, sec)
  const q = unit === 'bar' ? BEATS_PER_BAR : 1
  const scaled = b / q
  const rounded =
    direction === 'forward' ? Math.ceil(scaled) : direction === 'backward' ? Math.floor(scaled) : Math.round(scaled)
  return beatTimeSec(grid, rounded * q)
}

/**
 * Fold a tempo into the DJ-friendly range by octaves.
 *
 * The default 70–180 window is right for house and techno, but it silently
 * accepts half-time readings of fast material: a 145 BPM psytrance track
 * misread at 72.5 stays at 72.5, because 72.5 is already inside the window.
 * Callers analysing a known-tempo genre should pass a tighter window (see the
 * TEMPO_HINTS presets in detector.ts) rather than relying on the default.
 */
export function foldBpm(bpm: number, min = MIN_BPM, max = MAX_BPM): number {
  let value = bpm
  while (value > 0 && value < min) value *= 2
  while (value > max) value /= 2
  return value
}

export interface FittedGrid extends BeatGrid {
  residualSec: number
  beatCount: number
}

function medianInterval(times: number[]): number {
  const intervals: number[] = []
  for (let i = 1; i < times.length; i++) {
    const d = times[i] - times[i - 1]
    if (d > 1e-4) intervals.push(d)
  }
  if (intervals.length === 0) return 60 / 120
  intervals.sort((a, b) => a - b)
  return intervals[Math.floor(intervals.length / 2)]
}

function leastSquares(xs: number[], ys: number[]): { slope: number; intercept: number } {
  const n = xs.length
  let sumX = 0
  let sumY = 0
  for (let i = 0; i < n; i++) {
    sumX += xs[i]
    sumY += ys[i]
  }
  const meanX = sumX / n
  const meanY = sumY / n
  let num = 0
  let den = 0
  for (let i = 0; i < n; i++) {
    const dx = xs[i] - meanX
    num += dx * (ys[i] - meanY)
    den += dx * dx
  }
  const slope = den > 0.5 ? num / den : 60 / 120
  return { slope, intercept: meanY - slope * meanX }
}

/**
 * Robust fit of a constant-tempo grid to detected beat times.
 *
 * A plain least-squares fit over beat indices is easily tilted by one stray or
 * missed beat, so this starts from a circular-mean phase estimate (every beat
 * votes on the offset), assigns integer beat numbers, and iteratively refits
 * while dropping beats that disagree with the consensus. An expected BPM from
 * the tempo estimator, when supplied, keeps beat numbering unambiguous over
 * long tracks.
 */
export function fitGrid(beatTimesSec: number[], expectedBpm?: number): FittedGrid {
  const times = beatTimesSec.filter((t) => Number.isFinite(t))
  const fallback: FittedGrid = { bpm: 120, offsetMs: 0, confidence: 0, residualSec: 0, beatCount: times.length }
  if (times.length < 4) return fallback

  const initialPeriod = expectedBpm && expectedBpm > 0 ? 60 / expectedBpm : medianInterval(times)
  if (!Number.isFinite(initialPeriod) || initialPeriod <= 0) return fallback

  let sx = 0
  let sy = 0
  for (const t of times) {
    const angle = (2 * Math.PI * t) / initialPeriod
    sx += Math.cos(angle)
    sy += Math.sin(angle)
  }
  let slope = initialPeriod
  let intercept = (Math.atan2(sy, sx) / (2 * Math.PI)) * initialPeriod

  let used = times.length
  let residualSec = 0
  for (let pass = 0; pass < 4; pass++) {
    const xs: number[] = []
    const ys: number[] = []
    for (const t of times) {
      const k = Math.round((t - intercept) / slope)
      if (Math.abs(t - (intercept + k * slope)) <= initialPeriod * 0.35) {
        xs.push(k)
        ys.push(t)
      }
    }
    if (xs.length < 4) break
    const fit = leastSquares(xs, ys)
    if (!Number.isFinite(fit.slope) || fit.slope <= 0) break
    slope = fit.slope
    intercept = ((fit.intercept % slope) + slope) % slope
    used = xs.length
    let sumSq = 0
    for (let i = 0; i < xs.length; i++) sumSq += (ys[i] - (fit.intercept + fit.slope * xs[i])) ** 2
    residualSec = Math.sqrt(sumSq / xs.length)
  }

  const bpm = 60 / slope
  if (!Number.isFinite(bpm) || bpm <= 0) return fallback
  return {
    bpm,
    offsetMs: normalizeOffset(intercept * 1000, 60000 / bpm),
    confidence: 0,
    residualSec,
    beatCount: used
  }
}

/**
 * Grid with a shifted offset, keeping the tempo and the bar phase.
 *
 * The offset is folded at the bar, not at the beat: an offset larger than one
 * beat is how a grid expresses which beat is the downbeat (see the visual grid
 * editor), so wrapping it into the beat period would silently rotate the bar.
 */
export function nudgeGrid(grid: BeatGrid, deltaMs: number): BeatGrid {
  return { ...grid, offsetMs: normalizeOffset(grid.offsetMs + deltaMs, barSeconds(grid) * 1000) }
}

/**
 * Set the offset directly, without wrapping it into the beat or bar.
 *
 * The ±1 ms buttons can fold at the bar because a finished grid has a stable
 * phase, but a drag cannot: folding mid-gesture would jump the lines under the
 * pointer. A visual edit uses this raw setter while the pointer is down and
 * folds once, at the bar, when the gesture ends.
 */
export function setGridOffset(grid: BeatGrid, offsetMs: number): BeatGrid {
  return { ...grid, offsetMs }
}

export function setGridBpm(grid: BeatGrid, bpm: number): BeatGrid {
  const clamped = Math.min(300, Math.max(40, bpm))
  // Keep the downbeat at the same audio position, modulo the new bar length.
  return { ...grid, bpm: clamped, offsetMs: normalizeOffset(grid.offsetMs, barSeconds({ bpm: clamped }) * 1000) }
}

/** Double the tempo interpretation (beats get twice as fast). */
export function doubleGrid(grid: BeatGrid): BeatGrid {
  return setGridBpm(grid, grid.bpm * 2)
}

/** Half-time interpretation. */
export function halveGrid(grid: BeatGrid): BeatGrid {
  return setGridBpm(grid, grid.bpm / 2)
}
