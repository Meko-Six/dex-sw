import createStretch from 'signalsmith-stretch'
import { crossfadeGains } from '../../shared/curves'
import { beatPhase } from '../../shared/grid'
import { renderClicks } from '../../shared/synth'
import { phaseCorrectionBeats, seekTargetSec } from '../../shared/sync'
import { EqChain } from '../audio/eq'

/**
 * In-app audio self-test.
 *
 * These measurements run against real Web Audio graph + the Signalsmith
 * Stretch worklet, so "sync is tight" and "the loop is seamless" are numbers,
 * not opinions. Everything is measured from rendered audio, not from the
 * scheduler's own claims.
 */

export interface Metric {
  name: string
  value: number
  unit: string
  expected: string
  pass: boolean
}

export interface SelfTestReport {
  ok: boolean
  metrics: Metric[]
  errors: string[]
  durationMs: number
}

const SR = 48000

const RECORDER_SOURCE = `
class DexRecorder extends AudioWorkletProcessor {
  constructor() {
    super()
    this.recording = false
    this.port.onmessage = (event) => {
      const data = event.data || {}
      if (data.command === 'start') this.recording = true
      if (data.command === 'stop') this.recording = false
    }
  }
  process(inputs) {
    const input = inputs[0]
    if (this.recording && input && input.length > 0) {
      const channels = input.map((channel) => new Float32Array(channel))
      this.port.postMessage({ channels }, channels.map((channel) => channel.buffer))
    }
    return true
  }
}
registerProcessor('dex-recorder', DexRecorder)
`

interface Recorder {
  input: AudioNode
  start(): void
  stop(): Float32Array[]
}

/**
 * One registration per context: a processor name can only be registered once,
 * and every test now shares a single AudioContext.
 */
const recorderModules = new WeakMap<BaseAudioContext, Promise<void>>()

async function ensureRecorderModule(context: AudioContext): Promise<void> {
  let ready = recorderModules.get(context)
  if (!ready) {
    const url = URL.createObjectURL(new Blob([RECORDER_SOURCE], { type: 'application/javascript' }))
    ready = context.audioWorklet.addModule(url).finally(() => URL.revokeObjectURL(url))
    recorderModules.set(context, ready)
  }
  await ready
}

async function createRecorder(context: AudioContext): Promise<Recorder> {
  await ensureRecorderModule(context)
  const node = new AudioWorkletNode(context, 'dex-recorder', {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [2]
  })
  const sink = context.createGain()
  sink.gain.value = 0
  node.connect(sink)
  sink.connect(context.destination)

  let chunks: Float32Array[][] = []
  node.port.onmessage = (event: MessageEvent) => {
    chunks.push(event.data.channels as Float32Array[])
  }

  return {
    input: node,
    start() {
      chunks = []
      node.port.postMessage({ command: 'start' })
    },
    stop() {
      node.port.postMessage({ command: 'stop' })
      const channelCount = Math.max(1, chunks[0]?.length ?? 1)
      const merged: Float32Array[] = []
      for (let channel = 0; channel < channelCount; channel++) {
        const total = chunks.reduce((sum, chunk) => sum + (chunk[channel]?.length ?? 0), 0)
        const out = new Float32Array(total)
        let offset = 0
        for (const chunk of chunks) {
          const source = chunk[channel]
          if (!source) continue
          out.set(source, offset)
          offset += source.length
        }
        merged.push(out)
      }
      chunks = []
      return merged
    }
  }
}

function copy(channel: Float32Array): Float32Array {
  return Float32Array.from(channel)
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

interface Onset {
  time: number
  peak: number
}

/** Energy-difference onset picker with adaptive threshold and 80 ms separation. */
function findOnsets(channel: Float32Array, sampleRate: number): Onset[] {
  const hop = Math.max(1, Math.round(sampleRate * 0.004))
  const frame = hop * 3
  const count = Math.max(0, Math.floor((channel.length - frame) / hop))
  if (count < 8) return []
  const env = new Float32Array(count)
  for (let i = 0; i < count; i++) {
    let sum = 0
    const start = i * hop
    for (let j = 0; j < frame; j++) {
      const v = channel[start + j]
      sum += v * v
    }
    env[i] = Math.sqrt(sum / frame)
  }
  const diff = new Float32Array(count)
  for (let i = 1; i < count; i++) diff[i] = Math.max(0, env[i] - env[i - 1])
  let mean = 0
  for (let i = 0; i < count; i++) mean += diff[i]
  mean /= count
  let variance = 0
  for (let i = 0; i < count; i++) variance += (diff[i] - mean) ** 2
  const threshold = mean + Math.sqrt(variance / count) * 1.6

  const onsets: Onset[] = []
  let lastIndex = -1000
  const minGap = Math.round(0.08 / (hop / sampleRate))
  for (let i = 2; i < count - 1; i++) {
    if (diff[i] < threshold) continue
    if (diff[i] < diff[i - 1] || diff[i] < diff[i + 1]) continue
    const start = i * hop
    let peak = 0
    const windowEnd = Math.min(channel.length, start + frame * 4)
    for (let j = start; j < windowEnd; j++) peak = Math.max(peak, Math.abs(channel[j]))
    if (i - lastIndex < minGap) {
      if (onsets.length > 0 && env[i] > env[lastIndex]) {
        onsets[onsets.length - 1] = { time: (i * hop) / sampleRate, peak }
        lastIndex = i
      }
      continue
    }
    onsets.push({ time: (i * hop) / sampleRate, peak })
    lastIndex = i
  }
  return onsets
}

function rmsInWindow(channel: Float32Array, sampleRate: number, fromSec: number, toSec: number): number {
  const from = Math.max(0, Math.floor(fromSec * sampleRate))
  const to = Math.min(channel.length, Math.floor(toSec * sampleRate))
  if (to <= from) return 0
  let sum = 0
  for (let i = from; i < to; i++) sum += channel[i] * channel[i]
  return Math.sqrt(sum / (to - from))
}

function median(values: number[]): number {
  if (values.length === 0) return Number.NaN
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]
}

/** Normalised autocorrelation peak in a lag window — measures loop periodicity. */
function bestPeriod(
  channel: Float32Array,
  sampleRate: number,
  minSec: number,
  maxSec: number,
  stepSec = 0.002
): { period: number; score: number } {
  const maxLag = Math.floor(maxSec * sampleRate)
  const length = Math.min(Math.max(0, channel.length - maxLag), Math.floor(3 * sampleRate))
  let bestLag = Math.floor(minSec * sampleRate)
  let bestScore = -Infinity
  for (let lag = Math.floor(minSec * sampleRate); lag <= maxLag; lag += Math.max(1, Math.floor(stepSec * sampleRate))) {
    let num = 0
    let denA = 0
    let denB = 0
    for (let i = 0; i < length; i += 4) {
      const a = channel[i]
      const b = channel[i + lag]
      num += a * b
      denA += a * a
      denB += b * b
    }
    const score = num / Math.sqrt(denA * denB + 1e-12)
    if (score > bestScore) {
      bestScore = score
      bestLag = lag
    }
  }
  return { period: bestLag / sampleRate, score: bestScore }
}

function goertzel(channel: Float32Array, sampleRate: number, frequency: number, fromSec: number, toSec: number): number {
  const from = Math.max(0, Math.floor(fromSec * sampleRate))
  const to = Math.min(channel.length, Math.floor(toSec * sampleRate))
  const n = to - from
  if (n <= 0) return 0
  const omega = (2 * Math.PI * frequency) / sampleRate
  const coefficient = 2 * Math.cos(omega)
  let s1 = 0
  let s2 = 0
  for (let i = 0; i < n; i++) {
    const s0 = channel[from + i] + coefficient * s1 - s2
    s2 = s1
    s1 = s0
  }
  return (2 * Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))) / n
}

/**
 * All measurements share one context. Chromium caps the number of live
 * AudioContexts per document, and creating one per test eventually left
 * `resume()` pending forever halfway through the run.
 */
let sharedContext: AudioContext | null = null

async function withContext<T>(fn: (context: AudioContext) => Promise<T>): Promise<T> {
  if (!sharedContext) {
    sharedContext = new AudioContext({ sampleRate: SR })
    await sharedContext.resume()
  }
  return await fn(sharedContext)
}

async function testSync(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorderA = await createRecorder(context)
    const recorderB = await createRecorder(context)
    const deckA = await createStretch(context)
    const deckB = await createStretch(context)
    deckA.connect(recorderA.input)
    deckB.connect(recorderB.input)

    // Clicks on every beat: the house pattern's offbeat hats would read as
    // extra "beats" and make the period measurement meaningless.
    const audioA = renderClicks(120, 8, SR)
    const audioB = renderClicks(128, 8, SR)
    await deckA.addBuffers([copy(audioA), copy(audioA)])
    await deckB.addBuffers([copy(audioB), copy(audioB)])

    const gridA = { bpm: 120, offsetMs: 0, confidence: 1 }
    const gridB = { bpm: 128, offsetMs: 0, confidence: 1 }
    const posA = 0.2
    const posB = 0.5
    const rate = 120 / 128
    const correction = phaseCorrectionBeats(beatPhase(gridA, posA), beatPhase(gridB, posB))
    const targetB = seekTargetSec(posB, correction, gridB)

    const start = context.currentTime + 0.25
    recorderA.start()
    recorderB.start()
    await deckA.schedule({ output: start, active: true, input: posA, rate: 1, semitones: 0, loopStart: 0, loopEnd: 0 })
    await deckB.schedule({ output: start, active: true, input: targetB, rate, semitones: 0, loopStart: 0, loopEnd: 0 })
    await delay(5200)
    const a = recorderA.stop()[0]
    const b = recorderB.stop()[0]

    const onsetsA = findOnsets(a, SR).filter((onset) => onset.time > 0.8 && onset.time < 4.9)
    const onsetsB = findOnsets(b, SR).filter((onset) => onset.time > 0.3 && onset.time < 4.9)
    const differences: number[] = []
    for (const onset of onsetsA) {
      let best = Infinity
      for (const other of onsetsB) best = Math.min(best, Math.abs(other.time - onset.time))
      if (Number.isFinite(best) && best < 0.25) differences.push(best)
    }
    const alignmentMedian = median(differences) * 1000
    const alignmentMax = differences.length > 0 ? Math.max(...differences) * 1000 : Number.NaN
    metrics.push({
      name: 'Sync beat alignment (median)',
      value: Number.isFinite(alignmentMedian) ? alignmentMedian : -1,
      unit: 'ms',
      expected: '< 15 ms',
      pass: Number.isFinite(alignmentMedian) && alignmentMedian < 15 && differences.length >= 5
    })
    metrics.push({
      name: 'Sync beat alignment (worst beat)',
      value: Number.isFinite(alignmentMax) ? alignmentMax : -1,
      unit: 'ms',
      expected: '< 25 ms',
      pass: Number.isFinite(alignmentMax) && alignmentMax < 25
    })

    const spacing = median(onsetsB.slice(1).map((onset, index) => onset.time - onsetsB[index].time))
    const expectedSpacing = 60 / 128 / rate
    metrics.push({
      name: 'Synced deck beat period',
      value: spacing * 1000,
      unit: 'ms',
      expected: `${(expectedSpacing * 1000).toFixed(1)} ms ± 5`,
      pass: Math.abs(spacing - expectedSpacing) < 0.005
    })
  })
}

/**
 * A deck that is started *after* its sync partner must land on the master's
 * beat. This is measured from audio, so it covers the stretch node's seek
 * latency as well as the phase maths.
 */
async function testSyncedStart(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorderA = await createRecorder(context)
    const recorderB = await createRecorder(context)
    const deckA = await createStretch(context)
    const deckB = await createStretch(context)
    deckA.connect(recorderA.input)
    deckB.connect(recorderB.input)

    const audioA = renderClicks(120, 8, SR)
    const audioB = renderClicks(128, 8, SR)
    await deckA.addBuffers([copy(audioA), copy(audioA)])
    await deckB.addBuffers([copy(audioB), copy(audioB)])

    const gridA = { bpm: 120, offsetMs: 0, confidence: 1 }
    const gridB = { bpm: 128, offsetMs: 0, confidence: 1 }
    const posA = 0.2
    const posB = 0.4
    const rate = 120 / 128

    const startA = context.currentTime + 0.3
    const startB = startA + 1.0
    // A runs at rate 1 from posA, so its position at startB is fixed.
    const masterAtStartB = posA + (startB - startA)
    const correction = phaseCorrectionBeats(beatPhase(gridA, masterAtStartB), beatPhase(gridB, posB))
    const targetB = posB + correction * (60 / 128)

    recorderA.start()
    recorderB.start()
    await deckA.schedule({ output: startA, active: true, input: posA, rate: 1, semitones: 0, loopStart: 0, loopEnd: 0 })
    await deckB.schedule({ output: startB, active: true, input: targetB, rate, semitones: 0, loopStart: 0, loopEnd: 0 })
    await delay(4900)
    const a = recorderA.stop()[0]
    const b = recorderB.stop()[0]

    const from = 1.25
    const until = 4.6
    const onsetsA = findOnsets(a, SR).filter((onset) => onset.time > from && onset.time < until)
    const onsetsB = findOnsets(b, SR).filter((onset) => onset.time > from && onset.time < until)
    const differences: number[] = []
    for (const onset of onsetsB) {
      let best = Infinity
      for (const other of onsetsA) best = Math.min(best, Math.abs(other.time - onset.time))
      if (Number.isFinite(best) && best < 0.25) differences.push(best)
    }
    const medianDiff = median(differences) * 1000
    const maxDiff = differences.length > 0 ? Math.max(...differences) * 1000 : Number.NaN
    metrics.push({
      name: 'Synced late start (median)',
      value: Number.isFinite(medianDiff) ? medianDiff : -1,
      unit: 'ms',
      expected: '< 15 ms',
      pass: Number.isFinite(medianDiff) && medianDiff < 15 && differences.length >= 5
    })
    metrics.push({
      name: 'Synced late start (worst beat)',
      value: Number.isFinite(maxDiff) ? maxDiff : -1,
      unit: 'ms',
      expected: '< 25 ms',
      pass: Number.isFinite(maxDiff) && maxDiff < 25
    })
  })
}

async function testLoop(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorder = await createRecorder(context)
    const deck = await createStretch(context)
    deck.connect(recorder.input)

    // Accented pulse train: strong hit on every bar, soft hits on every beat.
    const buffer = new Float32Array(SR * 8)
    for (let beat = 0; beat < 16; beat++) {
      const at = Math.round(beat * 0.5 * SR)
      const amplitude = beat % 4 === 0 ? 1 : 0.28
      const length = Math.round(0.08 * SR)
      for (let i = 0; i < length; i++) {
        const t = i / SR
        buffer[at + i] += Math.sin(2 * Math.PI * 220 * t) * Math.exp(-t * 14) * amplitude
      }
    }
    await deck.addBuffers([copy(buffer), copy(buffer)])
    const start = context.currentTime + 0.2
    recorder.start()
    await deck.schedule({ output: start, active: true, input: 1, rate: 1, semitones: 0, loopStart: 1, loopEnd: 3 })
    await delay(5200)
    const rendered = recorder.stop()[0]

    const accents = findOnsets(rendered, SR).filter((onset) => onset.peak > 0.55)
    const accentGaps = accents.slice(1).map((onset, index) => onset.time - accents[index].time)
    const gap = median(accentGaps)
    const repeat = bestPeriod(rendered, SR, 1.85, 2.15)
    metrics.push({
      name: '4-beat loop repeat period',
      value: repeat.period * 1000,
      unit: 'ms',
      expected: '2000 ms ± 3',
      pass: Math.abs(repeat.period - 2) < 0.003
    })
    metrics.push({
      name: 'Loop self-similarity at the repeat',
      value: repeat.score,
      unit: 'corr',
      expected: '> 0.7',
      pass: repeat.score > 0.7
    })
    metrics.push({
      name: 'Accent spacing median',
      value: gap * 1000,
      unit: 'ms',
      expected: '2000 ms ± 10',
      pass: Math.abs(gap - 2) < 0.01 && accentGaps.length >= 1
    })
  })
}

async function testLoopSeam(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorder = await createRecorder(context)
    const deck = await createStretch(context)
    deck.connect(recorder.input)

    const sine = new Float32Array(SR * 8)
    for (let i = 0; i < sine.length; i++) sine[i] = Math.sin((2 * Math.PI * 220 * i) / SR) * 0.5
    await deck.addBuffers([copy(sine), copy(sine)])
    const start = context.currentTime + 0.2
    recorder.start()
    await deck.schedule({ output: start, active: true, input: 1, rate: 1, semitones: 0, loopStart: 1, loopEnd: 3 })
    await delay(4600)
    const rendered = recorder.stop()[0]

    let maxDelta = 0
    const deltas = new Float32Array(rendered.length - 1)
    for (let i = 1; i < rendered.length; i++) {
      const delta = Math.abs(rendered[i] - rendered[i - 1])
      deltas[i - 1] = delta
      if (delta > maxDelta) maxDelta = delta
    }
    const sorted = Array.from(deltas).sort((a, b) => a - b)
    const p999 = sorted[Math.floor(sorted.length * 0.999)] ?? 0
    const seamJump = maxDelta / Math.max(1e-6, p999)
    metrics.push({
      name: 'Loop seam discontinuity vs normal slew',
      value: seamJump,
      unit: '×',
      expected: '< 3×',
      pass: seamJump < 3
    })
  })
}

async function testEq(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorder = await createRecorder(context)
    const eq = new EqChain(context)
    const oscillator = context.createOscillator()
    oscillator.type = 'sine'
    const level = context.createGain()
    level.gain.value = 0.4
    oscillator.connect(level)
    level.connect(eq.input)
    eq.output.connect(recorder.input)
    oscillator.start()

    const measure = async (frequency: number, knob: number, band: 'low' | 'mid' | 'high', filter = 0): Promise<number> => {
      oscillator.frequency.setValueAtTime(frequency, context.currentTime)
      eq.setBand(band, knob)
      eq.setFilter(filter)
      await delay(260)
      recorder.start()
      await delay(420)
      const channel = recorder.stop()[0]
      return rmsInWindow(channel, SR, 0.08, 0.38)
    }

    const flat100 = await measure(100, 0, 'low')
    const killed100 = await measure(100, -1, 'low')
    const lowKillDb = 20 * Math.log10(Math.max(1e-9, killed100) / Math.max(1e-9, flat100))
    metrics.push({
      name: 'Low EQ kill at 100 Hz',
      value: lowKillDb,
      unit: 'dB',
      expected: '< -18 dB',
      pass: lowKillDb < -18
    })

    const flat1k = await measure(1000, 0, 'mid')
    const killed1k = await measure(1000, -1, 'low')
    const bleedDb = 20 * Math.log10(Math.max(1e-9, killed1k) / Math.max(1e-9, flat1k))
    metrics.push({
      name: 'Low kill bleed at 1 kHz',
      value: bleedDb,
      unit: 'dB',
      expected: '|x| < 3 dB',
      pass: Math.abs(bleedDb) < 3
    })

    const flat8k = await measure(8000, 0, 'high')
    const boosted8k = await measure(8000, 1, 'high')
    const highBoostDb = 20 * Math.log10(Math.max(1e-9, boosted8k) / Math.max(1e-9, flat8k))
    metrics.push({
      name: 'High EQ boost at 8 kHz',
      value: highBoostDb,
      unit: 'dB',
      expected: '> 4.5 dB',
      pass: highBoostDb > 4.5
    })

    const lowPassed8k = await measure(8000, 0, 'high', -1)
    const lowPassDb = 20 * Math.log10(Math.max(1e-9, lowPassed8k) / Math.max(1e-9, flat8k))
    metrics.push({
      name: 'Sweep filter low-pass at 8 kHz',
      value: lowPassDb,
      unit: 'dB',
      expected: '< -20 dB',
      pass: lowPassDb < -20
    })

    const highPassed100 = await measure(100, 0, 'low', 1)
    const highPassDb = 20 * Math.log10(Math.max(1e-9, highPassed100) / Math.max(1e-9, flat100))
    metrics.push({
      name: 'Sweep filter high-pass at 100 Hz',
      value: highPassDb,
      unit: 'dB',
      expected: '< -20 dB',
      pass: highPassDb < -20
    })

    oscillator.stop()
  })
}

async function testCrossfader(metrics: Metric[]): Promise<void> {
  await withContext(async (context) => {
    const recorder = await createRecorder(context)
    const left = context.createOscillator()
    left.frequency.value = 440
    const right = context.createOscillator()
    right.frequency.value = 660
    const gainLeft = context.createGain()
    const gainRight = context.createGain()
    const [a, b] = crossfadeGains(0.5)
    gainLeft.gain.value = a
    gainRight.gain.value = b
    const trimLeft = context.createGain()
    const trimRight = context.createGain()
    trimLeft.gain.value = 0.5
    trimRight.gain.value = 0.5
    left.connect(trimLeft)
    trimLeft.connect(gainLeft)
    right.connect(trimRight)
    trimRight.connect(gainRight)
    gainLeft.connect(recorder.input)
    gainRight.connect(recorder.input)
    left.start()
    right.start()

    recorder.start()
    await delay(900)
    const channel = recorder.stop()[0]
    const amplitudeLeft = goertzel(channel, SR, 440, 0.25, 0.75)
    const amplitudeRight = goertzel(channel, SR, 660, 0.25, 0.75)
    const expected = 0.5 * Math.SQRT1_2
    const errorDb = 20 * Math.log10(Math.max(1e-9, amplitudeLeft) / expected)
    metrics.push({
      name: 'Crossfader level at centre (deck A)',
      value: errorDb,
      unit: 'dB vs -3.01',
      expected: '|x| < 0.6 dB',
      pass: Math.abs(errorDb) < 0.6
    })
    const balanceDb = 20 * Math.log10(Math.max(1e-9, amplitudeLeft) / Math.max(1e-9, amplitudeRight))
    metrics.push({
      name: 'Crossfader L/R balance at centre',
      value: balanceDb,
      unit: 'dB',
      expected: '|x| < 0.3 dB',
      pass: Math.abs(balanceDb) < 0.3
    })
    left.stop()
    right.stop()
  })
}

export async function runSelfTest(onProgress: (message: string) => void): Promise<SelfTestReport> {
  const started = performance.now()
  const metrics: Metric[] = []
  const errors: string[] = []

  const steps: Array<[string, (m: Metric[]) => Promise<void>]> = [
    ['Measuring two-deck sync…', testSync],
    ['Measuring a late synced start…', testSyncedStart],
    ['Measuring loop period…', testLoop],
    ['Measuring loop seam…', testLoopSeam],
    ['Measuring EQ response…', testEq],
    ['Measuring crossfader law…', testCrossfader]
  ]

  for (const [label, step] of steps) {
    onProgress(label)
    try {
      await step(metrics)
    } catch (error) {
      errors.push(`${label} ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const context = sharedContext
  sharedContext = null
  await context?.close().catch(() => undefined)

  onProgress('Done')
  return {
    ok: errors.length === 0 && metrics.every((metric) => metric.pass),
    metrics,
    errors,
    durationMs: performance.now() - started
  }
}
