import XCTest
import AVFoundation
@testable import DexAudio

final class CueTests: XCTestCase {
    @MainActor
    func testHeldCueReleaseAndPlayLatchProduceExpectedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
            pcm.frameLength = 144_000
            for i in 0..<144_000 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.3 }
            try file.write(from: pcm)
        }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(mixer.a.error)
        mixer.start()
        mixer.crossfader = 0
        let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 1024)!
        func renderPeak() throws -> Float {
            var peak: Float = 0
            for block in 0..<30 {
                let status = try mixer.renderOffline(into: output)
                if status == .success, block > 10 {
                    for frame in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][frame])) }
                }
            }
            return peak
        }
        mixer.a.seek(to: 0.25)
        mixer.a.cueDown()
        XCTAssertTrue(mixer.a.previewing)
        XCTAssertGreaterThan(try renderPeak(), 0.01)
        mixer.a.cueUp()
        XCTAssertFalse(mixer.a.playing)
        XCTAssertEqual(mixer.a.position, 0.25, accuracy: 1e-9)
        XCTAssertLessThan(try renderPeak(), 0.001)
        mixer.a.cueDown()
        XCTAssertGreaterThan(try renderPeak(), 0.01)
        mixer.a.togglePlay()
        XCTAssertFalse(mixer.a.previewing)
        mixer.a.cueUp()
        XCTAssertTrue(mixer.a.playing)
        XCTAssertGreaterThan(try renderPeak(), 0.01)
    }
    /// Record two different source regions through saved hot-cue recalls, then
    /// exercise the independent main CUE repeatedly after metadata publishes.
    @MainActor
    func testSavedHotCuesLocateAndJumpWithoutDisablingMainCue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Two regions.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            pcm.frameLength = 48_000
            for second in 0..<18 {
                let hz = second < 6 ? 220.0 : 880.0
                for i in 0..<48_000 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * hz / 48_000)) * 0.3 }
                try file.write(from: pcm)
            }
        }
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))
        let mixer = NativeMixer(library: library)
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading)
        XCTAssertNil(mixer.a.error)
        mixer.crossfader = 0
        mixer.start()
        let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
                                     frameCapacity: 1024)!
        func assertTone(_ expected: Double, file: StaticString = #filePath, line: UInt = #line) throws {
            var samples: [Float] = []
            // The old source intentionally continues until the quantized beat.
            // Inspect the new region after that handover, not during its wait.
            for block in 0..<160 {
                if try mixer.renderOffline(into: output) == .success && block >= 145 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                }
            }
            func energy(_ hz: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                for (i, value) in samples.enumerated() {
                    let phase = 2 * .pi * hz * Double(i) / 48_000
                    real += Double(value) * cos(phase)
                    imaginary += Double(value) * sin(phase)
                }
                return hypot(real, imaginary) / Double(max(1, samples.count))
            }
            XCTAssertGreaterThan(energy(expected), 0.01, "Recalled marker must produce its own source region", file: file, line: line)
            XCTAssertLessThan(energy(expected == 220 ? 880 : 220), 0.005, "Previous region must not keep playing", file: file, line: line)
        }
        mixer.a.setGrid(bpm: 120, offsetMs: 250)
        mixer.a.seek(to: 0.25)
        mixer.a.cue() // Independent main cue, left unchanged by hot-cue capture/recall.
        mixer.a.seek(to: 0.75)
        mixer.a.hotCue(0)
        mixer.a.seek(to: 8.25)
        mixer.a.hotCue(1)
        await library.flush()
        XCTAssertNil(library.error)
        let saved = mixer.a.hotCues
        for slot in [0, 1, 0] {
            mixer.a.hotCue(slot)
            XCTAssertEqual(mixer.a.position, saved[slot]!)
            XCTAssertFalse(mixer.a.playing, "Locating a hot cue while paused must stay paused")
        }
        mixer.a.togglePlay()
        try assertTone(220)
        mixer.a.hotCue(1)
        XCTAssertTrue(mixer.a.playing)
        XCTAssertEqual(mixer.a.hotCues[1], 8.25)
        try assertTone(880)
        mixer.a.hotCue(0)
        XCTAssertTrue(mixer.a.playing)
        try assertTone(220)
        mixer.a.cueDown()
        XCTAssertFalse(mixer.a.playing)
        XCTAssertEqual(mixer.a.position, 0.25, "Main CUE must retain its own return point")
        mixer.a.cueUp()
        for _ in 0..<2 {
            mixer.a.cueDown()
            XCTAssertTrue(mixer.a.previewing)
            try assertTone(220)
            mixer.a.cueUp()
            XCTAssertFalse(mixer.a.playing)
            XCTAssertEqual(mixer.a.position, 0.25)
        }
        mixer.a.cueDown()
        mixer.a.togglePlay()
        mixer.a.cueUp()
        XCTAssertTrue(mixer.a.playing, "PLAY must still latch a CUE preview after hot-cue use")
        XCTAssertEqual(mixer.a.hotCues, saved, "Recalling hot cues must never overwrite their markers")
        XCTAssertNil(mixer.a.error)
    }

}
