import XCTest
@testable import DexConsole

final class GridWindowTests: XCTestCase {
    func testTheWindowCentresAndStaysInsideTheTrack() {
        XCTAssertEqual(GridWindow.start(centred: 24, span: 2, duration: 384), 23)
        XCTAssertEqual(GridWindow.start(centred: 0.5, span: 2, duration: 384), 0)
        XCTAssertEqual(GridWindow.start(centred: 384, span: 2, duration: 384), 382)
        XCTAssertEqual(GridWindow.start(centred: 1, span: 8, duration: 4), 0, "A track shorter than the window starts at 0")
    }

    func testStepsLandOnTheNextGridLineEitherWay() {
        // 120 BPM: a line every half second, starting at 0.1 s.
        XCTAssertEqual(GridWindow.line(after: 10, direction: 1, bpm: 120, offsetMs: 100), 10.1, accuracy: 1e-9)
        XCTAssertEqual(GridWindow.line(after: 10, direction: -1, bpm: 120, offsetMs: 100), 9.6, accuracy: 1e-9)
    }

    func testAStepFromALineMovesToTheNextOne() {
        XCTAssertEqual(GridWindow.line(after: 10.1, direction: 1, bpm: 120, offsetMs: 100), 10.6, accuracy: 1e-9)
        XCTAssertEqual(GridWindow.line(after: 10.1, direction: -1, bpm: 120, offsetMs: 100), 9.6, accuracy: 1e-9)
    }

    func testSamplesReadOutTheWindowAndNothingBeyondThem() {
        let samples = GridSamples(start: 10, perColumn: 1, values: [-1, 1, -2, 2, -3, 3])
        XCTAssertEqual(samples.columns(from: 11, count: 2).map(\.1), [2, 3])
        XCTAssertEqual(samples.columns(from: 12, count: 2).map(\.1), [3, 0])
        XCTAssertEqual(samples.columns(from: 9, count: 2).map(\.1), [0, 1])
    }
}
