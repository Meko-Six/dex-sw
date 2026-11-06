import DexEngineBenchKit
import Foundation
import XCTest

/// The gate 2 measurements as one run, muted. Skipped unless asked for: DEX_ENGINE_BENCH=1.
final class StretcherBenchTests: XCTestCase {
    func testMeasureOnThisDevice() throws {
        guard ProcessInfo.processInfo.environment["DEX_ENGINE_BENCH"] == "1" else {
            throw XCTSkip("Set DEX_ENGINE_BENCH=1 to measure the stretchers on this device.")
        }
        try DeviceBench.run { print($0) }
    }
}
