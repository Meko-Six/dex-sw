import XCTest
@testable import DexCore

final class WaveformDataTests: XCTestCase {
    private func packed(_ values: [(Float, Float)]) -> Data {
        var bytes = Data()
        for (peak, rms) in values { WaveformData.append(WaveformBin(peak: peak, rms: rms, low: rms, mid: 0, high: 0), to: &bytes) }
        return bytes
    }
    func testPyramidPreservesTransientAndWeightsPartialLastBin() throws {
        let data = try WaveformData(sampleRate: 1000, sourceFrames: 5, framesPerBin: 2,
                                    payload: packed([(1, 0.5), (0.25, 0.25), (0.8, 0.8)]))
        let top = try XCTUnwrap(data.levels.last?.sample(at: 0))
        XCTAssertEqual(top.peak, 1)
        let energy: Double = 0.5 * 0.5 * 2 + 0.25 * 0.25 * 2 + 0.8 * 0.8
        XCTAssertEqual(Double(top.rms), sqrt(energy / 5), accuracy: 0.001)
        XCTAssertLessThan(data.residentBytes, data.basePayload.count * 2 + 20)
        XCTAssertEqual(data.level(secondsPerPixel: 0.002).count, 3)
        XCTAssertEqual(data.level(secondsPerPixel: 1).count, 1)
    }
    func testMalformedAndOversizedDataAreRejectedBeforeAllocation() {
        let one = packed([(1, 0.5)])
        for (rate, frames, step, payload) in [(Double.nan, Int64(1), Int64(1), one), (48000, -1, 1, one),
                                           (48000, 1, 0, one), (48000, Int64.max, 1, one),
                                           (48000, 1, Int64.max, one), (48000, 300000, 1, one),
                                           (48000, 2, 1, one), (48000, 1, 1, Data(repeating: 255, count: 10))] {
            XCTAssertThrowsError(try WaveformData(sampleRate: rate, sourceFrames: frames, framesPerBin: step, payload: payload))
        }
    }
    func testTempoAwareViewportAlignsSyncedBeatsAndLeavesHeadroom() throws {
        let a = WaveformViewport(position: 50, outputSpan: 8, rate: 1)
        let b = WaveformViewport(position: 80, outputSpan: 8, rate: 120.0 / 125)
        XCTAssertEqual(a.fraction(at: 50), 0.5)
        XCTAssertEqual(b.fraction(at: 80), 0.5, accuracy: 1e-12)
        XCTAssertEqual(a.fraction(at: 50.5) - 0.5, b.fraction(at: 80 + 60.0 / 125) - 0.5, accuracy: 1e-10)
        XCTAssertEqual(a.sourceTime(at: a.fraction(at: 51)), 51)
        XCTAssertLessThan(WaveformScale.peak(1), 1)
        XCTAssertLessThan(WaveformScale.body(1), WaveformScale.peak(1))
        XCTAssertGreaterThan(WaveformScale.body(0.5), WaveformScale.body(0.1))
    }
}
