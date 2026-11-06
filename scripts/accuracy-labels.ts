#!/usr/bin/env node
/**
 * Import hand-marked downbeats from Audacity label files into
 * accuracy/manifest.json.
 *
 * Mark a few kicks in Audacity (click the onset, ⌘B), export them with
 * File → Export → Export Labels… as accuracy/labels/<track id>.txt, where the
 * id is the file name without its extension, then run this. Each label's start
 * time becomes one entry in that track's truth.downbeatsSec; nothing else in
 * the manifest changes. The times come from the marks alone, never from Dex,
 * so the bench still grades Dex against an independent answer.
 *
 * It also checks the marks against the tagged BPM, which is independent of
 * Dex too: the gap between two marks should be a whole number of beats. When
 * it is not, a mark is off the kick or the tag is wrong, and it says which
 * marks disagree. When the tag fits, the marks give the tempo to a fraction of
 * a BPM, which the integer tag cannot.
 *
 *   npm run accuracy:labels                  import accuracy/labels/*.txt
 *   npm run accuracy:labels -- --dry-run     check and print, write nothing
 *   npm run accuracy:labels -- --dir X --manifest Y
 */
import { existsSync } from 'node:fs'
import { readdir, readFile, writeFile } from 'node:fs/promises'
import { basename, extname, join, resolve } from 'node:path'
import { checkMarks, fitMarks, MARK_TOLERANCE_MS, parseLabels, type MarkFit } from './lib/audacity-labels'

interface Track {
  id: string
  file: string
  truth: { bpm?: number; downbeatsSec?: number[] }
}

interface Manifest {
  tracks: Track[]
}

/** The marking instructions put the second mark 8 bars after the first. */
const KICKS_IN_FIRST_GAP = 32
/** Three marks this far apart or more let the bench measure drift, not just phase. */
const MIN_SPAN_SEC = 120

function parseArgs(argv: string[]): { dir: string; manifest: string; dryRun: boolean } {
  let dir = 'accuracy/labels'
  let manifest = 'accuracy/manifest.json'
  let dryRun = false
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--dir') dir = argv[++i]
    else if (arg === '--manifest') manifest = argv[++i]
    else if (arg === '--dry-run') dryRun = true
    else if (arg === '--help' || arg === '-h') {
      console.log('usage: npm run accuracy:labels -- [--dir labelsDir] [--manifest path] [--dry-run]')
      process.exit(0)
    }
  }
  return { dir: resolve(dir), manifest: resolve(manifest), dryRun }
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2))
  if (!existsSync(options.dir)) {
    console.error(`no labels folder at ${options.dir}: export Audacity labels there as <track id>.txt`)
    process.exitCode = 1
    return
  }
  const manifest = JSON.parse(await readFile(options.manifest, 'utf8')) as Manifest
  const byId = new Map(manifest.tracks.map((track) => [track.id, track]))
  const files = (await readdir(options.dir)).filter((name) => extname(name).toLowerCase() === '.txt').sort()
  if (files.length === 0) {
    console.log(`no .txt label files in ${options.dir}`)
    return
  }

  let imported = 0
  let warnings = 0
  for (const name of files) {
    const id = basename(name, extname(name))
    const track = byId.get(id)
    if (!track) {
      console.log(`  ✗ ${name}: no track with the id "${id}" in the manifest (name it after the audio file)`)
      warnings++
      continue
    }
    const times = parseLabels(await readFile(join(options.dir, name), 'utf8'))
    if (times.length === 0) {
      console.log(`  ✗ ${id}: no labels in the file`)
      warnings++
      continue
    }

    const notes: string[] = []
    const span = times[times.length - 1] - times[0]
    if (times.length < 3) notes.push(`only ${times.length} mark${times.length === 1 ? '' : 's'}: phase is checked, drift needs three`)
    else if (span < MIN_SPAN_SEC) notes.push(`marks span ${span.toFixed(0)} s: spread them over the start, middle and end`)
    let tempo = ''
    // The tag counts the first gap. When there is no tag, or the marks will
    // not sit on a grid near it, count that gap as the 32 kicks the marking
    // instructions ask for instead.
    const tag = track.truth.bpm
    const clean = (fit: MarkFit | null): fit is MarkFit =>
      fit != null && !fit.firstGapUnsure && fit.residualsMs.every((ms) => Math.abs(ms) <= MARK_TOLERANCE_MS)
    const checked = tag && times.length >= 3 ? checkMarks(times, tag) : null
    const byKicks = times.length >= 3 ? fitMarks(times, (60 * KICKS_IN_FIRST_GAP) / (times[1] - times[0])) : null
    if (checked && !checked.odd) {
      tempo = `  marks give ${checked.fit.bpm.toFixed(3)} BPM (tag ${tag})`
    } else if (checked?.odd) {
      const { index, offMs } = checked.odd
      tempo = `  the others give ${checked.fit.bpm.toFixed(3)} BPM (tag ${tag})`
      notes.push(`mark ${index + 1} (${times[index].toFixed(3)} s) sits ${offMs > 0 ? '+' : ''}${offMs.toFixed(0)} ms off the beat the other marks agree on: left out; move it onto a kick and import again`)
    } else if (clean(byKicks) && byKicks.counts[1] === KICKS_IN_FIRST_GAP) {
      tempo = `  marks give ${byKicks.bpm.toFixed(3)} BPM, counting 32 kicks to the second mark`
      notes.push(tag ? `the tagged ${tag} BPM does not fit the marks: the tag looks wrong` : 'no BPM tag: the tempo above is from the marks alone')
    } else if (tag) {
      notes.push(`no steady beat near the tagged ${tag} BPM fits the marks, even leaving one out: check them, or the tempo changes`)
    } else {
      notes.push(times.length < 3 ? 'no BPM tag, and too few marks to find the tempo' : 'no BPM tag, and the marks do not fit a steady beat 32 kicks apart')
    }

    const before = track.truth.downbeatsSec
    // An odd mark stays out of the answers, or the bench would charge it to Dex.
    const kept = checked?.odd ? times.filter((_, i) => i !== checked.odd!.index) : times
    track.truth.downbeatsSec = kept.map((time) => Math.round(time * 1000) / 1000)
    const changed = JSON.stringify(before) !== JSON.stringify(track.truth.downbeatsSec)
    imported++
    warnings += notes.length
    console.log(`  ${notes.length ? '!' : '✓'} ${id}: ${kept.length} marks ${kept.map((time) => time.toFixed(3)).join(', ')}${changed ? '' : ' (unchanged)'}${tempo}`)
    for (const note of notes) console.log(`      ${note}`)
  }

  if (!options.dryRun && imported > 0) await writeFile(options.manifest, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log(
    `\n${imported} track${imported === 1 ? '' : 's'} ${options.dryRun ? 'checked (dry run, nothing written)' : `written to ${options.manifest}`}` +
      `${warnings ? `, ${warnings} thing${warnings === 1 ? '' : 's'} to look at` : ''}`
  )
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
