/** Gain-law maths shared by the UI and the audio engine. */

export function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v))
}

export function dbToGain(db: number): number {
  return Math.pow(10, db / 20)
}

export function gainToDb(gain: number): number {
  return 20 * Math.log10(Math.max(1e-9, gain))
}

/**
 * Equal-power crossfader. At centre both channels sit at -3 dB, so a blend is
 * perceived as constant loudness rather than a dip.
 */
export function crossfadeGains(position: number): [number, number] {
  const x = clamp(position, 0, 1)
  return [Math.cos((x * Math.PI) / 2), Math.sin((x * Math.PI) / 2)]
}

export const EQ_MIN_DB = -26
export const EQ_MAX_DB = 6
export const EQ_KILL_DB = -60
export const EQ_KILL_THRESHOLD = -0.995

/**
 * EQ knob (-1 … +1) to filter gain in dB: centre is unity, full left is a kill,
 * the right half adds up to +6 dB.
 */
export function eqDbFromKnob(knob: number): number {
  const v = clamp(knob, -1, 1)
  if (v <= EQ_KILL_THRESHOLD) return EQ_KILL_DB
  return v < 0 ? v * -EQ_MIN_DB : v * EQ_MAX_DB
}

export interface FilterSetting {
  type: 'lowpass' | 'highpass'
  /** Cutoff in Hz. */
  frequency: number
  q: number
}

/** Cutoff at the centre detent: effectively open, so the filter is transparent. */
export const FILTER_FLAT_HZ = 20000
/** Cutoff at full left (low-pass sweep). */
export const FILTER_LP_FLOOR_HZ = 120
/** Cutoff at full right (high-pass sweep). */
export const FILTER_HP_CEIL_HZ = 9000
/** Cutoff at the bottom of the high-pass sweep, just before the centre. */
export const FILTER_HP_FLOOR_HZ = 20
export const FILTER_BASE_Q = 0.7
export const FILTER_Q_RANGE = 0.6

/**
 * One-knob DJ sweep filter. Centre is transparent, the left half sweeps a
 * low-pass down to FILTER_LP_FLOOR_HZ, the right half sweeps a high-pass up to
 * FILTER_HP_CEIL_HZ. Frequency moves exponentially so the sweep sounds even
 * across the travel instead of doing all its work in the last millimetre.
 */
export function filterSetting(knob: number): FilterSetting {
  const v = clamp(knob, -1, 1)
  if (v < 0) {
    const depth = -v
    return {
      type: 'lowpass',
      frequency: FILTER_FLAT_HZ * Math.pow(FILTER_LP_FLOOR_HZ / FILTER_FLAT_HZ, depth),
      q: FILTER_BASE_Q + FILTER_Q_RANGE * depth
    }
  }
  if (v > 0) {
    return {
      type: 'highpass',
      frequency: FILTER_HP_FLOOR_HZ * Math.pow(FILTER_HP_CEIL_HZ / FILTER_HP_FLOOR_HZ, v),
      q: FILTER_BASE_Q + FILTER_Q_RANGE * v
    }
  }
  return { type: 'lowpass', frequency: FILTER_FLAT_HZ, q: FILTER_BASE_Q }
}

export function rmsToDb(rms: number): number {
  return 20 * Math.log10(Math.max(1e-6, rms))
}

export function meterScale(db: number): number {
  // -60 dB → 0, 0 dB → 1
  return clamp((db + 60) / 60, 0, 1)
}

/** Musical pitch of a playback ratio, in semitones. */
export function ratioToSemitones(ratio: number): number {
  return 12 * Math.log2(ratio)
}
