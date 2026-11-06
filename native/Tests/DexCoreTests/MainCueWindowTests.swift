import XCTest
@testable import DexCore

final class MainCueWindowTests: XCTestCase {
    func testLateMainCuePressesRetainIntendedBeatAndAdvanceAtIncomingRate() throws {
        for bpm in [40.0, 120, 300] {
            let grid = try BeatGrid(bpm: bpm, offsetMs: 137)
            for rate in [0.84, 1.0, 1.16] {
                let beat = grid.beatSeconds / rate
                let window = min(0.150, beat * 0.30)
                for cueRate in [0.84, 1.0, 1.16] {
                    for late in [0.0, window / 2, window] {
                        let timing = MixMath.cueLaunchTiming(position: grid.time(atBeat: 12) + late * rate,
                                                            referenceRate: rate, referenceGrid: grid, cueRate: cueRate)
                        XCTAssertEqual(timing.delay, 0.12, accuracy: 1e-8)
                        XCTAssertEqual(timing.sourceOffset, (0.12 + late) * cueRate, accuracy: 1e-8)
                    }
                    let outside = window + 0.001
                    let timing = MixMath.cueLaunchTiming(position: grid.time(atBeat: 12) + outside * rate,
                                                        referenceRate: rate, referenceGrid: grid, cueRate: cueRate)
                    XCTAssertEqual(timing.delay, max(0.12, beat - outside), accuracy: 1e-8)
                    XCTAssertEqual(timing.sourceOffset, max(0, 0.12 - (beat - outside)) * cueRate, accuracy: 1e-8)
                }
            }
        }
    }
    func testEarlyPreparationDoesNotDiscardIntendedBeatAndQueuedTimestampCanStayLate() throws {
        let grid = try BeatGrid(bpm: 120, offsetMs: 137)
        let early = MixMath.cueLaunchTiming(position: grid.time(atBeat: 8) - 0.08,
                                           referenceRate: 1, referenceGrid: grid, cueRate: 1.16)
        XCTAssertEqual(early.delay, 0.12, accuracy: 1e-9)
        XCTAssertEqual(early.sourceOffset, 0.04 * 1.16, accuracy: 1e-9)
        let queued = MixMath.cueLaunchTiming(position: grid.time(atBeat: 8) + 0.14,
                                            referenceRate: 1, referenceGrid: grid, cueRate: 0.84, preparation: 0.2)
        XCTAssertEqual(queued.delay, 0.2, accuracy: 1e-9)
        XCTAssertEqual(queued.sourceOffset, 0.34 * 0.84, accuracy: 1e-9)
    }
}
