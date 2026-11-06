import { describe, expect, it } from 'vitest'
import { detectBeats } from '../src/shared/detector'
import { renderPattern, type PatternStyle } from '../src/shared/synth'

const SR = 44100

function offsetErrorMs(offsetMs: number, bpm: number): number {
  const period = 60000 / bpm
  const wrapped = ((offsetMs % period) + period) % period
  return Math.min(wrapped, period - wrapped)
}

describe('beat detection', () => {
  const cases: Array<{ bpm: number; style: PatternStyle }> = [
    { bpm: 128, style: 'house' },
    { bpm: 124, style: 'house' },
    { bpm: 100, style: 'pop' },
    { bpm: 140, style: 'breakbeat' }
  ]

  for (const { bpm, style } of cases) {
    it(`locks ${bpm} BPM ${style}`, () => {
      const audio = renderPattern({ bpm, seconds: 24, sampleRate: SR, style, startOffsetMs: 137 })
      const result = detectBeats(audio, SR)
      expect(Math.abs(result.bpm - bpm)).toBeLessThan(0.6)
      expect(offsetErrorMs(result.offsetMs - 137, result.bpm)).toBeLessThan(50)
      expect(result.confidence).toBeGreaterThan(0.4)
    })
  }

  it('resolves drum & bass to a consistent octave', () => {
    const audio = renderPattern({ bpm: 174, seconds: 24, sampleRate: SR, style: 'dnb' })
    const result = detectBeats(audio, SR)
    const near = (target: number) => Math.abs(result.bpm - target) < 1.5
    expect(near(174) || near(87)).toBe(true)
    expect(result.confidence).toBeGreaterThan(0.3)
  })

  it('reports low confidence for silence', () => {
    const audio = renderPattern({ bpm: 128, seconds: 12, sampleRate: SR, style: 'silence' })
    const result = detectBeats(audio, SR)
    expect(result.confidence).toBeLessThan(0.25)
  })

  it('reports low confidence for noise', () => {
    const audio = new Float32Array(SR * 12)
    for (let i = 0; i < audio.length; i++) audio[i] = (Math.random() * 2 - 1) * 0.05
    const result = detectBeats(audio, SR)
    expect(result.confidence).toBeLessThan(0.5)
  })

  it('is stable when the grid offset is shifted', () => {
    const a = detectBeats(renderPattern({ bpm: 126, seconds: 20, sampleRate: SR, style: 'house', startOffsetMs: 0 }), SR)
    const b = detectBeats(renderPattern({ bpm: 126, seconds: 20, sampleRate: SR, style: 'house', startOffsetMs: 240 }), SR)
    expect(Math.abs(a.bpm - b.bpm)).toBeLessThan(0.2)
    const delta = offsetErrorMs(b.offsetMs - a.offsetMs - 240, a.bpm)
    expect(delta).toBeLessThan(50)
  })
})
