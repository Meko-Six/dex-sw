import XCTest
import AVFoundation
import Dispatch
@testable import DexAudio

final class AudioControlTests: XCTestCase {
    /// A deliberately slow framework operation must not block the main actor.
    /// Invalidation while it waits must win over its eventual completion.
    @MainActor
    func testBlockedControlLaneKeepsUIResponsiveAndCancelsStaleStart() async throws {
        await AudioControlExecutor.shared.drain()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let signal = AsyncStream<Bool>.makeStream()
        AudioControlExecutor.shared.submit {
            signal.continuation.yield(!Thread.isMainThread)
            signal.continuation.finish()
            _ = gate.wait(timeout: .now() + 3)
        }
        var iterator = signal.stream.makeAsyncIterator()
        let offMain = await iterator.next()
        XCTAssertEqual(offMain, true)
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        mixer.start()
        XCTAssertEqual(mixer.audioState, .recovering)
        XCTAssertFalse(mixer.a.audioAvailable)
        await Task.yield() // Let activation queue behind the blocked operation.
        mixer.handle(.interruptionBegan)
        XCTAssertEqual(mixer.audioState, .interrupted)
        mixer.handle(.interruptionEnded(shouldResume: true))
        await Task.yield()
        mixer.shutdown()
        gate.signal()
        await AudioControlExecutor.shared.drain()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(mixer.audioState, .unavailable)
        XCTAssertFalse(mixer.a.audioAvailable)
        XCTAssertFalse(mixer.a.playing)
        XCTAssertNil(mixer.error)
    }

    /// Exercise the real queued player path while rendering deterministically.
    /// Stop/start/seek supersession must never let a retired stop kill the last
    /// schedule, and stale schedules must not leave earlier source audio playing.
    @MainActor
    func testQueuedStopsAndLatestSchedulePreserveAudioAndReleaseOwnership() async throws {
        let before = AudioMemoryBudget.shared.reservedBytes
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("regions.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for second in 0..<4 {
                for i in 0..<48000 {
                    buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * (second < 2 ? 220 : 880) / 48000)) * 0.2
                    buffer.floatChannelData![1][i] = 0
                }
                try file.write(from: buffer)
            }
        }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(mixer.a.error)
        mixer.start(); mixer.crossfader = 0
        // The commands queue up behind a stalled read from disk.
        mixer.loaderHeld = true
        mixer.a.seek(to: 0.25); mixer.a.togglePlay()
        mixer.a.seek(to: 1.5)
        mixer.a.togglePlay() // Cancels both earlier schedules before they run.
        mixer.a.seek(to: 2.25); mixer.a.togglePlay()
        mixer.loaderHeld = false
        XCTAssertTrue(mixer.a.playing)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = []
        for block in 0..<30 {
            if try mixer.renderOffline(into: output) == .success && block >= 15 {
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
        }
        func energy(_ hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (i, sample) in samples.enumerated() {
                let phase = 2 * .pi * hz * Double(i) / 48000
                real += Double(sample) * cos(phase); imaginary += Double(sample) * sin(phase)
            }
            return hypot(real, imaginary) / Double(max(1, samples.count))
        }
        XCTAssertGreaterThan(energy(880), 0.01)
        XCTAssertLessThan(energy(220), 0.005)
        mixer.shutdown()
        await AudioControlExecutor.shared.drain()
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, before)
    }
}
