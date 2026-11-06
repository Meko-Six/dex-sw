#!/usr/bin/env node
/**
 * Generates deterministic test tracks in ./fixtures.
 *
 * These are synthesised four-to-the-floor loops with a known BPM, a known
 * downbeat and a little musical content (bass line, offbeat hats, claps), so
 * beat detection, grid alignment and sync can be checked by ear and by number.
 *
 *   npm run fixtures
 *
 * Each file is 16-bit stereo WAV at 48 kHz, which Chromium decodes natively.
 */
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

const SR = 48000
const OUT_DIR = path.resolve(process.cwd(), 'fixtures')

/** Tiny deterministic PRNG so every run produces identical files. */
function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function kick(t, gain = 1) {
  // Pitch-swept sine with a fast decay: the classic 909 thump.
  const freq = 46 + 130 * Math.exp(-t * 34)
  return Math.sin(2 * Math.PI * freq * t) * Math.exp(-t * 9) * gain
}

function hat(t, rand, gain = 1) {
  return (rand() * 2 - 1) * Math.exp(-t * 80) * gain
}

function clap(t, rand, gain = 1) {
  const noise = (rand() * 2 - 1) * Math.exp(-t * 26)
  const body = Math.sin(2 * Math.PI * 175 * t) * Math.exp(-t * 22) * 0.4
  return (noise + body) * gain
}

function bass(t, freq, gain = 1) {
  const saw = 2 * ((t * freq) % 1) - 1
  const sub = Math.sin(2 * Math.PI * freq * t)
  return (saw * 0.35 + sub * 0.65) * Math.exp(-t * 2.4) * gain
}

function renderTrack({ bpm, seconds, offsetSec = 0, seed = 1, bassNote = 55, hats = true }) {
  const random = mulberry32(seed)
  const frames = Math.round(seconds * SR)
  const left = new Float32Array(frames)
  const right = new Float32Array(frames)
  const beat = 60 / bpm

  const add = (atSec, lengthSec, fn, pan = 0) => {
    const start = Math.round(atSec * SR)
    const count = Math.round(lengthSec * SR)
    for (let i = 0; i < count; i++) {
      const index = start + i
      if (index < 0 || index >= frames) continue
      const value = fn(i / SR)
      left[index] += value * (1 - Math.max(0, pan))
      right[index] += value * (1 + Math.min(0, pan))
    }
  }

  const firstBeat = Math.ceil(offsetSec / beat)
  const totalBeats = Math.floor((seconds - offsetSec) / beat)

  for (let index = firstBeat; index < firstBeat + totalBeats; index++) {
    const at = offsetSec + index * beat
    const inBar = ((index % 4) + 4) % 4
    add(at, 0.4, (t) => kick(t, inBar === 0 ? 1 : 0.85))
    if (hats) add(at + beat / 2, 0.06, (t) => hat(t, random, 0.16), 0.25)
    if (inBar === 1 || inBar === 3) add(at, 0.18, (t) => clap(t, random, 0.2), -0.15)
    if (inBar === 0) {
      add(at, 0.45, (t) => bass(t, bassNote, 0.34))
      add(at + beat / 2, 0.35, (t) => bass(t, bassNote * 1.5, 0.22))
    }
  }

  // A short fade in/out so the files never click at their edges.
  const fade = Math.round(0.01 * SR)
  for (let i = 0; i < fade; i++) {
    const gain = i / fade
    left[i] *= gain
    right[i] *= gain
    const j = frames - 1 - i
    left[j] *= gain
    right[j] *= gain
  }

  return { left, right }
}

function encodeWav({ left, right }) {
  const frames = left.length
  const buffer = Buffer.alloc(44 + frames * 4)
  buffer.write('RIFF', 0, 'ascii')
  buffer.writeUInt32LE(36 + frames * 4, 4)
  buffer.write('WAVE', 8, 'ascii')
  buffer.write('fmt ', 12, 'ascii')
  buffer.writeUInt32LE(16, 16)
  buffer.writeUInt16LE(1, 20) // PCM
  buffer.writeUInt16LE(2, 22) // stereo
  buffer.writeUInt32LE(SR, 24)
  buffer.writeUInt32LE(SR * 4, 28)
  buffer.writeUInt16LE(4, 32)
  buffer.writeUInt16LE(16, 34)
  buffer.write('data', 36, 'ascii')
  buffer.writeUInt32LE(frames * 4, 40)

  let peak = 0
  for (let i = 0; i < frames; i++) peak = Math.max(peak, Math.abs(left[i]), Math.abs(right[i]))
  const normalize = peak > 0.98 ? 0.98 / peak : 1

  for (let i = 0; i < frames; i++) {
    const l = Math.max(-1, Math.min(1, left[i] * normalize))
    const r = Math.max(-1, Math.min(1, right[i] * normalize))
    buffer.writeInt16LE(Math.round(l * 32767), 44 + i * 4)
    buffer.writeInt16LE(Math.round(r * 32767), 46 + i * 4)
  }
  return buffer
}

const TRACKS = [
  { file: 'house-124.wav', bpm: 124, seconds: 32, seed: 124, bassNote: 55 },
  { file: 'techno-128.wav', bpm: 128, seconds: 32, seed: 128, bassNote: 49 },
  { file: 'deep-122.wav', bpm: 122, seconds: 32, seed: 122, bassNote: 58 },
  // Starts 250 ms before the first beat's grid line to exercise offset detection,
  // and drops the hats so the detector cannot lean on them.
  { file: 'offset-100.wav', bpm: 100, seconds: 24, seed: 100, bassNote: 65, offsetSec: 0.25, hats: false }
]

await mkdir(OUT_DIR, { recursive: true })
for (const track of TRACKS) {
  const wav = encodeWav(renderTrack(track))
  const target = path.join(OUT_DIR, track.file)
  await writeFile(target, wav)
  console.log(`${track.file}  ${track.bpm} BPM  ${(wav.length / 1024 / 1024).toFixed(1)} MB`)
}
console.log(`\nWrote ${TRACKS.length} fixtures to ${OUT_DIR}`)
