import XCTest
@testable import DexCore

/// The curves match `src/shared/mixer.ts` and `curves.ts`.
final class MixerCurvesTests: XCTestCase {
    func testFaderLaw() {
        XCTAssertEqual(FaderLaw.db(1), 0)
        XCTAssertEqual(FaderLaw.db(0.8), -3, accuracy: 1e-9)
        XCTAssertEqual(FaderLaw.db(0.5), -9, accuracy: 1e-9)
        XCTAssertEqual(FaderLaw.db(0.03), -48, accuracy: 1e-9)
        XCTAssertEqual(FaderLaw.db(0.005), -.infinity)
        XCTAssertEqual(FaderLaw.gain(0), 0)
        XCTAssertEqual(FaderLaw.gain(0.6), pow(10, -6.0 / 20), accuracy: 1e-12)
    }

    func testALinkedBandMovesTheOtherWayAndClamps() {
        XCTAssertEqual(FaderLaw.linked(0.5, delta: 0.2), 0.3, accuracy: 1e-12)
        XCTAssertEqual(FaderLaw.linked(0.9, delta: -0.3), 1)
        XCTAssertEqual(FaderLaw.linked(0.1, delta: 0.3), 0)
    }

    func testTheLinkKeepsThePlayingDecksBand() {
        XCTAssertEqual(FaderLaw.linkKeeper(aPlaying: true, bPlaying: false, bIsMaster: true), "A", "The playing deck, even when B is master")
        XCTAssertEqual(FaderLaw.linkKeeper(aPlaying: false, bPlaying: true, bIsMaster: false), "B")
        XCTAssertEqual(FaderLaw.linkKeeper(aPlaying: true, bPlaying: true, bIsMaster: true), "B", "Both playing: the master")
        XCTAssertEqual(FaderLaw.linkKeeper(aPlaying: false, bPlaying: false, bIsMaster: false), "A", "Neither playing: the master")
    }

    func testFilterSetting() {
        XCTAssertTrue(FilterSetting(knob: 0).flat)
        let low = FilterSetting(knob: -1)
        XCTAssertFalse(low.highPass); XCTAssertEqual(low.frequency, 120, accuracy: 1e-9); XCTAssertEqual(low.q, 1.3, accuracy: 1e-12)
        let high = FilterSetting(knob: 0.5)
        XCTAssertTrue(high.highPass); XCTAssertEqual(high.frequency, 20 * (9_000 / 20.0).squareRoot(), accuracy: 1e-9)
        XCTAssertTrue(FilterSetting(knob: .nan).flat)
    }
}
