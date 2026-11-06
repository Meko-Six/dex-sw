import XCTest
import DexCore
@testable import DexConsole

final class GestureMathTests: XCTestCase {
    func testPlatterTurnsTwoBeatsARound() {
        XCTAssertEqual(platterBeatDelta(0, .pi / 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(platterBeatDelta(.pi / 2, 0), -0.5, accuracy: 1e-12)
        // Across the ±π seam it takes the short way.
        XCTAssertEqual(platterBeatDelta(3, -3), (2 * .pi - 6) / .pi, accuracy: 1e-12)
    }

    func testTempoFaderRoundTrips() {
        for rate in [0.84, 0.97, 1, 1.0231, 1.16] {
            XCTAssertEqual(MixerMath.faderToTempo(MixerMath.tempoToFader(rate)), rate, accuracy: 1e-12)
        }
        XCTAssertEqual(MixerMath.tempoToFader(0.84), 1, accuracy: 1e-12)
    }

    /// One bin per 0.1 s, bands rising with the bin number.
    private func ramp(bins: Int) throws -> WaveformData {
        var payload = Data()
        for i in 0..<bins {
            let v = Float(i) / Float(bins)
            WaveformData.append(WaveformBin(peak: v, rms: v, low: v, mid: v / 2, high: v / 4), to: &payload)
        }
        return try WaveformData(sampleRate: 1_000, sourceFrames: Int64(bins) * 100, framesPerBin: 100, payload: payload)
    }

    func testEnvelopesReadTheLevelThatFitsAColumn() throws {
        let data = try ramp(bins: 64)
        // 0.2 s a column reads the level that pools bin pairs by energy, as Electron's pyramid does.
        let envelopes = TrackWave.envelopes(data, first: 0, perPixel: 0.2, columns: 32)
        let pooled = { (a: Double, b: Double) in Float(((a * a + b * b) / 2).squareRoot() / 64) }
        XCTAssertEqual(envelopes[0], pooled(0, 1), accuracy: 1e-3)
        XCTAssertEqual(envelopes[10 * 3], pooled(20, 21), accuracy: 1e-3)
        XCTAssertEqual(envelopes[10 * 3 + 1], pooled(20, 21) / 2, accuracy: 1e-3)
        XCTAssertEqual(envelopes[10 * 3 + 2], pooled(20, 21) / 4, accuracy: 1e-3)
        // Coarser than any level, each column takes its loudest bin.
        let wide = TrackWave.envelopes(data, first: 0, perPixel: 6.4, columns: 1)
        XCTAssertEqual(wide[0], data.levels.last!.sample(at: 0)!.low)
    }

    func testEnvelopesBlendBinsWhenZoomedPastTheData() throws {
        let data = try ramp(bins: 64)
        // 0.05 s a column: column 2 is centred at 0.125 s, three quarters of the way from bin 0's centre to bin 1's.
        let envelopes = TrackWave.envelopes(data, first: 0, perPixel: 0.05, columns: 8)
        XCTAssertEqual(envelopes[2 * 3], 0.75 / 64, accuracy: 1e-4)
        // Before the track starts, nothing.
        XCTAssertEqual(TrackWave.envelopes(data, first: -8, perPixel: 0.05, columns: 4), [Float](repeating: 0, count: 12))
    }
}
