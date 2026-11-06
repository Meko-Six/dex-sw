/** Waveform peak envelopes, stored as int8 so the library JSON stays small. */

export interface WaveformPeaks {
  /** Interleaved min/max pairs, one pair per bin, values in -127…127. */
  bins: Int8Array
  /** Samples per bin in the source buffer. */
  binSize: number
}

export function computePeaks(channels: Float32Array[], binCount = 4096): WaveformPeaks {
  const totalSamples = channels.reduce((max, ch) => Math.max(max, ch.length), 0)
  const bins = new Int8Array(binCount * 2)
  if (totalSamples === 0) return { bins, binSize: 1 }
  const binSize = Math.max(1, Math.floor(totalSamples / binCount))

  for (let bin = 0; bin < binCount; bin++) {
    let min = 0
    let max = 0
    const start = bin * binSize
    const end = Math.min(totalSamples, start + binSize)
    for (let i = start; i < end; i++) {
      for (let c = 0; c < channels.length; c++) {
        const v = channels[c][i] ?? 0
        if (v < min) min = v
        if (v > max) max = v
      }
    }
    bins[bin * 2] = Math.round(Math.max(-1, min) * 127)
    bins[bin * 2 + 1] = Math.round(Math.min(1, max) * 127)
  }
  return { bins, binSize }
}

/** Downmix to mono for analysis (keeps a copy so the decode buffer is untouched). */
export function toMono(channels: Float32Array[]): Float32Array {
  if (channels.length === 0) return new Float32Array(0)
  if (channels.length === 1) return Float32Array.from(channels[0])
  const length = channels[0].length
  const out = new Float32Array(length)
  for (let i = 0; i < length; i++) {
    let sum = 0
    for (let c = 0; c < channels.length; c++) sum += channels[c][i] ?? 0
    out[i] = sum / channels.length
  }
  return out
}

/** Root-mean-square level of a windowed frame, used by the meter. */
export function rms(frame: Float32Array): number {
  let sum = 0
  for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i]
  return frame.length > 0 ? Math.sqrt(sum / frame.length) : 0
}

export function quantizePeaks(bins: Int8Array): number[] {
  return Array.from(bins)
}

export function peaksFromNumbers(values: number[]): Int8Array {
  return Int8Array.from(values)
}
