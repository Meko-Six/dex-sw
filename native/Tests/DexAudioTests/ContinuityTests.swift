import XCTest
import AVFoundation
@testable import DexAudio

final class ContinuityTests: XCTestCase {
    @MainActor
    func testSeeksSyncLoopAndRapidSupersessionHaveNoSilentHoles() async throws {
        try await measure(deckBPM: 120, masterBPM: 128)
        try await measure(deckBPM: 128, masterBPM: 120)
    }
    @MainActor
    private func measure(deckBPM: Double, masterBPM: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: sourceFormat.settings)
            let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000)!
            chunk.frameLength = 48_000
            for frame in 0..<48_000 {
                chunk.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.2
                chunk.floatChannelData![1][frame] = 0.15 // Phase-independent gap detector.
            }
            for _ in 0..<20 { try file.write(from: chunk) }
        }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url); mixer.b.load(url)
        for _ in 0..<500 where mixer.a.loading || mixer.b.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(mixer.a.error); XCTAssertNil(mixer.b.error)
        mixer.a.setGrid(bpm: deckBPM); mixer.b.setGrid(bpm: masterBPM)
        mixer.a.seek(to: 10.11); mixer.a.hotCue(0); mixer.a.seek(to: 0)
        mixer.setMaster(mixer.b)
        mixer.a.level = 1; mixer.volume = 0.7; mixer.crossfader = 0
        mixer.start(); mixer.a.togglePlay(); mixer.b.togglePlay()
        let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 256)!
        var recorded = [Float](), tone = [Float]()
        var seek = false, sync = false, loop = false, shrink = false, grow = false, exitLoop = false, burst = false, inFade = false, hotCue = false
        var attempts = 0
        while recorded.count < 11 * 48_000 && attempts < 8000 {
            attempts += 1
            let time = Double(recorded.count) / 48_000
            if !seek && time >= 1 { mixer.a.seek(to: 3.31); seek = true }
            if !sync && time >= 2 { mixer.a.toggleSync(); sync = true }
            if !loop && time >= 3 {
                mixer.a.setLoopBeats(4)
                mixer.a.toggleLoop()
                XCTAssertTrue(mixer.a.loopActive)
                loop = true
            }
            if !shrink && time >= 3.7 {
                mixer.a.setLoopBeats(0.5)
                XCTAssertTrue(mixer.a.loopActive)
                XCTAssertEqual(mixer.a.loopBeats, 0.5)
                shrink = true
            }
            if !grow && time >= 4.3 {
                mixer.a.setLoopBeats(8)
                XCTAssertTrue(mixer.a.loopActive)
                XCTAssertEqual(mixer.a.loopBeats, 8)
                grow = true
            }
            if !exitLoop && time >= 5 { mixer.a.toggleLoop(); exitLoop = true }
            if !burst && time >= 6 {
                for i in 0..<10 { mixer.a.seek(to: Double(i) + 0.123) }
                burst = true
            }
            if !inFade && time >= 6.032 { mixer.a.seek(to: 7.123); inFade = true }
            if !hotCue && time >= 7 { mixer.a.hotCue(0); hotCue = true }
            if try mixer.renderOffline(into: pcm) == .success {
                tone.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                recorded.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
            }
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(recorded.count, 11 * 48_000)
        XCTAssertNil(mixer.a.error)
        var minimum = Double.infinity
        for start in stride(from: 24_000, to: recorded.count - 96, by: 96) {
            let rms = sqrt(recorded[start..<(start + 96)].reduce(0.0) { $0 + Double($1 * $1) } / 96)
            minimum = min(minimum, rms)
        }
        var toneMinimum = Double.infinity, lowTime = 0.0
        // The independent stretchers can briefly cancel a sine's phase in a
        // crossfade. Keep the strict 2 ms DC gap check above; measure tone power
        // across 20 ms so an ordinary phase overlap is not mistaken for silence.
        for start in stride(from: 24_000, to: tone.count - 960, by: 96) {
            let rms = sqrt(tone[start..<(start + 960)].reduce(0.0) { $0 + Double($1 * $1) } / 960)
            if rms < toneMinimum { toneMinimum = rms; lowTime = Double(start) / 48_000 }
        }
        print("CONTINUITY source=\(deckBPM) master=\(masterBPM) minimum2msDC=\(minimum) minimum20msTone=\(toneMinimum) toneDipAt=\(lowTime)")
        XCTAssertGreaterThan(toneMinimum, 0.03, "The tone must remain audible through arbitrary-phase seeks")
        XCTAssertGreaterThan(minimum, 0.04, "No 2 ms output window should collapse during a transport handover")
    }
}
