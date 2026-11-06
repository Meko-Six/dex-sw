import { FFT } from './fft'
import { BEATS_PER_BAR, foldBpm, MAX_BPM, MIN_BPM, normalizeOffset } from './grid'
import {
  bandFrames,
  chooseTempo,
  estimateBarPhase,
  locateKick,
  refineTempo,
  type BandFrames,
  type TempoHypothesis
} from './grid-refine'

/**
 * Beat detection.
 *
 * Pipeline (self-contained, no native deps, runs in a worker):
 *   1. resample to 11.025 kHz mono
 *   2. short-window STFT -> band-limited spectral-flux onset envelope
 *   3. autocorrelation tempo estimate with a log-Gaussian prior + octave folding
 *   4. global comb fit: search (period, phase) for the grid that lands on the
 *      most onset energy across the whole track
 *   5. the comb's own confidence: onset contrast, autocorrelation strength,
 *      coverage and how tightly the onsets sit on its grid
 *   6. refinement (grid-refine.ts) on ~0.5 ms band energies: the tempo by
 *      folding over the whole track, preferring a whole-number BPM; ½×/⅔×/…/2×
 *      readings ranked by how undiluted their folded kick is; the phase put
 *      on the kick's attack rather than whatever the comb landed on; and the
 *      bar phase, so offsetMs is a downbeat (it is folded at the bar, not the beat).
 *      Confidence leans on how sharply the track folds at its tempo.
 *
 * A constant-tempo grid is the model the mixer actually uses (grid lines, sync,
 * loops), so fitting it directly is both simpler and more stable than tracking
 * beats frame-by-frame and then regressing a line through them — the DP tracker
 * happily locked onto half-beat hats on 4/4 material.
 */

export const ANALYSIS_SAMPLE_RATE = 11025
const FRAME_SIZE = 256
const HOP_SIZE = 128
export const ANALYSIS_FPS = ANALYSIS_SAMPLE_RATE / HOP_SIZE

/** Another reading of the same track, ready to apply: its own kick phase and downbeat. */
export interface GridAlternate {
  bpm: number
  offsetMs: number
  /** e.g. "2/3": this tempo over the chosen one. */
  relation: string
  /** Folded kick salience relative to the strongest reading (1 = strongest). */
  salience: number
}

/** What the refinement measured, for confidence and for the bench. */
export interface GridEvidence {
  /** How sharply the low band folds at the tempo (a steady kick folds sharply). */
  foldSharpness: number
  /** How far the kick stands out from the rest of the folded beat. */
  kickContrast: number
  /** How clearly the bar phase won, 0…~0.5. */
  barMargin: number
  /** True when the tempo is a whole number the fold preferred. */
  wholeNumberBpm: boolean
}

export interface BeatDetection {
  bpm: number
  /** A downbeat ("one"), in [0, bar). */
  offsetMs: number
  confidence: number
  beatsMs: number[]
  /** Metrically related tempo readings, strongest first (the chosen one included). */
  hypotheses: TempoHypothesis[]
  /** Another reading is close enough that the grid should be flagged for a person to check. */
  uncertain: boolean
  /** The other readings as ready-made grids, strongest first. */
  alternates: GridAlternate[]
  evidence: GridEvidence
}

/**
 * Tempo search constraints for a known genre.
 *
 * The defaults reproduce the original behaviour (prior at 122 BPM, fold into
 * 70–180). A crate of psytrance or hard trance should pass a preset instead:
 * with a 70 BPM floor, a half-time reading of a 145 BPM track is inside the
 * window and foldBpm cannot rescue it.
 */
export interface TempoHint {
  /** Centre of the log-Gaussian tempo prior. */
  bpmPrior?: number
  /** Width of the prior in octaves; smaller is more opinionated. */
  priorWidthOctaves?: number
  /** Autocorrelation search range. */
  minBpm?: number
  maxBpm?: number
  /** Octave folding window for the final answer. */
  foldMin?: number
  foldMax?: number
}

export const TEMPO_HINTS: Record<string, TempoHint> = {
  auto: {},
  psytrance: { bpmPrior: 143, priorWidthOctaves: 0.22, minBpm: 100, maxBpm: 180, foldMin: 120, foldMax: 175 },
  hardTrance: { bpmPrior: 146, priorWidthOctaves: 0.25, minBpm: 100, maxBpm: 185, foldMin: 125, foldMax: 180 },
  house: { bpmPrior: 124, priorWidthOctaves: 0.35, minBpm: 80, maxBpm: 180, foldMin: 100, foldMax: 140 }
}

/** Linear resampling is plenty for transient detection and keeps this dependency-free. */
export function resampleLinear(input: Float32Array, from: number, to: number): Float32Array {
  if (from === to) return input
  const ratio = from / to
  const length = Math.max(1, Math.floor(input.length / ratio))
  const out = new Float32Array(length)
  for (let i = 0; i < length; i++) {
    const pos = i * ratio
    const i0 = Math.floor(pos)
    const frac = pos - i0
    const a = input[i0] ?? 0
    const b = input[i0 + 1] ?? a
    out[i] = a + (b - a) * frac
  }
  return out
}

function hann(n: number): Float32Array {
  const w = new Float32Array(n)
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1))
  return w
}

function mean(values: Float32Array): number {
  if (values.length === 0) return 0
  let sum = 0
  for (let i = 0; i < values.length; i++) sum += values[i]
  return sum / values.length
}

function rmsOf(values: Float32Array): number {
  if (values.length === 0) return 0
  let sum = 0
  for (let i = 0; i < values.length; i++) sum += values[i] * values[i]
  return Math.sqrt(sum / values.length)
}

/** Spectral-flux onset strength envelope, detrended and normalised. */
export function onsetEnvelope(x: Float32Array): Float32Array {
  const frameCount = Math.floor((x.length - FRAME_SIZE) / HOP_SIZE) + 1
  if (frameCount < 8) return new Float32Array(0)

  const binHz = ANALYSIS_SAMPLE_RATE / FRAME_SIZE
  const halfBins = FRAME_SIZE / 2
  const maxBin = Math.min(halfBins - 1, Math.round(6000 / binHz))
  const lowLo = Math.max(1, Math.round(30 / binHz))
  const lowHi = Math.min(maxBin, Math.max(lowLo + 1, Math.round(160 / binHz)))

  const fft = new FFT(FRAME_SIZE)
  const re = new Float64Array(FRAME_SIZE)
  const im = new Float64Array(FRAME_SIZE)
  const window = hann(FRAME_SIZE)
  const mag = new Float32Array(halfBins)
  const prevMag = new Float32Array(halfBins)
  const flux = new Float32Array(frameCount)
  const lowFlux = new Float32Array(frameCount)

  for (let f = 0; f < frameCount; f++) {
    const offset = f * HOP_SIZE
    for (let i = 0; i < FRAME_SIZE; i++) {
      re[i] = x[offset + i] * window[i]
      im[i] = 0
    }
    fft.transform(re, im)
    let sum = 0
    let low = 0
    for (let k = 1; k < halfBins; k++) {
      const m = Math.log1p(60 * Math.hypot(re[k], im[k]))
      mag[k] = m
      const diff = m - prevMag[k]
      if (diff > 0) {
        if (k <= maxBin) sum += diff
        if (k >= lowLo && k <= lowHi) low += diff
      }
    }
    flux[f] = sum
    lowFlux[f] = low
    prevMag.set(mag)
  }

  const fluxMean = mean(flux) || 1
  const lowMean = mean(lowFlux) || 1
  const combined = new Float32Array(frameCount)
  for (let i = 0; i < frameCount; i++) {
    combined[i] = 0.6 * (flux[i] / fluxMean) + 0.4 * (lowFlux[i] / lowMean)
  }

  // Remove the slow-moving baseline so quiet sections do not dominate.
  const radius = Math.max(1, Math.round(ANALYSIS_FPS * 0.5))
  const prefix = new Float64Array(frameCount + 1)
  for (let i = 0; i < frameCount; i++) prefix[i + 1] = prefix[i] + combined[i]
  const out = new Float32Array(frameCount)
  for (let i = 0; i < frameCount; i++) {
    const lo = Math.max(0, i - radius)
    const hi = Math.min(frameCount, i + radius + 1)
    const avg = (prefix[hi] - prefix[lo]) / (hi - lo)
    out[i] = Math.max(0, combined[i] - avg)
  }

  const m = mean(out)
  let variance = 0
  for (let i = 0; i < frameCount; i++) variance += (out[i] - m) ** 2
  const std = Math.sqrt(variance / frameCount)
  if (std > 1e-6) {
    for (let i = 0; i < frameCount; i++) out[i] = (out[i] - m) / std
  }
  return out
}

export interface TempoEstimate {
  bpm: number
  /** Autocorrelation strength at the winning lag, normalised to 0…1. */
  strength: number
}

/**
 * Autocorrelation tempo estimate. The log-Gaussian prior keeps ambiguous
 * material near typical dance tempos; octave folding puts the answer in
 * 70-180 BPM (a 174 BPM drum & bass track stays at 174).
 */
export function estimateTempo(env: Float32Array, fps = ANALYSIS_FPS, hint: TempoHint = {}): TempoEstimate {
  const minBpm = hint.minBpm ?? 60
  const maxBpm = hint.maxBpm ?? 205
  const priorCenter = hint.bpmPrior ?? 122
  const priorWidth = hint.priorWidthOctaves ?? 0.9
  const minLag = Math.max(2, Math.floor((60 / maxBpm) * fps))
  const maxLag = Math.min(env.length - 2, Math.ceil((60 / minBpm) * fps))
  if (maxLag <= minLag + 2) return { bpm: 120, strength: 0 }

  const ac = new Float64Array(maxLag + 2)
  for (let lag = minLag; lag <= maxLag; lag++) {
    let sum = 0
    const n = env.length - lag
    for (let i = 0; i < n; i++) sum += env[i] * env[i + lag]
    ac[lag] = sum / n
  }
  const acAt = (lag: number): number => (lag >= minLag && lag <= maxLag ? ac[lag] : 0)

  let selfEnergy = 0
  for (let i = 0; i < env.length; i++) selfEnergy += env[i] * env[i]
  selfEnergy = Math.max(1e-9, selfEnergy / env.length)

  let best = -Infinity
  let bestLag = minLag
  for (let lag = minLag; lag <= maxLag; lag++) {
    const bpm = (60 * fps) / lag
    const prior = Math.exp(-0.5 * (Math.log2(bpm / priorCenter) / priorWidth) ** 2)
    // Reward the faster interpretation slightly so we don't lock to half-time.
    const harmonic = ac[lag] + 0.3 * acAt(Math.round(lag / 2))
    const score = harmonic * prior
    if (score > best) {
      best = score
      bestLag = lag
    }
  }

  const y0 = acAt(bestLag - 1)
  const y1 = acAt(bestLag)
  const y2 = acAt(bestLag + 1)
  const denom = y0 - 2 * y1 + y2
  const delta = Math.abs(denom) > 1e-12 ? Math.max(-0.5, Math.min(0.5, (0.5 * (y0 - y2)) / denom)) : 0
  const bpm = foldBpm((60 * fps) / (bestLag + delta), hint.foldMin, hint.foldMax)
  const strength = Math.max(0, Math.min(1, (y1 / selfEnergy) * 1.15))
  return { bpm, strength }
}

function envAt(env: Float32Array, pos: number): number {
  if (pos < 0 || pos >= env.length - 1) return 0
  const i = Math.floor(pos)
  const f = pos - i
  return env[i] * (1 - f) + env[i + 1] * f
}

interface GridSearch {
  periodFrames: number
  offsetFrames: number
  score: number
  meanOnset: number
  coverage: number
}

function scoreGrid(env: Float32Array, period: number, offset: number): GridSearch {
  let sum = 0
  let count = 0
  let hits = 0
  for (let pos = offset; pos < env.length; pos += period) {
    const v = envAt(env, pos)
    sum += v
    if (v > 0.5) hits++
    count++
  }
  return {
    periodFrames: period,
    offsetFrames: offset,
    score: count > 0 ? sum / count : 0,
    meanOnset: count > 0 ? sum / count : 0,
    coverage: count > 0 ? hits / count : 0
  }
}

/**
 * Global comb fit: the (period, phase) pair whose beat positions carry the most
 * onset energy over the whole track. Coarse scan then a fine local refinement.
 */
export function fitBeatPhase(env: Float32Array, periodGuess: number): GridSearch {
  let best: GridSearch = { periodFrames: periodGuess, offsetFrames: 0, score: -Infinity, meanOnset: 0, coverage: 0 }

  const evaluate = (period: number, offset: number): void => {
    const result = scoreGrid(env, period, offset)
    // Mild preference for the tempo estimator's answer, and reward grids that
    // actually land on many beats rather than one lucky position.
    const score = result.score - 0.08 * Math.abs(period - periodGuess) - 1.5 * Math.max(0, 0.3 - result.coverage)
    if (score > best.score) best = { ...result, score }
  }

  const coarseStep = Math.max(0.01, periodGuess * 0.0008)
  for (let period = periodGuess * 0.97; period <= periodGuess * 1.03; period += coarseStep) {
    for (let offset = 0; offset < period; offset += 1) evaluate(period, offset)
  }

  const p0 = best.periodFrames
  const o0 = best.offsetFrames
  const fineSpan = periodGuess * 0.0015
  for (let period = p0 - fineSpan; period <= p0 + fineSpan; period += fineSpan / 8) {
    for (let d = -1.5; d <= 1.5; d += 0.1) {
      let offset = (o0 + d) % period
      if (offset < 0) offset += period
      evaluate(period, offset)
    }
  }
  return best
}

/** Mean distance between grid beats and the nearest local onset peak, in seconds. */
export function gridJitterSec(env: Float32Array, period: number, offset: number): number {
  let sum = 0
  let count = 0
  const radius = Math.max(1, Math.round(period * 0.2))
  for (let pos = offset; pos < env.length; pos += period) {
    const center = Math.round(pos)
    let bestValue = -Infinity
    let bestIndex = center
    for (let i = Math.max(0, center - radius); i <= Math.min(env.length - 1, center + radius); i++) {
      if (env[i] > bestValue) {
        bestValue = env[i]
        bestIndex = i
      }
    }
    if (bestValue > 0.3) {
      sum += Math.abs(bestIndex - pos)
      count++
    }
  }
  if (count === 0) return 0.1
  return (sum / count) * (HOP_SIZE / ANALYSIS_SAMPLE_RATE)
}

function clamp01(v: number): number {
  return Math.max(0, Math.min(1, v))
}

export function detectBeats(input: Float32Array, sampleRate: number, hint: TempoHint = {}): BeatDetection {
  const fallback: BeatDetection = {
    bpm: 120,
    offsetMs: 0,
    confidence: 0,
    beatsMs: [],
    hypotheses: [],
    uncertain: true,
    alternates: [],
    evidence: { foldSharpness: 0, kickContrast: 0, barMargin: 0, wholeNumberBpm: false }
  }
  if (input.length < sampleRate * 6) return fallback

  let energy = 0
  for (let i = 0; i < input.length; i += 16) energy += input[i] * input[i]
  const inputRms = Math.sqrt(energy / Math.max(1, input.length / 16))
  if (inputRms < 1e-4) return fallback

  const mono = resampleLinear(input, sampleRate, ANALYSIS_SAMPLE_RATE)
  const env = onsetEnvelope(mono)
  if (env.length < ANALYSIS_FPS * 4) return fallback

  const { bpm: tempoBpm, strength } = estimateTempo(env, ANALYSIS_FPS, hint)
  const grid = fitBeatPhase(env, (60 / tempoBpm) * ANALYSIS_FPS)
  const coarseBpm = foldBpm((60 * ANALYSIS_FPS) / grid.periodFrames, hint.foldMin, hint.foldMax)

  const contrast = grid.meanOnset / Math.max(1e-6, rmsOf(env))
  const jitter = gridJitterSec(env, grid.periodFrames, grid.offsetFrames)

  const combConfidence = clamp01(
    0.45 * clamp01((contrast - 0.9) / 1.6) +
      0.3 * clamp01(strength * 1.2) +
      0.15 * clamp01(grid.coverage) +
      0.1 * clamp01(1 - jitter / 0.03)
  )

  // Refinement at full rate: precise tempo, the right metrical reading, the kick's phase.
  const bands = bandFrames(input, sampleRate)
  const refined = refineTempo(bands, coarseBpm)
  const choice = chooseTempo(bands, refined.bpm, hint.foldMin ?? MIN_BPM, hint.foldMax ?? MAX_BPM)
  const final = Math.abs(choice.chosen.bpm - refined.bpm) < 0.01 ? refined : refineTempo(bands, choice.chosen.bpm, 0.05)
  const bpm = final.bpm
  const placed = placeGrid(bands, bpm)
  const periodSec = 60 / bpm

  const alternates: GridAlternate[] = choice.hypotheses
    .filter((h) => h !== choice.chosen)
    .slice(0, 3)
    .map((h) => ({ bpm: h.bpm, offsetMs: placeGrid(bands, h.bpm).offsetMs, relation: h.relation, salience: h.salience }))

  // Fold sharpness is what separates a steady kick from noise (real tracks fold at 0.55 and up,
  // noise near 0.25); a clear bar phase and the comb's own measure add a little.
  const confidence = clamp01(
    (0.6 * clamp01((final.sharpness - 0.3) / 0.4) + 0.2 * clamp01(placed.barMargin / 0.08) + 0.2 * combConfidence) *
      (choice.uncertain ? 0.7 : 1)
  )

  const beatCount = Math.floor((input.length / sampleRate - placed.kickSec) / periodSec) + 1
  const beatsMs: number[] = []
  for (let i = 0; i < beatCount; i++) beatsMs.push(Math.round((placed.kickSec + i * periodSec) * 1000))

  return {
    bpm,
    offsetMs: placed.offsetMs,
    confidence,
    beatsMs,
    hypotheses: choice.hypotheses.map((h) => (h === choice.chosen ? { ...h, bpm } : h)),
    uncertain: choice.uncertain,
    alternates,
    evidence: {
      foldSharpness: final.sharpness,
      kickContrast: placed.kickContrast,
      barMargin: placed.barMargin,
      wholeNumberBpm: final.wholeNumber
    }
  }
}

/** Kick phase and downbeat at a known tempo. */
function placeGrid(
  bands: BandFrames,
  bpm: number
): { offsetMs: number; kickSec: number; kickContrast: number; barMargin: number } {
  const periodSec = 60 / bpm
  const kick = locateKick(bands, bpm)
  // Beat 0 is the first kick at the start of the audio; one found a hair before 0:00 wraps to the
  // end of the beat, but it is still beat 0, and a render that starts on bar 1 starts there.
  const firstBeatSec = kick.offsetSec > periodSec - 0.02 ? kick.offsetSec - periodSec : kick.offsetSec
  const bar = estimateBarPhase(bands, bpm, firstBeatSec, BEATS_PER_BAR)
  return {
    offsetMs: normalizeOffset((firstBeatSec + bar.beat * periodSec) * 1000, BEATS_PER_BAR * periodSec * 1000),
    kickSec: kick.offsetSec,
    kickContrast: kick.contrast,
    barMargin: bar.margin
  }
}
