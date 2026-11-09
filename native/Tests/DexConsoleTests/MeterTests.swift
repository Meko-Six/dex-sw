import XCTest
@testable import DexConsole

/// The meters' movement and scale, as the mockup's `meterLoop` and `meterPct`.
final class MeterTests: XCTestCase {
    func testRisesAtOnceFallsTwentyDecibelsASecondAndHoldsTwoSeconds() {
        var meters = MeterBallistics()
        meters.update(MeterLevels(a: -10, l: -3, r: -3, b: -.infinity), dt: 0.016, now: 1)
        XCTAssertEqual(meters.meters.level.a, -10)
        XCTAssertEqual(meters.meters.level.b, MeterLevels.floor, "silence sits on the floor")
        // Half a second of silence: down 10 dB, the held segment stays.
        var now = 1.0
        for _ in 0..<50 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertEqual(meters.meters.level.a, -20, accuracy: 0.01)
        XCTAssertEqual(meters.meters.hold.a, -10)
        // After 2 s the held segment lets go.
        for _ in 0..<160 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertLessThan(meters.meters.hold.a, -10)
        for _ in 0..<500 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertEqual(meters.meters, .silent, "and everything comes to rest")
    }

    func testZonesSitOnTheAimPoints() {
        XCTAssertEqual(Meters.percent(MeterZones.deckAim), 100.0 * 24 / 36, accuracy: 1e-9, "−6 dBFS: the deck's aim mark")
        XCTAssertEqual(Meters.percent(MeterZones.masterAim), 100.0 * 27 / 36, accuracy: 1e-9, "−3 dBFS: the master's aim mark")
        XCTAssertEqual(Meters.percent(MeterZones.clip), 100.0 * 30 / 36, accuracy: 1e-9, "0 dBFS: red starts here")
        XCTAssertLessThan(Meters.percent(-6.1), Meters.percent(MeterZones.deckAim))
        XCTAssertGreaterThan(Meters.percent(-5.9), Meters.percent(MeterZones.deckAim))
    }

    func testTheClipFlagFollowsTheHold() {
        var meters = MeterBallistics()
        meters.update(MeterLevels(a: 0.2, l: -12, r: -12, b: -90), dt: 0.016, now: 5)
        XCTAssertTrue(meters.meters.isClipping("A"))
        XCTAssertFalse(meters.meters.isClipping("L"), "a quiet meter never clips")
        XCTAssertFalse(meters.meters.masterClipping, "channel overload alone does not light the master lamp")
        var now = 5.0
        for _ in 0..<100 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertTrue(meters.meters.isClipping("A"), "still inside the 2 s hold")
        for _ in 0..<160 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertFalse(meters.meters.isClipping("A"), "the hold has let go")
    }

    func testEitherSideLightsTheMasterClipLamp() {
        for id in ["L", "R"] {
            let levels = MeterLevels(a: -3, l: id == "L" ? 0 : -3, r: id == "R" ? 0 : -3, b: -3)
            XCTAssertTrue(Meters(level: .silent, hold: levels).masterClipping)
        }
    }

    func testJustBelowZeroNeverClips() {
        var meters = MeterBallistics()
        meters.update(MeterLevels(a: -0.1, l: -0.1, r: -0.1, b: -0.1), dt: 0.016, now: 1)
        XCTAssertFalse(meters.meters.isClipping("A"))
        XCTAssertEqual(meters.meters.hold.a, -0.1, "but the held segment still shows it")
    }

    func testTheLadderHasTwelveEvenRungs() {
        XCTAssertEqual(MeterLadder.rungs.count, 12, "twelve rungs")
        XCTAssertEqual(MeterLadder.rungs.filter { $0.ink == 0x25A859 }.count, 6, "six green at the foot")
        XCTAssertEqual(MeterLadder.rungs.filter { $0.ink == 0xD8A029 }.count, 4, "four amber")
        XCTAssertEqual(MeterLadder.rungs.filter { $0.ink == 0xD03A2C }.count, 2, "two red")
        XCTAssertEqual(MeterLadder.rungs.first?.low, -30, "the foot is the floor")
        XCTAssertEqual(MeterLadder.rungs.last?.high, 6, "the top is the scale's ceiling")
        XCTAssertTrue(MeterLadder.rungs.allSatisfy { $0.low < $0.high }, "every rung spans something")
        XCTAssertTrue(MeterLadder.rungs.allSatisfy { abs($0.high - $0.low - 3) < 1e-9 }, "every rung is 3 dB, so none is twice the height")
    }

    func testRedStillBeginsAtTheCeiling() {
        XCTAssertEqual(MeterLadder.rungs[MeterLadder.red].low, MeterZones.clip, "red starts at 0 dBFS")
        XCTAssertEqual(MeterLadder.rungs[MeterLadder.amber].low, -12, "amber starts 12 dB down")
        XCTAssertEqual(MeterLadder.rungs[MeterLadder.amber - 1].low, -15, "green ends there")
    }

    func testARungLightsWhenTheLevelReachesIt() {
        XCTAssertEqual(MeterLadder.rung(for: -31), -1, "below the floor nothing lights")
        XCTAssertEqual(MeterLadder.rung(for: -30), 0)
        XCTAssertEqual(MeterLadder.rung(for: -28), 0)
        XCTAssertEqual(MeterLadder.rung(for: -27), 1)
        XCTAssertEqual(MeterLadder.rung(for: -2), 9, "into the top amber")
        XCTAssertEqual(MeterLadder.rung(for: 0), 10, "the first red")
        XCTAssertEqual(MeterLadder.rung(for: 6), 11)
    }

    func testOneScaleForAllFour() {
        XCTAssertEqual(Meters.percent(-30), 0)
        XCTAssertEqual(Meters.percent(0), 100.0 * 30 / 36, accuracy: 1e-9, "0 dBFS, where red starts")
        XCTAssertEqual(Meters.percent(6), 100)
        XCTAssertEqual(Meters.percent(-90), 0)
    }
}
