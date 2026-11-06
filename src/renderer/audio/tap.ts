import type { BeatGrid } from '../../shared/grid'

/**
 * Input tap: listens to an audio input device and measures its tempo.
 *
 * This is the loopback path for material that cannot be loaded as a file — most
 * usefully a virtual device such as BlackHole carrying another app's output. It
 * is deliberately analysis-only: the tap never reaches the master or cue buses,
 * so it cannot mix or alter what it hears, and nothing is recorded or uploaded.
 *
 * Capture runs through a worklet that posts mono blocks, a rolling 8 s window is
 * handed to the same detector the library uses, and the last few estimates are
 * median-filtered so the readout does not flicker.
 */

const RECORDER_SOURCE = `
class DexTap extends AudioWorkletProcessor {
  constructor() {
    super()
    this.blocks = []
    this.frames = 0
    this.port.onmessage = (event) => {
      if (event.data && event.data.command === 'flush') this.flush()
    }
  }
  flush() {
    if (this.frames === 0) return
    const merged = new Float32Array(this.frames)
    let offset = 0
    for (const block of this.blocks) {
      merged.set(block, offset)
      offset += block.length
    }
    this.blocks = []
    this.frames = 0
    this.port.postMessage({ chunk: merged }, [merged.buffer])
  }
  process(inputs) {
    const input = inputs[0]
    if (input && input.length > 0) {
      const length = input[0].length
      const mono = new Float32Array(length)
      for (let channel = 0; channel < input.length; channel++) {
        const data = input[channel]
        for (let i = 0; i < length; i++) mono[i] += data[i] / input.length
      }
      this.blocks.push(mono)
      this.frames += length
      if (this.frames >= 4096) this.flush()
    }
    return true
  }
}
registerProcessor('dex-tap', DexTap)
`

export const TAP_WINDOW_SEC = 8
const TAP_STRIDE_SEC = 2.5
const RING_SEC = 9

export interface TapDevice {
  id: string
  label: string
  /** Looks like a virtual loopback device (BlackHole, Loopback, VB-Cable…). */
  loopback: boolean
}

export interface TapSnapshot {
  status: 'idle' | 'starting' | 'listening' | 'error'
  devices: TapDevice[]
  deviceId: string | null
  deviceLabel: string | null
  levelDb: number
  bpm: number | null
  confidence: number
  error: string | null
  /** Number of analysis windows that fed the current reading. */
  windows: number
}

const LOOPBACK_HINTS = ['blackhole', 'loopback', 'soundflower', 'vb-cable', 'stereo mix', 'virtual', 'aggregate']

function isLoopbackLabel(label: string): boolean {
  const lower = label.toLowerCase()
  return LOOPBACK_HINTS.some((hint) => lower.includes(hint))
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]
}

export class InputTap {
  private generation = 0
  private listeners = new Set<() => void>()
  private snapshot: TapSnapshot = {
    status: 'idle',
    devices: [],
    deviceId: null,
    deviceLabel: null,
    levelDb: -60,
    bpm: null,
    confidence: 0,
    error: null,
    windows: 0
  }

  private context: AudioContext | null = null
  private stream: MediaStream | null = null
  private source: MediaStreamAudioSourceNode | null = null
  private analyser: AnalyserNode | null = null
  private silence: GainNode | null = null
  private worklet: AudioWorkletNode | null = null
  private worker: Worker | null = null
  private meterTimer: number | null = null
  private levelBuffer: Float32Array<ArrayBuffer> | null = null
  private chunks: Float32Array[] = []
  private buffered = 0
  private sinceAnalysis = 0
  private readings: number[] = []
  private confidences: number[] = []
  private requestId = 0
  private externalStop: (() => void) | null = null

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  getSnapshot = (): TapSnapshot => this.snapshot

  private emit(patch: Partial<TapSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch }
    for (const listener of this.listeners) listener()
  }

  async refreshDevices(): Promise<TapDevice[]> {
    try {
      const all = await navigator.mediaDevices.enumerateDevices()
      const devices = all
        .filter((device) => device.kind === 'audioinput')
        .map((device, index) => ({
          id: device.deviceId,
          label: device.label || `Audio input ${index + 1}`,
          loopback: isLoopbackLabel(device.label)
        }))
        .sort((a, b) => Number(b.loopback) - Number(a.loopback))
      this.emit({ devices })
      return devices
    } catch {
      this.emit({ devices: [] })
      return []
    }
  }

  /**
   * Start listening. `stream` is only used by the development test signal;
   * production calls pass a device id (or nothing for the system default).
   */
  async start(deviceId?: string | null, stream?: MediaStream, stopExternal?: () => void): Promise<void> {
    if (this.snapshot.status === 'listening' || this.snapshot.status === 'starting') return
    const generation = ++this.generation
    this.emit({ status: 'starting', error: null, bpm: null, confidence: 0, windows: 0 })
    this.readings = []
    this.confidences = []
    try {
      let media = stream ?? null
      if (!media) {
        media = await navigator.mediaDevices.getUserMedia({
          audio: {
            ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
            echoCancellation: false,
            noiseSuppression: false,
            autoGainControl: false,
            channelCount: 2
          },
          video: false
        })
      }
      if (generation !== this.generation) {
        for (const track of media.getTracks()) track.stop()
        stopExternal?.()
        return
      }
      this.stream = media
      this.externalStop = stopExternal ?? null

      const context = new AudioContext({ latencyHint: 'interactive' })
      this.context = context
      await context.resume()
      if (generation !== this.generation) return

      const url = URL.createObjectURL(new Blob([RECORDER_SOURCE], { type: 'application/javascript' }))
      try {
        await context.audioWorklet.addModule(url)
      } finally {
        URL.revokeObjectURL(url)
      }

      if (generation !== this.generation) return
      const source = context.createMediaStreamSource(media)
      this.source = source
      const analyser = context.createAnalyser()
      analyser.fftSize = 1024
      analyser.smoothingTimeConstant = 0.3
      this.analyser = analyser
      // Pull the graph without monitoring: the tap must stay out of the mix.
      const silence = context.createGain()
      silence.gain.value = 0
      this.silence = silence
      source.connect(analyser)
      analyser.connect(silence)
      silence.connect(context.destination)

      const worklet = new AudioWorkletNode(context, 'dex-tap', {
        numberOfInputs: 1,
        numberOfOutputs: 0,
        channelCount: 2,
        channelCountMode: 'explicit'
      })
      this.worklet = worklet
      worklet.port.onmessage = (event: MessageEvent) => {
        const chunk = (event.data as { chunk?: Float32Array }).chunk
        if (chunk) this.ingest(chunk)
      }
      source.connect(worklet)

      this.worker = new Worker(new URL('./analysis.worker.ts', import.meta.url), { type: 'module' })
      this.worker.onmessage = (event: MessageEvent) => this.onAnalysis(event)
      this.worker.onerror = () => {
        this.emit({ status: 'error', error: 'The tempo analyser stopped unexpectedly.' })
        void this.stop(true)
      }

      this.levelBuffer = new Float32Array(analyser.fftSize)
      this.chunks = []
      this.buffered = 0
      this.sinceAnalysis = 0
      this.meterTimer = window.setInterval(() => this.readLevel(), 100)

      const track = media.getAudioTracks()[0]
      this.emit({
        status: 'listening',
        deviceId: deviceId ?? null,
        deviceLabel: track?.label ?? this.snapshot.deviceLabel ?? 'System input',
        levelDb: -60
      })
      await this.refreshDevices()
    } catch (error) {
      if (generation !== this.generation) return
      const message = describeError(error)
      this.emit({ status: 'error', error: message, levelDb: -60 })
      await this.stop(true)
    }
  }

  private readLevel(): void {
    const analyser = this.analyser
    const buffer = this.levelBuffer
    if (!analyser || !buffer) return
    analyser.getFloatTimeDomainData(buffer)
    let sum = 0
    for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i]
    const rms = Math.sqrt(sum / buffer.length)
    const db = 20 * Math.log10(Math.max(1e-6, rms))
    this.emit({ levelDb: Math.max(-60, Math.min(0, db)) })
  }

  private ingest(chunk: Float32Array): void {
    this.chunks.push(chunk)
    this.buffered += chunk.length
    const sampleRate = this.context?.sampleRate ?? 48000
    const ringFrames = RING_SEC * sampleRate
    while (this.buffered - this.chunks[0].length >= ringFrames) {
      this.buffered -= this.chunks[0].length
      this.chunks.shift()
    }
    this.sinceAnalysis += chunk.length
    if (this.sinceAnalysis < TAP_STRIDE_SEC * sampleRate) return
    this.sinceAnalysis = 0
    if (this.buffered < TAP_WINDOW_SEC * sampleRate) return

    const frames = Math.floor(TAP_WINDOW_SEC * sampleRate)
    const window = new Float32Array(frames)
    let offset = frames
    for (let i = this.chunks.length - 1; i >= 0 && offset > 0; i--) {
      const data = this.chunks[i]
      const take = Math.min(data.length, offset)
      window.set(data.subarray(data.length - take), offset - take)
      offset -= take
    }
    const worker = this.worker
    if (!worker) return
    const id = ++this.requestId
    worker.postMessage({ id, channels: [window], sampleRate, peaks: false }, [window.buffer])
  }

  private onAnalysis(event: MessageEvent): void {
    const data = event.data as {
      detection?: { bpm: number; offsetMs: number; confidence: number }
      error?: string
    }
    if (data.error) {
      this.emit({ error: data.error })
      return
    }
    const detection = data.detection
    if (!detection || detection.confidence < 0.15) {
      // Too little rhythmic content (silence, speech, a fading mix).
      this.emit({ bpm: null, confidence: 0, windows: 0 })
      this.readings = []
      this.confidences = []
      return
    }
    this.readings.push(detection.bpm)
    this.confidences.push(detection.confidence)
    if (this.readings.length > 5) this.readings.shift()
    if (this.confidences.length > 5) this.confidences.shift()
    this.emit({
      bpm: median(this.readings),
      confidence: this.confidences.reduce((sum, value) => sum + value, 0) / this.confidences.length,
      windows: this.readings.length,
      error: null
    })
  }

  /** Stop capturing. `keepStatus` preserves an error for the UI. */
  async stop(keepStatus = false): Promise<void> {
    const generation = ++this.generation
    if (this.meterTimer !== null) window.clearInterval(this.meterTimer)
    this.meterTimer = null
    if (this.worklet) {
      try {
        this.worklet.port.postMessage({ command: 'flush' })
      } catch {
        /* already gone */
      }
      this.worklet.port.onmessage = null
      this.worklet.disconnect()
    }
    this.worklet = null
    this.source?.disconnect()
    this.source = null
    this.analyser?.disconnect()
    this.analyser = null
    this.levelBuffer = null
    this.silence?.disconnect()
    this.silence = null
    for (const track of this.stream?.getTracks() ?? []) track.stop()
    this.stream = null
    this.worker?.terminate()
    this.worker = null
    this.externalStop?.()
    this.externalStop = null
    const context = this.context
    this.context = null
    if (context && context.state !== 'closed') await context.close().catch(() => undefined)
    if (generation !== this.generation) return
    this.chunks = []
    this.buffered = 0
    this.sinceAnalysis = 0
    this.readings = []
    this.confidences = []
    this.emit({
      status: keepStatus ? this.snapshot.status : 'idle',
      levelDb: -60,
      bpm: null,
      confidence: 0,
      windows: 0,
      deviceLabel: keepStatus ? this.snapshot.deviceLabel : null
    })
  }
}

function describeError(error: unknown): string {
  if (error instanceof DOMException) {
    if (error.name === 'NotAllowedError') return 'Microphone access was denied. Allow it in System Settings → Privacy & Security → Microphone, then try again.'
    if (error.name === 'NotFoundError') return 'No audio input device was found. Install a loopback device (BlackHole 2ch) or connect an interface.'
    if (error.name === 'OverconstrainedError') return 'That input device is no longer available. Pick another one.'
    if (error.name === 'NotReadableError') return 'The input device is busy in another app.'
  }
  return error instanceof Error ? error.message : String(error)
}

/** Compute the tempo ratio that would match a deck to a detected BPM. */
export function tapTempoRatio(bpm: number, grid: BeatGrid | null): number | null {
  if (!grid || bpm <= 0) return null
  return Math.max(0.84, Math.min(1.16, bpm / grid.bpm))
}

export const tap = new InputTap()

if (import.meta.env.DEV && typeof window !== 'undefined') {
  ;(window as unknown as { __tap?: InputTap }).__tap = tap
}
