import XCTest
@testable import DexConsole

/// The sheets' rules: grid edits, Camelot keys, cue times and line breaks.
final class SheetMathTests: XCTestCase {
    private let grid = ConsoleState.Grid(bpm: 120, offsetMs: 100, confidence: 0.9)

    func testGridEditsFoldAtTheBar() {
        // A 120 BPM bar is 2000 ms: offsets fold into it and keep their phase.
        XCTAssertEqual(GridEdits.nudge(grid, -101).offsetMs, 1999, accuracy: 1e-9)
        XCTAssertEqual(GridEdits.offset(grid, 4100).offsetMs, 100, accuracy: 1e-9)
        let doubled = GridEdits.tempo(grid, 240)
        XCTAssertEqual(doubled.bpm, 240)
        XCTAssertEqual(doubled.offsetMs, 100, accuracy: 1e-9)
        XCTAssertEqual(doubled.confidence, 0.9)
        XCTAssertEqual(GridEdits.tempo(grid, 500).bpm, 300)
    }

    func testTakingAReadingPutsTheOldOneBack() {
        let alternates = [ConsoleState.Library.Alternate(bpm: 80, offsetMs: 10, relation: "2/3"),
                          ConsoleState.Library.Alternate(bpm: 160, offsetMs: 20, relation: "4/3")]
        let (next, list) = GridEdits.take(alternates[0], from: grid, alternates: alternates)
        XCTAssertEqual(next, ConsoleState.Grid(bpm: 80, offsetMs: 10, confidence: 0.9))
        XCTAssertEqual(list.map(\.bpm), [120, 160])
        XCTAssertEqual(list.map(\.relation), ["3/2", "2"])
        XCTAssertEqual(GridEdits.invert("2"), "1/2")
        XCTAssertEqual(GridEdits.invert("1/2"), "2")
    }

    func testCamelotNeighboursAndOrder() {
        XCTAssertEqual(Camelot.compatible("12A"), ["12A", "11A", "1A", "12B"])
        XCTAssertEqual(Camelot.compatible("1B"), ["1B", "12B", "2B", "1A"])
        XCTAssertLessThan(Camelot.rank("1B"), Camelot.rank("2A"))
        XCTAssertLessThan(Camelot.rank("12B"), Camelot.rank(nil))
        XCTAssertNil(Camelot.parse("13A"))
    }

    func testCueTimesAndTapRatios() {
        XCTAssertEqual(cueTime(104.79), "1:44.7")
        XCTAssertEqual(cueTime(-1), "0:00.0")
        XCTAssertEqual(tapTempoRatio(128, 133)!, 128 / 133, accuracy: 1e-12)
        XCTAssertEqual(tapTempoRatio(200, 100), 1.16)
        XCTAssertNil(tapTempoRatio(0, 120))
    }

    func testLinesBreakGreedilyLikeCSS() {
        let face = Face.ui(16)
        let breaker = LineBreaker(runs: [Para.Run("Headphone CUE on the focused deck", face)])
        // 271.47 pt in one line: in a 271 pt column the last word goes down
        // alone, where the system's own wrapping would take two words down.
        XCTAssertEqual(breaker.lines(width: 271).map { $0.map(\.text).joined() }, ["Headphone CUE on the focused", "deck"])
        XCTAssertEqual(breaker.lines(width: 272).count, 1)
        XCTAssertEqual(breaker.natural, face.width(of: "Headphone CUE on the focused deck"), accuracy: 1e-9)
    }
}
