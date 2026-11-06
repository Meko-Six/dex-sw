import { analyzePower } from '../../shared/power'
import type { BeatGrid } from '../../shared/grid'
import { detectBeats } from '../../shared/detector'
import { computePeaks, toMono } from '../../shared/dsp'
import { chromaVector, estimateKeyFromChroma } from '../../shared/key'
import { buildWaveformLevels } from '../../shared/waveform-levels'

/**
 * Off-thread analysis: beat grid, waveform peaks, musical key and intensity. Channels are transferred in,
 * so the decoded AudioBuffer (which the deck keeps) is not touched.
 */
const scope = self as unknown as {
  onmessage: ((event: MessageEvent) => void) | null
  postMessage(message: unknown): void
}

interface Request {
  id: number
  channels: Float32Array[]
  sampleRate: number
  /** The input tap only needs the tempo; skipping peaks and key halves the work. */
  peaks?: boolean
  /** Loaded-deck waveform, optionally backfilling a missing intensity cache. */
  kind?: 'analysis' | 'levels'
  grid?: BeatGrid | null
  power?: boolean
}

scope.onmessage = (event: MessageEvent) => {
  const { id, channels, sampleRate, peaks: wantPeaks = true, kind = 'analysis' } = event.data as Request
  const request = event.data as Request
  if (kind === 'levels') {
    try {
      const levels = buildWaveformLevels(channels, sampleRate)
      ;(scope.postMessage as (message: unknown, transfer: Transferable[]) => void)(
        { id, levels, power: request.power ? analyzePower(channels, sampleRate, request.grid ?? null) : undefined },
        levels.levels.flatMap((level) => [level.data.buffer as ArrayBuffer, ...(level.bands ? [level.bands.buffer as ArrayBuffer] : [])])
      )
    } catch (error) {
      scope.postMessage({ id, error: error instanceof Error ? error.message : String(error) })
    } finally { releaseChannels(channels) }
    return
  }
  try {
    const mono = toMono(channels)
    const detection = detectBeats(mono, sampleRate)
    const peaks = wantPeaks ? Array.from(computePeaks(channels, 4000).bins) : []
    scope.postMessage({
      id, detection, peaks,
      key: wantPeaks ? detectKey(mono, sampleRate) : null,
      power: wantPeaks ? analyzePower(channels, sampleRate, detection) : undefined
    })
  } catch (error) {
    scope.postMessage({ id, error: error instanceof Error ? error.message : String(error) })
  } finally { releaseChannels(channels) }
}

/** These transferred arrays are worker-owned and dead after the response.
 * Release their backing stores without waiting for an idle worker's next GC. */
function releaseChannels(channels: Float32Array[]): void {
  for (const channel of channels) {
    const buffer = channel.buffer as ArrayBuffer & { transfer?: (length: number) => ArrayBuffer }
    buffer.transfer?.(0)
  }
}

/** Null when there is too little pitched material to say anything (silence, a short clip). */
function detectKey(mono: Float32Array, sampleRate: number): { key: string; camelot: string; confidence: number } | null {
  const chroma = chromaVector(mono, sampleRate)
  if (!chroma.some((value) => value > 0)) return null
  const estimate = estimateKeyFromChroma(chroma)
  return { key: estimate.key, camelot: estimate.camelot, confidence: estimate.confidence }
}
