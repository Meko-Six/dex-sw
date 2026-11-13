import XCTest
@testable import DexCore

final class TransportTests: XCTestCase {
    func testTempoChangeOnlyAffectsScheduledFuture() {
        var clock = DeckTimeline()
        clock.schedule(at: 1, rate: 1, position: 10)
        clock.schedule(at: 11.03, rate: 1.08)
        XCTAssertEqual(clock.position(at: 11), 20, accuracy: 1e-9)
        XCTAssertEqual(clock.position(at: 12.03), 21.11, accuracy: 1e-9)
    }
    func testPauseResumeAndPendingSeek() {
        var clock = DeckTimeline()
        clock.schedule(at: 0, rate: 1)
        clock.schedule(at: 5.03, rate: 1, position: 30)
        clock.schedule(at: 5.04, rate: 0.95)
        XCTAssertEqual(clock.position(at: 5), 5, accuracy: 1e-9)
        XCTAssertEqual(clock.position(at: 6.04), 30.96, accuracy: 1e-9)
        clock.schedule(at: 7, rate: 0)
        let paused = clock.position(at: 7)
        clock.schedule(at: 20, rate: 1)
        XCTAssertEqual(clock.position(at: 21), paused + 1, accuracy: 1e-9)
    }
    func testLoopTravelsWithItsSegment() {
        var timeline = DeckTimeline()
        timeline.schedule(at: 0, rate: 1, position: 10)
        timeline.changeLoop(12...14, at: 1)
        XCTAssertEqual(timeline.position(at: 0.5), 10.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.position(at: 3.5), 13.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.position(at: 4.5), 12.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.unfoldedPosition(at: 4.5), 14.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.loop(at: 0.5), nil)
        // A pause keeps the loop in force; a landing brings its own.
        timeline.reset(at: 4, position: 13)
        XCTAssertEqual(timeline.loop(at: 4), 12...14)
        timeline.land(at: 5, position: 20, rate: 1, loop: nil)
        XCTAssertEqual(timeline.position(at: 6), 21, accuracy: 1e-9)
        XCTAssertEqual(timeline.loop(at: 4.5), 12...14)
    }
    func testRateChangeWaitsForTheLandingStillToCome() {
        var timeline = DeckTimeline()
        timeline.schedule(at: 0, rate: 1, position: 0)
        timeline.land(at: 2, position: 30, rate: 1, loop: nil)
        timeline.changeRate(1.1, from: 1)
        XCTAssertEqual(timeline.position(at: 1.5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.position(at: 3), 31.1, accuracy: 1e-9)
    }
    func testBlocksBeforeAPendingLandingDoNotReanchorOverIt() {
        var timeline = DeckTimeline()
        timeline.schedule(at: 0, rate: 1, position: 0)
        timeline.land(at: 1, position: 50, rate: 1, loop: nil)
        // The outgoing audio is still playing: the landing stays planned.
        timeline.follow(blockStart: 0.5, position: 0.6, rate: 1, loop: nil, landing: nil, landingWaiting: false)
        XCTAssertEqual(timeline.pendingLanding, 1)
        XCTAssertEqual(timeline.position(at: 1.2), 50.2, accuracy: 1e-9)
        // The engine says when the landing really comes out.
        timeline.follow(blockStart: 0.9, position: 0.95, rate: 1, loop: nil, landing: (due: 1.01, position: 50), landingWaiting: false)
        XCTAssertEqual(timeline.position(at: 1.21), 50.2, accuracy: 1e-9)
        XCTAssertEqual(timeline.position(at: 0.95), 0.95, accuracy: 1e-9)
        // Overdue and waiting for its audio: what is really playing is followed, and it stays pending.
        timeline.follow(blockStart: 1.05, position: 1.1, rate: 1, loop: nil, landing: nil, landingWaiting: true)
        XCTAssertEqual(timeline.pendingLanding, 1.01)
        XCTAssertEqual(timeline.position(at: 1.05), 1.1, accuracy: 1e-9)
        // Once it is played, every block is the truth, loop and all.
        timeline.follow(blockStart: 1.1, position: 50.09, rate: 1, loop: 50...52, landing: nil, landingWaiting: false)
        XCTAssertNil(timeline.pendingLanding)
        XCTAssertEqual(timeline.position(at: 3.1), 50.09, accuracy: 1e-9)
    }
    func testCueWaitsForNextOutputBeatAcrossPhasesAndRates() throws {
        let grid = try BeatGrid(bpm: 128, offsetMs: 137, confidence: 1)
        for rate in [0.84, 1, 1.16] {
            for step in 0..<100 {
                let position = grid.time(atBeat: 12 + Double(step) / 100)
                let delay = MixMath.nextBeatDelay(position: position, rate: rate, grid: grid)
                XCTAssertGreaterThanOrEqual(delay, 0)
                XCTAssertLessThan(delay, grid.beatSeconds / rate)
                XCTAssertEqual(MixMath.wrapPhase(grid.phase(at: position + delay * rate)), 0, accuracy: 1e-9)
            }
        }
    }
    func testHotCueRecallPreservesAllFourBeatsOfTheBar() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 137)
        for rate in [0.84, 1.0, 1.16] {
            for target in 0..<4 {
                for step in 0..<400 {
                    let current = -4 + Double(step) / 100
                    let position = grid.time(atBeat: current)
                    let cue = grid.time(atBeat: Double(16 + target))
                    let wait = MixMath.hotCueDelay(position: position, cue: cue, rate: rate, grid: grid)
                    let result = grid.beat(at: position + wait * rate)
                    XCTAssertGreaterThanOrEqual(wait, 0)
                    XCTAssertLessThan(wait, 4 * grid.beatSeconds / rate)
                    var phase = (result - Double(target)).truncatingRemainder(dividingBy: 4)
                    if phase < 0 { phase += 4 }
                    XCTAssertTrue(phase < 1e-8 || phase > 4 - 1e-8)
                }
            }
        }
        let anticipated = grid.time(atBeat: 2.6) // During beat 3.
        let cue = grid.time(atBeat: 16) // First beat of a later bar.
        let wait = MixMath.hotCueDelay(position: anticipated, cue: cue, rate: 1, grid: grid)
        XCTAssertEqual(grid.beat(at: anticipated + wait), 4, accuracy: 1e-9)
    }
    func testHumanCueWindowAcceptsEarlyAndLatePressesWithoutLosingTheBar() throws {
        for bpm in [40.0, 120, 180, 300] {
            let grid = try BeatGrid(bpm: bpm, offsetMs: 137)
            for rate in [0.84, 1, 1.16] {
                let beat = grid.beatSeconds / rate
                let window = min(0.1, beat * 0.2)
                for target in 0..<4 {
                    let boundary = grid.time(atBeat: Double(12 + target))
                    let cue = grid.time(atBeat: Double(28 + target))
                    for delta in [-0.2, -window * 0.8, 0, window * 0.8] {
                        let position = boundary + delta * rate
                        let timing = MixMath.hotCueTiming(position: position, cue: cue, rate: rate, grid: grid)
                        XCTAssertEqual(timing.delay, max(0.12, -delta), accuracy: 1e-8)
                        XCTAssertEqual(timing.sourceOffset, max(0, delta + timing.delay) * rate, accuracy: 1e-8)
                        let outgoing = grid.beat(at: position + timing.delay * rate)
                        let incoming = grid.beat(at: cue + timing.sourceOffset)
                        XCTAssertEqual((incoming - outgoing) / 4, ((incoming - outgoing) / 4).rounded(), accuracy: 1e-8)
                    }
                    let late = window + 0.02
                    let outside = MixMath.hotCueTiming(position: boundary + late * rate, cue: cue, rate: rate, grid: grid)
                    XCTAssertEqual(outside.delay, 4 * beat - late, accuracy: 1e-8)
                    XCTAssertEqual(outside.sourceOffset, 0, accuracy: 1e-8)
                }
            }
        }
    }
    func testCueSnappingSelectsRealBeatsAtBothTrackEdges() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 137)
        XCTAssertEqual(grid.cueTime(near: 0, duration: 2)!, 0.137, accuracy: 1e-9)
        XCTAssertEqual(grid.cueTime(near: 0.9, duration: 2)!, 1.137, accuracy: 1e-9)
        XCTAssertEqual(grid.cueTime(near: 2, duration: 2)!, 1.637, accuracy: 1e-9)
        let early = try BeatGrid(bpm: 120, offsetMs: -100)
        XCTAssertEqual(early.cueTime(near: 0, duration: 2)!, 0.4, accuracy: 1e-9)
        XCTAssertNil(grid.cueTime(near: 0, duration: 0.1))
        XCTAssertNil(grid.cueTime(near: .nan, duration: 2))
        let atZero = try BeatGrid(bpm: 120)
        XCTAssertEqual(atZero.cueTime(near: 2, duration: 2), 1.5)
    }
    func testGridAndLoopMatchElectronRules() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 100)
        XCTAssertEqual(grid.quantize(0.85), 1.1, accuracy: 1e-9)
        let loop = LoopRegion(grid: grid, position: 0.2, lengthBeats: 8)
        XCTAssertEqual(loop.bounds(grid: grid).lowerBound, 0.6, accuracy: 1e-9)
        XCTAssertEqual(loop.bounds(grid: grid).upperBound, 4.6, accuracy: 1e-9)
        let half = LoopRegion(grid: grid, position: 0.2, lengthBeats: 0.5)
        XCTAssertEqual(half.bounds(grid: grid).lowerBound, 0.6, accuracy: 1e-9)
        XCTAssertEqual(half.bounds(grid: grid).upperBound, 0.85, accuracy: 1e-9)
        XCTAssertThrowsError(try BeatGrid(bpm: .nan))
        XCTAssertThrowsError(try BeatGrid(bpm: 0))
    }
    func testShrinkingKeepsThePlayheadsWindow() throws {
        let grid = try BeatGrid(bpm: 120)
        let four = LoopRegion(grid: grid, position: 1, lengthBeats: 4) // Beats 2–6.
        XCTAssertEqual(four.resized(to: 2, around: 3.5).startBeat, 2, "Beats 1–2 keep loop-in")
        XCTAssertEqual(four.resized(to: 2, around: 4).startBeat, 4, "Beat 3 onward keeps loop-out")
        XCTAssertEqual(four.resized(to: 2, around: 5.9).startBeat, 4)
        XCTAssertEqual(four.resized(to: 1, around: 4.5).startBeat, 4)
        XCTAssertEqual(four.resized(to: 0.5, around: 5.8).startBeat, 5.5)
        XCTAssertEqual(four.resized(to: 2, around: 9).startBeat, 4, "A wrapped beat folds into the loop")
        XCTAssertEqual(four.resized(to: 2, around: 1.5).startBeat, 2, "An armed loop keeps loop-in")
        XCTAssertEqual(four.resized(to: 8, around: 5).startBeat, 2, "Growing keeps loop-in")
        XCTAssertEqual(four.resized(to: 2, around: .nan), LoopRegion(grid: grid, position: 1, lengthBeats: 2))
    }
    func testCrossfaderIsFullOnBothSidesUntilTheCentreAndTempoLimits() {
        XCTAssertTrue(MixMath.crossfade(0) == (1, 0))
        XCTAssertTrue(MixMath.crossfade(0.5) == (1, 1), "centred, both decks are fully open")
        XCTAssertTrue(MixMath.crossfade(1) == (0, 1))
        XCTAssertEqual(MixMath.crossfade(0.75).0, cos(.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(MixMath.crossfade(0.25).1, cos(.pi / 4), accuracy: 1e-12)
        var previous = MixMath.crossfade(0)
        for step in 1...100 {
            let gains = MixMath.crossfade(Double(step) / 100)
            XCTAssertLessThanOrEqual(gains.0, previous.0); XCTAssertGreaterThanOrEqual(gains.1, previous.1)
            if step <= 50 { XCTAssertEqual(gains.0, 1) } else { XCTAssertEqual(gains.1, 1) }
            previous = gains
        }
        XCTAssertEqual(MixMath.tempoRate(master: 100, follower: 190), 0.84)
        XCTAssertEqual(MixMath.tempoRate(master: 190, follower: 100), 1.16)
    }
}
