import XCTest
import AVFoundation
@testable import DexAudio

final class TempoDetectionTests: XCTestCase {
    private func fixture(bpm: Double, offset: Double, rate: Double, seconds: Int = 24, noiseOnly: Bool = false, rightOnly: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: rightOnly ? 2 : 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate))!
        pcm.frameLength = UInt32(rate)
        let period = 60 / bpm
        var random: UInt64 = 42
        for second in 0..<seconds {
            for i in 0..<Int(rate) {
                let time = Double(second) + Double(i) / rate - offset
                var sample = 0.0
                if noiseOnly {
                    random = random &* 6364136223846793005 &+ 1
                    sample = (Double(random >> 32) / Double(UInt32.max) * 2 - 1) * 0.1
                } else if time >= 0 {
                    let phase = time - floor(time / period) * period
                    let beat = Int(floor(time / period))
                    let frequency = 46 + 130 * exp(-phase * 34)
                    sample = sin(2 * .pi * frequency * phase) * exp(-phase * 9) * (beat % 4 == 0 ? 0.8 : 0.65)
                    if phase < 0.006 { sample += sin(2 * .pi * 3500 * phase) * exp(-phase * 600) * 0.15 }
                    let hatPhase = phase - period / 2
                    if hatPhase >= 0 { sample += sin(2 * .pi * 4300 * hatPhase) * exp(-hatPhase * 80) * 0.1 }
                }
                pcm.floatChannelData![0][i] = rightOnly ? 0 : Float(sample)
                if rightOnly { pcm.floatChannelData![1][i] = Float(sample) }
            }
            try file.write(from: pcm)
        }
        return url
    }
    func testBPMAndKickOffsetAcrossSampleRates() throws {
        for (bpm, rate) in [(100.0, 32_000.0), (123.4, 44_100.0), (128.0, 48_000.0), (174.0, 48_000.0)] {
            let url = try fixture(bpm: bpm, offset: 0.173, rate: rate)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try WaveformReader.read(url: url)
            let grid = try XCTUnwrap(result.detection.grid)
            let period = 60 / bpm
            let phase = (grid.offsetMs / 1000 - 0.173).truncatingRemainder(dividingBy: period)
            let error = min(abs(phase), abs(abs(phase) - period))
            print("DETECT expected=\(bpm) rate=\(rate) bpm=\(grid.bpm) offsetMs=\(grid.offsetMs) phaseErrorMs=\(error * 1000) confidence=\(grid.confidence)")
            XCTAssertEqual(grid.bpm, bpm, accuracy: 0.06)
            XCTAssertLessThan(error, 0.008)
        }
    }
    func testChunkSizeDoesNotChangeDetectedGrid() throws {
        let url = try fixture(bpm: 127.6, offset: 0.25, rate: 44_100, seconds: 16)
        defer { try? FileManager.default.removeItem(at: url) }
        let small = try WaveformReader.read(url: url, chunkFrames: 1024)
        let large = try WaveformReader.read(url: url, chunkFrames: 32_768)
        XCTAssertEqual(small.detection.grid, large.detection.grid)
        XCTAssertEqual(small.peaks, large.peaks)
    }
    func testNoiseAndShortClipsDoNotInventUsableGrid() throws {
        let noise = try fixture(bpm: 120, offset: 0, rate: 48_000, seconds: 12, noiseOnly: true)
        let short = try fixture(bpm: 120, offset: 0, rate: 48_000, seconds: 3)
        defer { try? FileManager.default.removeItem(at: noise); try? FileManager.default.removeItem(at: short) }
        XCTAssertNil(try WaveformReader.read(url: noise).detection.grid)
        XCTAssertNil(try WaveformReader.read(url: short).detection.grid)
    }
    func testStereoAnalysisIncludesTheRightChannel() throws {
        let url = try fixture(bpm: 128, offset: 0.173, rate: 48_000, rightOnly: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try WaveformReader.read(url: url)
        let grid = try XCTUnwrap(result.detection.grid)
        XCTAssertEqual(grid.bpm, 128, accuracy: 0.06)
    }

    @MainActor
    func testLoadCommitsLatestDetectedGridAndAllowsManualCorrection() async throws {
        let first = try fixture(bpm: 128, offset: 0.173, rate: 48_000, seconds: 16)
        let latest = try fixture(bpm: 124, offset: 0.25, rate: 48_000, seconds: 16)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: latest) }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        mixer.a.load(first)
        mixer.a.load(latest)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading)
        XCTAssertNil(mixer.a.error)
        XCTAssertEqual(try XCTUnwrap(mixer.a.grid).bpm, 124, accuracy: 0.06)
        XCTAssertEqual(mixer.a.name, latest.deletingPathExtension().lastPathComponent)
        mixer.a.setGrid(bpm: 123, offsetMs: 10)
        XCTAssertEqual(mixer.a.grid?.bpm, 123)
        XCTAssertEqual(mixer.a.grid?.offsetMs, 10)
        XCTAssertFalse(mixer.a.gridUncertain)
    }

}
