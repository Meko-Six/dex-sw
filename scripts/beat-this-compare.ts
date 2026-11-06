#!/usr/bin/env node
/**
 * Score Beat This (the ML beat tracker) against the hand marks and Dex's own grid.
 *
 *   npm run accuracy:beat-this        reads out/beat-this/*.json from scripts/beat-this/run.py
 *
 * For each checkpoint: how far its beats sit from the marks (raw, and after a
 * straight grid is fitted through them), and whether its downbeats put bar 1
 * where the marks do. Bar positions are counted on Dex's grid, whose "one" the
 * marks agree with on every marked track, so 0 means "same bar 1 as the marks".
 */
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { detectBeats } from '../src/shared/detector'
import { toMono } from '../src/shared/dsp'
import { fitGrid } from '../src/shared/grid'
import { decodeStereo } from './lib/audio-decode'

const SAMPLE_RATE = 22050
const TOLERANCE_MS = 15
const ACTIVATION_FPS = 50

interface BeatThisTrack {
  beats: number[]
  downbeats: number[]
  downAct: number[]
  seconds: number
  durationSec: number
}

interface Track {
  id: string
  file: string
  truth: { downbeatsSec?: number[] }
}

async function main(): Promise<void> {
  const dir = resolve('accuracy')
  const manifest = JSON.parse(await readFile(join(dir, 'manifest.json'), 'utf8')) as { tracks: Track[] }
  const marked = manifest.tracks.filter((track) => (track.truth.downbeatsSec?.length ?? 0) > 0)
  const checkpoints: Array<[string, Record<string, BeatThisTrack>]> = []
  for (const name of ['small0', 'final0']) {
    const path = resolve('out', 'beat-this', `${name}.json`)
    if (existsSync(path)) checkpoints.push([name, JSON.parse(await readFile(path, 'utf8'))])
  }
  if (checkpoints.length === 0) {
    console.error('no out/beat-this/*.json: run scripts/beat-this/run.py first (see scripts/beat-this/README.md)')
    process.exitCode = 1
    return
  }

  const totals = new Map<string, { onGrid: number; bar: number; count: number; worstMs: number; seconds: number; audio: number }>()
  for (const track of marked) {
    const marks = track.truth.downbeatsSec ?? []
    const dex = detectBeats(toMono(await decodeStereo(join(dir, track.file), SAMPLE_RATE)), SAMPLE_RATE)
    const period = 60 / dex.bpm
    const offset = dex.offsetMs / 1000
    const barOf = (sec: number): number => ((Math.round((sec - offset) / period) % 4) + 4) % 4
    const markVotes = [0, 0, 0, 0]
    for (const mark of marks) markVotes[barOf(mark)]++
    const marksBar = markVotes.indexOf(Math.max(...markVotes))

    let line = `${track.id.slice(0, 34).padEnd(35)}`
    for (const [name, results] of checkpoints) {
      const result = results[track.id]
      if (!result) continue
      const total = totals.get(name) ?? { onGrid: 0, bar: 0, count: 0, worstMs: 0, seconds: 0, audio: 0 }
      const fit = fitGrid(result.beats, dex.bpm)
      const fitPeriod = 60 / fit.bpm
      const fitOffset = fit.offsetMs / 1000
      const worstMs = Math.max(
        ...marks.map((mark) => {
          const beat = Math.round((mark - fitOffset) / fitPeriod)
          return Math.abs(mark - fitOffset - beat * fitPeriod) * 1000
        })
      )
      // Downbeat activation at each of Dex's beats, summed by position in the bar.
      const votes = [0, 0, 0, 0]
      const beats = Math.floor((result.durationSec - offset) / period)
      for (let k = 0; k < beats; k++) {
        const frame = Math.round((offset + k * period) * ACTIVATION_FPS)
        let peak = 0
        for (let f = frame - 1; f <= frame + 1; f++) peak = Math.max(peak, result.downAct[f] ?? 0)
        votes[k % 4] += peak
      }
      const bar = votes.indexOf(Math.max(...votes))
      total.count++
      if (worstMs <= TOLERANCE_MS) total.onGrid++
      if (bar === marksBar) total.bar++
      total.worstMs = Math.max(total.worstMs, worstMs)
      total.seconds += result.seconds
      total.audio += result.durationSec
      totals.set(name, total)
      line += `  ${name} ${fit.bpm.toFixed(3)} worst ${worstMs.toFixed(0).padStart(3)}ms bar ${bar === marksBar ? '✓' : `✗ ${bar}`} `
    }
    console.log(line)
  }

  console.log(`\nDex: every marked track on the beat (${TOLERANCE_MS} ms) and on the right bar — see npm run accuracy -- --marked`)
  for (const [name, total] of totals) {
    console.log(
      `${name}: fitted grid on the beat ${total.onGrid}/${total.count} (worst ${total.worstMs.toFixed(0)} ms), ` +
        `bar 1 right ${total.bar}/${total.count}, ${(total.seconds / total.count).toFixed(1)} s per track in PyTorch`
    )
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
