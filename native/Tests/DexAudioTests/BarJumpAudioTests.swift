import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

final class BarJumpAudioTests: XCTestCase {
    /// Every 4/4 bar has a different sustained pitch; right-channel DC exposes
    /// short silence independently of the stretcher's tone phase.
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        pcm.frameLength = 48_000
        for second in 0..<32 {
            let hz = Double(second / 2 + 1) * 220
            for i in 0..<48_000 {
                pcm.floatChannelData![0][i] = Float(sin(2 * .pi * hz * Double(i) / 48_000)) * 0.25
                pcm.floatChannelData![1][i] = 0.15
            }
            try file.write(from: pcm)
        }
        return url
    }
    @MainActor
    private func prepare(_ mixer: NativeMixer, url: URL, rate: Double = 1) async throws {
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
        mixer.a.setGrid(bpm: 120)
        mixer.a.tempo = rate
        mixer.crossfader = 0
        mixer.a.level = 1
        mixer.volume = 0.7
        mixer.start()
    }
    @MainActor
    private func ready(_ deck: NativeDeck) async throws {
    }
    @MainActor
    private func record(_ mixer: NativeMixer, seconds: Double) throws -> (tone: [Float], dc: [Float]) {
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 256)!
        var tone: [Float] = [], dc: [Float] = []
        for _ in 0..<Int(ceil(seconds * 48_000 / 256)) {
            XCTAssertEqual(try mixer.renderOffline(into: pcm), .success)
            tone.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            dc.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
        }
        mixer.a.refreshPosition()
        return (tone, dc)
    }
    private func magnitude(_ values: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, value) in values.enumerated() {
            let angle = 2 * .pi * hz * Double(i) / 48_000
            re += Double(value) * cos(angle); im += Double(value) * sin(angle)
        }
        return hypot(re, im) / Double(max(1, values.count))
    }
    private func assertContinuous(_ output: (tone: [Float], dc: [Float]), file: StaticString = #filePath, line: UInt = #line) {
        let minimum = minimumCombinedRMS(output.dc, output.tone)
        XCTAssertGreaterThan(minimum, 0.03, "Jump must not insert a 2 ms silence in both channels", file: file, line: line)
    }
    @MainActor
    func testPlayingAndRapidJumpsPreserveOwnClockAtTempoExtremes() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try await prepare(mixer, url: url, rate: rate)
            mixer.a.seek(to: 0.5); mixer.a.togglePlay()
            _ = try record(mixer, seconds: 0.6)
            let before = mixer.a.position
            mixer.a.jumpBars = 4
            mixer.a.jump(direction: 1)
            XCTAssertEqual(mixer.a.position, before, accuracy: 0.001, "Display stays on outgoing audio during preparation")
            let output = try record(mixer, seconds: 0.6)
            XCTAssertEqual(mixer.a.position - before, 8 + Double(output.dc.count) / 48_000 * rate, accuracy: 0.0001)
            assertContinuous(output)
            XCTAssertGreaterThan(magnitude(output.tone.suffix(12_000), hz: 1100), 0.015)
            // Two quick one-bar presses accumulate before the first handover.
            mixer.a.jumpBars = 1
            let rapidOrigin = mixer.a.position
            mixer.a.jump(direction: 1); mixer.a.jump(direction: 1)
            let rapid = try record(mixer, seconds: 0.4)
            XCTAssertEqual(mixer.a.position - rapidOrigin, 4 + Double(rapid.dc.count) / 48_000 * rate, accuracy: 0.0001)
            assertContinuous(rapid)
            let fadeOrigin = mixer.a.position
            mixer.a.jump(direction: 1)
            let fade = try record(mixer, seconds: 0.123)
            mixer.a.jump(direction: 1); mixer.a.jump(direction: 1)
            let queued = try record(mixer, seconds: 0.4)
            XCTAssertEqual(mixer.a.position - fadeOrigin, 6 + Double(fade.dc.count + queued.dc.count) / 48_000 * rate, accuracy: 0.0001)
            assertContinuous(queued)
            XCTAssertTrue(mixer.a.playing); XCTAssertNil(mixer.a.error)
        }
    }
    @MainActor
    func testMovedLoopRendersNewContentAndPreservesPausedAndPlayingState() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try await prepare(mixer, url: url, rate: rate)
            mixer.a.seek(to: 2); mixer.a.setLoopBeats(1); mixer.a.toggleLoop()
            try await ready(mixer.a)
            mixer.a.jump(direction: 1); try await ready(mixer.a)
            XCTAssertEqual(mixer.a.position, 4, accuracy: 1e-9)
            XCTAssertEqual(mixer.a.loopBounds, 4...4.5)
            XCTAssertFalse(mixer.a.playing)
            mixer.a.togglePlay()
            _ = try record(mixer, seconds: 0.6)
            let phase = (mixer.a.position - 4).truncatingRemainder(dividingBy: 0.5)
            mixer.a.jump(direction: 1); try await ready(mixer.a)
            let moved = try record(mixer, seconds: 0.6)
            assertContinuous(moved)
            XCTAssertEqual(mixer.a.loopBounds, 6...6.5)
            let expected = (phase + Double(moved.dc.count) / 48_000 * rate).truncatingRemainder(dividingBy: 0.5)
            XCTAssertEqual(mixer.a.position, 6 + expected, accuracy: 0.0001)
            XCTAssertGreaterThan(magnitude(moved.tone.suffix(12_000), hz: 880), 0.015)
            XCTAssertLessThan(magnitude(moved.tone.suffix(12_000), hz: 660), 0.005)
            mixer.a.jump(direction: -1); try await ready(mixer.a)
            let back = try record(mixer, seconds: 0.6)
            assertContinuous(back)
            XCTAssertEqual(mixer.a.loopBounds, 4...4.5)
            XCTAssertGreaterThan(magnitude(back.tone.suffix(12_000), hz: 660), 0.015)
            mixer.a.jump(direction: 1); mixer.a.jump(direction: 1)
            try await ready(mixer.a)
            let rapid = try record(mixer, seconds: 0.6)
            assertContinuous(rapid)
            XCTAssertEqual(mixer.a.loopBounds, 8...8.5)
            XCTAssertGreaterThan(magnitude(rapid.tone.suffix(12_000), hz: 1100), 0.015)
            XCTAssertTrue(mixer.a.playing); XCTAssertNil(mixer.a.error)
        }
    }
    @MainActor
    func testLoopMovesAtOnceAndLeavingItDoesNotBringItBack() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.seek(to: 2); mixer.a.setLoopBeats(1); mixer.a.toggleLoop()
        try await ready(mixer.a)
        mixer.a.jump(direction: 1); mixer.a.toggleLoop()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(mixer.a.loopActive)
        // A loop moves at once, read from the engine's own cache, so there's nothing to cancel
        // or fail: the press moves one whole bar, once, and leaving the loop doesn't bring it back.
        XCTAssertEqual(mixer.a.position, 4)
        mixer.a.toggleLoop()
        XCTAssertEqual(mixer.a.loopBounds, 4...4.5)
        try FileManager.default.removeItem(at: url)
        mixer.a.jump(direction: 1)
        XCTAssertEqual(mixer.a.loopBounds, 6...6.5)
        XCTAssertEqual(mixer.a.position, 6)
        XCTAssertNil(mixer.a.error, "The engine keeps the track open, so a deleted file still plays")
        mixer.a.togglePlay()
        let moved = try record(mixer, seconds: 1.2)
        XCTAssertGreaterThan(magnitude(moved.tone.suffix(12_000), hz: 880), 0.015, "The moved loop plays the bar it was moved to")
        XCTAssertLessThan(magnitude(moved.tone.suffix(12_000), hz: 660), 0.005)
        XCTAssertEqual(mixer.a.loopBounds, 6...6.5)
    }
    @MainActor
    func testRecordedBeatAccentsContinueAcrossForwardAndBackwardJumps() async throws {
        let tones = [900.0, 1300, 1700, 2100]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let offset = 0.137, marker = offset + 8
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            pcm.frameLength = 48_000
            for second in 0..<24 {
                for frame in 0..<48_000 {
                    let absolute = Double(second) + Double(frame) / 48_000
                    let time = absolute - offset, beat = floor(time / 0.5)
                    let phase = time - beat * 0.5, index = (Int(beat) % 4 + 4) % 4
                    let pulse = time >= 0 && phase < 0.03
                        ? Float(sin(phase * 2 * .pi * tones[index]) * exp(-phase * 190) * 0.4) : 0
                    pcm.floatChannelData![0][frame] = absolute < marker ? pulse : 0
                    pcm.floatChannelData![1][frame] = absolute >= marker ? pulse : 0
                }
                try file.write(from: pcm)
            }
        }
        func attacks(_ samples: [Float]) -> [Double] {
            var times: [Double] = []
            for i in stride(from: 0, to: samples.count - 96, by: 96) {
                let rms = sqrt(samples[i..<(i + 96)].reduce(0.0) { $0 + Double($1 * $1) } / 96)
                let time = Double(i) / 48_000
                if rms > 0.025, time - (times.last ?? -1) > 0.25 { times.append(time) }
            }
            return times
        }
        func accent(_ samples: [Float], at time: Double) -> Int {
            let start = Int(time * 48_000), end = min(samples.count, start + 960)
            return tones.indices.max { magnitude(samples[start..<end], hz: tones[$0]) < magnitude(samples[start..<end], hz: tones[$1]) }!
        }
        for rate in [0.84, 1.0, 1.16] {
            for direction in [-1, 1] {
                let mixer = NativeMixer(); defer { mixer.shutdown() }
                try await prepare(mixer, url: url, rate: rate)
                // An unmatched other deck cannot become the jump's beat reference.
                mixer.b.load(url)
                for _ in 0..<500 where mixer.b.loading { try await Task.sleep(for: .milliseconds(5)) }
                mixer.b.setGrid(bpm: 157, offsetMs: 23)
                mixer.b.togglePlay()
                mixer.a.setGrid(bpm: 120, offsetMs: offset * 1000)
                mixer.a.seek(to: direction > 0 ? offset : marker)
                mixer.a.jumpBars = 4; mixer.a.togglePlay()
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                var left: [Float] = [], right: [Float] = []
                var triggered = false
                while left.count < 5 * 48_000 {
                    if !triggered && left.count >= Int(1.23 * 48_000) {
                        mixer.a.jump(direction: direction); triggered = true
                    }
                    await AudioControlExecutor.shared.drain()
                    if try mixer.renderOffline(into: pcm) == .success {
                        left.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                        right.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
                    }
                    await Task.yield()
                }
                let old = direction > 0 ? left : right, new = direction > 0 ? right : left
                let first = try XCTUnwrap(attacks(new).first)
                let previous = try XCTUnwrap(attacks(old).last { $0 < first - 0.25 / rate })
                XCTAssertEqual(first - previous, 0.5 / rate, accuracy: 0.015)
                XCTAssertEqual(accent(new, at: first), (accent(old, at: previous) + 1) % 4)
                let incoming = attacks(new).prefix(4).map { accent(new, at: $0) }
                for (a, b) in zip(incoming, incoming.dropFirst()) { XCTAssertEqual(b, (a + 1) % 4) }
                print("BAR JUMP direction=\(direction) rate=\(rate) boundaryMs=\(abs(first - previous - 0.5 / rate) * 1000)")
                XCTAssertTrue(mixer.a.playing); XCTAssertNil(mixer.a.error)
            }
        }
    }

    @MainActor
    func testJumpChecksWholeBarRoomOnItsLandingFrame() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.seek(to: 27.379); mixer.a.togglePlay()
        _ = try record(mixer, seconds: 0.4)
        mixer.a.jump(direction: 1)
        // A jump lands on the next block, and the room is judged on that frame. So the press
        // comes on the first block where the bar no longer fits there, the tightest case there is.
        var steps = 0
        func landing() -> Double { mixer.a.heardPosition(ahead: mixer.a.replacementLookahead + mixer.a.outputDelay) }
        while landing() <= 30, steps < 400 { _ = try record(mixer, seconds: 256.0 / 48_000); steps += 1 }
        XCTAssertLessThan(landing() - 30, 256.0 / 48_000 + 1e-6, "The press must be within a block of the last bar that fits")
        mixer.a.jump(direction: 1)
        _ = try record(mixer, seconds: 0.4)
        XCTAssertTrue(mixer.a.playing, "A jump that no longer fits must not play out the track and stop")
        XCTAssertLessThan(mixer.a.position, 31)
        XCTAssertGreaterThan(mixer.a.position, 30)
        XCTAssertNil(mixer.a.error)
    }

}
