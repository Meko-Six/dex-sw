/** Real-track calibration/sanity report; energy has no human-labelled ground truth.
 * npx esbuild scripts/check-power.ts --bundle --platform=node --format=esm --outfile=out/check-power.mjs
 * node out/check-power.mjs [--all]
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { analyzePower, validPower } from '../src/shared/power'
import { decodeStereo } from './lib/audio-decode'

const manifest = JSON.parse(readFileSync('accuracy/manifest.json', 'utf8')) as {
  tracks: { file: string; truth: { bpm?: number; lufs?: number; downbeatsSec?: number[] } }[]
}
const selected = process.argv.includes('--all') ? manifest.tracks : manifest.tracks.filter((t) => /Solace|Dark_Rooms|Reverser|Insanity_Instantly|Presence_Interactive_Noise_Remix|Traffic_Original/.test(t.file))
const report = []
for (const track of selected) {
  const channels = await decodeStereo('accuracy/' + track.file, 22050)
  const grid = { bpm: track.truth.bpm ?? 120, offsetMs: ((track.truth.downbeatsSec?.[0] ?? 0) % (240 / (track.truth.bpm ?? 120))) * 1000, confidence: 1 }
  const begin = performance.now()
  const power = analyzePower(channels, 22050, grid)
  const ms = Math.round(performance.now() - begin)
  const quiet = analyzePower(channels.map((c) => c.map((v) => v * 0.25)), 22050, grid)
  const gainError = Math.max(...power.values.map((v, i) => Math.abs(v - quiet.values[i])))
  if (!validPower(power, channels[0].length / 22050) || gainError > 0.002) throw new Error('Invalid or gain-sensitive curve: ' + track.file)
  const result = { file: track.file, seconds: Math.round(power.durationSec), score: power.score, min: Math.min(...power.values), max: Math.max(...power.values), lufs: power.lufs, referenceLufs: track.truth.lufs, lufsError: track.truth.lufs == null ? null : +(power.lufs! - track.truth.lufs).toFixed(2), gainError, ms, bytes: JSON.stringify(power).length }
  report.push(result)
  console.log(JSON.stringify(result))
}
writeFileSync('out/power-report.json', JSON.stringify({ note: 'Heuristic intensity sanity report, not human-rated accuracy.', tracks: report }, null, 2))
