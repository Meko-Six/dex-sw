import { describe, expect, it } from 'vitest'
import { detectBeats } from '../src/shared/detector'
import { bandFrames, chooseTempo, estimateBarPhase, locateKick, refineTempo } from '../src/shared/grid-refine'
import { renderPattern } from '../src/shared/synth'

const SR = 44100

/** Distance between two phases on a circle of `periodMs`. */
function phaseErrorMs(aMs: number, bMs: number, periodMs: number): number {
  const d = (((aMs - bMs) % periodMs) + periodMs) % periodMs
  return Math.min(d, periodMs - d)
}

describe('grid refinement', () => {
  it('lands a near-miss tempo on the whole number over a long track', () => {
    // 0.03 BPM off is what the comb fit read on real tracks; over 90 s it slips the grid ~20 ms.
    const bands = bandFrames(renderPattern({ bpm: 126, seconds: 90, sampleRate: SR, style: 'house' }), SR)
    const refined = refineTempo(bands, 125.97)
    expect(refined.bpm).toBe(126)
    expect(refined.wholeNumber).toBe(true)
  })

  it('keeps a tempo that is not a whole number', () => {
    const bands = bandFrames(renderPattern({ bpm: 125.6, seconds: 90, sampleRate: SR, style: 'house' }), SR)
    const refined = refineTempo(bands, 125.5)
    expect(refined.wholeNumber).toBe(false)
    expect(Math.abs(refined.bpm - 125.6)).toBeLessThan(0.005)
  })

  it('puts the grid on the kick, not the off-beat bass or hat', () => {
    const audio = renderPattern({ bpm: 128, seconds: 40, sampleRate: SR, style: 'house', startOffsetMs: 137 })
    const kick = locateKick(bandFrames(audio, SR), 128)
    expect(phaseErrorMs(kick.offsetSec * 1000, 137, 60000 / 128)).toBeLessThan(2)
  })

  it('recovers 125 from the 3:2 reading at 83.33', () => {
    // Traffic's failure: a grid every one-and-a-half beats lands on a kick only every other line.
    const bands = bandFrames(renderPattern({ bpm: 125, seconds: 40, sampleRate: SR, style: 'house' }), SR)
    const choice = chooseTempo(bands, (125 * 2) / 3, 70, 180)
    expect(choice.chosen.bpm).toBe(125)
    expect(choice.hypotheses.map((h) => h.relation)).toContain('2/3')
  })

  it('finds bar one from where the arrangement changes, even when the audio starts mid-bar', () => {
    // Kicks from 0:00.137, but bars begin two beats later: a pad comes in and out on those bar lines.
    const bpm = 124
    const beat = 60 / bpm
    const audio = renderPattern({ bpm, seconds: 60, sampleRate: SR, style: 'house', startOffsetMs: 137 })
    const firstBarSec = 0.137 + 2 * beat
    for (let i = 0; i < audio.length; i++) {
      const t = i / SR - firstBarSec
      if (t < 0) continue
      const bar = Math.floor(t / (4 * beat))
      if (bar % 2 === 0) audio[i] += 0.2 * Math.sin(2 * Math.PI * 660 * (i / SR))
    }
    const bands = bandFrames(audio, SR)
    const kick = locateKick(bands, bpm)
    const bar = estimateBarPhase(bands, bpm, kick.offsetSec)
    expect(bar.beat).toBe(2)
    expect(bar.margin).toBeGreaterThan(0)
  })

  it('returns a downbeat offset folded at the bar, with alternates ready to apply', () => {
    const bpm = 126
    const audio = renderPattern({ bpm, seconds: 40, sampleRate: SR, style: 'house', startOffsetMs: 300 })
    const result = detectBeats(audio, SR)
    const barMs = (4 * 60000) / result.bpm
    expect(result.bpm).toBe(126)
    expect(result.offsetMs).toBeGreaterThanOrEqual(0)
    expect(result.offsetMs).toBeLessThan(barMs)
    // The render starts on bar 1, so the downbeat is the first kick.
    expect(phaseErrorMs(result.offsetMs, 300, barMs)).toBeLessThan(2)
    expect(result.alternates.length).toBeGreaterThan(0)
    for (const alternate of result.alternates) {
      expect(alternate.bpm).not.toBe(result.bpm)
      expect(alternate.offsetMs).toBeGreaterThanOrEqual(0)
    }
    expect(result.evidence.wholeNumberBpm).toBe(true)
  })
})
