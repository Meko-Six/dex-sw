import { describe, expect, it } from 'vitest'
import { TransportClock } from '../src/renderer/audio/transport-clock'

describe('scheduled audio clock', () => {
  it('integrates a tempo change only from the scheduled output time', () => {
    const clock = new TransportClock()
    clock.schedule(1, 1, 10)
    clock.schedule(11.03, 1.08)
    expect(clock.positionAt(11)).toBeCloseTo(20)
    expect(clock.positionAt(11.03)).toBeCloseTo(20.03)
    expect(clock.positionAt(12.03)).toBeCloseTo(21.11)
  })

  it('keeps phase through repeated drift corrections', () => {
    const clock = new TransportClock()
    clock.schedule(0, 1, 0)
    let expected = 0
    let rate = 1
    for (let i = 1; i < 400; i++) {
      expected += 0.25 * rate
      rate = 1 + Math.sin(i) * 0.0025
      clock.schedule(i * 0.25, rate)
      expect(clock.positionAt(i * 0.25)).toBeCloseTo(expected, 8)
    }
  })

  it('leaves a pending seek intact when its rate is updated', () => {
    const clock = new TransportClock()
    clock.schedule(0, 1, 0)
    clock.schedule(5.03, 1, 30)
    clock.schedule(5.04, 0.95)
    expect(clock.positionAt(5)).toBeCloseTo(5)
    expect(clock.positionAt(5.03)).toBeCloseTo(30)
    expect(clock.positionAt(6.04)).toBeCloseTo(30.96)
  })

  it('pauses and resumes without counting paused time', () => {
    const clock = new TransportClock()
    clock.schedule(1, 1, 5)
    clock.schedule(3, 0)
    clock.schedule(10, 1)
    expect(clock.positionAt(9)).toBeCloseTo(7)
    expect(clock.positionAt(11)).toBeCloseTo(8)
  })

  it('replaces a queued rate change at the same time without jumping', () => {
    const clock = new TransportClock()
    clock.schedule(0, 1, 0)
    clock.schedule(5, 1.1)
    clock.schedule(5, 1.2)
    expect(clock.positionAt(4)).toBeCloseTo(4)
    expect(clock.positionAt(6)).toBeCloseTo(6.2)
  })
})
