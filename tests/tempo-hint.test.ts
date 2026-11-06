import { describe, expect, it } from 'vitest'
import { detectBeats, TEMPO_HINTS } from '../src/shared/detector'
import { foldBpm } from '../src/shared/grid'
import { renderPattern } from '../src/shared/synth'

const SR = 44100

describe('foldBpm windows', () => {
  it('keeps the default 70–180 behaviour', () => {
    expect(foldBpm(128)).toBe(128)
    expect(foldBpm(64)).toBe(128)
    expect(foldBpm(256)).toBe(128)
  })

  it('cannot rescue a half-time reading of fast material by default', () => {
    // This is the hazard the tempo hint exists for: 72.5 is already inside
    // 70–180, so the default window leaves it at 72.5.
    expect(foldBpm(72.5)).toBe(72.5)
  })

  it('folds a half-time reading up when given a fast-genre window', () => {
    expect(foldBpm(72.5, 120, 175)).toBe(145)
    expect(foldBpm(74, 120, 175)).toBe(148)
  })
})

describe('tempo hints on psytrance and hard trance tempos', () => {
  const cases = [
    { bpm: 140, style: 'house' as const },
    { bpm: 145, style: 'house' as const },
    { bpm: 148, style: 'house' as const },
    { bpm: 150, style: 'breakbeat' as const }
  ]

  for (const { bpm, style } of cases) {
    it(`locks ${bpm} BPM with the psytrance hint`, () => {
      const audio = renderPattern({ bpm, seconds: 24, sampleRate: SR, style })
      const result = detectBeats(audio, SR, TEMPO_HINTS.psytrance)
      expect(Math.abs(result.bpm - bpm)).toBeLessThan(1.2)
      expect(result.confidence).toBeGreaterThan(0.3)
    })
  }

  it('beats the default prior on a 148 BPM psy pattern', () => {
    const audio = renderPattern({ bpm: 148, seconds: 24, sampleRate: SR, style: 'house' })
    const withHint = detectBeats(audio, SR, TEMPO_HINTS.psytrance)
    const withoutHint = detectBeats(audio, SR)
    const hintError = Math.min(Math.abs(withHint.bpm - 148), Math.abs(withHint.bpm - 74))
    const defaultError = Math.min(Math.abs(withoutHint.bpm - 148), Math.abs(withoutHint.bpm - 74))
    expect(hintError).toBeLessThanOrEqual(defaultError + 1e-6)
  })
})

describe('hint presets', () => {
  it('exposes a narrow window per genre', () => {
    expect(Object.keys(TEMPO_HINTS)).toEqual(['auto', 'psytrance', 'hardTrance', 'house'])
    expect(TEMPO_HINTS.psytrance.bpmPrior).toBe(143)
    expect(TEMPO_HINTS.auto).toEqual({})
  })
})
