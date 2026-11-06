import XCTest
import AVFoundation
@testable import DexAudio

final class WaveformTests: XCTestCase {
    func testChunkBoundariesAndStereoPeaks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for frame in 0..<48_000 {
                buffer.floatChannelData![0][frame] = 0
                buffer.floatChannelData![1][frame] = frame >= 24_000 ? -0.75 : 0.25
            }
            try file.write(from: buffer)
        }
        let small = try WaveformReader.read(url: url, bins: 8, chunkFrames: 1024)
        let large = try WaveformReader.read(url: url, bins: 8, chunkFrames: 16_384)
        XCTAssertEqual(small.decodedFrames, 48_000)
        XCTAssertEqual(small.duration, 1, accuracy: 1e-9)
        XCTAssertEqual(small.peaks, large.peaks)
        XCTAssertEqual(small.peaks[0], 0.25, accuracy: 1e-5)
        XCTAssertEqual(small.peaks[7], 0.75, accuracy: 1e-5)
        XCTAssertEqual(small.bufferCapacity, 1024)
        XCTAssertNotNil(small.waveform)
        XCTAssertEqual(small.waveform?.data.basePayload, large.waveform?.data.basePayload)
        XCTAssertGreaterThan(small.waveform!.data.levels[0].sample(at: 150)!.rms, 0.74, "Right-only audio must stay visible")
        XCTAssertThrowsError(try WaveformReader.read(url: url, bins: Int.max))
    }
}
