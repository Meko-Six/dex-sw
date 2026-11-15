import AVFoundation
import XCTest
import DexCore
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
        let highs = stride(from: 1, to: values.count, by: GridWaveBuilder.stride).map { values[$0] }
        XCTAssertEqual(highs.firstIndex { $0 > 0 }, 7, "2 ms is the eighth quarter-millisecond column")
        XCTAssertEqual(highs[7], 0.6, accuracy: 0.001, "The channels are averaged")
        XCTAssertEqual(highs.filter { $0 > 0 }.count, 1)
    }

    func testColumnsPastEitherEndAreEmpty() throws {
        let url = try click(at: 100)
        let before = try GridWaveReader.read(url: url, start: -0.01, perColumn: 0.001, columns: 20)
        XCTAssertEqual(before.count, 20 * GridWaveBuilder.stride)
        let highs = stride(from: 1, to: before.count, by: GridWaveBuilder.stride).map { before[$0] }
        XCTAssertEqual(highs.filter { $0 != 0 }.count, 1, "The click, at 2.3 ms into the file, once")
        XCTAssertEqual(highs.firstIndex { $0 > 0 }, 12)
        XCTAssertEqual((0..<12).map { GridWaveBuilder.column(before, $0) }, Array(repeating: .empty, count: 12), "Nothing before the click")
        let after = try GridWaveReader.read(url: url, start: 2, perColumn: 0.001, columns: 20)
        XCTAssertEqual(after, [Float](repeating: 0, count: 20 * GridWaveBuilder.stride))
    }

    /// One second of a sine at `hz`, mono.
    private func tone(_ hz: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for n in 0..<44_100 { buffer.floatChannelData![0][n] = Float(0.5 * sin(2 * .pi * hz * Double(n) / 44_100)) }
        try file.write(from: buffer)
        return url
    }

    func testEachToneLightsItsOwnBand() throws {
        // Mid-file, after the warm-up, so the filters have settled.
        func bands(_ hz: Double) throws -> (mid: Float, top: Float) {
            let values = try GridWaveReader.read(url: try tone(hz), start: 0.5, perColumn: 0.01, columns: 4)
            let column = GridWaveBuilder.column(values, 2)
            XCTAssertEqual(column.high, 0.5, accuracy: 0.01)
            return (column.mid, column.top)
        }
        let bass = try bands(60), vocal = try bands(1_000), hat = try bands(10_000)
        XCTAssertLessThan(bass.mid, 0.1); XCTAssertLessThan(bass.top, 0.01)
        XCTAssertGreaterThan(vocal.mid, 0.4); XCTAssertLessThan(vocal.top, 0.05)
        XCTAssertGreaterThan(hat.top, 0.45); XCTAssertLessThan(hat.mid, 0.1)
    }
}
