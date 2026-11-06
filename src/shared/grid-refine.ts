/**
 * Grid refinement: turns the detector's coarse (tempo, phase) into a grid that
 * stays on the kick for the whole track.
 *
 * The coarse comb fit works on an 11.6 ms onset envelope, which is fine for
 * finding a tempo but not for holding it: 0.03 BPM of error slips the grid by
 * 60–230 ms over a six-minute track, and on psytrance the comb happily locks to
 * a bass sixteenth instead of the kick. Hand-marked tracks showed both.
 *
 * Three steps, all on band energies at ~0.5 ms:
 *
 *   1. Tempo by folding. Overlay the low-band energy of every beat at a
 *      candidate period; at the true period the kicks pile up into one sharp
 *      peak, a hair off they smear. The sharpest fold wins, and a whole-number
 *      BPM that folds as sharply is preferred, since tracks made in a DAW sit on
 *      one exactly.
 *   2. Phase from a kick model. A kick is the strongest low-frequency onset in
 *      the beat (low band quiet before, loud after; a bass note rises out of the
 *      previous note's tail, a hat has no low end), and its attack is the
 *      sharpest high-band click around where that low end arrives (a pitch
 *      sweep can reach the low band 20–40 ms after the click, and a slow kick body
 *      like Mahadeva Power Source's over 40). When the
 *      strongest onset has a weak click and another strong one a sharp click
 *      (a sidechained off-beat bass), the click can tip it.
 *   3. Tempo hypotheses. The folded kick salience is diluted at a period that is
 *      too short (half the folds land between kicks) but not at one that is too
 *      long, so the answer is the fastest candidate whose kick is as salient as
 *      the best. This is what tells 125 from the 3:2 reading at 83.3.
 *   4. Bar phase. Arrangements change on the bar line (a loop enters, the bass
 *      moves, a breakdown starts), so the beat position whose band energies
 *      differ most from the beat before is the "one". The first beat of the
 *      audio only breaks a near-tie: 4 of 20 marked tracks do not start on bar 1.
 */

/** A low-band onset this share of the strongest is a kick candidate. */
const KICK_CANDIDATE_SHARE = 0.3
/** Frame length for the band energies, in seconds (rounded to whole samples per rate). */
const FRAME_TARGET_SEC = 0.0005
/** Frames are summed by this factor for the tempo search, which needs less resolution. */
const TEMPO_DECIMATION = 4
const HIGH_BAND_HZ = 2000
const LOW_BAND_HZ = 120

/** How sharply a whole-number tempo must fold, relative to the best, to be preferred. */
const WHOLE_BPM_TOLERANCE = 0.97
/** A faster tempo whose kick salience is at least this share of the best is not diluted. */
const UNDILUTED_SHARE = 0.75
/** A rejected faster reading this salient (or a slower one this much stronger) makes the call uncertain. */
const AMBIGUOUS_SHARE = 0.6

export interface BandFrames {
  /** Energy above HIGH_BAND_HZ per frame: clicks and hats. */
  high: Float32Array
  /** What the other two bands leave: leads, pads, snares. */
  mid: Float32Array
  /** Energy below LOW_BAND_HZ per frame: kick body and bass. */
  low: Float32Array
  frameSec: number
}

/** Two-pole low-pass and two-pole high-pass band energies, framed at ~0.5 ms. */
export function bandFrames(x: Float32Array, sampleRate: number): BandFrames {
  const hop = Math.max(1, Math.round(sampleRate * FRAME_TARGET_SEC))
  const frames = Math.floor(x.length / hop)
  const high = new Float32Array(frames)
  const mid = new Float32Array(frames)
  const low = new Float32Array(frames)
  const aLow = Math.exp((-2 * Math.PI * LOW_BAND_HZ) / sampleRate)
  const aHigh = Math.exp((-2 * Math.PI * HIGH_BAND_HZ) / sampleRate)
  let l1 = 0
  let l2 = 0
  let h1 = 0
  let h2 = 0
  for (let f = 0, i = 0; f < frames; f++) {
    let sumLow = 0
    let sumMid = 0
    let sumHigh = 0
    for (let j = 0; j < hop; j++, i++) {
      const v = x[i]
      l1 = (1 - aLow) * v + aLow * l1
      l2 = (1 - aLow) * l1 + aLow * l2
      sumLow += l2 * l2
      h1 = (1 - aHigh) * v + aHigh * h1
      const y = v - h1
      h2 = (1 - aHigh) * y + aHigh * h2
      const z = y - h2
      sumHigh += z * z
      const m = v - l2 - z
      sumMid += m * m
    }
    low[f] = sumLow
    mid[f] = sumMid
    high[f] = sumHigh
  }
  return { high, mid, low, frameSec: hop / sampleRate }
}

function decimate(values: Float32Array, factor: number): Float32Array {
  const out = new Float32Array(Math.floor(values.length / factor))
  for (let i = 0; i < out.length; i++) {
    let sum = 0
    for (let j = 0; j < factor; j++) sum += values[i * factor + j]
    out[i] = sum
  }
  return out
}

/**
 * Mean of `values` folded at `periodFrames` into `bins` phase bins, phase 0 at
 * frame 0. Frame f covers [f, f+1) frames, so its centre is what is binned.
 */
export function foldFrames(values: Float32Array, periodFrames: number, bins: number): Float64Array {
  const sum = new Float64Array(bins)
  const count = new Float64Array(bins)
  const scale = bins / periodFrames
  // Step the phase instead of taking a modulo per frame; re-anchor now and then so it cannot drift.
  let pos = (0.5 * scale) % bins
  for (let f = 0; f < values.length; f++) {
    if ((f & 4095) === 0) pos = ((f + 0.5) * scale) % bins
    const b = pos >= bins ? bins - 1 : pos | 0
    sum[b] += values[f]
    count[b]++
    pos += scale
    if (pos >= bins) pos -= bins
  }
  for (let b = 0; b < bins; b++) sum[b] = count[b] > 0 ? sum[b] / count[b] : 0
  return sum
}

/** Coefficient of variation of a fold: how much the energy piles up at one phase. */
function foldSharpness(profile: Float64Array): number {
  let mean = 0
  for (const v of profile) mean += v
  mean /= profile.length
  if (mean <= 0) return 0
  let variance = 0
  for (const v of profile) variance += (v - mean) ** 2
  return Math.sqrt(variance / profile.length) / mean
}

export interface TempoRefinement {
  bpm: number
  /** True when the whole-number tempo was chosen over the sharpest fractional one. */
  wholeNumber: boolean
  /** Fold sharpness at the chosen tempo (higher = steadier, more periodic). */
  sharpness: number
}

/**
 * Precise tempo near `bpmGuess` by folding the low band. The search spans
 * ±`spanBpm` and steps finer than the fold's own peak width, which narrows as
 * the track gets longer (a longer baseline resolves the tempo better).
 */
export function refineTempo(bands: BandFrames, bpmGuess: number, spanBpm = 0.5): TempoRefinement {
  const low = decimate(bands.low, TEMPO_DECIMATION)
  const frameSec = bands.frameSec * TEMPO_DECIMATION
  const durationSec = low.length * frameSec
  const sharpnessAt = (bpm: number): number => foldSharpness(foldFrames(low, 60 / bpm / frameSec, 120))

  const beats = Math.max(16, (durationSec * bpmGuess) / 60)
  // A tempo error of d BPM smears the fold by beats·d/bpm of a beat; step at a quarter-beat smear.
  const coarseStep = Math.min(0.02, (0.25 * bpmGuess) / beats)
  let best = bpmGuess
  let bestSharpness = -Infinity
  for (let bpm = bpmGuess - spanBpm; bpm <= bpmGuess + spanBpm + 1e-9; bpm += coarseStep) {
    const s = sharpnessAt(bpm)
    if (s > bestSharpness) {
      bestSharpness = s
      best = bpm
    }
  }
  const fineStep = coarseStep / 10
  const centre = best
  for (let bpm = centre - coarseStep; bpm <= centre + coarseStep + 1e-9; bpm += fineStep) {
    const s = sharpnessAt(bpm)
    if (s > bestSharpness) {
      bestSharpness = s
      best = bpm
    }
  }

  const whole = Math.round(best)
  if (Math.abs(whole - best) <= spanBpm) {
    const s = sharpnessAt(whole)
    if (s >= WHOLE_BPM_TOLERANCE * bestSharpness) return { bpm: whole, wholeNumber: true, sharpness: s }
  }
  return { bpm: best, wholeNumber: false, sharpness: bestSharpness }
}

/** Circular running mean over a folded profile: mean of `len` bins starting at `from`. */
function circularWindow(profile: Float64Array): (from: number, len: number) => number {
  const n = profile.length
  const prefix = new Float64Array(2 * n + 1)
  for (let i = 0; i < 2 * n; i++) prefix[i + 1] = prefix[i] + profile[i % n]
  return (from, len) => {
    const start = ((from % n) + n) % n
    return (prefix[start + len] - prefix[start]) / len
  }
}

export interface KickPhase {
  /** Seconds from the start of the audio to a kick attack (in [0, period)). */
  offsetSec: number
  /** Folded low-band onset strength at the kick, in the band's own energy units. */
  salience: number
  /** The kick's onset over the beat's mean onset: how much it stands out from the rest of the beat. */
  contrast: number
}

interface KickProfiles {
  bins: number
  binSec: number
  /** Low-band onset strength per phase bin: energy 10–80 ms after minus 20 ms before. */
  onset: Float64Array
  high: (from: number, len: number) => number
}

function kickProfiles(bands: BandFrames, bpm: number): KickProfiles {
  const periodFrames = 60 / bpm / bands.frameSec
  const bins = Math.max(16, Math.round(periodFrames))
  const binSec = 60 / bpm / bins
  const toBins = (ms: number): number => Math.max(1, Math.round(ms / 1000 / binSec))
  const low = circularWindow(foldFrames(bands.low, periodFrames, bins))
  const high = circularWindow(foldFrames(bands.high, periodFrames, bins))
  const onset = new Float64Array(bins)
  for (let k = 0; k < bins; k++) {
    onset[k] = Math.max(0, low(k + toBins(10), toBins(70)) - low(k - toBins(20), toBins(20)))
  }
  return { bins, binSec, onset, high }
}

/** Kick salience at a tempo: how strongly the folded beat holds one low-frequency onset. */
export function kickSalience(bands: BandFrames, bpm: number): number {
  const { onset } = kickProfiles(bands, bpm)
  let max = 0
  for (const v of onset) max = Math.max(max, v)
  return max
}

/**
 * Where in the beat the kick attack is, at a tempo already known precisely.
 *
 * Every strong low-band onset is a candidate (a local peak within 30 ms, at
 * least 30 % of the strongest), each paired with its click. The low-band onset
 * is the main evidence and the click the second, so a candidate scores
 * onset² × click. A plain product is too even: Traffic's kick has a weak click
 * beside an off-beat hat with a strong one, while Nice Day sidechains its bass
 * so the off-beat bass swells out of silence and outscores the kick's onset,
 * which rises out of the last bass note's tail but has twice the click.
 */
export function locateKick(bands: BandFrames, bpm: number): KickPhase {
  const { bins, binSec, onset, high } = kickProfiles(bands, bpm)
  const toBins = (ms: number): number => Math.max(1, Math.round(ms / 1000 / binSec))
  const at = (k: number): number => onset[((k % bins) + bins) % bins]
  let strongest = 0
  for (let k = 0; k < bins; k++) strongest = Math.max(strongest, onset[k])

  // The click: the biggest jump in high-band energy (3 ms after over 6 ms before),
  // from 60 ms before the low-band onset (a pitch sweep reaches the low band late;
  // Mahadeva Power Source's onset lands 42 ms after its click)
  // to 15 ms after it (the onset looks 10 ms ahead, so a kick whose low end starts
  // at once scores highest just before its own attack).
  const clickNear = (lowAt: number): { attack: number; click: number } => {
    let attack = lowAt
    let click = -Infinity
    for (let d = -toBins(60); d <= toBins(15); d++) {
      const k = lowAt + d
      const value = high(k, toBins(3)) - high(k - toBins(6), toBins(6))
      if (value > click) {
        click = value
        attack = k
      }
    }
    return { attack, click: Math.max(0, click) }
  }

  const candidates: Array<{ lowAt: number; onset: number; attack: number; click: number }> = []
  const peakRadius = toBins(30)
  for (let k = 0; k < bins; k++) {
    if (onset[k] < KICK_CANDIDATE_SHARE * strongest || onset[k] <= 0) continue
    let peak = true
    for (let d = 1; d <= peakRadius && peak; d++) if (at(k - d) > onset[k] || at(k + d) > onset[k]) peak = false
    if (peak) candidates.push({ lowAt: k, onset: onset[k], ...clickNear(k) })
  }
  if (candidates.length === 0) {
    let lowAt = 0
    for (let k = 1; k < bins; k++) if (onset[k] > onset[lowAt]) lowAt = k
    candidates.push({ lowAt, onset: onset[lowAt], ...clickNear(lowAt) })
  }
  const loudestClick = Math.max(...candidates.map((c) => c.click)) || 1
  const score = (c: (typeof candidates)[number]): number => (c.onset / strongest) ** 2 * (c.click / loudestClick)
  const kick = candidates.reduce((best, c) => (score(c) > score(best) ? c : best))

  const periodSec = 60 / bpm
  const offsetSec = ((((kick.attack % bins) + bins) % bins) * binSec) % periodSec
  let mean = 0
  for (const v of onset) mean += v
  mean /= bins
  return { offsetSec, salience: kick.onset, contrast: mean > 0 ? kick.onset / mean : 0 }
}

export interface TempoHypothesis {
  bpm: number
  /** The candidate's ratio to the coarse reading, e.g. "3/2". */
  relation: string
  /** Folded kick salience relative to the strongest candidate (1 = strongest). */
  salience: number
}

export interface HypothesisChoice {
  chosen: TempoHypothesis
  /** Every candidate in range, strongest first. */
  hypotheses: TempoHypothesis[]
  /** True when another reading is close enough that a person should check. */
  uncertain: boolean
}

const RELATIONS: Array<[number, string]> = [
  [1 / 2, '1/2'],
  [2 / 3, '2/3'],
  [3 / 4, '3/4'],
  [1, '1'],
  [4 / 3, '4/3'],
  [3 / 2, '3/2'],
  [2, '2']
]

/**
 * Pick between metrically related readings of a precise tempo. Each candidate
 * is the refined tempo times a simple ratio (so it is precise too), kept to
 * [minBpm, maxBpm]; the fastest one whose kick is undiluted wins. The
 * hypotheses returned are then the same ratios of the *chosen* tempo, which are
 * the readings a person would want to try instead.
 */
export function chooseTempo(bands: BandFrames, refinedBpm: number, minBpm: number, maxBpm: number): HypothesisChoice {
  const strengths = new Map<string, number>()
  const strengthAt = (bpm: number): number => {
    const key = bpm.toFixed(3)
    let value = strengths.get(key)
    if (value === undefined) {
      value = kickSalience(bands, bpm)
      strengths.set(key, value)
    }
    return value
  }
  const around = (centre: number): Array<{ bpm: number; relation: string; strength: number }> => {
    const out: Array<{ bpm: number; relation: string; strength: number }> = []
    for (const [ratio, relation] of RELATIONS) {
      let bpm = centre * ratio
      if (bpm < minBpm || bpm > maxBpm) continue
      // Ratios of a whole-number tempo that land within a hair of a whole number are that number.
      if (Math.abs(bpm - Math.round(bpm)) < 0.01) bpm = Math.round(bpm)
      out.push({ bpm, relation, strength: strengthAt(bpm) })
    }
    return out
  }

  const first = around(refinedBpm)
  if (first.length === 0) {
    const only = { bpm: refinedBpm, relation: '1', salience: 1 }
    return { chosen: only, hypotheses: [only], uncertain: true }
  }
  const firstStrongest = Math.max(...first.map((h) => h.strength)) || 1
  const byTempo = [...first].sort((a, b) => b.bpm - a.bpm)
  const pick = byTempo.find((h) => h.strength >= UNDILUTED_SHARE * firstStrongest) ?? byTempo[0]

  const second = around(pick.bpm)
  const strongest = Math.max(firstStrongest, ...second.map((h) => h.strength)) || 1
  const hypotheses = second
    .map((h) => ({ bpm: h.bpm, relation: h.relation, salience: h.strength / strongest }))
    .sort((a, b) => b.salience - a.salience)
  const chosen = hypotheses.find((h) => h.relation === '1') ?? hypotheses[0]
  const fasterRival = hypotheses.some((h) => h.bpm > chosen.bpm && h.salience >= AMBIGUOUS_SHARE)
  const slowerStronger = chosen.salience < 1 - (1 - UNDILUTED_SHARE) / 2
  return { chosen, hypotheses, uncertain: fasterRival || slowerStronger }
}

/**
 * Tie-break for the bar that begins with the audio, as a share of the vote. A
 * loop that never changes has no bar line to find, and many renders start on
 * bar 1, but 4 of the 20 marked tracks do not (Nice Day fades in a beat early),
 * so this stays below the smallest margin the votes win by on a real track.
 */
const START_ON_BAR_ONE = 0.02
/** Share of beats with the biggest bar-scale change that vote a second time. */
const BIG_CHANGE_SHARE = 0.05
/** ...and only when the change is this many times the track's median bar-to-bar change, */
const BIG_CHANGE_OVER_MEDIAN = 3
/**
 * ...and at least this big in absolute terms (summed log-energy change over the
 * three bands). A perfect loop's median change is near zero, so the ratio alone
 * lets its noise through: a synthetic loop's biggest change is ~0.1, while real
 * tracks' drops and breakdowns reach 2–20.
 */
const BIG_CHANGE_MIN = 0.5

export interface BarPhase {
  /** Grid beats from beat 0 (the first beat at the start of the audio) to the first "one", 0–3. */
  beat: number
  /** Winning vote share minus the runner-up's; near 0 means a guess. */
  margin: number
}

/**
 * Which beat of the bar is the "one". `firstBeatSec` is beat 0, the first grid
 * beat at the start of the audio (it may sit a hair before 0:00).
 */
export function estimateBarPhase(bands: BandFrames, bpm: number, firstBeatSec: number, beatsPerBar = 4): BarPhase {
  const periodFrames = 60 / bpm / bands.frameSec
  const startFrame = firstBeatSec / bands.frameSec
  const count = Math.floor((bands.low.length - Math.max(0, startFrame)) / periodFrames)
  if (count < beatsPerBar * 4) return { beat: 0, margin: 0 }

  // Log energy per beat and band.
  const series = [bands.low, bands.mid, bands.high]
  const perBeat: number[][] = []
  for (let k = 0; k < count; k++) {
    const from = Math.max(0, Math.round(startFrame + k * periodFrames))
    const to = Math.min(bands.low.length, Math.round(startFrame + (k + 1) * periodFrames))
    perBeat.push(
      series.map((band) => {
        let sum = 0
        for (let f = from; f < to; f++) sum += band[f]
        return Math.log(sum / Math.max(1, to - from) + 1e-9)
      })
    )
  }

  // Change from the beat before (every beat votes) and from the bar before (the biggest changes vote again).
  const beatChange = new Array<number>(beatsPerBar).fill(0)
  const barChange: Array<{ k: number; value: number }> = []
  for (let k = beatsPerBar; k < count - beatsPerBar; k++) {
    let step = 0
    let bar = 0
    for (let b = 0; b < series.length; b++) {
      step += Math.abs(perBeat[k][b] - perBeat[k - 1][b])
      let after = 0
      let before = 0
      for (let i = 0; i < beatsPerBar; i++) {
        after += perBeat[k + i][b]
        before += perBeat[k - 1 - i][b]
      }
      bar += Math.abs(after - before) / beatsPerBar
    }
    beatChange[k % beatsPerBar] += step
    barChange.push({ k, value: bar })
  }
  barChange.sort((a, b) => b.value - a.value)
  // Only a real arrangement change votes: a loop that never changes has no bar line to find,
  // and the top few percent of its noise would otherwise outvote the tie-break.
  const medianChange = barChange[Math.floor(barChange.length / 2)]?.value ?? 0
  const bigChange = new Array<number>(beatsPerBar).fill(1)
  for (const { k, value } of barChange.slice(0, Math.max(1, Math.round(barChange.length * BIG_CHANGE_SHARE)))) {
    if (value >= Math.max(BIG_CHANGE_OVER_MEDIAN * medianChange, BIG_CHANGE_MIN)) {
      bigChange[k % beatsPerBar] += value / Math.max(BIG_CHANGE_MIN, medianChange)
    }
  }

  const share = (votes: number[]): number[] => {
    const total = votes.reduce((sum, v) => sum + v, 0) || 1
    return votes.map((v) => v / total)
  }
  const a = share(beatChange)
  const b = share(bigChange)
  const score = a.map((v, i) => v + b[i] + (i === 0 ? START_ON_BAR_ONE : 0))
  const order = score.map((v, i) => ({ v, i })).sort((x, y) => y.v - x.v)
  return { beat: order[0].i, margin: (order[0].v - order[1].v) / 2 }
}
