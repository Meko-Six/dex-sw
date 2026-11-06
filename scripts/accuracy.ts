#!/usr/bin/env node
/**
 * Accuracy bench for the analysis pipeline.
 *
 * Runs the *real* detector/key/loudness code over a folder of tracks, compares
 * each result against hand-checked answers, and prints a scoreboard. The unit
 * tests prove the maths on synthetic audio and the in-app self-test proves the
 * audio graph; neither can catch a wrong BPM octave or a grid that drifts over
 * the length of a real track. This is that missing layer.
 *
 *   npm run accuracy                  score ./accuracy
 *   npm run accuracy -- /path/to/set  score any folder
 *   npm run accuracy -- --self        score the synthetic fixtures (no music needed)
 *   npm run accuracy -- --marked      score only the tracks with hand-marked beats (fast)
 *   npm run accuracy -- --no-hint     ignore each track's genre, as the app does today
 *
 * The folder holds manifest.json (the answers, committed) plus the audio files
 * (copyrighted, not committed). Exit code is non-zero only when an aggregate
 * breaches a threshold from the manifest's `targets`.
 */
import { existsSync } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { detectBeats, TEMPO_HINTS, type GridEvidence, type TempoHint } from '../src/shared/detector'
import { toMono } from '../src/shared/dsp'
import { camelotFor, estimateKey, harmonicNeighbours, type Mode } from '../src/shared/key'
import { analyzeLoudness } from '../src/shared/loudness'
import { decodeStereo } from './lib/audio-decode'

/** The analysers run at 22.05 kHz: enough for the detector's 11.025 kHz and key's own rate. */
const SAMPLE_RATE = 22050
const DEFAULT_DIR = 'accuracy'
const DEFAULT_REPORT = 'out/accuracy-report.json'
const DEFAULT_DOWNBEAT_TOLERANCE_MS = 15

// --- manifest ------------------------------------------------------------------

interface Targets {
  bpmExactPct: number
  octavePct: number
  gridMedianMs: number
  gridP95Ms: number
  gridDriftMs: number
  downbeatHitPct: number
  barHitPct: number
  keyExactPct: number
  keyTop3Pct: number
  lufsTolerance: number
  /** Absolute BPM tolerance for "exact"; Beatport tag BPM is integer-rounded. */
  bpmToleranceBpm: number
}

const DEFAULT_TARGETS: Targets = {
  bpmExactPct: 0.9,
  octavePct: 1.0,
  gridMedianMs: 12,
  gridP95Ms: 25,
  gridDriftMs: 25,
  downbeatHitPct: 0.9,
  barHitPct: 0.9,
  keyExactPct: 0.6,
  keyTop3Pct: 0.8,
  lufsTolerance: 0.5,
  bpmToleranceBpm: 0.5
}

interface TrackTruth {
  /** True tempo. Beatport tag BPM is integer-rounded, so "exact" allows a half BPM. */
  bpm?: number
  key?: string
  camelot?: string
  downbeatsSec?: number[]
  lufs?: number
  /** A DJ-mashed / tempo-changing track: printed but kept out of every aggregate. */
  tempoChanging?: boolean
}

interface ManifestTrack {
  id: string
  file: string
  genre?: string
  truth: TrackTruth
  notes?: string
}

interface Manifest {
  version: 1
  targets?: Partial<Targets>
  tracks: ManifestTrack[]
}

// --- scoring types -------------------------------------------------------------

type TempoVerdict = 'exact' | 'half' | 'double' | 'off' | 'other'

interface GridScore {
  medianMs: number
  p95Ms: number
  worstMs: number
  count: number
  errorsMs: number[]
}

interface KeyScore {
  dex: string
  dexCamelot: string
  truth: string
  truthCamelot: string
  exact: boolean
  top3: boolean
  related: boolean
  confidence: number
}

interface TrackResult {
  id: string
  file: string
  genre: string
  status: 'scored' | 'failed'
  tempoChanging: boolean
  error?: string
  notes?: string
  bpm?: { dex: number; truth: number; delta: number; verdict: TempoVerdict }
  beatConfidence?: number
  grid?: GridScore | null
  downbeat?: { hit: boolean; worstMs: number; toleranceMs: number } | null
  /** Marks per beat of Dex's bar (index 0 = Dex's "one"); right when the "one" holds the most. */
  bar?: { hit: boolean; positions: number[] } | null
  /** Dex flagged the tempo as uncertain; the alternates it would offer. */
  uncertain?: boolean
  alternates?: string[]
  /** What the grid refinement measured (see GridEvidence in detector.ts). */
  gridEvidence?: GridEvidence
  key?: KeyScore | null
  loudness?: { dex: number; truth: number; delta: number } | null
  lufsDex?: number
  peakDb?: number
}

interface Summary {
  tracks: number
  scored: number
  bpmExactPct: number | null
  bpmCount: number
  octaveFlipCount: number | null
  gridMedianMs: number | null
  gridP95Ms: number | null
  gridDriftMs: number | null
  downbeatHitPct: number | null
  downbeatCount: number
  barHitPct: number | null
  barCount: number
  flaggedCount: number
  keyExactPct: number | null
  keyTop3Pct: number | null
  keyRelatedPct: number | null
  keyCount: number
  lufsMedianAbsDelta: number | null
  lufsCount: number
  calibration: Array<{ bucket: string; count: number; missPct: number }> | null
}

// --- small maths helpers -------------------------------------------------------

function median(values: number[]): number {
  if (values.length === 0) return Number.NaN
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]
}

function percentile(sorted: number[], q: number): number {
  if (sorted.length === 0) return Number.NaN
  const index = Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))
  return sorted[index]
}

const PITCH_LETTERS: Record<string, number> = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }

/** Parse "F# minor" / "F#m" / "Bb major" into a pitch class and mode. */
function parseKeyName(name: string): { tonic: number; mode: Mode } | null {
  const match = name.trim().match(/^([A-Ga-g])([#b]?)\s*(major|minor|maj|min|m)?$/i)
  if (!match) return null
  const base = PITCH_LETTERS[match[1].toUpperCase()]
  if (base === undefined) return null
  const accidental = match[2] === '#' ? 1 : match[2] === 'b' ? -1 : 0
  const tonic = (((base + accidental) % 12) + 12) % 12
  const suffix = (match[3] ?? '').toLowerCase()
  const mode: Mode = suffix.startsWith('min') || suffix === 'm' ? 'minor' : 'major'
  return { tonic, mode }
}

function truthCamelot(truth: TrackTruth): string | null {
  if (truth.camelot) return truth.camelot.trim().toUpperCase()
  if (truth.key) {
    const parsed = parseKeyName(truth.key)
    if (parsed) return camelotFor(parsed.tonic, parsed.mode)
  }
  return null
}

function classifyBpm(dex: number, truth: number, toleranceBpm: number): TempoVerdict {
  if (!Number.isFinite(dex) || !Number.isFinite(truth) || truth <= 0) return 'other'
  if (Math.abs(dex - truth) <= toleranceBpm) return 'exact'
  const ratio = dex / truth
  if (Math.abs(ratio - 2) <= 0.02) return 'double'
  if (Math.abs(ratio - 0.5) <= 0.01) return 'half'
  if (Math.abs(ratio - 1) <= 0.04) return 'off'
  return 'other'
}

/**
 * Distance from every hand-marked downbeat to the nearest grid line the
 * detector produced. Truth downbeats are beats, so the nearest *beat* line is
 * the right comparison; a short median with a large worst value means the tempo
 * is slightly wrong and the grid slips along the track.
 */
function scoreGrid(offsetMs: number, bpm: number, downbeatsSec: number[]): GridScore | null {
  if (downbeatsSec.length === 0 || !Number.isFinite(bpm) || bpm <= 0) return null
  const periodMs = 60000 / bpm
  const errorsMs = downbeatsSec.map((downbeat) => {
    const targetMs = downbeat * 1000
    const index = Math.round((targetMs - offsetMs) / periodMs)
    return Math.abs(targetMs - (offsetMs + index * periodMs))
  })
  const sorted = [...errorsMs].sort((a, b) => a - b)
  return {
    medianMs: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    worstMs: sorted[sorted.length - 1],
    count: sorted.length,
    errorsMs
  }
}

/**
 * Which beat of Dex's bar each mark falls on. The marks are meant to be "ones"
 * but a person can be a beat out on one of them, so the bar is right when Dex's
 * "one" holds more marks than any other beat.
 */
function scoreBar(offsetMs: number, bpm: number, downbeatsSec: number[]): TrackResult['bar'] {
  if (downbeatsSec.length === 0 || !Number.isFinite(bpm) || bpm <= 0) return null
  const periodMs = 60000 / bpm
  const positions = [0, 0, 0, 0]
  for (const downbeat of downbeatsSec) {
    const beat = Math.round((downbeat * 1000 - offsetMs) / periodMs)
    positions[((beat % 4) + 4) % 4]++
  }
  return { hit: positions[0] > Math.max(positions[1], positions[2], positions[3]), positions }
}

// --- options & self fixtures ---------------------------------------------------

interface Options {
  dir: string
  self: boolean
  marked: boolean
  noHint: boolean
  report: string
}

function parseArgs(argv: string[]): Options {
  let dir = ''
  let self = false
  let marked = false
  let noHint = false
  let report = DEFAULT_REPORT
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--self') self = true
    else if (arg === '--marked') marked = true
    else if (arg === '--no-hint') noHint = true
    else if (arg === '--report') report = argv[++i] ?? report
    else if (arg === '--help' || arg === '-h') {
      console.log('usage: npm run accuracy -- [dir] [--self] [--marked] [--no-hint] [--report path]')
      process.exit(0)
    } else dir = arg
  }
  return { dir: resolve(dir || DEFAULT_DIR), self, marked, noHint, report: resolve(report) }
}

/**
 * Synthetic fixtures from scripts/make-fixtures.mjs, whose BPM and offset are
 * known exactly. Scoring these proves the bench works before any real music is
 * involved (and it is the only mode CI can run, since real tracks are not
 * committed). Keep in sync with the TRACKS array in that script.
 */
const SELF_FIXTURES: Array<{ file: string; bpm: number; seconds: number; offsetSec: number }> = [
  { file: 'house-124.wav', bpm: 124, seconds: 32, offsetSec: 0 },
  { file: 'techno-128.wav', bpm: 128, seconds: 32, offsetSec: 0 },
  { file: 'deep-122.wav', bpm: 122, seconds: 32, offsetSec: 0 },
  { file: 'offset-100.wav', bpm: 100, seconds: 24, offsetSec: 0.25 }
]

function downbeatsFor(bpm: number, offsetSec: number, seconds: number): number[] {
  const bar = 4 * (60 / bpm)
  const out: number[] = []
  for (let t = offsetSec; t < seconds - 0.01; t += bar) out.push(Math.round(t * 1000) / 1000)
  return out
}

function buildSelfManifest(): Manifest {
  return {
    version: 1,
    tracks: SELF_FIXTURES.map((fixture) => ({
      id: fixture.file.replace(/\.wav$/, ''),
      file: fixture.file,
      genre: 'auto',
      truth: {
        bpm: fixture.bpm,
        downbeatsSec: downbeatsFor(fixture.bpm, fixture.offsetSec, fixture.seconds)
      },
      notes: 'synthetic fixture (known-exact BPM and offset)'
    }))
  }
}

// --- running -------------------------------------------------------------------

function tempoHintFor(genre: string): TempoHint {
  const hint = TEMPO_HINTS[genre]
  if (!hint) {
    console.warn(`  ! unknown genre "${genre}", using the default tempo prior`)
    return TEMPO_HINTS.auto
  }
  return hint
}

async function scoreTrack(
  track: ManifestTrack,
  dir: string,
  programRoot: string,
  bpmToleranceBpm: number
): Promise<TrackResult> {
  const base: TrackResult = {
    id: track.id,
    file: track.file,
    genre: track.genre ?? 'auto',
    status: 'failed',
    tempoChanging: Boolean(track.truth.tempoChanging),
    notes: track.notes
  }

  const path = isAbsolute(track.file) ? track.file : join(dir, track.file)
  if (!existsSync(path)) {
    return { ...base, error: `missing file ${path} (run npm run accuracy from ${programRoot})` }
  }

  try {
    const channels = await decodeStereo(path, SAMPLE_RATE)
    if (channels[0].length === 0) return { ...base, error: 'decoded zero samples' }
    const mono = toMono(channels)

    const beat = detectBeats(mono, SAMPLE_RATE, tempoHintFor(base.genre))
    const key = estimateKey(mono, SAMPLE_RATE)
    const loudness = analyzeLoudness(channels, SAMPLE_RATE)

    const truth = track.truth
    const truthBpm = truth.bpm
    const bpm =
      typeof truthBpm === 'number' && Number.isFinite(truthBpm)
        ? {
            dex: beat.bpm,
            truth: truthBpm,
            delta: beat.bpm - truthBpm,
            verdict: classifyBpm(beat.bpm, truthBpm, bpmToleranceBpm)
          }
        : undefined
    const grid = scoreGrid(beat.offsetMs, beat.bpm, truth.downbeatsSec ?? [])

    let downbeat: TrackResult['downbeat'] = null
    if (grid) {
      downbeat = {
        hit: grid.worstMs <= DEFAULT_DOWNBEAT_TOLERANCE_MS,
        worstMs: grid.worstMs,
        toleranceMs: DEFAULT_DOWNBEAT_TOLERANCE_MS
      }
    }

    const bar = scoreBar(beat.offsetMs, beat.bpm, truth.downbeatsSec ?? [])
    const alternates = beat.hypotheses
      .filter((h) => Math.abs(h.bpm - beat.bpm) > 0.01)
      .map((h) => `${h.bpm.toFixed(2)} (${Math.round(h.salience * 100)}%)`)

    let keyScore: KeyScore | null = null
    const wantCamelot = truthCamelot(truth)
    if (truth.key && wantCamelot) {
      const neighbours = harmonicNeighbours(wantCamelot)
      const related = neighbours
        ? [neighbours.relative, neighbours.previous, neighbours.next].includes(key.camelot)
        : false
      keyScore = {
        dex: key.key,
        dexCamelot: key.camelot,
        truth: truth.key,
        truthCamelot: wantCamelot,
        exact: key.camelot === wantCamelot,
        top3: key.candidates.slice(0, 3).some((candidate) => candidate.key === truth.key),
        related,
        confidence: key.confidence
      }
    }

    let loudnessScore: TrackResult['loudness'] = null
    if (typeof truth.lufs === 'number' && Number.isFinite(loudness.integratedLufs)) {
      loudnessScore = {
        dex: loudness.integratedLufs,
        truth: truth.lufs,
        delta: Math.round((loudness.integratedLufs - truth.lufs) * 10) / 10
      }
    }

    return {
      ...base,
      status: 'scored',
      bpm,
      beatConfidence: beat.confidence,
      grid,
      downbeat,
      bar,
      uncertain: beat.uncertain,
      alternates,
      gridEvidence: beat.evidence,
      key: keyScore,
      loudness: loudnessScore,
      lufsDex: Number.isFinite(loudness.integratedLufs) ? loudness.integratedLufs : undefined,
      peakDb: Number.isFinite(loudness.peakDb) ? loudness.peakDb : undefined
    }
  } catch (error) {
    return { ...base, error: error instanceof Error ? error.message : String(error) }
  }
}

function summarise(results: TrackResult[]): Summary {
  // Tempo-changing tracks are printed but excluded everywhere: a constant grid
  // cannot be right on them, and scoring them would poison the average.
  const scored = results.filter((result) => result.status === 'scored' && !result.tempoChanging)

  const bpmScored = scored.filter((result) => result.bpm)
  const bpmExact = bpmScored.filter((result) => result.bpm?.verdict === 'exact').length
  const octaveFlips = bpmScored.filter(
    (result) => result.bpm?.verdict === 'half' || result.bpm?.verdict === 'double'
  ).length

  const gridErrors = scored.flatMap((result) => result.grid?.errorsMs ?? [])
  const gridSorted = [...gridErrors].sort((a, b) => a - b)

  const downbeatScored = scored.filter((result) => result.downbeat)
  const downbeatHits = downbeatScored.filter((result) => result.downbeat?.hit).length

  const barScored = scored.filter((result) => result.bar)
  const barHits = barScored.filter((result) => result.bar?.hit).length

  const keyScored = scored.filter((result) => result.key)
  const keyExact = keyScored.filter((result) => result.key?.exact).length
  const keyTop3 = keyScored.filter((result) => result.key?.top3).length
  const keyRelated = keyScored.filter((result) => result.key?.related).length

  const lufsDeltas = scored
    .map((result) => result.loudness)
    .filter((value): value is { dex: number; truth: number; delta: number } => Boolean(value))
    .map((value) => Math.abs(value.delta))

  // Confidence calibration only says anything once the set is large enough.
  let calibration: Summary['calibration'] = null
  if (scored.length >= 20) {
    const buckets: Array<{ bucket: string; test: (c: number) => boolean }> = [
      { bucket: 'low  (<0.5)', test: (c) => c < 0.5 },
      { bucket: 'mid  (0.5-0.8)', test: (c) => c >= 0.5 && c < 0.8 },
      { bucket: 'high (>=0.8)', test: (c) => c >= 0.8 }
    ]
    calibration = buckets
      .map(({ bucket, test }) => {
        const inBucket = scored.filter((result) => test(result.beatConfidence ?? 0))
        const misses = inBucket.filter(
          (result) =>
            (result.bpm ? result.bpm.verdict !== 'exact' : false) ||
            (result.downbeat ? !result.downbeat.hit : false) ||
            (result.key ? !result.key.exact : false)
        )
        return {
          bucket,
          count: inBucket.length,
          missPct: inBucket.length > 0 ? misses.length / inBucket.length : 0
        }
      })
      .filter((row) => row.count > 0)
  }

  return {
    tracks: results.length,
    scored: scored.length,
    bpmExactPct: bpmScored.length > 0 ? bpmExact / bpmScored.length : null,
    bpmCount: bpmScored.length,
    octaveFlipCount: bpmScored.length > 0 ? octaveFlips : null,
    gridMedianMs: gridSorted.length > 0 ? percentile(gridSorted, 0.5) : null,
    gridP95Ms: gridSorted.length > 0 ? percentile(gridSorted, 0.95) : null,
    gridDriftMs: gridSorted.length > 0 ? gridSorted[gridSorted.length - 1] : null,
    downbeatHitPct: downbeatScored.length > 0 ? downbeatHits / downbeatScored.length : null,
    downbeatCount: downbeatScored.length,
    barHitPct: barScored.length > 0 ? barHits / barScored.length : null,
    barCount: barScored.length,
    flaggedCount: scored.filter((result) => result.uncertain).length,
    keyExactPct: keyScored.length > 0 ? keyExact / keyScored.length : null,
    keyTop3Pct: keyScored.length > 0 ? keyTop3 / keyScored.length : null,
    keyRelatedPct: keyScored.length > 0 ? keyRelated / keyScored.length : null,
    keyCount: keyScored.length,
    lufsMedianAbsDelta: lufsDeltas.length > 0 ? median(lufsDeltas) : null,
    lufsCount: lufsDeltas.length,
    calibration
  }
}

function gate(summary: Summary, targets: Targets): string[] {
  const breaches: string[] = []
  const pct = (value: number): string => `${Math.round(value * 100)}%`
  const check = (label: string, actual: number | null, limit: number, kind: 'min' | 'max'): void => {
    if (actual === null) return
    const ok = kind === 'min' ? actual >= limit : actual <= limit
    if (!ok) {
      const want = kind === 'min' ? `>= ${pct(limit)}` : `<= ${limit}`
      const got = kind === 'min' ? pct(actual) : actual.toFixed(1)
      breaches.push(`${label}: ${got} (want ${want})`)
    }
  }
  check('BPM exact', summary.bpmExactPct, targets.bpmExactPct, 'min')
  check(
    'Octave-correct',
    summary.bpmCount > 0 ? 1 - (summary.octaveFlipCount ?? 0) / summary.bpmCount : null,
    targets.octavePct,
    'min'
  )
  check('Grid median', summary.gridMedianMs, targets.gridMedianMs, 'max')
  check('Grid p95', summary.gridP95Ms, targets.gridP95Ms, 'max')
  check('Grid drift', summary.gridDriftMs, targets.gridDriftMs, 'max')
  check('Downbeat on grid', summary.downbeatHitPct, targets.downbeatHitPct, 'min')
  check('Bar phase', summary.barHitPct, targets.barHitPct, 'min')
  check('Key exact', summary.keyExactPct, targets.keyExactPct, 'min')
  check('Key top-3', summary.keyTop3Pct, targets.keyTop3Pct, 'min')
  check('Loudness |Δ|', summary.lufsMedianAbsDelta, targets.lufsTolerance, 'max')
  return breaches
}

// --- printing ------------------------------------------------------------------

function fmtMs(value: number | null | undefined): string {
  return value === null || value === undefined ? '   —  ' : `${value.toFixed(1)}ms`
}

function rowFor(result: TrackResult): string {
  const id = result.id.padEnd(20)
  if (result.status === 'failed') return `${id} FAILED  ${result.error ?? ''}`
  const flag = result.tempoChanging ? ' *' : '  '

  const bpm = result.bpm
  const bpmText = bpm
    ? `${bpm.truth.toFixed(1)}/${bpm.dex.toFixed(3)} ${bpm.verdict.padEnd(6)}`
    : 'n/a'.padEnd(24)

  const grid = result.grid
    ? `grid ${fmtMs(result.grid.medianMs)}/${fmtMs(result.grid.p95Ms)}  drift ${fmtMs(result.grid.worstMs)}`
    : 'grid —                '

  const down = result.downbeat
    ? result.downbeat.hit
      ? 'beat ✓   '
      : `beat ✗ ${result.downbeat.worstMs.toFixed(0)}ms`.padEnd(9)
    : 'beat —   '
  const bar = result.bar ? (result.bar.hit ? 'bar ✓   ' : `bar ✗ ${result.bar.positions.join('')}`.padEnd(8)) : 'bar —   '
  const flag2 = result.uncertain ? `  ? also ${result.alternates?.join(', ') || '—'}` : ''

  const keyMark = result.key
    ? result.key.exact
      ? '✓'
      : result.key.top3
        ? '~'
        : result.key.related
          ? '≈'
          : '✗'
    : ''
  const key = result.key ? `key ${result.key.dexCamelot}${keyMark}`.padEnd(9) : 'key —    '

  const conf = `conf ${(result.beatConfidence ?? 0).toFixed(2)}`
  const lufs = result.loudness
    ? `LUFS ${result.loudness.dex.toFixed(1)} Δ${result.loudness.delta >= 0 ? '+' : ''}${result.loudness.delta.toFixed(1)}`
    : 'LUFS —'

  return `${id}${flag}${bpmText}  ${grid}  ${down} ${bar} ${key} ${conf}  ${lufs}${flag2}`
}

function printSummary(summary: Summary): void {
  const pct = (value: number | null): string => (value === null ? 'not checked' : `${Math.round(value * 100)}%`)
  console.log('\n────────────── summary ──────────────')
  console.log(`tracks   ${summary.tracks} (scored ${summary.scored})`)
  console.log(
    `BPM      exact ${pct(summary.bpmExactPct)}   octave flips ${summary.octaveFlipCount ?? '—'}   (${summary.bpmCount} tracks)`
  )
  console.log(
    `grid     median ${fmtMs(summary.gridMedianMs)}   p95 ${fmtMs(summary.gridP95Ms)}   drift ${fmtMs(summary.gridDriftMs)}`
  )
  console.log(
    `downbeat on-grid ${pct(summary.downbeatHitPct)}   (${summary.downbeatCount} track${summary.downbeatCount === 1 ? '' : 's'}, 15ms tolerance)`
  )
  console.log(`bar      "one" right ${pct(summary.barHitPct)}   (${summary.barCount} tracks)`)
  console.log(`flagged  ${summary.flaggedCount} of ${summary.scored} tracks marked uncertain`)
  console.log(
    `key      exact ${pct(summary.keyExactPct)}   top-3 ${pct(summary.keyTop3Pct)}   neighbour-only ${pct(summary.keyRelatedPct)}   (${summary.keyCount} tracks)`
  )
  console.log(
    `loudness |Δ| median ${summary.lufsMedianAbsDelta === null ? 'not checked' : `${summary.lufsMedianAbsDelta.toFixed(1)} LU`}   (${summary.lufsCount} tracks)`
  )
  if (summary.calibration) {
    console.log('confidence calibration (does low confidence predict a miss?):')
    for (const row of summary.calibration) {
      console.log(`  ${row.bucket.padEnd(14)} ${row.count} tracks, ${Math.round(row.missPct * 100)}% missed`)
    }
  }
}

// --- main ----------------------------------------------------------------------

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2))

  let manifest: Manifest
  let source: string
  if (options.self) {
    manifest = buildSelfManifest()
    source = 'synthetic fixtures'
  } else {
    const manifestPath = join(options.dir, 'manifest.json')
    if (!existsSync(manifestPath)) {
      console.error(`no manifest at ${manifestPath}`)
      console.error('run "npm run accuracy -- --self" to check the bench itself, or add a manifest (see accuracy/README.md)')
      process.exitCode = 1
      return
    }
    manifest = JSON.parse(await readFile(manifestPath, 'utf8')) as Manifest
    if (manifest.version !== 1 || !Array.isArray(manifest.tracks)) {
      console.error(`${manifestPath} is not a version-1 accuracy manifest`)
      process.exitCode = 1
      return
    }
    source = options.dir
  }
  if (options.marked) {
    manifest = { ...manifest, tracks: manifest.tracks.filter((track) => (track.truth.downbeatsSec?.length ?? 0) > 0) }
    source += ' (marked tracks only)'
  }
  if (options.noHint) {
    manifest = { ...manifest, tracks: manifest.tracks.map((track) => ({ ...track, genre: 'auto' })) }
    source += ' (no genre hints)'
  }

  const targets: Targets = { ...DEFAULT_TARGETS, ...(manifest.targets ?? {}) }
  console.log(`accuracy bench — ${source}`)
  console.log(`scoring ${manifest.tracks.length} track${manifest.tracks.length === 1 ? '' : 's'}\n`)
  if (manifest.tracks.length === 0) {
    console.log('(no tracks yet — add entries to accuracy/manifest.json; see accuracy/README.md)\n')
  }

  const results: TrackResult[] = []
  for (const track of manifest.tracks) {
    const result = await scoreTrack(
      track,
      options.self ? resolve('fixtures') : options.dir,
      process.cwd(),
      targets.bpmToleranceBpm
    )
    results.push(result)
    console.log(rowFor(result))
  }

  const summary = summarise(results)
  printSummary(summary)

  const breaches = gate(summary, targets)
  if (breaches.length > 0) {
    console.log('\n────────────── below target ──────────────')
    for (const breach of breaches) console.log(`  ${breach}`)
  } else if (summary.scored > 0) {
    console.log('\nall measured metrics meet their targets')
  }

  await mkdir(dirname(options.report), { recursive: true })
  await writeFile(
    options.report,
    `${JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        source,
        targets,
        summary,
        breaches,
        tracks: results.map(({ grid, ...result }) => ({
          ...result,
          grid: grid
            ? { medianMs: grid.medianMs, p95Ms: grid.p95Ms, worstMs: grid.worstMs, count: grid.count }
            : null
        }))
      },
      null,
      2
    )}\n`
  )
  console.log(`\nreport → ${options.report}`)

  const failures = results.filter((result) => result.status === 'failed').length
  if (failures > 0) console.warn(`${failures} track${failures === 1 ? '' : 's'} failed to score`)
  if (breaches.length > 0 || failures > 0) process.exitCode = 1
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
