import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

final class WaveformEnvelopeTests: XCTestCase {
    private func envelope(hz: Double, phase: Float = 1, chunk: Int = 1024) throws -> TrackWaveform {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let builder = try WaveformEnvelopeBuilder(format: format, frames: 48017, chunkFrames: UInt32(chunk))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(chunk))!
        var cursor = 0
        while cursor < 48017 {
            let n = min(chunk, 48017 - cursor); buffer.frameLength = UInt32(n)
            for i in 0..<n {
                let value = Float(sin(Double(i + cursor) * 2 * .pi * hz / 48000)) * 0.5
                buffer.floatChannelData![0][i] = value
                buffer.floatChannelData![1][i] = value * phase
            }
            try builder.consume(buffer); cursor += n
        }
        return try builder.finish(frames: 48017)
    }
    func testFrequencyBandsAndAntiphaseStereoKeepEnergy() throws {
        for (hz, band) in [(70.0, 0), (1000.0, 1), (10000.0, 2)] {
            let wave = try envelope(hz: hz, phase: -1)
            let bin = try XCTUnwrap(wave.data.levels[0].sample(at: 100))
            let bands = [bin.low, bin.mid, bin.high]
            XCTAssertEqual(bands.firstIndex(of: bands.max()!), band)
            XCTAssertGreaterThan(bin.rms, 0.3, "Opposite stereo phase must not cancel the display")
            XCTAssertGreaterThan(bin.peak, 0.49)
        }
    }
    func testChunkIndependenceIncludesFinalPartialBinAndCacheRoundTrip() throws {
        let a = try envelope(hz: 1000, chunk: 1024), b = try envelope(hz: 1000, chunk: 16384)
        XCTAssertEqual(a.data.basePayload, b.data.basePayload)
        XCTAssertEqual(a.data.levels[0].count, 201)
        let restored = try TrackWaveform.decode(sampleRate: a.data.sampleRate, frames: a.data.sourceFrames,
                                                step: a.data.framesPerBin, payload: a.data.basePayload)
        XCTAssertEqual(restored.data.basePayload, a.data.basePayload)
        XCTAssertEqual(restored.data.levels.last?.sample(at: 0), a.data.levels.last?.sample(at: 0))
    }
    func testLongTrackReservationIsBoundedAndReleased() throws {
        let before = AudioMemoryBudget.shared.reservedBytes
        let format = AVAudioFormat(standardFormatWithSampleRate: 192000, channels: 2)!
        do {
            let builder = try WaveformEnvelopeBuilder(format: format, frames: 192000 * 60 * 120, chunkFrames: 16384)
            withExtendedLifetime(builder) {
                XCTAssertGreaterThan(AudioMemoryBudget.shared.reservedBytes, before)
                XCTAssertLessThanOrEqual(AudioMemoryBudget.shared.reservedBytes - before, 5 * 1024 * 1024 + 65536)
            }
        }
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, before)
    }
}
