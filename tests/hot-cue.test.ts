import { describe, expect, it } from 'vitest'
import {
  clearHotCueAt,
  emptyHotCues,
  HOT_CUE_COLOURS,
  HOT_CUE_COUNT,
  normalizeHotCues,
  pressHotCue
} from '../src/shared/hot-cue'

describe('pressHotCue', () => {
  it('sets an empty slot at the playhead', () => {
    const cues = emptyHotCues()
    expect(cues).toHaveLength(HOT_CUE_COUNT)
    expect(cues.every((cue) => cue === null)).toBe(true)

    const result = pressHotCue(cues, 1, 42.5, 120)
    expect(result.cues[1]).toBe(42.5)
    expect(result.seekTo).toBeNull()
    expect(cues[1]).toBeNull() // the input list is not mutated
  })

  it('recalls a filled slot instead of moving it', () => {
    const cues = pressHotCue(emptyHotCues(), 0, 12, 120).cues
    const result = pressHotCue(cues, 0, 80, 120)
    expect(result.seekTo).toBe(12)
    expect(result.cues[0]).toBe(12)
  })

  it('clamps the captured position to the track', () => {
    expect(pressHotCue(emptyHotCues(), 0, -3, 120).cues[0]).toBe(0)
    expect(pressHotCue(emptyHotCues(), 0, 200, 120).cues[0]).toBe(120)
    expect(pressHotCue(emptyHotCues(), 0, 50, 0).cues[0]).toBe(0)
  })

  it('ignores slots outside the list', () => {
    const cues = emptyHotCues()
    expect(pressHotCue(cues, -1, 4, 120).cues).toBe(cues)
    expect(pressHotCue(cues, HOT_CUE_COUNT, 4, 120).cues).toBe(cues)
    expect(pressHotCue(cues, 1.5, 4, 120).seekTo).toBeNull()
  })
})

describe('normalizeHotCues', () => {
  it('fills missing slots and keeps saved times', () => {
    expect(normalizeHotCues([1.5, null, 12])).toEqual([1.5, null, 12, null, null, null, null, null])
    expect(normalizeHotCues(undefined)).toEqual(emptyHotCues())
    expect(normalizeHotCues('nope')).toEqual(emptyHotCues())
  })

  it('drops non-finite values and clamps to the track', () => {
    expect(normalizeHotCues([NaN, Infinity, -4, 500], 120)).toEqual([null, null, 0, 120, null, null, null, null])
    expect(normalizeHotCues([1, 2, 3, 4, 5, 6, 7, 8, 9])).toEqual([1, 2, 3, 4, 5, 6, 7, 8])
  })

  it('loads a four-slot library into the first four of eight slots', () => {
    const cues = normalizeHotCues([4, null, 30.5, 61], 120)
    expect(cues).toHaveLength(8)
    expect(cues.slice(0, 4)).toEqual([4, null, 30.5, 61])
    expect(cues.slice(4).every((cue) => cue === null)).toBe(true)
  })
})

describe('hot cue colours', () => {
  it('gives every slot its own colour', () => {
    expect(HOT_CUE_COLOURS).toHaveLength(HOT_CUE_COUNT)
    expect(new Set(HOT_CUE_COLOURS).size).toBe(HOT_CUE_COUNT)
  })
})

describe('clearHotCueAt', () => {
  it('empties one slot without touching the others', () => {
    const cues = pressHotCue(pressHotCue(emptyHotCues(), 0, 4, 120).cues, 2, 40, 120).cues
    const cleared = clearHotCueAt(cues, 2)
    expect(cleared[0]).toBe(4)
    expect(cleared[1]).toBeNull()
    expect(cleared[2]).toBeNull()
    expect(cues[2]).toBe(40)
    expect(clearHotCueAt(cleared, 2)).toBe(cleared)
  })
})
