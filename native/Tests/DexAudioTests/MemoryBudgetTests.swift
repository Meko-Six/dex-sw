import XCTest
import AVFoundation
@testable import DexAudio

/// The engine's cache is fixed memory: counted, but never taken from the room loads and
/// analysis need, memory pressure included.
final class MemoryBudgetTests: XCTestCase {
    func testFixedMemoryLeavesThePreparationLimitAlone() throws {
        let budget = AudioMemoryBudget(limit: 1_000)
        var cache: AudioMemoryBudget.Lease? = budget.reserveFixed(5_000)
        XCTAssertEqual(budget.reservedBytes, 5_000)
        var load: AudioMemoryBudget.Lease? = try budget.reserve(1_000)
        XCTAssertThrowsError(try budget.reserve(1), "The preparation limit still holds")
        load = nil
        budget.setPressure(true)
        XCTAssertNoThrow(try budget.reserve(500), "Under pressure the preparation half is still there")
        XCTAssertThrowsError(try budget.reserve(501))
        budget.setPressure(false)
        withExtendedLifetime((cache, load)) {}
        cache = nil
        XCTAssertEqual(budget.reservedBytes, 0)
    }

    /// Two engines alive at once, as when one shuts down while the next starts, and memory
    /// pressure on top: a track still loads.
    @MainActor func testATrackLoadsUnderPressureBesideTwoEngines() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for channel in 0..<2 { for frame in 0..<48_000 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.3 } }
            for _ in 0..<30 { try file.write(from: buffer) }
        }
        let other = NativeMixer(); defer { other.shutdown() }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        AudioMemoryBudget.shared.setPressure(true)
        defer { AudioMemoryBudget.shared.setPressure(false) }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(mixer.a.error)
        XCTAssertNotNil(mixer.a.waveform)
        XCTAssertEqual(mixer.a.duration, 30, accuracy: 0.01)
    }
}
