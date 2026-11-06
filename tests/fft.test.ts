import { describe, expect, it } from 'vitest'
import { FFT } from '../src/shared/fft'

describe('FFT', () => {
  it('rejects non power-of-two sizes', () => {
    expect(() => new FFT(100)).toThrow()
  })

  it('puts a pure sine energy in the right bin', () => {
    const n = 64
    const bin = 8
    const re = new Float64Array(n)
    const im = new Float64Array(n)
    for (let i = 0; i < n; i++) re[i] = Math.cos((2 * Math.PI * bin * i) / n)
    new FFT(n).transform(re, im)
    let best = -1
    let bestMag = -1
    for (let k = 1; k < n / 2; k++) {
      const mag = Math.hypot(re[k], im[k])
      if (mag > bestMag) {
        bestMag = mag
        best = k
      }
    }
    expect(best).toBe(bin)
    expect(bestMag).toBeCloseTo(n / 2, 4)
  })

  it('matches a direct DFT on random input', () => {
    const n = 32
    const signal = new Float64Array(n)
    for (let i = 0; i < n; i++) signal[i] = Math.sin(i * 0.7) + Math.cos(i * 0.2) * 0.5
    const re = Float64Array.from(signal)
    const im = new Float64Array(n)
    new FFT(n).transform(re, im)

    for (const k of [0, 3, 9, 16]) {
      let dr = 0
      let di = 0
      for (let i = 0; i < n; i++) {
        const angle = (-2 * Math.PI * k * i) / n
        dr += signal[i] * Math.cos(angle)
        di += signal[i] * Math.sin(angle)
      }
      expect(re[k]).toBeCloseTo(dr, 8)
      expect(im[k]).toBeCloseTo(di, 8)
    }
  })
})
