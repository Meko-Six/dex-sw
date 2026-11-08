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

    func testOneScaleForAllFour() {
        XCTAssertEqual(Meters.percent(-30), 0)
        XCTAssertEqual(Meters.percent(0), 100.0 * 30 / 36, accuracy: 1e-9, "0 dBFS, where red starts")
        XCTAssertEqual(Meters.percent(6), 100)
        XCTAssertEqual(Meters.percent(-90), 0)
    }
}
