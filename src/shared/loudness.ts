/**
 * Integrated loudness per ITU-R BS.1770-4 (the algorithm behind LUFS), plus the
 * peak and a gain suggestion for level matching.
 *
 * Psytrance and hard trance are mastered hot and heavily limited. Two tracks
 * that look identical on a peak meter can sit 6 dB apart in perceived level, so
 * mixing by peak means constantly riding the trims. Measuring integrated
 * loudness gives a per-track gain that actually levels the crate.
 *
 * K-weighting coefficients are the standard 48 kHz set; every channel is
 * resampled to 48 kHz first rather than deriving filters per sample rate, which
 * keeps this to one pair of biquads and matches the reference filter exactly.
 */

const REFERENCE_RATE = 48_000
const BLOCK_SEC = 0.4
const HOP_SEC = 0.1
const ABSOLUTE_GATE_LUFS = -70
const RELATIVE_GATE_LU = -10

/** Stage 1: high shelf. Stage 2: high pass. Coefficients are for 48 kHz. */
const SHELF_B = [1.53512485958697, -2.69169618940638, 1.19839281085285]
const SHELF_A = [1, -1.69065929318241, 0.73248077421585]
const HIGHPASS_B = [1, -2, 1]
const HIGHPASS_A = [1, -1.99004745483398, 0.99007225036621]

export interface LoudnessReport {
  /** Integrated loudness in LUFS, -Infinity for silence. */
  integratedLufs: number
  /** Highest sample value in dBFS (not oversampled, so not true-peak). */
  peakDb: number
  /** Peak minus integrated loudness: low values indicate a crushed master. */
  peakToLoudnessDb: number
  /** Suggested gain to hit the target, clamped to ±12 dB. */
  gainDb: number
  targetLufs: number
}

function toDb(value: number): number {
  return value > 0 ? 20 * Math.log10(value) : -Infinity
}

export function integratedLoudness(channels: Float32Array[], sampleRate: number): number {
  if (channels.length === 0) return -Infinity
  if (!Number.isFinite(sampleRate) || sampleRate <= 0) return -Infinity
  const ratio = sampleRate / REFERENCE_RATE
  const length = Math.floor(Math.min(...channels.map((channel) => channel.length)) / ratio)
  const blockLength = Math.round(BLOCK_SEC * REFERENCE_RATE)
  const hopLength = Math.round(HOP_SEC * REFERENCE_RATE)
  if (length < blockLength) return -Infinity

  // Stream the resampler and both K-weighting filters into a 400 ms ring.
  // Full-length resampled/filtered copies used hundreds of MB per song.
  const blockPowers = new Float64Array(Math.floor((length - blockLength) / hopLength) + 1)
  for (const channel of channels) {
    const ring = new Float64Array(blockLength)
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0
    let h1 = 0, h2 = 0, z1 = 0, z2 = 0
    let sum = 0, block = 0
    for (let i = 0; i < length; i++) {
      const pos = i * ratio
      const index = Math.floor(pos)
      const a = channel[index] ?? 0
      const b = channel[index + 1] ?? a
      const x = Math.fround(a + (b - a) * (pos - index))
      const y = SHELF_B[0] * x + SHELF_B[1] * x1 + SHELF_B[2] * x2 - SHELF_A[1] * y1 - SHELF_A[2] * y2
      x2 = x1; x1 = x; y2 = y1; y1 = y
      const h = Math.fround(y)
      const z = HIGHPASS_B[0] * h + HIGHPASS_B[1] * h1 + HIGHPASS_B[2] * h2 - HIGHPASS_A[1] * z1 - HIGHPASS_A[2] * z2
      h2 = h1; h1 = h; z2 = z1; z1 = z
      const weighted = Math.fround(z)
      const square = weighted * weighted
      const slot = i % blockLength
      sum += square - ring[slot]
      ring[slot] = square
      if (i + 1 >= blockLength && (i + 1 - blockLength) % hopLength === 0) blockPowers[block++] += Math.max(0, sum) / blockLength
    }
  }
  if (blockPowers.length === 0) return -Infinity

  const toLufs = (power: number): number =>
    power > 0 ? -0.691 + 10 * Math.log10(power) : -Infinity

  // Absolute gate.
  const aboveAbsolute = blockPowers.filter((power) => toLufs(power) > ABSOLUTE_GATE_LUFS)
  if (aboveAbsolute.length === 0) return -Infinity

  // Relative gate, measured from the power mean of the absolute-gated blocks.
  const meanPower = aboveAbsolute.reduce((sum, power) => sum + power, 0) / aboveAbsolute.length
  const relativeGate = toLufs(meanPower) + RELATIVE_GATE_LU
  const gated = aboveAbsolute.filter((power) => toLufs(power) > relativeGate)
  if (gated.length === 0) return -Infinity

  return toLufs(gated.reduce((sum, power) => sum + power, 0) / gated.length)
}

export function analyzeLoudness(
  channels: Float32Array[],
  sampleRate: number,
  targetLufs = -10
): LoudnessReport {
  const integrated = integratedLoudness(channels, sampleRate)
  let peak = 0
  for (const channel of channels) {
    for (let i = 0; i < channel.length; i++) {
      const magnitude = Math.abs(channel[i])
      if (magnitude > peak) peak = magnitude
    }
  }
  const peakDb = toDb(peak)
  const gain = Number.isFinite(integrated)
    ? Math.max(-12, Math.min(12, targetLufs - integrated))
    : 0
  return {
    integratedLufs: Number.isFinite(integrated) ? Math.round(integrated * 10) / 10 : -Infinity,
    peakDb: Number.isFinite(peakDb) ? Math.round(peakDb * 10) / 10 : -Infinity,
    peakToLoudnessDb: Number.isFinite(peakDb) && Number.isFinite(integrated)
      ? Math.round((peakDb - integrated) * 10) / 10
      : -Infinity,
    gainDb: Math.round(gain * 10) / 10,
    targetLufs
  }
}

/** Clamped gain in dB, for callers that already have an integrated value. */
export function gainForTarget(integrated: number, targetLufs = -10, limitDb = 12): number {
  if (!Number.isFinite(integrated)) return 0
  return Math.max(-limitDb, Math.min(limitDb, targetLufs - integrated))
}

export function dbToLinear(db: number): number {
  return 10 ** (db / 20)
}
