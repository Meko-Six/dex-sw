import { describe, expect, it } from 'vitest'
import { beatPhase } from '../src/shared/grid'
import {
  SyncController,
  alignedPositionSec,
  cueLeadInSec,
  effectiveRate,
  phaseCorrectionBeats,
  phaseErrorBeats,
  seekTargetSec,
  tempoRateFor,
  wrapPhase
} from '../src/shared/sync'

const masterGrid = { bpm: 128, offsetMs: 0, confidence: 1 }
const followerGrid = { bpm: 127.4, offsetMs: 40, confidence: 1 }

describe('sync', () => {
  it('never skips the cue attack at any master phase, even at the file start', () => {
    for (const cue of [0, 0.04, 12.345]) {
      for (let phase = 0; phase < 1; phase += 0.01) {
        const master = phase * 60 / masterGrid.bpm
        const target = cueLeadInSec(cue, master, masterGrid, followerGrid)
        expect(target).toBeLessThanOrEqual(cue)
        expect(cue - target).toBeLessThan(60 / followerGrid.bpm)
        expect(phaseErrorBeats(master, masterGrid, target, followerGrid)).toBeCloseTo(0, 8)
      }
    }
  })

  it('allows silent lead-in before zero instead of jumping forward a beat', () => {
    const grid = { bpm: 120, offsetMs: 0, confidence: 1 }
    expect(cueLeadInSec(0, 0.4, grid, grid)).toBeCloseTo(-0.1)
    expect(cueLeadInSec(0, 0.1, grid, grid)).toBeCloseTo(-0.4)
    expect(cueLeadInSec(0, 0, grid, grid)).toBe(0)
  })

  it('does not add a beat of lead-in for rounding noise at the boundary', () => {
    expect(cueLeadInSec(0, 1e-12, masterGrid, masterGrid)).toBe(0)
  })

  it('keeps phase when the nearest match would fall before the file starts', () => {
    const target = alignedPositionSec(0, -0.3, followerGrid, 100)
    expect(target).toBeCloseTo(0.7 * 60 / followerGrid.bpm)
    expect(wrapPhase(beatPhase(followerGrid, target) - beatPhase(followerGrid, -0.3 * 60 / followerGrid.bpm))).toBeCloseTo(0)
  })

  it('chooses an equivalent beat inside the end of the file', () => {
    const target = alignedPositionSec(100, 0.3, followerGrid, 100)
    expect(target).toBeLessThan(100)
    expect((100 + 0.3 * 60 / followerGrid.bpm - target) / (60 / followerGrid.bpm)).toBeCloseTo(1)
  })

  it('clamps the tempo ratio to ±16%', () => {
    expect(tempoRateFor(128, 128)).toBeCloseTo(1)
    expect(tempoRateFor(100, 190)).toBeCloseTo(0.84)
    expect(tempoRateFor(190, 100)).toBeCloseTo(1.16)
  })

  it('wraps phase errors into (-0.5, 0.5]', () => {
    expect(wrapPhase(0.25)).toBeCloseTo(0.25)
    expect(wrapPhase(0.75)).toBeCloseTo(-0.25)
    expect(wrapPhase(-0.75)).toBeCloseTo(0.25)
    expect(wrapPhase(3.1)).toBeCloseTo(0.1)
  })

  it('corrects the follower forward only, inside one beat', () => {
    for (let masterPhase = 0; masterPhase < 1; masterPhase += 0.07) {
      for (let followerPhase = 0; followerPhase < 1; followerPhase += 0.11) {
        const beats = phaseCorrectionBeats(masterPhase, followerPhase)
        expect(beats).toBeGreaterThanOrEqual(0)
        expect(beats).toBeLessThan(1)
        expect(wrapPhase(masterPhase - (followerPhase + beats))).toBeCloseTo(0, 9)
      }
    }
  })

  it('seeks forward by the correction', () => {
    const target = seekTargetSec(12, 0.5, followerGrid)
    expect(target).toBeCloseTo(12 + 0.5 * (60 / followerGrid.bpm), 9)
  })

  it('converges a wrong detected BPM using rate trim only', () => {
    // The commanded rate is 0.16% too fast for what actually comes out of the
    // deck (a wrong detected BPM). Only drift trimming can cancel that.
    const rateError = 0.0016
    const base = tempoRateFor(masterGrid.bpm, followerGrid.bpm)
    const controller = new SyncController()

    // Align once, like pressing SYNC.
    const masterStart = 10
    const followerStart = 3.2
    const correction = phaseCorrectionBeats(
      beatPhase(masterGrid, masterStart),
      beatPhase(followerGrid, followerStart)
    )
    const alignedFollower = seekTargetSec(followerStart, correction, followerGrid)

    let trim = 0
    let maxLateError = 0
    let finalError = 0
    let masterSec = masterStart
    let followerSec = alignedFollower
    const dt = 0.1
    for (let t = 0; t <= 180; t += dt) {
      // The deck integrates whatever rate it is commanded, so integrate here too.
      const rate = effectiveRate(base, trim) * (1 + rateError)
      followerSec += rate * dt
      masterSec += dt
      const error = phaseErrorBeats(masterSec, masterGrid, followerSec, followerGrid)
      trim = controller.update(error)
      if (t > 30) maxLateError = Math.max(maxLateError, Math.abs(error))
      finalError = Math.abs(error)
    }
    // It must actually cancel the error, and hold the decks together.
    expect(controller.value).toBeLessThan(-0.001)
    expect(Math.abs(controller.value)).toBeLessThanOrEqual(0.0025 + 1e-9)
    expect(maxLateError).toBeLessThan(0.03)
    expect(finalError).toBeLessThan(0.01)
  })

  it('resets its trim', () => {
    const controller = new SyncController()
    controller.update(0.4)
    expect(Math.abs(controller.value)).toBeGreaterThan(0)
    controller.reset()
    expect(controller.value).toBe(0)
  })
})
