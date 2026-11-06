/**
 * Deterministic synthetic drum patterns.
 *
 * These exist so beat detection, sync and looping can be tested and measured
 * without shipping any copyrighted audio: every fixture has a known BPM and a
 * known beat-1 position, so accuracy is a number, not an opinion.
 */

export type PatternStyle = 'house' | 'pop' | 'dnb' | 'breakbeat' | 'silence'

interface PatternMasks {
  kick: string
  snare: string
  hat: string
  bass: string
}

const PATTERNS: Record<PatternStyle, PatternMasks> = {
  // 16 steps per bar, one character per 16th note.
  house: {
    kick: '1000100010001000',
    snare: '0000100000001000',
    hat: '1010101010101010',
    bass: '0010001000100010'
  },
  pop: {
    kick: '1000000010000000',
    snare: '0000100000001000',
    hat: '1010101010101010',
    bass: '1000100010001000'
  },
  dnb: {
    kick: '1000000000100000',
    snare: '0000100000000100',
    hat: '1011101110111011',
    bass: '1000000010000000'
  },
  breakbeat: {
    kick: '1000000010001000',
    snare: '0000100000100100',
    hat: '1010101010101010',
    bass: '0000100000001000'
  },
  silence: {
    kick: '0000000000000000',
    snare: '0000000000000000',
    hat: '0000000000000000',
    bass: '0000000000000000'
  }
}

export interface PatternOptions {
  bpm: number
  seconds: number
  sampleRate?: number
  style?: PatternStyle
  /** Bar-1 alignment offset in milliseconds (used to verify grid offsets). */
  startOffsetMs?: number
  /** Delay every second 16th by this fraction of a step (0 … 0.3). */
  swing?: number
  gain?: number
  /**
   * Noise seed. Fixed by default: this is measurement material, and a pattern
   * whose snare and hat noise changes per run makes the detector tests
   * irreproducible — a one-in-a-hundred phase lock would look like a flake.
   */
  seed?: number
}

/** Small deterministic PRNG (mulberry32) for the noise sources below. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function addKick(buffer: Float32Array, sampleRate: number, at: number, gain: number): void {
  const length = Math.floor(sampleRate * 0.35)
  for (let i = 0; i < length; i++) {
    const index = at + i
    if (index < 0 || index >= buffer.length) continue
    const t = i / sampleRate
    const phase = 2 * Math.PI * (48 * t + (110 / 30) * (1 - Math.exp(-30 * t)))
    buffer[index] += Math.sin(phase) * Math.exp(-t * 16) * 0.85 * gain
  }
}

function addSnare(buffer: Float32Array, sampleRate: number, at: number, gain: number, rand: () => number): void {
  const length = Math.floor(sampleRate * 0.25)
  let noise = 0
  for (let i = 0; i < length; i++) {
    const index = at + i
    const t = i / sampleRate
    noise = rand() * 2 - 1
    const env = Math.exp(-t * 20)
    const body = Math.sin(2 * Math.PI * 185 * t) * Math.exp(-t * 26)
    if (index >= 0 && index < buffer.length) {
      buffer[index] += (noise * 0.42 + body * 0.32) * env * gain
    }
  }
}

function addHat(buffer: Float32Array, sampleRate: number, at: number, gain: number, rand: () => number): void {
  const length = Math.floor(sampleRate * 0.09)
  let previous = 0
  for (let i = 0; i < length; i++) {
    const index = at + i
    const t = i / sampleRate
    const noise = rand() * 2 - 1
    const high = noise - previous
    previous = noise
    if (index >= 0 && index < buffer.length) {
      buffer[index] += high * Math.exp(-t * 75) * 0.22 * gain
    }
  }
}

function addBass(buffer: Float32Array, sampleRate: number, at: number, gain: number): void {
  const length = Math.floor(sampleRate * 0.22)
  for (let i = 0; i < length; i++) {
    const index = at + i
    if (index < 0 || index >= buffer.length) continue
    const t = i / sampleRate
    const env = Math.exp(-t * 9)
    buffer[index] += (Math.sin(2 * Math.PI * 55 * t) * 0.28 + Math.sin(2 * Math.PI * 110 * t) * 0.08) * env * gain
  }
}

/** Render a mono drum pattern with a known tempo and beat alignment. */
export function renderPattern(options: PatternOptions): Float32Array {
  const sampleRate = options.sampleRate ?? 44100
  const style = options.style ?? 'house'
  const gain = options.gain ?? 0.8
  const length = Math.max(1, Math.floor(sampleRate * options.seconds))
  const buffer = new Float32Array(length)
  const masks = PATTERNS[style]
  const stepSec = 60 / options.bpm / 4
  const startSample = Math.round(((options.startOffsetMs ?? 0) / 1000) * sampleRate)
  const totalSteps = Math.ceil((options.seconds * 1000) / (stepSec * 1000)) + 16
  const rand = mulberry32(options.seed ?? 1)

  for (let step = 0; step < totalSteps; step++) {
    const barStep = step % 16
    let time = startSample / sampleRate + step * stepSec
    if (options.swing && barStep % 2 === 1) time += stepSec * options.swing
    const at = Math.round(time * sampleRate)
    if (masks.kick[barStep] === '1') addKick(buffer, sampleRate, at, gain)
    if (masks.snare[barStep] === '1') addSnare(buffer, sampleRate, at, gain, rand)
    if (masks.hat[barStep] === '1') addHat(buffer, sampleRate, at, gain, rand)
    if (masks.bass[barStep] === '1') addBass(buffer, sampleRate, at, gain)
  }

  for (let i = 0; i < length; i++) {
    const v = buffer[i]
    buffer[i] = v > 1 ? 1 : v < -1 ? -1 : v
  }
  return buffer
}

/** Impulse train on every beat — used to measure grid/loop timing exactly. */
export function renderClicks(bpm: number, seconds: number, sampleRate = 44100): Float32Array {
  const length = Math.floor(seconds * sampleRate)
  const out = new Float32Array(length)
  const beatSec = 60 / bpm
  const clickLength = Math.floor(sampleRate * 0.02)
  for (let beat = 0; beat * beatSec < seconds; beat++) {
    const at = Math.round(beat * beatSec * sampleRate)
    for (let i = 0; i < clickLength; i++) {
      const index = at + i
      if (index >= length) break
      const t = i / sampleRate
      out[index] += Math.sin(2 * Math.PI * 1200 * t) * Math.exp(-t * 300) * 0.7
    }
  }
  return out
}

/** Stereo copy helper for engines that expect per-channel arrays. */
export function toStereo(mono: Float32Array): Float32Array[] {
  return [mono, Float32Array.from(mono)]
}

export interface ChordOptions {
  /** Pitch class of the root, 0 = C … 11 = B. */
  root: number
  mode: 'major' | 'minor'
  seconds: number
  sampleRate?: number
  /** Scientific octave of the root; 4 is middle C. */
  octave?: number
  /** Harmonic partials per note (1 = pure sine). */
  partials?: number
  gain?: number
}

function midiToHz(midi: number): number {
  return 440 * 2 ** ((midi - 69) / 12)
}

/**
 * A sustained triad with optional harmonics, for key-detection tests.
 *
 * A pure sine triad is the clearest possible input; adding partials makes it
 * more like a synth patch and checks that harmonic energy does not drag the
 * estimate to a neighbouring key.
 */
export function renderChord(options: ChordOptions): Float32Array {
  const sampleRate = options.sampleRate ?? 44100
  const gain = options.gain ?? 0.25
  const octave = options.octave ?? 4
  const partials = Math.max(1, options.partials ?? 1)
  const rootMidi = 12 * (octave + 1) + options.root
  const intervals = options.mode === 'major' ? [0, 4, 7] : [0, 3, 7]
  const length = Math.max(1, Math.floor(options.seconds * sampleRate))
  const buffer = new Float32Array(length)

  // 30 ms fade in/out so the fixture has no click energy of its own.
  const fade = Math.min(Math.floor(sampleRate * 0.03), Math.floor(length / 2))

  for (const interval of intervals) {
    const frequency = midiToHz(rootMidi + interval)
    for (let partial = 1; partial <= partials; partial++) {
      const amplitude = gain / partial ** 1.6
      const partialHz = frequency * partial
      if (partialHz >= sampleRate / 2) break
      const phase = 2 * Math.PI * partialHz / sampleRate
      for (let i = 0; i < length; i++) {
        const envelope = i < fade ? i / fade : i > length - fade ? (length - i) / fade : 1
        buffer[i] += Math.sin(phase * i) * amplitude * envelope
      }
    }
  }
  return buffer
}
