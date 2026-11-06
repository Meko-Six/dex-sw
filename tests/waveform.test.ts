import { describe, expect, it } from 'vitest'
import {
  MIN_WAVEFORM_SPAN,
  seekByDrag,
  seekToFraction,
  timeToX,
  waveformView,
  zoomSpan
} from '../src/shared/waveform'

describe('waveformView', () => {
  it('keeps the current position at the centre of the window', () => {
    for (const at of [0, 0.25, 0.5, 0.75, 1]) {
      const view = waveformView(at * 120, 120, 0.4)
      expect(view.centerFraction).toBeCloseTo(at)
      expect((view.startSec + view.endSec) / 2).toBeCloseTo(at * 120)
      expect(view.spanSec).toBeCloseTo(48)
    }
  })

  it('extends past the track at the edges instead of moving the line', () => {
    const start = waveformView(0, 100, 0.5)
    expect(start.startSec).toBeCloseTo(-25)
    expect(start.endSec).toBeCloseTo(25)

    const end = waveformView(100, 100, 0.5)
    expect(end.startSec).toBeCloseTo(75)
    expect(end.endSec).toBeCloseTo(125)
  })

  it('clamps the span and a zero duration', () => {
    expect(waveformView(0, 0, 0.5).span).toBe(0.5)
    expect(waveformView(0, 0, 0).span).toBe(MIN_WAVEFORM_SPAN)
    expect(waveformView(0, 100, 4).span).toBe(1)
  })
})

describe('seekToFraction', () => {
  it('leaves the position unchanged at the centre line', () => {
    expect(seekToFraction(40, 100, 0.5, 0.5)).toBeCloseTo(40)
  })

  it('maps the visible window around the current position', () => {
    expect(seekToFraction(40, 100, 0.5, 0.75)).toBeCloseTo(52.5)
    expect(seekToFraction(40, 100, 0.5, 0.25)).toBeCloseTo(27.5)
  })

  it('clamps to the track', () => {
    expect(seekToFraction(5, 100, 0.5, 0)).toBe(0)
    expect(seekToFraction(95, 100, 0.5, 1)).toBe(100)
  })
})

describe('seekByDrag', () => {
  it('moves earlier when the waveform is dragged right', () => {
    expect(seekByDrag(50, 100, 0.4, 0.1)).toBeCloseTo(46)
    expect(seekByDrag(50, 100, 0.4, -0.1)).toBeCloseTo(54)
  })

  it('clamps at the ends', () => {
    expect(seekByDrag(1, 100, 1, 1)).toBe(0)
    expect(seekByDrag(99, 100, 1, -1)).toBe(100)
  })
})

describe('zoomSpan', () => {
  it('zooms out and in within the allowed range', () => {
    expect(zoomSpan(0.4, 1.3)).toBeCloseTo(0.52)
    expect(zoomSpan(0.4, 0.5)).toBeCloseTo(0.2)
    expect(zoomSpan(0.4, 20)).toBe(1)
    expect(zoomSpan(0.4, 0.0001)).toBe(MIN_WAVEFORM_SPAN)
  })
})

describe('timeToX', () => {
  it('maps the window edges and centre to the canvas', () => {
    expect(timeToX(0, 0, 8, 400)).toBe(0)
    expect(timeToX(4, 0, 8, 400)).toBe(200)
    expect(timeToX(8, 0, 8, 400)).toBe(400)
  })

  it('returns null for times outside the window', () => {
    expect(timeToX(-1, 0, 8, 400)).toBeNull()
    expect(timeToX(9, 0, 8, 400)).toBeNull()
    expect(timeToX(0, 0, 0, 400)).toBeNull()
    expect(timeToX(0, 0, 8, 0)).toBeNull()
  })
})
