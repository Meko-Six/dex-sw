import AVFoundation
import XCTest
@testable import DexAudio

final class GridWaveReaderTests: XCTestCase {
    /// One second of silence at 44.1 kHz, stereo, with a click on `frame`.
    private func click(at frame: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        buffer.floatChannelData![0][frame] = 0.8
        buffer.floatChannelData![1][frame] = 0.4
        try file.write(from: buffer)
        return url
    }

    func testAClickLandsInItsColumnFinerThanTheStoredEnvelope() throws {
        // 0.25 ms columns from 0.5 s; the click is 2 ms later, under the envelope's 5 ms bin.
        let url = try click(at: 22_050 + 88)
        let values = try GridWaveReader.read(url: url, start: 0.5, perColumn: 0.00025, columns: 40)
        let highs = stride(from: 1, to: values.count, by: 2).map { values[$0] }
        XCTAssertEqual(highs.firstIndex { $0 > 0 }, 7, "2 ms is the eighth quarter-millisecond column")
        XCTAssertEqual(highs[7], 0.6, accuracy: 0.001, "The channels are averaged")
        XCTAssertEqual(highs.filter { $0 > 0 }.count, 1)
    }

    func testColumnsPastEitherEndAreEmpty() throws {
        let url = try click(at: 100)
        let before = try GridWaveReader.read(url: url, start: -0.01, perColumn: 0.001, columns: 20)
        XCTAssertEqual(before.count, 40)
        XCTAssertEqual(before.filter { $0 != 0 }.count, 1, "The click, at 2.3 ms into the file, once")
        let highs = stride(from: 1, to: before.count, by: 2).map { before[$0] }
        XCTAssertEqual(highs.firstIndex { $0 > 0 }, 12)
        let after = try GridWaveReader.read(url: url, start: 2, perColumn: 0.001, columns: 20)
        XCTAssertEqual(after, [Float](repeating: 0, count: 40))
    }
}
