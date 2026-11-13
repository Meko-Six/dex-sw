import XCTest
import AVFoundation
@testable import DexAudio

/// A deck that plays to the end stops when the end is heard, not before, and rests there.
final class EndOfTrackTests: XCTestCase {
    @MainActor
    func testTheDeckStopsWhenTheEndIsHeard() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let value = Float(sin(2 * .pi * 440 * Double(i) / 48_000)) * 0.2
                buffer.floatChannelData![0][i] = value
                buffer.floatChannelData![1][i] = value
            }
            try file.write(from: buffer)
        }
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(mixer.a.error)
        mixer.start()
        mixer.a.seek(to: 2)
        mixer.a.togglePlay()
        let started = mixer.a.audioNow()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var stoppedAt: Double?
        for _ in 0..<(48_000 * 3 / 256) {
            _ = try mixer.renderOffline(into: buffer)
            mixer.a.refreshPosition()
            if stoppedAt == nil, !mixer.a.playing { stoppedAt = mixer.a.audioNow() }
        }
        let stopped = try XCTUnwrap(stoppedAt, "The deck must stop at the end of the track")
        // One second of track from the start, heard the output delay later; a block either way.
        let heard = started + 1 + mixer.a.outputDelay
        print(String(format: "end heard at %.4f s, deck stopped at %.4f s", heard, stopped))
        XCTAssertGreaterThanOrEqual(stopped, heard - 256.0 / 48_000)
        XCTAssertLessThan(stopped, heard + 0.05)
        XCTAssertFalse(mixer.a.playing)
        XCTAssertEqual(mixer.a.position, mixer.a.duration, accuracy: 1e-9)
    }
}
