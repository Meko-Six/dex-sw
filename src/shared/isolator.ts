/**
 * Three-band DJ isolator maths, shared by the audio engine and the tests.
 *
 * The signal is split by Linkwitz-Riley 24 dB/oct crossovers (two cascaded
 * Butterworth biquads each) into LOW, MID and HIGH, each band gets its own
 * gain, and the bands are summed. Unlike shelving EQ, a band at gain 0 is
 * really gone and leaves the other two untouched.
 *
 * LR4 low-pass + high-pass at one frequency sums to a second-order all-pass,
 * not to a wire. So MID + HIGH come out with the high crossover's all-pass on
 * them, and the LOW band is given the same all-pass; with that, all three at
 * unity sum to a flat magnitude.
 */

/** LOW / MID crossover. Kick fundamentals and bass sit below it. */
export const ISO_LOW_HZ = 220
/** MID / HIGH crossover. Hats, air and vocal presence sit above it. */
export const ISO_HIGH_HZ = 3500

/** Linear Q of a second-order Butterworth section. */
export const BUTTERWORTH_Q = Math.SQRT1_2

export type IsoBiquadType = 'lowpass' | 'highpass' | 'allpass'

export interface IsoBiquad {
  type: IsoBiquadType
  /** Centre / corner frequency in Hz. */
  frequency: number
  /** Linear Q. Use webAudioQ() when setting a BiquadFilterNode. */
  q: number
}

export interface IsolatorSections {
  /** Low-pass at the low crossover, then the all-pass that phase-matches LOW. */
  low: IsoBiquad[]
  /** High-pass at the low crossover, shared by MID and HIGH. */
  rest: IsoBiquad[]
  /** Low-pass at the high crossover, after `rest`. */
  mid: IsoBiquad[]
  /** High-pass at the high crossover, after `rest`. */
  high: IsoBiquad[]
}

function lr4(type: 'lowpass' | 'highpass', frequency: number): IsoBiquad[] {
  return [
    { type, frequency, q: BUTTERWORTH_Q },
    { type, frequency, q: BUTTERWORTH_Q }
  ]
}

export function isolatorSections(lowHz = ISO_LOW_HZ, highHz = ISO_HIGH_HZ): IsolatorSections {
  return {
    low: [...lr4('lowpass', lowHz), { type: 'allpass', frequency: highHz, q: BUTTERWORTH_Q }],
    rest: lr4('highpass', lowHz),
    mid: lr4('lowpass', highHz),
    high: lr4('highpass', highHz)
  }
}

/**
 * The value to put in BiquadFilterNode.Q. Web Audio reads lowpass/highpass Q
 * in dB (a resonance), but allpass Q linearly. Passing 0.707 to a lowpass
 * gives Q ≈ 1.08 per section and a ~+7.5 dB bump at an LR4 crossover.
 */
export function webAudioQ(section: IsoBiquad): number {
  return section.type === 'allpass' ? section.q : 20 * Math.log10(section.q)
}

export type Complex = [re: number, im: number]

/**
 * Complex response of one section at `hz`, using the Web Audio spec's biquad
 * formulas (RBJ cookbook, bilinear transform). `q` is linear here.
 */
export function biquadResponse(section: IsoBiquad, hz: number, sampleRate: number): Complex {
  const w0 = (2 * Math.PI * section.frequency) / sampleRate
  const cos = Math.cos(w0)
  const alpha = Math.sin(w0) / (2 * section.q)
  let b: [number, number, number]
  let a: [number, number, number]
  if (section.type === 'lowpass') {
    b = [(1 - cos) / 2, 1 - cos, (1 - cos) / 2]
    a = [1 + alpha, -2 * cos, 1 - alpha]
  } else if (section.type === 'highpass') {
    b = [(1 + cos) / 2, -(1 + cos), (1 + cos) / 2]
    a = [1 + alpha, -2 * cos, 1 - alpha]
  } else {
    b = [1 - alpha, -2 * cos, 1 + alpha]
    a = [1 + alpha, -2 * cos, 1 - alpha]
  }
  // H(z) at z = e^{jω}: Σ c_k e^{-jkω}.
  const w = (2 * Math.PI * hz) / sampleRate
  const poly = (c: number[]): Complex => [
    c[0] + c[1] * Math.cos(w) + c[2] * Math.cos(2 * w),
    -(c[1] * Math.sin(w) + c[2] * Math.sin(2 * w))
  ]
  const [nr, ni] = poly(b)
  const [dr, di] = poly(a)
  const d = dr * dr + di * di
  return [(nr * dr + ni * di) / d, (ni * dr - nr * di) / d]
}

function cascade(sections: IsoBiquad[], hz: number, sampleRate: number): Complex {
  let re = 1
  let im = 0
  for (const section of sections) {
    const [r, i] = biquadResponse(section, hz, sampleRate)
    const nextRe = re * r - im * i
    im = re * i + im * r
    re = nextRe
  }
  return [re, im]
}

export interface BandGains {
  low: number
  mid: number
  high: number
}

/** Magnitude in dB of the whole isolator at `hz`, with linear band gains. */
export function isolatorResponseDb(
  gains: BandGains,
  hz: number,
  sampleRate: number,
  sections: IsolatorSections = isolatorSections()
): number {
  const low = cascade(sections.low, hz, sampleRate)
  const mid = cascade([...sections.rest, ...sections.mid], hz, sampleRate)
  const high = cascade([...sections.rest, ...sections.high], hz, sampleRate)
  const re = gains.low * low[0] + gains.mid * mid[0] + gains.high * high[0]
  const im = gains.low * low[1] + gains.mid * mid[1] + gains.high * high[1]
  return 20 * Math.log10(Math.max(1e-12, Math.hypot(re, im)))
}
