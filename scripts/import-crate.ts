#!/usr/bin/env node
/**
 * Import a folder's manifest into Dex's library.json.
 *
 * The manifest lists *what* audio to import; this script decides
 * *where the beats are*, using the same detector the mixer runs at playback
 * time. Keeping analysis here (rather than duplicating it in the manifest) is
 * what guarantees the grid the mixer draws is the grid the detector produced.
 *
 *   node scripts/import-crate.ts ~/Music/MyCrate [options]
 *
 * Options:
 *   --out PATH          library file to write (default <crate>/library.json)
 *   --merge PATH        merge into an existing library (default: --out if it exists)
 *   --genre NAME        tempo hint: auto | psytrance | hardTrance | house
 *   --target-lufs N     loudness target for gainDb (default -10)
 *   --include-c         also import grade-C entries (not recommended)
 *   --dry-run           analyse everything, write nothing
 */
import { readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { detectBeats, TEMPO_HINTS, type TempoHint } from '../src/shared/detector'
import { decodeStereo } from './lib/audio-decode'
import { computePeaks, quantizePeaks, toMono } from '../src/shared/dsp'
import { estimateKey } from '../src/shared/key'
import { analyzePower } from '../src/shared/power'
import type { LibraryDoc, TrackMeta } from '../src/shared/types'

/** 22.05 kHz is enough: the detector downsamples to 11.025 kHz internally. */
const SAMPLE_RATE = 22050
const PEAK_BINS = 4096

interface CrateEntry {
  spotifyId: string
  isrc?: string
  title: string
  rawTitle: string
  artists: string[]
  album: string
  versionLabel?: string
  status: 'included' | 'rejected' | 'missing'
  file?: string
  source: 'local' | 'youtube' | 'lossless' | 'manual' | 'none'
  sourceUrl?: string
  grade?: 'A' | 'B' | 'C'
}

interface CrateManifest {
  version: 1
  entries: CrateEntry[]
  playlist?: { name?: string }
}

interface Options {
  crateDir: string
  out: string
  merge: string
  genre: string
  targetLufs: number
  includeC: boolean
  dryRun: boolean
}

function parseArgs(argv: string[]): Options {
  const positional: string[] = []
  let out = ''
  let merge = ''
  let genre = 'auto'
  let targetLufs = -10
  let includeC = false
  let dryRun = false

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--out') out = argv[++i]
    else if (arg === '--merge') merge = argv[++i]
    else if (arg === '--genre') genre = argv[++i]
    else if (arg === '--target-lufs') targetLufs = Number(argv[++i])
    else if (arg === '--include-c') includeC = true
    else if (arg === '--dry-run') dryRun = true
    else if (arg === '--help' || arg === '-h') {
      console.log('see the header of scripts/import-crate.ts for usage')
      process.exit(0)
    } else positional.push(arg)
  }

  const crateDir = resolve(positional[0] ?? '.')
  return {
    crateDir,
    out: out ? resolve(out) : join(crateDir, 'library.json'),
    merge: merge ? resolve(merge) : '',
    genre,
    targetLufs: Number.isFinite(targetLufs) ? targetLufs : -10,
    includeC,
    dryRun
  }
}

async function readManifest(crateDir: string): Promise<CrateManifest> {
  const path = join(crateDir, 'manifest.json')
  const parsed = JSON.parse(await readFile(path, 'utf8')) as Partial<CrateManifest>
  if (parsed.version !== 1 || !Array.isArray(parsed.entries)) {
    throw new Error(`${path} is not a version-1 crate manifest`)
  }
  return parsed as CrateManifest
}

function tempoHint(genre: string): TempoHint {
  const hint = TEMPO_HINTS[genre]
  if (!hint) {
    throw new Error(`unknown genre "${genre}" (expected one of: ${Object.keys(TEMPO_HINTS).join(', ')})`)
  }
  return hint
}

async function analyzeEntry(entry: CrateEntry, crateDir: string, hint: TempoHint, targetLufs: number): Promise<TrackMeta> {
  if (!entry.file) throw new Error('entry has no file')
  const absolute = join(crateDir, entry.file)
  if (!existsSync(absolute)) throw new Error(`missing file ${absolute}`)

  const channels = await decodeStereo(absolute, SAMPLE_RATE)
  if (channels[0].length === 0) throw new Error('decoded zero samples')
  const mono = toMono(channels)
  const durationSec = channels[0].length / SAMPLE_RATE

  const beat = detectBeats(mono, SAMPLE_RATE, hint)
  const peaks = computePeaks(channels, PEAK_BINS)
  const key = estimateKey(mono, SAMPLE_RATE)
  const power = analyzePower(channels, SAMPLE_RATE, beat, targetLufs)

  const name = `${entry.artists[0] ?? 'Unknown'} - ${entry.title}`
  return {
    id: entry.spotifyId,
    name,
    path: absolute,
    durationSec: Math.round(durationSec * 1000) / 1000,
    bpm: Math.round(beat.bpm * 100) / 100,
    offsetMs: Math.round(beat.offsetMs),
    confidence: Math.round(beat.confidence * 1000) / 1000,
    peaks: quantizePeaks(peaks.bins),
    analyzedAt: new Date().toISOString(),
    key: key.key,
    camelot: key.camelot,
    keyConfidence: Math.round(key.confidence * 100) / 100,
    power,
    lufs: power.lufs,
    gainDb: power.gainDb,
    peakToLoudnessDb: power.peakToLoudnessDb,
    source: entry.source,
    sourceUrl: entry.sourceUrl,
    isrc: entry.isrc,
    spotifyId: entry.spotifyId,
    qualityGrade: entry.grade
  }
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2))
  const hint = tempoHint(options.genre)
  const manifest = await readManifest(options.crateDir)

  const importable = manifest.entries.filter(
    (entry) => entry.status === 'included' && entry.file && (entry.grade !== 'C' || options.includeC)
  )
  const skipped = manifest.entries.length - importable.length
  console.log(`${manifest.playlist?.name ?? 'crate'}: ${importable.length} importable, ${skipped} skipped`)

  const tracks: TrackMeta[] = []
  let failures = 0

  for (const [index, entry] of importable.entries()) {
    const label = `${entry.artists[0] ?? '?'} — ${entry.rawTitle}`
    try {
      const meta = await analyzeEntry(entry, options.crateDir, hint, options.targetLufs)
      tracks.push(meta)
      console.log(
        `[${index + 1}/${importable.length}] ${label}\n` +
          `    ${meta.bpm} BPM · ${meta.key} (${meta.camelot}, ${meta.keyConfidence ?? '?'}) · ` +
          `${meta.lufs} LUFS · ${meta.confidence} beat confidence`
      )
    } catch (error) {
      failures++
      console.warn(`[${index + 1}/${importable.length}] FAILED ${label}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const mergePath = options.merge || (existsSync(options.out) ? options.out : '')
  let existing: LibraryDoc = { version: 1, tracks: [] }
  if (mergePath) {
    existing = JSON.parse(await readFile(mergePath, 'utf8')) as LibraryDoc
  }

  const byId = new Map(existing.tracks.map((track) => [track.id, track]))
  for (const track of tracks) byId.set(track.id, track)
  const merged: LibraryDoc = {
    version: 1,
    tracks: [...byId.values()].sort((a, b) => a.name.localeCompare(b.name))
  }

  if (options.dryRun) {
    console.log(`dry run: would write ${merged.tracks.length} tracks to ${options.out}`)
  } else {
    await writeFile(options.out, `${JSON.stringify(merged, null, 2)}\n`)
    console.log(`wrote ${merged.tracks.length} tracks to ${options.out}`)
  }

  if (failures > 0) {
    console.warn(`${failures} tracks failed analysis`)
    if (tracks.length === 0) process.exitCode = 1
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
