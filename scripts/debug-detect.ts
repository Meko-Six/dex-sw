/**
 * Dev-only tuning harness: prints beat-detector internals for synthetic
 * fixtures so thresholds and confidence can be checked as numbers.
 *
 *   npx esbuild scripts/debug-detect.ts --bundle --format=esm --platform=node --outfile=/tmp/debug-detect.mjs && node /tmp/debug-detect.mjs
 */
import {
  ANALYSIS_FPS,
  ANALYSIS_SAMPLE_RATE,
  detectBeats,
  estimateTempo,
  fitBeatPhase,
  gridJitterSec,
  onsetEnvelope,
  resampleLinear
} from '../src/shared/detector'
import { renderPattern, type PatternStyle } from '../src/shared/synth'

const SR = 44100

function analyze(bpm: number, style: PatternStyle, offsetMs = 0, seconds = 24) {
  const audio = renderPattern({ bpm, seconds, sampleRate: SR, style, startOffsetMs: offsetMs })
  const env = onsetEnvelope(resampleLinear(audio, SR, ANALYSIS_SAMPLE_RATE))
  const tempo = estimateTempo(env, ANALYSIS_FPS)
  const grid = fitBeatPhase(env, (60 / tempo.bpm) * ANALYSIS_FPS)
  const jitter = gridJitterSec(env, grid.periodFrames, grid.offsetFrames)
  const out = detectBeats(audio, SR)
  console.log(
    [
      `${style}@${bpm} (offset ${offsetMs}ms)`.padEnd(34),
      `tempo=${tempo.bpm.toFixed(2)}`,
      `strength=${tempo.strength.toFixed(2)}`,
      `period=${grid.periodFrames.toFixed(3)}`,
      `phase=${grid.offsetFrames.toFixed(2)}`,
      `coverage=${grid.coverage.toFixed(2)}`,
      `jitter=${(jitter * 1000).toFixed(1)}ms`,
      `=> ${out.bpm.toFixed(2)} / ${out.offsetMs.toFixed(0)}ms`,
      `conf=${out.confidence.toFixed(2)}`
    ].join('  ')
  )
}

analyze(128, 'house')
analyze(124, 'house')
analyze(100, 'pop')
analyze(140, 'breakbeat')
analyze(174, 'dnb')
analyze(126, 'house', 0, 20)
analyze(126, 'house', 240, 20)
analyze(126, 'house', 137, 20)

const noise = new Float32Array(SR * 12)
for (let i = 0; i < noise.length; i++) noise[i] = (Math.random() * 2 - 1) * 0.05
const noiseResult = detectBeats(noise, SR)
console.log('noise', noiseResult.bpm.toFixed(2), noiseResult.confidence.toFixed(2))
