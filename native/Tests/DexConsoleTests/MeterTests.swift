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
        XCTAssertEqual(Meters.percent(MeterZones.deckAim), 100.0 * 24 / 36, accuracy: 1e-9, "−6 dBFS: green ends here")
        XCTAssertEqual(Meters.percent(MeterZones.masterAim), 100.0 * 27 / 36, accuracy: 1e-9, "−3 dBFS: amber ends here")
        XCTAssertEqual(Meters.percent(MeterZones.clip), 100.0 * 30 / 36, accuracy: 1e-9, "0 dBFS: red starts here")
        XCTAssertLessThan(Meters.percent(-6.1), Meters.percent(MeterZones.deckAim))
        XCTAssertGreaterThan(Meters.percent(-5.9), Meters.percent(MeterZones.deckAim))
    }

    func testTheClipFlagFollowsTheHold() {
        var meters = MeterBallistics()
        meters.update(MeterLevels(a: 0.2, l: -12, r: -12, b: -90), dt: 0.016, now: 5)
        XCTAssertTrue(meters.meters.isClipping("A"))
        XCTAssertFalse(meters.meters.isClipping("L"), "a quiet meter never clips")
        var now = 5.0
        for _ in 0..<100 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertTrue(meters.meters.isClipping("A"), "still inside the 2 s hold")
        for _ in 0..<160 { now += 0.01; meters.update(.silent, dt: 0.01, now: now) }
        XCTAssertFalse(meters.meters.isClipping("A"), "the hold has let go")
    }

    func testJustBelowZeroNeverClips() {
        var meters = MeterBallistics()
        meters.update(MeterLevels(a: -0.1, l: -0.1, r: -0.1, b: -0.1), dt: 0.016, now: 1)
        XCTAssertFalse(meters.meters.isClipping("A"))
        XCTAssertEqual(meters.meters.hold.a, -0.1, "but the held segment still shows it")
    }

    func testOneScaleForAllFour() {
        XCTAssertEqual(Meters.percent(-30), 0)
        XCTAssertEqual(Meters.percent(0), 100.0 * 30 / 36, accuracy: 1e-9, "0 dBFS, where red starts")
        XCTAssertEqual(Meters.percent(6), 100)
        XCTAssertEqual(Meters.percent(-90), 0)
    }
}
