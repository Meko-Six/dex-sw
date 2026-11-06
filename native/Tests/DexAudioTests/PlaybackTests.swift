import XCTest
import AVFoundation
@testable import DexAudio

final class PlaybackTests: XCTestCase {
    /// Records the actual file -> player -> time-pitch -> EQ -> mixer graph.
    /// Uses an unequal sample rate to catch file-frame/output-frame confusion.
    @MainActor
    func testFilePlaybackSeekAndPlayingDeckProtection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
            pcm.frameLength = 88_200
            for i in 0..<88_200 {
                pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.2
            }
            try file.write(from: pcm)
        }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<200 where mixer.a.loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(mixer.a.loading)
        XCTAssertNil(mixer.a.error)
        XCTAssertEqual(mixer.a.duration, 2, accuracy: 1e-6)
        mixer.crossfader = 0
        mixer.a.level = 1
        mixer.volume = 0.5
        mixer.start()
        XCTAssertNil(mixer.error)
        mixer.a.togglePlay()
        XCTAssertTrue(mixer.a.playing)
        mixer.a.load(url)
        XCTAssertNotNil(mixer.a.error, "Replacing an audible deck must be rejected")
        let output = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
            frameCapacity: 1024)!
        var peak: Float = 0
        for _ in 0..<40 {
            let status = try mixer.renderOffline(into: output)
            if status == .success {
                for frame in 0..<Int(output.frameLength) {
                    peak = max(peak, abs(output.floatChannelData![0][frame]))
                }
            }
        }
        XCTAssertGreaterThan(peak, 0.01, "Production graph must produce audio")
        XCTAssertLessThan(peak, 0.3, "Mixer gain must be applied")
        // The waveform moves when the new audio is heard, not on the press.
        mixer.a.seek(to: 1)
        for _ in 0..<10 { _ = try mixer.renderOffline(into: output) }
        mixer.a.refreshPosition()
        XCTAssertGreaterThanOrEqual(mixer.a.position, 1)
        // The seek lands on the next block, so the bound is all that was rendered since, less
        // the delay after the engine: never ahead of the sound.
        XCTAssertLessThan(mixer.a.position, 1 + 10 * 1024 / 48_000 - mixer.a.outputDelay + 1e-6)
        mixer.a.togglePlay()
        XCTAssertFalse(mixer.a.playing)
        mixer.a.seek(to: -1)
        XCTAssertEqual(mixer.a.position, 0)
        mixer.a.seek(to: 20)
        XCTAssertEqual(mixer.a.position, 2)
    }
}
