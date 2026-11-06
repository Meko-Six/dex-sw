import XCTest
@testable import DexCore

final class GridEditingTests: XCTestCase {
    func testOffsetNormalizationPreservesBarPhaseIncludingNegativeOffsets() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 1500)
        let moved = try GridEditing.offset(grid, milliseconds: 1499)
        XCTAssertEqual(moved.offsetMs, 1499)
        XCTAssertEqual(moved.phase(at: 1.499), 0, accuracy: 1e-9)
        let negative = try GridEditing.offset(grid, milliseconds: -1)
        XCTAssertEqual(negative.offsetMs, 1999)
        XCTAssertEqual(negative.beat(at: -0.001), -4, accuracy: 1e-9)
        let downbeat = try GridEditing.offset(grid, milliseconds: 12543)
        XCTAssertEqual(downbeat.beat(at: 12.543), 24, accuracy: 1e-9)
        XCTAssertThrowsError(try GridEditing.offset(grid, milliseconds: .infinity))
    }
    func testTempoChangesKeepDownbeatModuloNewBarAndStayWithinSupportedRange() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 1500)
        let doubled = try GridEditing.tempo(grid, bpm: 240)
        XCTAssertEqual(doubled.offsetMs, 500)
        XCTAssertEqual(doubled.beat(at: 1.5), 4, accuracy: 1e-9)
        let halved = try GridEditing.tempo(grid, bpm: 60)
        XCTAssertEqual(halved.offsetMs, 1500)
        XCTAssertEqual(try GridEditing.tempo(grid, bpm: 600).bpm, 300)
        XCTAssertEqual(try GridEditing.tempo(grid, bpm: 20).bpm, 40)
        XCTAssertThrowsError(try GridEditing.tempo(grid, bpm: .nan))
    }
    func testTapTempoRequiresThreeTapsAndResetsAfterPauseOrClockReversal() {
        var taps = GridTapTempo()
        XCTAssertNil(taps.tap(at: 10))
        XCTAssertNil(taps.tap(at: 10.5))
        XCTAssertEqual(taps.tap(at: 11)!, 120, accuracy: 1e-9)
        XCTAssertNil(taps.tap(at: 15))
        XCTAssertEqual(taps.count, 1)
        XCTAssertNil(taps.tap(at: 14))
        XCTAssertEqual(taps.count, 1)
        XCTAssertNil(taps.tap(at: .nan))
        XCTAssertEqual(taps.count, 1)
        for i in 1...20 { _ = taps.tap(at: 14 + Double(i) * 0.25) }
        XCTAssertEqual(taps.count, 8)
        XCTAssertEqual(taps.tap(at: 19.25)!, 200, accuracy: 1e-9)
    }
}
