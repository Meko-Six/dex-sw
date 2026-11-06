import { buildBandEnvelopes } from './waveform-bands'

/**
 * Multi-resolution waveform data for the screen.
 *
 * The library keeps 4,000 min/max pairs per track, which is plenty for the
 * overview but only ~10 per second, so a zoomed-in lane stretched each one
 * into a 20–30 pt block. On load the deck builds a pyramid instead: a base
 * level at BASE_BIN samples per bin (~1,400 per second at 44.1 kHz), then
 * each level LEVEL_FACTOR times coarser, so any zoom can pick a level with a
 * few bins per screen pixel.
 *
 * Every bin is four bytes, laid out to upload straight into an RGBA8 texture:
 * min and max peak (128 is silence), RMS (0 … 255), and a spare byte.
 * A second RGBA8 texture holds independent LOW/MID/HIGH RMS envelopes.
 */

export const BASE_BIN = 32
export const LEVEL_FACTOR = 4
/** Stop adding levels once one is this short: coarser than any screen needs. */
const TOP_LEVEL_BINS = 512

export interface WaveformLevel {
  /** Source samples per bin. Fractional only for levels made from library peaks. */
  binSize: number
  count: number
  /** RGBA per bin: min, max, rms, 255. */
  data: Uint8Array
  /** Optional LOW/MID/HIGH RMS envelopes; absent in coarse library peaks. */
  bands?: Uint8Array
}

export interface WaveformLevels {
  sampleRate: number
  totalSamples: number
  /** Finest first. */
  levels: WaveformLevel[]
}

const encodePeak = (value: number): number => Math.round(Math.max(-1, Math.min(1, value)) * 127) + 128
export const decodePeak = (byte: number): number => (byte - 128) / 127

export function buildWaveformLevels(channels: Float32Array[], sampleRate: number): WaveformLevels {
  const totalSamples = channels.reduce((max, ch) => Math.max(max, ch.length), 0)
  const count = Math.max(1, Math.ceil(totalSamples / BASE_BIN))
  const data = new Uint8Array(count * 4)
  for (let bin = 0; bin < count; bin++) {
    const start = bin * BASE_BIN
    const end = Math.min(totalSamples, start + BASE_BIN)
    let min = 0
    let max = 0
    let squares = 0
    let n = 0
    for (let c = 0; c < channels.length; c++) {
      const channel = channels[c]
      const stop = Math.min(end, channel.length)
      for (let i = start; i < stop; i++) {
        const v = channel[i]
        if (v < min) min = v
        if (v > max) max = v
        squares += v * v
      }
      n += Math.max(0, stop - start)
    }
    const o = bin * 4
    data[o] = encodePeak(min)
    data[o + 1] = encodePeak(max)
    data[o + 2] = Math.round(Math.min(1, n > 0 ? Math.sqrt(squares / n) : 0) * 255)
    data[o + 3] = 255
  }
  return { sampleRate, totalSamples, levels: pyramid({ binSize: BASE_BIN, count, data, bands: buildBandEnvelopes(channels, sampleRate, BASE_BIN, count) }) }
}

/**
 * Stand-in levels from the library's coarse peaks, so a lane has something to
 * draw while the full pyramid is built. There is no RMS in them.
 */
export function levelsFromPeaks(peaks: Int8Array, durationSec: number, sampleRate = 44100): WaveformLevels {
  const count = Math.max(1, Math.floor(peaks.length / 2))
  const totalSamples = Math.max(1, Math.round(durationSec * sampleRate))
  const data = new Uint8Array(count * 4)
  for (let bin = 0; bin < count; bin++) {
    data[bin * 4] = (peaks[bin * 2] ?? 0) + 128
    data[bin * 4 + 1] = (peaks[bin * 2 + 1] ?? 0) + 128
    data[bin * 4 + 3] = 255
  }
  return { sampleRate, totalSamples, levels: [{ binSize: totalSamples / count, count, data }] }
}

function pyramid(base: WaveformLevel): WaveformLevel[] {
  const levels = [base]
  let level = base
  while (level.count > TOP_LEVEL_BINS) {
    const count = Math.ceil(level.count / LEVEL_FACTOR)
    const data = new Uint8Array(count * 4)
    const bands = level.bands ? new Uint8Array(count * 4) : undefined
    for (let bin = 0; bin < count; bin++) {
      let min = 255
      let max = 0
      let squares = 0
      let n = 0
      const bandSquares = [0, 0, 0]
      for (let k = bin * LEVEL_FACTOR; k < Math.min(level.count, (bin + 1) * LEVEL_FACTOR); k++) {
        min = Math.min(min, level.data[k * 4])
        max = Math.max(max, level.data[k * 4 + 1])
        if (bands && level.bands) for (let band = 0; band < 3; band++) {
          bandSquares[band] += level.bands[k * 4 + band] ** 2
        }
        squares += level.data[k * 4 + 2] ** 2
        n++
      }
      if (bands) for (let band = 0; band < 3; band++) bands[bin * 4 + band] = Math.round(Math.sqrt(bandSquares[band] / n))
      data[bin * 4] = min
      data[bin * 4 + 1] = max
      data[bin * 4 + 2] = Math.round(Math.sqrt(squares / n))
      data[bin * 4 + 3] = 255
    }
    level = { binSize: level.binSize * LEVEL_FACTOR, count, data, bands }
    levels.push(level)
  }
  return levels
}

/** The coarsest level that still has at least one bin per pixel. */
export function pickLevel(levels: WaveformLevels, samplesPerPixel: number): WaveformLevel {
  let chosen = levels.levels[0]
  for (const level of levels.levels) if (level.binSize <= samplesPerPixel) chosen = level
  return chosen
}

/**
 * Whole-pixel scrolling: the view starts on a pixel column fixed in track
 * time, so each column always covers the same samples and the waveform
 * slides without its bars flickering as they cross pixel boundaries.
 */
export function snapView(startSec: number, spanSec: number, pixels: number, sampleRate: number): {
  startCol: number
  samplesPerPixel: number
  startSec: number
} {
  const samplesPerPixel = (spanSec * sampleRate) / Math.max(1, pixels)
  const startCol = Math.floor((startSec * sampleRate) / samplesPerPixel)
  return { startCol, samplesPerPixel, startSec: (startCol * samplesPerPixel) / sampleRate }
}
