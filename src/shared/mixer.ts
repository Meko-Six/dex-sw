import { clamp, crossfadeGains, dbToGain } from './curves'

/**
 * The mixer's fader law, shared by LEVEL and the cut-only EQ faders: the top
 * is unity, and the travel spends most of its length on the useful cuts
 * (−3, −6, −12 dB) before falling away to silence at the foot. Positions run
 * 0 (foot) … 1 (top).
 */
export const FADER_LAW: ReadonlyArray<readonly [position: number, db: number]> = [
  [1, 0],
  [0.8, -3],
  [0.6, -6],
  [0.4, -12],
  [0.2, -24],
  [0.03, -48]
]

/** Below this the fader is at its foot: silence. */
const FADER_FLOOR = 0.005

/** Fader position to dB; −Infinity at the foot. */
export function faderDb(position: number): number {
  const p = clamp(position, 0, 1)
  if (p <= FADER_FLOOR) return Number.NEGATIVE_INFINITY
  const last = FADER_LAW[FADER_LAW.length - 1]
  // The last stretch runs from −48 dB down towards −70 dB before the mute.
  if (p < last[0]) return last[1] - ((last[0] - p) / (last[0] - FADER_FLOOR)) * 22
  for (let i = 1; i < FADER_LAW.length; i++) {
    const [p0, d0] = FADER_LAW[i - 1]
    const [p1, d1] = FADER_LAW[i]
    if (p >= p1) return d1 + ((d0 - d1) * (p - p1)) / (p0 - p1)
  }
  return last[1]
}

export function faderGain(position: number): number {
  const db = faderDb(position)
  return db === Number.NEGATIVE_INFINITY ? 0 : dbToGain(db)
}

/** "0.0", "−3.0", "+1.4", "−∞". */
export function formatDb(db: number): string {
  if (db === Number.NEGATIVE_INFINITY) return '−∞'
  if (Math.abs(db) < 0.05) return '0.0'
  return `${db > 0 ? '+' : '−'}${Math.abs(db).toFixed(1)}`
}

export const TRIM_RANGE_DB = 12

/** The trim a track's measured gain asks for: to a tenth of a dB, within the trim's range. */
export function autoTrimDb(gainDb: number): number {
  return clamp(Math.round(gainDb * 10) / 10, -TRIM_RANGE_DB, TRIM_RANGE_DB)
}

export interface LowChannel {
  /** LOW fader position, 0…1. */
  low: number
  lowKill: boolean
  /** LEVEL fader position, 0…1. */
  level: number
  trimDb: number
}

/**
 * Worst case for the two basslines: both decks' low band summed as if the
 * kicks were in phase, after trim, LEVEL and the crossfader. 0 dB is one
 * track's full low on its own; two full lows in the middle of the crossfader
 * read about +3 dB.
 */
export function lowSumDb(a: LowChannel, b: LowChannel, crossfader: number): number {
  const [ga, gb] = crossfadeGains(crossfader)
  const part = (channel: LowChannel, xf: number): number =>
    channel.lowKill ? 0 : faderGain(channel.low) * faderGain(channel.level) * dbToGain(channel.trimDb) * xf
  const sum = part(a, ga) + part(b, gb)
  return sum <= 0 ? Number.NEGATIVE_INFINITY : 20 * Math.log10(sum)
}

/** Where LOW Σ starts to warn, and where it means the lows are stacking. */
export const LOW_SUM_WARN_DB = 1
export const LOW_SUM_HOT_DB = 3

/**
 * LINK LOWS: one drag trades one deck's low for the other's. The other fader
 * moves the same distance the opposite way, from where it started.
 */
export function linkedLow(otherStart: number, delta: number): number {
  return clamp(otherStart - delta, 0, 1)
}
