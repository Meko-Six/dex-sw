import XCTest
import AVFoundation
@testable import DexAudio

/// The engine's change signal reaches the main actor: once for a burst, and not while nothing changes.
final class EngineChangesTests: XCTestCase {
    @MainActor
    func testChangesWakeTheMainActorAndQuietDoesNot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 10)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.1; buffer.floatChannelData![1][i] = 0.1 }
            try file.write(from: buffer)
        }
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        mixer.start()
        var wakes = 0
        mixer.core.notifyChanges { wakes += 1 }
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        func render(_ seconds: Double) throws { for _ in 0..<Int(seconds * 48_000 / 256) { _ = try mixer.renderOffline(into: block) } }
        func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

        mixer.a.togglePlay()
        try render(0.5)
        try await settle()
        XCTAssertGreaterThan(wakes, 0, "Starting to play is a change")
        // A burst rendered faster than the main actor runs is at most a few wakes, not one a block.
        XCTAssertLessThan(wakes, 10)
        let afterStart = wakes
        try render(2)
        try await settle()
        XCTAssertEqual(wakes, afterStart, "Playing on changes nothing")
        mixer.a.togglePlay()
        try render(0.1)
        try await settle()
        XCTAssertGreaterThan(wakes, afterStart, "A pause is a change")
    }
}
