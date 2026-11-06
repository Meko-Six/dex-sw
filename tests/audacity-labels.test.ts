import { describe, expect, it } from 'vitest'
import { checkMarks, fitMarks, parseLabels } from '../scripts/lib/audacity-labels'

describe('parseLabels', () => {
  it('reads point and region labels by their start, in order', () => {
    const text = '95.250000\t95.250000\t\n12.500000\t12.500000\tone\n180.125000\t181.000000\tend\n'
    expect(parseLabels(text)).toEqual([12.5, 95.25, 180.125])
  })

  it('skips spectral lines, blank lines and junk, and reads a decimal comma', () => {
    const text = '12,500000\t12,500000\t\n\\\t100.0\t2000.0\n\nnot a label\n'
    expect(parseLabels(text)).toEqual([12.5])
  })

  it('keeps one of two marks placed on the same spot', () => {
    expect(parseLabels('10.000\t10.000\t\n10.002\t10.002\t\n')).toEqual([10])
  })

  it('prefers the point label over a stray selection on the same spot', () => {
    // A region 11 ms before the real mark, as a stray drag leaves it.
    expect(parseLabels('62.045335\t62.149596\t\n62.056581\t62.056581\t1\n93.0\t93.0\t2\n')).toEqual([62.056581, 93])
  })
})

describe('fitMarks', () => {
  const marks = (bpm: number, counts: number[], start = 10) => counts.map((count) => start + (count * 60) / bpm)

  it('gives the played tempo to a fraction of the whole-number tag', () => {
    // Played at 125.02, tagged 125.
    const fit = fitMarks(marks(125.02, [0, 32, 300, 640]), 125)!
    expect(fit.counts).toEqual([0, 32, 300, 640])
    expect(fit.bpm).toBeCloseTo(125.02, 3)
    expect(Math.max(...fit.residualsMs.map(Math.abs))).toBeLessThan(1)
  })

  it('shows a mark on the wrong sound as a residual, not a different tempo', () => {
    // The middle mark 120 ms late: a hat or snare after the kick. (An error of
    // 20-60 ms can fit a slightly different tempo with only four marks, so
    // marking by eye on the onset still matters.)
    const times = marks(125, [0, 32, 300, 600])
    times[2] += 0.12
    const fit = fitMarks(times, 125)!
    expect(fit.residualsMs.some((ms) => Math.abs(ms) > 15)).toBe(true)
  })

  it('warns when the first gap is too long to count from the tag', () => {
    expect(fitMarks(marks(125, [0, 300, 600]), 125)!.firstGapUnsure).toBe(true)
    expect(fitMarks(marks(125, [0, 32, 300, 600]), 125)!.firstGapUnsure).toBe(false)
  })

  it('exposes a tag at the wrong tempo', () => {
    // Played at 148 and tagged 99, as 343063 is: the 32-kick gap reads as
    // about 21 beats at 99, and the later marks fall off that grid.
    const fit = fitMarks(marks(148, [0, 32, 300, 640]), 99)!
    expect(Math.abs(fit.bpm - 99) > 0.5 || fit.residualsMs.some((ms) => Math.abs(ms) > 15)).toBe(true)
  })
})

describe('checkMarks', () => {
  const marks = (bpm: number, counts: number[], start = 10) => counts.map((count) => start + (count * 60) / bpm)

  it('keeps every mark when they all sit on the tagged tempo', () => {
    const result = checkMarks(marks(124, [0, 64, 384, 674], 62.057), 124)!
    expect(result.odd).toBeNull()
    expect(result.fit.bpm).toBeCloseTo(124, 3)
  })

  it('names a second mark on the off-beat, not the mark after it', () => {
    // Traffic: the second mark half a beat late.
    const times = marks(125, [0, 31.5, 256, 752], 0.002)
    const result = checkMarks(times, 125)!
    expect(result.odd?.index).toBe(1)
    expect(result.odd!.offMs).toBeCloseTo(240, -1)
    expect(result.fit.bpm).toBeCloseTo(125, 3)
  })

  it('names a label left at 0.000 where no kick is', () => {
    // Our Lights Shine: the first kick is 50 ms in, the label is at zero.
    const result = checkMarks([0, ...marks(126, [32, 512, 864], 0.05)], 126)!
    expect(result.odd?.index).toBe(0)
    expect(result.odd!.offMs).toBeCloseTo(-50, 0)
    expect(result.fit.bpm).toBeCloseTo(126, 3)
  })
})
