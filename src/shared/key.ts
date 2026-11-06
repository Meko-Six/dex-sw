import { FFT } from './fft'
import { resampleLinear } from './detector'

/**
 * Musical key estimation + Camelot wheel mapping.
 *
 * Pipeline:
 *   1. resample to 22.05 kHz mono
 *   2. STFT (4096 / 2048) over frames sampled across the whole track
 *   3. pick spectral peaks in 110 Hz – 2 kHz and fold them onto 12 pitch
 *      classes, weighting by magnitude^0.75
 *   4. correlate the chroma vector against Sha'ath's major and minor
 *      profiles, rotated through all 12 tonics
 *
 * Three deliberate choices, each checked against the accuracy bench
 * (accuracy/README.md) on real tracks:
 *
 *   - The band starts at 110 Hz, not 40 Hz. A four-on-the-floor kick has a
 *     strong 48–55 Hz fundamental which would otherwise vote for A or G# in
 *     every track of the genre, whether or not the track is in that key.
 *   - Peaks are weighted by a power of their magnitude, not its log. A log
 *     (it was log1p(100·mag)) flattens a held chord and a noise peak to
 *     nearly the same vote, and its constant made the weighting depend on how
 *     loud the track is; a power weighting scales out with the per-frame
 *     normalisation. On the bench this took key from 37 % to 55 % exact.
 *   - The profiles are Sha'ath's (KeyFinder), derived from recorded popular
 *     and electronic music, not Krumhansl–Kessler's classical probe tones.
 *     Still a fixed template rather than a learned model, so no WASM binary
 *     (and no AGPL obligations) comes into the app.
 *
 * Confidence is the correlation margin between the winner and the runner-up.
 * Heavily sidechained, distorted psytrance can honestly score low; the top
 * three candidates are returned so the operator can pick rather than trust.
 */

export const KEY_ANALYSIS_RATE = 22050
const FRAME_SIZE = 4096
const HOP_SIZE = 2048
const MIN_HZ = 110
const MAX_HZ = 2000
/** Frames analysed per track; spread evenly so long tracks stay fast. */
const MAX_FRAMES = 800

const PITCH_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'] as const

/** Sha'ath's key profiles (KeyFinder, 2011), indexed from the tonic. */
const MAJOR_PROFILE = [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
const MINOR_PROFILE = [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]
/** Peak weight = magnitude^PEAK_POWER: between sqrt (quiet partials count more) and linear. */
const PEAK_POWER = 0.75
/**
 * A major reading stands only if the major third has this many times the minor
 * third's energy. Scored on the bench: 1.1–1.5 all beat no rule (55 %), 1.25
 * best at 65 %; it was tuned on the tracks it is scored on.
 */
const MAJOR_THIRD_RATIO = 1.25

/**
 * Camelot codes indexed by pitch class (0 = C … 11 = B).
 * 8B is C major, 8A is A minor, which is the standard reference point.
 */
const MAJOR_CAMELOT = ['8B', '3B', '10B', '5B', '12B', '7B', '2B', '9B', '4B', '11B', '6B', '1B']
const MINOR_CAMELOT = ['5A', '12A', '7A', '2A', '9A', '4A', '11A', '6A', '1A', '8A', '3A', '10A']

export type Mode = 'major' | 'minor'

export interface KeyCandidate {
  /** Pitch class 0…11. */
  tonic: number
  tonicName: string
  mode: Mode
  /** e.g. "F# minor" */
  key: string
  /** e.g. "11A" */
  camelot: string
  score: number
}

export interface KeyEstimate {
  key: string
  tonicName: string
  mode: Mode
  camelot: string
  /** 0…1 margin over the runner-up key. */
  confidence: number
  candidates: KeyCandidate[]
}

export function camelotFor(tonic: number, mode: Mode): string {
  const index = ((tonic % 12) + 12) % 12
  return mode === 'major' ? MAJOR_CAMELOT[index] : MINOR_CAMELOT[index]
}

export function keyName(tonic: number, mode: Mode): string {
  const index = ((tonic % 12) + 12) % 12
  return `${PITCH_NAMES[index]} ${mode}`
}

function hann(size: number): Float32Array {
  const window = new Float32Array(size)
  for (let i = 0; i < size; i++) window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (size - 1))
  return window
}

/**
 * Chroma vector for a mono signal: 12 bins of accumulated spectral-peak energy.
 * Frames are normalised individually so a quiet breakdown contributes as much
 * pitch information as a loud drop.
 */
export function chromaVector(input: Float32Array, sampleRate: number): Float32Array {
  const chroma = new Float32Array(12)
  if (input.length < FRAME_SIZE * 4) return chroma

  const samples = sampleRate === KEY_ANALYSIS_RATE ? input : resampleLinear(input, sampleRate, KEY_ANALYSIS_RATE)
  const binHz = KEY_ANALYSIS_RATE / FRAME_SIZE
  const minBin = Math.max(2, Math.floor(MIN_HZ / binHz))
  const maxBin = Math.min(FRAME_SIZE / 2 - 2, Math.ceil(MAX_HZ / binHz))

  const fft = new FFT(FRAME_SIZE)
  const window = hann(FRAME_SIZE)
  const re = new Float64Array(FRAME_SIZE)
  const im = new Float64Array(FRAME_SIZE)
  const magnitude = new Float32Array(maxBin + 2)

  const totalFrames = Math.floor((samples.length - FRAME_SIZE) / HOP_SIZE) + 1
  const stride = Math.max(1, Math.ceil(totalFrames / MAX_FRAMES))
  let usedFrames = 0

  for (let frame = 0; frame < totalFrames; frame += stride) {
    const offset = frame * HOP_SIZE
    let energy = 0
    for (let i = 0; i < FRAME_SIZE; i++) {
      const value = samples[offset + i]
      energy += value * value
      re[i] = value * window[i]
      im[i] = 0
    }
    // Skip near-silence: it adds noise, not pitch.
    if (energy / FRAME_SIZE < 1e-6) continue
    fft.transform(re, im)

    // One bin either side too: the band's edge bins are peaks only if they
    // stand above their real neighbours, not above an unfilled zero.
    for (let bin = minBin - 1; bin <= maxBin + 1; bin++) {
      magnitude[bin] = Math.pow(Math.hypot(re[bin], im[bin]), PEAK_POWER)
    }

    // Spectral peaks only: a harmonic series is one pitch, not six.
    const frameChroma = new Float32Array(12)
    let peakSum = 0
    for (let bin = minBin; bin <= maxBin; bin++) {
      const value = magnitude[bin]
      if (value <= magnitude[bin - 1] || value < magnitude[bin + 1]) continue
      const frequency = bin * binHz
      const midi = 69 + 12 * Math.log2(frequency / 440)
      const pitchClass = ((Math.round(midi) % 12) + 12) % 12
      frameChroma[pitchClass] += value
      peakSum += value
    }
    if (peakSum <= 0) continue

    for (let i = 0; i < 12; i++) chroma[i] += frameChroma[i] / peakSum
    usedFrames++
  }

  if (usedFrames === 0) return chroma
  let total = 0
  for (let i = 0; i < 12; i++) total += chroma[i]
  if (total > 0) for (let i = 0; i < 12; i++) chroma[i] /= total
  return chroma
}

function pearson(a: ArrayLike<number>, b: ArrayLike<number>): number {
  const n = a.length
  let meanA = 0
  let meanB = 0
  for (let i = 0; i < n; i++) {
    meanA += a[i]
    meanB += b[i]
  }
  meanA /= n
  meanB /= n
  let num = 0
  let denA = 0
  let denB = 0
  for (let i = 0; i < n; i++) {
    const da = a[i] - meanA
    const db = b[i] - meanB
    num += da * db
    denA += da * da
    denB += db * db
  }
  if (denA <= 1e-12 || denB <= 1e-12) return 0
  return num / Math.sqrt(denA * denB)
}

function correlate(chroma: Float32Array, profile: number[], tonic: number): number {
  const rotated = new Array<number>(12)
  for (let i = 0; i < 12; i++) rotated[i] = profile[(i - tonic + 12) % 12]
  return pearson(chroma, rotated)
}

export function estimateKeyFromChroma(chroma: Float32Array): KeyEstimate {
  const scored: KeyCandidate[] = []
  for (const mode of ['major', 'minor'] as const) {
    const profile = mode === 'major' ? MAJOR_PROFILE : MINOR_PROFILE
    for (let tonic = 0; tonic < 12; tonic++) {
      scored.push({
        tonic,
        tonicName: PITCH_NAMES[tonic],
        mode,
        key: keyName(tonic, mode),
        camelot: camelotFor(tonic, mode),
        score: correlate(chroma, profile, tonic)
      })
    }
  }
  scored.sort((a, b) => b.score - a.score)

  // Minor unless the major third clearly wins. Much psytrance and techno has no
  // third at all, and the profiles then call the mode on noise; this music is
  // mostly minor, so a major reading has to show its third.
  const top = scored[0]
  const parallelMinor = scored.find((candidate) => candidate.tonic === top.tonic && candidate.mode === 'minor')
  const best =
    top.mode === 'major' && parallelMinor && chroma[(top.tonic + 4) % 12] <= MAJOR_THIRD_RATIO * chroma[(top.tonic + 3) % 12]
      ? parallelMinor
      : top
  if (best !== top) {
    scored.splice(scored.indexOf(best), 1)
    scored.unshift(best)
  }
  // The runner-up is often the relative major/minor of the same key, which is
  // the ambiguity that actually matters here, so compare against the best
  // *different* key. It is the profiles' own margin, so a mode called by the
  // third rule keeps the confidence of the tonic it was read on.
  const runnerUp = scored.find((candidate) => candidate.key !== top.key) ?? top
  const margin = top.score - runnerUp.score
  const confidence = Math.max(0, Math.min(1, margin / 0.2))

  return {
    key: best.key,
    tonicName: best.tonicName,
    mode: best.mode,
    camelot: best.camelot,
    confidence,
    candidates: scored.slice(0, 3)
  }
}

export function estimateKey(input: Float32Array, sampleRate: number): KeyEstimate {
  return estimateKeyFromChroma(chromaVector(input, sampleRate))
}

export interface HarmonicNeighbours {
  /** The same key in the other mode (energy is usually compatible). */
  relative: string
  /** One step counter-clockwise on the wheel. */
  previous: string
  /** One step clockwise on the wheel. */
  next: string
}

/**
 * Camelot neighbours: ±1 in the same letter and the relative major/minor are
 * the mixes that do not fight. Returned as Camelot codes.
 */
export function harmonicNeighbours(camelot: string): HarmonicNeighbours | null {
  const match = camelot.match(/^(\d{1,2})([AB])$/)
  if (!match) return null
  const number = Number(match[1])
  const letter = match[2] as 'A' | 'B'
  const wrap = (value: number): number => ((value - 1 + 12) % 12) + 1
  return {
    relative: `${number}${letter === 'A' ? 'B' : 'A'}`,
    previous: `${wrap(number - 1)}${letter}`,
    next: `${wrap(number + 1)}${letter}`
  }
}
