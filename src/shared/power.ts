import type { BeatGrid } from './grid'
import { analyzeLoudness } from './loudness'

/** Increment when feature scaling changes; older curves are rebuilt on load. */
export const POWER_VERSION = 1

export interface PowerAnalysis {
  version: number
  durationSec: number
  /** Absolute track time, including a partial first bar before the grid origin. */
  startSec: number
  barSec: number
  /** Musical intensity, 0…1, using shared feature scaling (not a per-track rank). */
  values: number[]
  score: number
  lufs?: number
  gainDb: number
  peakToLoudnessDb?: number
}

const clamp = (x: number): number => Math.max(0, Math.min(1, x))
const percentile = (values: number[], fraction: number): number => {
  const sorted = values.slice().sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))] ?? 0
}

/** Ignore effectively silent padding when choosing the active reference. */
function activeReference(values: number[]): number {
  const peak = values.reduce((max, v) => Math.max(max, v), 0)
  return percentile(values.filter((v) => v > peak * 0.0001), 0.9)
}

/**
 * A musical-intensity estimate, not a loudness meter or a genre classifier.
 * Stereo channel powers are averaged, so out-of-phase material doesn't vanish.
 * Relative section level, band attacks, bass and treble activity are measured
 * in 20 ms frames and pooled into bars. The active-section reference removes
 * uniform mastering gain; the weights/scales stay the same between tracks.
 *
 * This deliberately doesn't rank each track's quietest/loudest bars as 0/1:
 * a sustained pad should remain cooler than a rhythmically dense drum track.
 */
export function analyzePower(channels: Float32Array[], sampleRate: number, grid: BeatGrid | null, targetLufs = -10): PowerAnalysis {
  if (!Number.isFinite(sampleRate) || sampleRate <= 0) throw new Error('Invalid sample rate')
  const length = channels.length ? Math.min(...channels.map((c) => c.length)) : 0
  const durationSec = length / sampleRate
  const bpm = grid && Number.isFinite(grid.bpm) && grid.bpm > 0 ? grid.bpm : 120
  const barSec = 240 / bpm
  const offset = grid && Number.isFinite(grid.offsetMs) ? grid.offsetMs / 1000 : 0
  const folded = ((offset % barSec) + barSec) % barSec
  const startSec = folded > 1e-9 ? folded - barSec : 0
  const count = Math.max(1, Math.ceil((durationSec - startSec) / barSec))
  const hop = Math.max(1, Math.round(sampleRate * 0.02))
  const frameSec = hop / sampleRate
  const frames = Math.ceil(length / hop)
  const low = new Float64Array(frames)
  const mid = new Float64Array(frames)
  const high = new Float64Array(frames)
  const alphaLow = 1 - Math.exp(-2 * Math.PI * 160 / sampleRate)
  const alphaHigh = 1 - Math.exp(-2 * Math.PI * 2000 / sampleRate)
  for (const channel of channels) {
    let bass = 0, smooth = 0
    for (let i = 0; i < length; i++) {
      const x = Number.isFinite(channel[i]) ? channel[i] : 0
      bass += alphaLow * (x - bass)
      smooth += alphaHigh * (x - smooth)
      const treble = x - smooth
      const middle = smooth - bass
      const frame = Math.floor(i / hop)
      low[frame] += bass * bass
      mid[frame] += middle * middle
      high[frame] += treble * treble
    }
  }
  for (let i = 0; i < frames; i++) {
    const divisor = Math.min(hop, length - i * hop) * channels.length
    low[i] /= divisor; mid[i] /= divisor; high[i] /= divisor
  }
  const bars = Array.from({ length: count }, () => ({ power: 0, low: 0, high: 0, n: 0, attacks: 0 }))
  const frameReference = activeReference(Array.from(mid, (p, i) => p + low[i] + high[i]))
  let previousLow = 0, previousMid = 0, previousHigh = 0, lastAttack = -Infinity
  for (let i = 0; i < frames; i++) {
    const time = (i + 0.5) * frameSec
    const bar = bars[Math.min(count - 1, Math.max(0, Math.floor((time - startSec) / barSec)))]
    const power = low[i] + mid[i] + high[i]
    bar.power += power; bar.low += low[i]; bar.high += high[i]; bar.n++
    // Positive band-envelope changes; floor relative to active material avoids
    // treating tiny fluctuations in quiet tails as a series of attacks.
    const floor = Math.max(1e-16, frameReference * 0.04)
    const flux = (now: number, before: number): number => Math.max(0, now - before) / Math.max(floor, now + before)
    const attack = Math.max(flux(low[i], previousLow), flux(mid[i], previousMid), flux(high[i], previousHigh))
    if (power > frameReference * 0.015 && attack > 0.32 && time - lastAttack >= 0.065) {
      bar.attacks++; lastAttack = time
    }
    previousLow = low[i]; previousMid = mid[i]; previousHigh = high[i]
  }
  const reference = activeReference(bars.filter((bar) => bar.n).map((bar) => bar.power / bar.n))
  const values = bars.map((bar, i) => {
    if (!bar.n || reference <= 1e-16) return 0
    const relative = clamp(Math.sqrt((bar.power / bar.n) / reference))
    const seconds = Math.max(frameSec, Math.min(durationSec, startSec + (i + 1) * barSec) - Math.max(0, startSec + i * barSec))
    const rhythm = 1 - Math.exp(-bar.attacks / seconds / 3)
    const bass = clamp(bar.low / Math.max(1e-16, bar.power) / 0.55)
    const brightness = clamp(bar.high / Math.max(1e-16, bar.power) / 0.3)
    return Math.round(clamp(relative * (0.22 + 0.48 * rhythm + 0.19 * bass + 0.11 * brightness)) * 1000) / 1000
  })
  // Report loudness independently: input trim never changes the saved curve.
  const loudness = analyzeLoudness(channels.length === 1 ? [channels[0], channels[0]] : channels, sampleRate, targetLufs)
  return {
    version: POWER_VERSION, durationSec, startSec, barSec, values,
    score: Math.round(percentile(values.filter((v) => v > 0), 0.7) * 100),
    lufs: Number.isFinite(loudness.integratedLufs) ? loudness.integratedLufs : undefined,
    gainDb: loudness.gainDb,
    peakToLoudnessDb: Number.isFinite(loudness.peakToLoudnessDb) ? loudness.peakToLoudnessDb : undefined
  }
}

export function validPower(power: PowerAnalysis | null | undefined, durationSec: number): power is PowerAnalysis {
  return !!power && power.version === POWER_VERSION && Math.abs(power.durationSec - durationSec) < 0.1
    && Number.isFinite(power.startSec) && Number.isFinite(power.barSec) && power.barSec > 0
    && Array.isArray(power.values) && power.values.length > 0 && power.values.length <= 100000
    && Number.isFinite(power.score) && power.score >= 0 && power.score <= 100
    && Number.isFinite(power.gainDb) && Math.abs(power.gainDb) <= 300
    && power.values.every((v) => Number.isFinite(v) && v >= 0 && v <= 1)
}

/** Linear interpolation between bar centres, identical in the GPU and fallback. */
export function powerAt(power: PowerAnalysis, seconds: number): number {
  const index = Math.max(0, Math.min(power.values.length - 1, (seconds - power.startSec) / power.barSec - 0.5))
  const lo = Math.floor(index)
  return power.values[lo] + (power.values[Math.min(lo + 1, power.values.length - 1)] - power.values[lo]) * (index - lo)
}

/** Shared cool-to-warm palette. RGB values are linear interpolations in sRGB. */
export const ENERGY_COLOURS = [[69, 124, 230], [43, 204, 208], [241, 196, 72], [255, 87, 70]] as const
export function energyColour(value: number): [number, number, number] {
  const position = clamp(value) * (ENERGY_COLOURS.length - 1)
  const lo = Math.min(ENERGY_COLOURS.length - 2, Math.floor(position))
  const t = position - lo
  return [0, 1, 2].map((c) => (ENERGY_COLOURS[lo][c] * (1 - t) + ENERGY_COLOURS[lo + 1][c] * t) / 255) as [number, number, number]
}
