import { ISO_HIGH_HZ, ISO_LOW_HZ } from './isolator'

/** Display crossovers match the mixer's LOW/MID/HIGH divisions. These are
 * analysis filters only; the waveform never changes with the live EQ. */
function filter(type: 'lowpass' | 'highpass', hz: number, sampleRate: number): (x: number) => number {
  const w = 2 * Math.PI * Math.min(hz, sampleRate * 0.45) / sampleRate
  const cosine = Math.cos(w), alpha = Math.sin(w) / Math.SQRT2
  const a0 = 1 + alpha
  const b0 = (type === 'lowpass' ? 1 - cosine : 1 + cosine) / 2 / a0
  const b1 = (type === 'lowpass' ? 1 - cosine : -(1 + cosine)) / a0
  const b2 = b0, a1 = -2 * cosine / a0, a2 = (1 - alpha) / a0
  let z1 = 0, z2 = 0
  return (x) => {
    const y = b0 * x + z1
    z1 = b1 * x - a1 * y + z2
    z2 = b2 * x - a2 * y
    return y
  }
}

/** Per-bin band RMS envelopes, RGBA8: LOW, MID, HIGH, unused.
 * Channels are measured separately then combined by maximum, never summed:
 * stereo phase cancellation cannot erase a bass line. No full-length filtered
 * copies are allocated. The caller pools these envelopes into its pyramid. */
export function buildBandEnvelopes(channels: Float32Array[], sampleRate: number, binSize: number, count: number): Uint8Array {
  const data = new Uint8Array(count * 4)
  for (const channel of channels) {
    const lowpass = filter('lowpass', ISO_LOW_HZ, sampleRate)
    const highpass = filter('highpass', ISO_HIGH_HZ, sampleRate)
    const midHighpass = filter('highpass', ISO_LOW_HZ, sampleRate)
    const midLowpass = filter('lowpass', ISO_HIGH_HZ, sampleRate)
    for (let bin = 0; bin < count; bin++) {
      let low = 0, mid = 0, high = 0
      const start = bin * binSize
      const stop = Math.min(channel.length, (bin + 1) * binSize)
      for (let i = start; i < stop; i++) {
        const x = Number.isFinite(channel[i]) ? channel[i] : 0
        const l = lowpass(x), m = midLowpass(midHighpass(x)), h = highpass(x)
        low += l * l; mid += m * m; high += h * h
      }
      const n = Math.max(1, stop - start)
      low = Math.sqrt(low / n); mid = Math.sqrt(mid / n); high = Math.sqrt(high / n)
      const offset = bin * 4
      data[offset] = Math.max(data[offset], Math.round(Math.min(1, low) * 255))
      data[offset + 1] = Math.max(data[offset + 1], Math.round(Math.min(1, mid) * 255))
      data[offset + 2] = Math.max(data[offset + 2], Math.round(Math.min(1, high) * 255))
    }
  }
  return data
}

/** Display emphasis for bass body, mid detail and treble transients. Fixed
 * across both decks; no per-track or played/unplayed color changes. */
export const BAND_GAINS = [1.6, 1.5, 1.5] as const
export const BAND_COLOURS = [[46, 115, 235], [211, 145, 49], [255, 249, 226]] as const
export const BAND_GAMMA = 0.8
export function bandHeight(value: number, band: number): number {
  return Math.min(1, value * BAND_GAINS[band]) ** BAND_GAMMA
}
