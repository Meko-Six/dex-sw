#!/usr/bin/env node
/**
 * Build accuracy/manifest.json from the tracks' own metadata.
 *
 * Beatport-encoded files carry TBPM (tempo) and TKEY (key) in their tags —
 * values independent of Dex's detector — and integrated loudness is measured
 * with ffmpeg's own ebur128, so the bench gets real ground truth without anyone
 * hand-typing BPM and key (nothing to hand-tap is circular, which is the whole
 * point). Downbeats still have to be marked by hand for grid scoring; re-running
 * this preserves anything already filled in.
 *
 *   npm run accuracy:manifest                 scan accuracy/audio → accuracy/manifest.json
 *   npm run accuracy:manifest -- --dir X       scan another folder
 *   npm run accuracy:manifest -- --force       drop preserved fields (downbeats, notes, BPM from marks)
 */
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile, readdir, writeFile } from 'node:fs/promises'
import { basename, dirname, extname, join, relative, resolve, sep } from 'node:path'
import { isAudioFile } from '../src/shared/types'

interface Truth {
  bpm?: number
  /** 'marks' when `bpm` was set from hand-marked beats because the tag is wrong or missing; kept on re-runs. */
  bpmSource?: 'marks'
  key?: string
  camelot?: string
  lufs?: number
  downbeatsSec?: number[]
  tempoChanging?: boolean
  source?: string
}

interface Track {
  id: string
  file: string
  genre: string
  truth: Truth
  notes?: string
}

interface Manifest {
  version: 1
  targets?: Record<string, number>
  tracks: Track[]
}

const DEFAULT_TARGETS = {
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

const PITCH_CLASS: Record<string, number> = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }
const SHARP_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

/** Camelot tables, indexed by pitch class — mirrors src/shared/key.ts. */
const MAJOR_CAMELOT = ['8B', '3B', '10B', '5B', '12B', '7B', '2B', '9B', '4B', '11B', '6B', '1B']
const MINOR_CAMELOT = ['5A', '12A', '7A', '2A', '9A', '4A', '11A', '6A', '1A', '8A', '3A', '10A']

function keyFromCamelot(code: string): string | null {
  const match = code.match(/^(\d{1,2})([AB])$/)
  if (!match) return null
  const table = match[2] === 'B' ? MAJOR_CAMELOT : MINOR_CAMELOT
  const tonic = table.indexOf(`${Number(match[1])}${match[2]}`)
  if (tonic < 0) return null
  return `${SHARP_NAMES[tonic]} ${match[2] === 'B' ? 'major' : 'minor'}`
}

function run(command: string, args: string[], maxBuffer: number): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolveP, reject) => {
    execFile(command, args, { maxBuffer, encoding: 'utf8' }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(`${command} failed: ${error.message}`))
        return
      }
      resolveP({ stdout, stderr })
    })
  })
}

/** ffprobe format tags, lower-cased so TBPM/TBpm both resolve. */
async function probeTags(path: string): Promise<Record<string, string>> {
  const { stdout } = await run(
    'ffprobe',
    ['-v', 'error', '-show_entries', 'format_tags', '-of', 'json', path],
    8 * 1024 * 1024
  )
  const parsed = JSON.parse(stdout) as { format?: { tags?: Record<string, string> } }
  const tags: Record<string, string> = {}
  for (const [key, value] of Object.entries(parsed.format?.tags ?? {})) tags[key.toLowerCase()] = value
  return tags
}

/** Integrated loudness from ffmpeg's ebur128 filter — an independent meter. */
async function measureLufs(path: string): Promise<number | null> {
  try {
    const { stderr } = await run(
      'ffmpeg',
      ['-hide_banner', '-nostdin', '-i', path, '-filter_complex', 'ebur128', '-f', 'null', '-'],
      64 * 1024 * 1024
    )
    // ffmpeg prints an inline progress line per frame (early ones read -70 LUFS
    // before the gate opens); the gated integrated value in the final Summary
    // block is the last match.
    const matches = [...stderr.matchAll(/I:\s*(-?\d+(?:\.\d+)?)\s*LUFS/g)]
    return matches.length > 0 ? Number(matches[matches.length - 1][1]) : null
  } catch {
    return null
  }
}

/** Beatport stores either a note name ("D#min") or a Camelot code ("6A") in TKEY. */
function keyFromTag(value: string): { name: string; camelot?: string } | null {
  if (/^unknown$/i.test(value.trim())) return null
  const camelot = value.trim().toUpperCase().match(/^(\d{1,2})([AB])$/)
  if (camelot) {
    const code = `${Number(camelot[1])}${camelot[2]}`
    const name = keyFromCamelot(code)
    return name ? { name, camelot: code } : null
  }
  const name = normalizeKeyTag(value)
  return name ? { name } : null
}

/** "D#min" / "Amaj" / "F#m" → "D# minor" / "A major". */
function normalizeKeyTag(value: string): string | null {
  const match = value.trim().match(/^([A-Ga-g])([#b]?)\s*(maj|min|m|major|minor)?$/i)
  if (!match) return null
  const base = PITCH_CLASS[match[1].toUpperCase()]
  if (base === undefined) return null
  const accidental = match[2] === '#' ? 1 : match[2] === 'b' ? -1 : 0
  const pitchClass = (((base + accidental) % 12) + 12) % 12
  const suffix = (match[3] ?? 'maj').toLowerCase()
  const mode = suffix.startsWith('min') || suffix === 'm' ? 'minor' : 'major'
  return `${SHARP_NAMES[pitchClass]} ${mode}`
}

/** Map a genre tag or folder name onto a TEMPO_HINTS preset. */
function genreHint(genreTag: string | undefined, folder: string): string {
  const haystack = `${genreTag ?? ''} ${folder}`.toLowerCase()
  if (/psy|goa/.test(haystack)) return 'psytrance'
  if (/hard\s*trance/.test(haystack)) return 'hardTrance'
  if (/house/.test(haystack)) return 'house'
  return 'auto'
}

async function walk(dir: string): Promise<string[]> {
  const found: string[] = []
  const entries = await readdir(dir, { withFileTypes: true })
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name.startsWith('.')) continue
    const full = join(dir, entry.name)
    if (entry.isDirectory()) found.push(...(await walk(full)))
    else if (entry.isFile() && isAudioFile(entry.name)) found.push(full)
  }
  return found
}

/** Run `fn` over `items` with a small concurrency limit so ffmpeg batches up. */
async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length)
  let next = 0
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (;;) {
      const index = next++
      if (index >= items.length) return
      results[index] = await fn(items[index])
    }
  })
  await Promise.all(workers)
  return results
}

interface Options {
  dir: string
  out: string
  force: boolean
}

function parseArgs(argv: string[]): Options {
  let dir = 'accuracy/audio'
  let out = 'accuracy/manifest.json'
  let force = false
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--dir') dir = argv[++i] ?? dir
    else if (arg === '--out') out = argv[++i] ?? out
    else if (arg === '--force') force = true
    else if (arg === '--help' || arg === '-h') {
      console.log('usage: npm run accuracy:manifest -- [--dir audioDir] [--out manifestPath] [--force]')
      process.exit(0)
    }
  }
  return { dir: resolve(dir), out: resolve(out), force }
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2))
  if (!existsSync(options.dir)) {
    console.error(`no such folder: ${options.dir}`)
    process.exitCode = 1
    return
  }

  const manifestDir = dirname(options.out)
  let existing: Manifest | null = null
  if (existsSync(options.out)) {
    existing = JSON.parse(await readFile(options.out, 'utf8')) as Manifest
  }
  const previous = new Map((existing?.tracks ?? []).map((track) => [track.file, track]))

  const files = await walk(options.dir)
  if (files.length === 0) {
    console.error(`no audio files under ${options.dir}`)
    process.exitCode = 1
    return
  }
  console.log(`scanning ${files.length} track${files.length === 1 ? '' : 's'} under ${options.dir}\n`)

  const tracks = await mapLimit(files, 4, async (file): Promise<Track> => {
    const rel = relative(manifestDir, file).split(sep).join('/')
    const fallback: Track = { id: basename(file, extname(file)), file: rel, genre: 'auto', truth: {} }
    try {
      const tags = await probeTags(file)
      const bpmValue = tags.tbpm ? Number.parseInt(tags.tbpm, 10) : Number.NaN
      const keyTag = tags.tkey?.trim() ?? ''
      const key = keyTag ? keyFromTag(keyTag) : null
      const lufs = await measureLufs(file)
      const prior = options.force ? undefined : previous.get(rel)

      const truth: Truth = { source: 'beatport-id3' }
      if (Number.isFinite(bpmValue)) truth.bpm = bpmValue
      if (key?.name) truth.key = key.name
      if (key?.camelot) truth.camelot = key.camelot
      if (lufs !== null) truth.lufs = lufs
      if (prior?.truth.downbeatsSec) truth.downbeatsSec = prior.truth.downbeatsSec
      if (prior?.truth.tempoChanging) truth.tempoChanging = true
      if (prior?.truth.camelot) truth.camelot = prior.truth.camelot
      if (prior?.truth.bpmSource === 'marks' && prior.truth.bpm !== undefined) {
        truth.bpm = prior.truth.bpm
        truth.bpmSource = 'marks'
      }

      const missing: string[] = []
      if (!Number.isFinite(bpmValue)) missing.push('TBPM')
      if (!key?.name) missing.push('TKEY')
      console.log(
        `  ${rel.padEnd(58)} ${Number.isFinite(bpmValue) ? `${bpmValue} BPM` : 'BPM ?'}` +
          `${key?.name ? `  ${key.name}` : '  key ?'}` +
          `${lufs !== null ? `  ${lufs.toFixed(1)} LUFS` : ''}` +
          `${missing.length > 0 ? `   ← no ${missing.join('/')} in tags; set by hand` : ''}`
      )

      return { id: basename(file, extname(file)), file: rel, genre: genreHint(tags.genre, basename(dirname(file))), truth, notes: prior?.notes }
    } catch (error) {
      console.warn(`  ! ${rel}: ${error instanceof Error ? error.message : String(error)}`)
      return fallback
    }
  })

  const manifest: Manifest = {
    version: 1,
    targets: { ...DEFAULT_TARGETS, ...(existing?.targets ?? {}) },
    tracks: tracks.sort((a, b) => a.file.localeCompare(b.file))
  }
  await writeFile(options.out, `${JSON.stringify(manifest, null, 2)}\n`)

  const withBpm = tracks.filter((track) => track.truth.bpm !== undefined).length
  const withKey = tracks.filter((track) => track.truth.key !== undefined).length
  const withLufs = tracks.filter((track) => track.truth.lufs !== undefined).length
  console.log(
    `\nwrote ${tracks.length} tracks to ${options.out}\n` +
      `  ${withBpm} with BPM, ${withKey} with key, ${withLufs} with loudness\n` +
      `  ${tracks.length - withBpm + (tracks.length - withKey)} gap(s) need a hand-set value`
  )
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
