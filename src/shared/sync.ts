import { type BeatGrid, beatPhase, beatSeconds } from './grid'

/** How far a deck may be dragged from its own tempo to match another. */
export const MAX_TEMPO_DELTA = 0.16
/** Beats over which the phase error is scheduled to be removed. */
export const SYNC_CORRECTION_BEATS = 2.5
/** Hard limit on the drift correction (±0.25%) — inaudible. */
export const SYNC_TRIM_LIMIT = 0.0025

export function tempoRateFor(masterBpm: number, followerBpm: number, maxDelta = MAX_TEMPO_DELTA): number {
  const raw = masterBpm / Math.max(1e-6, followerBpm)
  return Math.min(1 + maxDelta, Math.max(1 - maxDelta, raw))
}

/** Wrap a phase error into (-0.5, 0.5] beats. */
export function wrapPhase(error: number): number {
  let e = error % 1
  if (e > 0.5) e -= 1
  if (e <= -0.5) e += 1
  return e
}

export function phaseErrorBeats(masterSec: number, masterGrid: BeatGrid, followerSec: number, followerGrid: BeatGrid): number {
  return wrapPhase(beatPhase(masterGrid, masterSec) - beatPhase(followerGrid, followerSec))
}

/** Beats the follower must jump forward to land on the master's phase, in [0, 1). */
export function phaseCorrectionBeats(masterPhase: number, followerPhase: number): number {
  let d = masterPhase - followerPhase
  while (d < 0) d += 1
  while (d >= 1) d -= 1
  return d
}

/** Forward-only seek target used by SYNC (never jumps backwards). */
export function seekTargetSec(followerSec: number, correctionBeats: number, followerGrid: BeatGrid): number {
  return followerSec + correctionBeats * beatSeconds(followerGrid)
}

/** Nearest phase match inside the file; clamping an out-of-bounds match loses phase. */
export function alignedPositionSec(position: number, correctionBeats: number, grid: BeatGrid, duration: number): number {
  const period = beatSeconds(grid)
  let target = position + correctionBeats * period
  if (target < 0) target += Math.ceil(-target / period) * period
  if (target > duration) target -= Math.ceil((target - duration) / period) * period
  return Math.max(0, Math.min(duration, target))
}

/** Start before the cue, never after its attack, while matching the master's phase. */
export function cueLeadInSec(cueSec: number, masterSec: number, masterGrid: BeatGrid, cueGrid: BeatGrid): number {
  let lead = phaseCorrectionBeats(beatPhase(cueGrid, cueSec), beatPhase(masterGrid, masterSec))
  // Floating-point noise at a beat boundary must not add a whole beat of lead-in.
  if (lead > 1 - 1e-9) lead = 0
  return cueSec - lead * beatSeconds(cueGrid)
}

/**
 * Rate-trim controller. Rather than seeking (audible), it nudges the follower's
 * playback ratio so the phase error is removed over a couple of beats. It is
 * proportional with smoothing: a persistent error means a genuinely wrong BPM,
 * which it keeps cancelling without oscillating.
 *
 * Call it at a roughly steady rate (~10 Hz); each call smooths the trim 15% of
 * the way to its target.
 */
export class SyncController {
  private trim = 0

  reset(): void {
    this.trim = 0
  }

  get value(): number {
    return this.trim
  }

  /**
   * @param error master phase minus follower phase, in beats. A negative error
   * means the follower is ahead, so its rate is reduced (negative trim).
   */
  update(error: number): number {
    const target = wrapPhase(error) / SYNC_CORRECTION_BEATS
    const clamped = Math.max(-SYNC_TRIM_LIMIT, Math.min(SYNC_TRIM_LIMIT, target))
    this.trim += (clamped - this.trim) * 0.15
    return this.trim
  }
}

/** Mix a base tempo rate with the drift trim. */
export function effectiveRate(baseRate: number, trim: number): number {
  return baseRate * (1 + trim)
}
