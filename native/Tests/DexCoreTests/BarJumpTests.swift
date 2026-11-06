import XCTest
@testable import DexCore

final class BarJumpTests: XCTestCase {
    func testPlayingJumpsKeepBarPhaseAndAdmitOnlyWholeBarsAtEdges() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 137)
        for beat in [0.25, 1.5, 2.8, 3.999] {
            let source = grid.time(atBeat: beat + 12)
            let jump = try XCTUnwrap(BarJump.plan(grid: grid, position: source, duration: 40, playing: true, bars: 4))
            XCTAssertEqual(grid.beat(at: jump.position) - grid.beat(at: source), 16, accuracy: 1e-9)
            let back = try XCTUnwrap(BarJump.plan(grid: grid, position: source, duration: 40, playing: true, bars: -32))
            XCTAssertEqual(back.bars, -Int(floor(source / 2)))
            XCTAssertEqual(back.position, source + Double(back.bars) * 2, accuracy: 1e-9)
        }
        let end = try XCTUnwrap(BarJump.plan(grid: grid, position: 37.5, duration: 40, playing: true, bars: 32))
        XCTAssertEqual(end.position, 39.5)
        XCTAssertEqual(end.bars, 1)
        XCTAssertEqual(BarJump.plan(grid: grid, position: 39.5, duration: 40, playing: true, bars: 1)?.bars, 0)
    }
    func testPausedJumpSnapsToPlayableBarWithPositiveOrNegativeOffset() throws {
        for offset in [-137.0, 137, 1500] {
            let grid = try BeatGrid(bpm: 120, offsetMs: offset)
            let jump = try XCTUnwrap(BarJump.plan(grid: grid, position: 7.1, duration: 20, playing: false, bars: 1))
            XCTAssertEqual(grid.beat(at: jump.position).truncatingRemainder(dividingBy: 4), 0, accuracy: 1e-9)
            let edge = try XCTUnwrap(BarJump.plan(grid: grid, position: 0, duration: 20, playing: false, bars: -32))
            XCTAssertGreaterThanOrEqual(edge.position, 0)
            XCTAssertLessThan(edge.position, 2)
            XCTAssertEqual(edge.bars, 0)
        }
    }
    func testLoopBoundsLimitJumpAndShortOrInvalidGridsRejectCleanly() throws {
        let grid = try BeatGrid(bpm: 120)
        let jump = try XCTUnwrap(BarJump.plan(grid: grid, position: 4.5, duration: 12, playing: true, bars: 32, loop: 4...8))
        XCTAssertEqual(jump.bars, 2)
        XCTAssertEqual(jump.position, 8.5)
        XCTAssertNil(BarJump.plan(grid: grid, position: .nan, duration: 12, playing: true, bars: 1))
        XCTAssertNil(BarJump.plan(grid: grid, position: 0, duration: 0, playing: false, bars: 1))
        XCTAssertNil(BarJump.plan(grid: try BeatGrid(bpm: 120, offsetMs: 1500), position: 0, duration: 1, playing: false, bars: 1))
    }
}
