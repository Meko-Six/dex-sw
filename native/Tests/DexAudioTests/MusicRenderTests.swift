import XCTest
import AVFoundation
@testable import DexAudio

/// Optional local-song exports for listening. No copyrighted fixture is committed.
final class MusicRenderTests: XCTestCase {
    @MainActor
    func testExportRealMusicTempoComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DEX_NATIVE_REFERENCE_AUDIO"], let directory = env["DEX_NATIVE_AUDIO_OUTPUT"] else {
            throw XCTSkip("Set DEX_NATIVE_REFERENCE_AUDIO and DEX_NATIVE_AUDIO_OUTPUT for local-song listening exports.")
        }
        let source = URL(fileURLWithPath: path)
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for rate in [0.84, 1.0, 1.16] {
            let mixer = NativeMixer()
            defer { mixer.shutdown() }
            try mixer.enableOfflineRendering()
            mixer.a.load(source)
            for _ in 0..<6000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(mixer.a.loading)
            XCTAssertNil(mixer.a.error)
            guard mixer.a.duration > 30 else { throw XCTSkip("Listening comparison needs a track longer than 30 seconds.") }
            mixer.a.seek(to: min(60, mixer.a.duration - 30))
            mixer.a.tempo = rate
            mixer.a.level = 1
            mixer.crossfader = 0
            mixer.volume = 0.7
            mixer.start()
            mixer.a.togglePlay()
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            let output = destination.appendingPathComponent("native-keylock-\(Int((rate * 100).rounded())).wav")
            let file = try AVAudioFile(forWriting: output, settings: format.settings)
            var frames = 0, attempts = 0
            var peak: Float = 0
            while frames < 20 * 48_000 && attempts < 4000 {
                attempts += 1
                if try mixer.renderOffline(into: pcm) == .success {
                    for channel in 0..<2 {
                        for i in 0..<Int(pcm.frameLength) {
                            let sample = pcm.floatChannelData![channel][i]
                            XCTAssertTrue(sample.isFinite)
                            peak = max(peak, abs(sample))
                        }
                    }
                    try file.write(from: pcm)
                    frames += Int(pcm.frameLength)
                }
                await Task.yield()
            }
            XCTAssertGreaterThanOrEqual(frames, 20 * 48_000)
            XCTAssertGreaterThan(peak, 0.001)
            XCTAssertLessThanOrEqual(peak, 1.001, "The master limiter must contain stretched-music peaks")
            print("MUSIC rate=\(rate) peak=\(peak) renderedFrames=\(frames) output=\(output.path)")
        }
    }
    @MainActor
    func testExportAudibleJogAndCoast() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DEX_NATIVE_REFERENCE_AUDIO"], let directory = env["DEX_NATIVE_AUDIO_OUTPUT"] else {
            throw XCTSkip("Set local reference audio/output for the audible jog listening export.")
        }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(URL(fileURLWithPath: path))
        for _ in 0..<6000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
        guard mixer.a.duration > 30 else { throw XCTSkip("Jog export needs a longer reference track.") }
        mixer.a.seek(to: min(60, mixer.a.duration - 20))
        mixer.a.level = 1; mixer.volume = 0.7; mixer.crossfader = 0
        mixer.start(); mixer.a.togglePlay()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = try AVAudioFile(forWriting: destination.appendingPathComponent("native-vinyl-jog.wav"), settings: format.settings)
        var frames = 0, stage = 0, attempts = 0, peak: Float = 0
        while frames < 8 * 48_000 && attempts < 4000 {
            attempts += 1
            let time = Double(frames) / 48_000
            if stage == 0 && time >= 1 {
                mixer.a.beginJog()
                for _ in 0..<500 where !mixer.a.jog.ready { try await Task.sleep(for: .milliseconds(2)) }
                stage = 1
            }
            if stage == 1 && time < 2 { mixer.a.jog.move(displacement: (time - 1) * 2) }
            if stage == 1 && time >= 2 { mixer.a.jog.release(); stage = 2 }
            if stage == 2 && time >= 4 {
                mixer.a.beginJog()
                for _ in 0..<500 where !mixer.a.jog.ready { try await Task.sleep(for: .milliseconds(2)) }
                stage = 3
            }
            if stage == 3 && time < 5 { mixer.a.jog.move(displacement: -(time - 4) * 1.5) }
            if stage == 3 && time >= 5 { mixer.a.jog.release(); stage = 4 }
            if try mixer.renderOffline(into: pcm) == .success {
                for channel in 0..<2 {
                    for i in 0..<Int(pcm.frameLength) {
                        let sample = pcm.floatChannelData![channel][i]
                        XCTAssertTrue(sample.isFinite); peak = max(peak, abs(sample))
                    }
                }
                try output.write(from: pcm); frames += Int(pcm.frameLength)
            }
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(frames, 8 * 48_000)
        XCTAssertGreaterThan(peak, 0.01); XCTAssertLessThanOrEqual(peak, 1.001)
        XCTAssertFalse(mixer.a.jog.active); XCTAssertTrue(mixer.a.playing)
        print("MUSIC JOG peak=\(peak) output=\(destination.appendingPathComponent("native-vinyl-jog.wav").path)")
    }

}
