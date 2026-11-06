import XCTest
import AVFoundation
@testable import DexAudio

final class LoopResizeTests: XCTestCase {
    /// Each half-beat has a distinct pitch. Combined channel energy detects
    /// output holes even when the stretcher rotates the DC channel's phase.
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)!
        chunk.frameLength = 12_000
        for halfBeat in 0..<32 {
            let frequency = 220 + Double(halfBeat) * 55
            for i in 0..<12_000 {
                chunk.floatChannelData![0][i] = Float(sin(2 * .pi * frequency * Double(i) / 48_000)) * 0.25
                chunk.floatChannelData![1][i] = 0.15
            }
            try file.write(from: chunk)
        }
        return url
    }
    @MainActor
    private func prepare(_ mixer: NativeMixer, url: URL, beats: Double, position: Double = 0.75) async throws {
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading)
        XCTAssertNil(mixer.a.error)
        mixer.a.setGrid(bpm: 120)
        mixer.a.seek(to: position)
        mixer.a.setLoopBeats(beats)
        mixer.a.toggleLoop()
        try await ready(mixer.a)
        mixer.crossfader = 0
        mixer.a.level = 1
        mixer.volume = 0.7
        mixer.start()
        mixer.a.togglePlay()
    }
    @MainActor
    private func ready(_ deck: NativeDeck) async throws {
        XCTAssertTrue(deck.loopActive)
    }
    @MainActor
    private func record(_ mixer: NativeMixer, seconds: Double) throws -> (tone: [Float], dc: [Float]) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var tone: [Float] = [], dc: [Float] = []
        let frames = Int(seconds * 48_000)
        var attempts = 0
        while tone.count < frames && attempts < frames / 256 * 4 + 10 {
            attempts += 1
            if try mixer.renderOffline(into: buffer) == .success {
                tone.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                dc.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
            }
        }
        XCTAssertGreaterThanOrEqual(tone.count, frames)
        mixer.a.refreshPosition()
        return (tone, dc)
    }
    private func magnitude(_ values: ArraySlice<Float>, hz: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i, sample) in values.enumerated() {
            let angle = 2 * .pi * hz * Double(i) / 48_000
            real += Double(sample) * cos(angle)
            imaginary += Double(sample) * sin(angle)
        }
        return hypot(real, imaginary) / Double(max(1, values.count))
    }
    private func assertContinuous(_ values: [Float], file: StaticString = #filePath, line: UInt = #line) {
        var minimum = Double.infinity, at = 0
        for i in stride(from: 0, to: values.count - 96, by: 96) {
            let rms = sqrt(values[i..<(i + 96)].reduce(0.0) { $0 + Double($1 * $1) } / 96)
            if rms < minimum { minimum = rms; at = i }
        }
        XCTAssertGreaterThan(minimum, 0.03, "No silent 2 ms hole during live loop resizing (at \(Double(at) / 48_000)s)", file: file, line: line)
    }

    @MainActor
    func testLiveResizeKeepsPlayheadWindowAndRendersHalfBeatContentAtAllTempoExtremes() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            let mixer = NativeMixer()
            defer { mixer.shutdown() }
            mixer.a.tempo = rate
            try await prepare(mixer, url: url, beats: 4)
            _ = try record(mixer, seconds: 2.6)
            var previous = try XCTUnwrap(mixer.a.loopBounds)
            for beats in [2.0, 1, 0.5, 1, 2, 4] {
                mixer.a.setLoopBeats(beats)
                XCTAssertTrue(mixer.a.playing)
                try await ready(mixer.a)
                XCTAssertNil(mixer.a.error)
                XCTAssertEqual(mixer.a.loopBeats, beats)
                let bounds = try XCTUnwrap(mixer.a.loopBounds)
                XCTAssertEqual(bounds.upperBound - bounds.lowerBound, beats * 0.5, accuracy: 1e-9)
                if bounds.upperBound - bounds.lowerBound < previous.upperBound - previous.lowerBound {
                    XCTAssertGreaterThanOrEqual(bounds.lowerBound, previous.lowerBound - 1e-9, "Shrinking stays inside the old loop")
                    XCTAssertLessThanOrEqual(bounds.upperBound, previous.upperBound + 1e-9)
                } else {
                    XCTAssertEqual(bounds.lowerBound, previous.lowerBound, accuracy: 1e-9, "Growing keeps loop-in")
                }
                previous = bounds
                // The fixture changes pitch every half-beat (0.25 s).
                let anchored = 220 + (bounds.lowerBound / 0.25).rounded() * 55
                let samples = try record(mixer, seconds: 1.25)
                let minimumCombined = minimumCombinedRMS(samples.dc, samples.tone)
                print("RESIZE rate=\(rate) beats=\(beats) minCombined=\(minimumCombined)")
                XCTAssertGreaterThan(minimumCombined, 0.03, "Neither channel may fall silent during resize")
                XCTAssertTrue(mixer.a.playing)
                XCTAssertGreaterThanOrEqual(mixer.a.position, bounds.lowerBound)
                XCTAssertLessThan(mixer.a.position, bounds.upperBound)
                if beats == 0.5 {
                    let tail = samples.tone.suffix(24_000)
                    XCTAssertGreaterThan(magnitude(tail, hz: anchored), 0.015, "The half-beat must repeat its anchored source region")
                    XCTAssertLessThan(magnitude(tail, hz: anchored + 55), 0.005, "The following half-beat must be excluded")
                } else if beats == 1 {
                    // Short windows identify the admitted content without
                    // cancelling repeated tones whose phase resets each loop.
                    let maximum = stride(from: 16_000, to: samples.tone.count - 3840, by: 1920).map { start in
                        magnitude(samples.tone[start..<(start + 3840)], hz: anchored + 55)
                    }.max()!
                    XCTAssertGreaterThan(maximum, 0.015,
                                         "Doubling must admit the next half-beat, not keep the old short buffer")
                }
            }
        }
    }

    @MainActor
    private func assertHoldsPlayhead(_ mixer: NativeMixer, length: Double, within outer: ClosedRange<Double>,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let deck = mixer.a
        let bounds = try XCTUnwrap(deck.loopBounds, file: file, line: line)
        XCTAssertEqual(bounds.upperBound - bounds.lowerBound, length, accuracy: 1e-9, file: file, line: line)
        XCTAssertTrue(outer.contains(bounds.lowerBound) && outer.contains(bounds.upperBound), "\(bounds)", file: file, line: line)
        _ = try record(mixer, seconds: 0.2) // Past the handover, which keeps the outgoing playhead.
        XCTAssertTrue((bounds.lowerBound..<bounds.upperBound).contains(deck.position), "\(deck.position) in \(bounds)", file: file, line: line)
    }

    @MainActor
    func testHalvingInTheLaterHalfKeepsLoopOutAndPlaysOn() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try await prepare(mixer, url: url, beats: 4) // Loop 1–3 s; beat 3 starts at 2 s.
        for _ in 0..<40 where !(2.1...2.5).contains(mixer.a.position) { _ = try record(mixer, seconds: 0.05) }
        let pressed = mixer.a.position
        XCTAssertTrue((2.1...2.5).contains(pressed))
        mixer.a.setLoopBeats(2)
        try await ready(mixer.a)
        XCTAssertNil(mixer.a.error)
        XCTAssertEqual(mixer.a.loopBounds, 2...3, "The 4-beat loop's end becomes the 2-beat loop's end")
        mixer.a.refreshPosition()
        XCTAssertGreaterThanOrEqual(mixer.a.position, pressed, "The playhead carries on rather than returning to loop-in")
        assertContinuous(try record(mixer, seconds: 1.2).dc)
        XCTAssertTrue((2.0..<3.0).contains(mixer.a.position))

        mixer.a.togglePlay()
        mixer.a.setLoopBeats(4)
        try await ready(mixer.a)
        XCTAssertEqual(mixer.a.loopBounds, 2...4, "Growing keeps loop-in")
        mixer.a.seek(to: 3.6)
        let paused = mixer.a.position
        mixer.a.setLoopBeats(1)
        try await ready(mixer.a)
        XCTAssertEqual(mixer.a.loopBounds, 3.5...4)
        XCTAssertEqual(mixer.a.position, paused, accuracy: 1e-9, "A paused resize leaves the playhead alone")
    }

    @MainActor
    func testRapidRequestsInFlightResizeAndExitUseLatestSize() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try await prepare(mixer, url: url, beats: 4)
        _ = try record(mixer, seconds: 1)
        for beats in [2.0, 1, 0.5, 8, 2, 0.5] { mixer.a.setLoopBeats(beats) }
        try await ready(mixer.a)
        XCTAssertEqual(mixer.a.loopBeats, 0.5)
        try assertHoldsPlayhead(mixer, length: 0.25, within: 1...3)
        assertContinuous(try record(mixer, seconds: 0.6).dc)
        mixer.a.setLoopBeats(8)
        try await ready(mixer.a)
        // The next resize arrives inside the render-thread overlap, not merely
        // before an inaudible preparation. It must not disturb that active fade.
        _ = try record(mixer, seconds: 0.123)
        mixer.a.setLoopBeats(1)
        try await ready(mixer.a)
        assertContinuous(try record(mixer, seconds: 0.8).dc)
        XCTAssertEqual(mixer.a.loopBeats, 1)
        try assertHoldsPlayhead(mixer, length: 0.5, within: 1...5)
        mixer.a.setLoopBeats(4)
        mixer.a.toggleLoop() // Cancel a new read while leaving the audible loop.
        for _ in 0..<10 { await Task.yield() }
        assertContinuous(try record(mixer, seconds: 1).dc)
        XCTAssertFalse(mixer.a.loopActive)
        XCTAssertNil(mixer.a.loopBounds)
        XCTAssertTrue(mixer.a.playing)
        _ = try record(mixer, seconds: 1)
        XCTAssertGreaterThan(mixer.a.position, 2, "Exit must release the loop rather than reactivate a stale preparation")
        XCTAssertNil(mixer.a.error)
    }

    @MainActor
    func testInvalidExpansionPreservesTheLoopAndADeletedFileDoesNot() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try await prepare(mixer, url: url, beats: 0.5, position: 7)
        _ = try record(mixer, seconds: 0.5)
        mixer.a.setLoopBeats(4) // End would be 9 seconds, past the file end.
        XCTAssertNotNil(mixer.a.error)
        XCTAssertEqual(mixer.a.loopBeats, 0.5)
        XCTAssertEqual(mixer.a.loopBounds, 7...7.25)
        XCTAssertTrue(mixer.a.loopActive)
        assertContinuous(try record(mixer, seconds: 0.5).dc)
        try FileManager.default.removeItem(at: url)
        // The engine keeps the track open and reads loops from its own cache, so a deleted
        // file can't fail the resize: it happens, and the loop plays on.
        mixer.a.setLoopBeats(1)
        XCTAssertNil(mixer.a.error)
        XCTAssertEqual(mixer.a.loopBeats, 1)
        XCTAssertEqual(mixer.a.loopBounds, 7...7.5)
        XCTAssertTrue(mixer.a.playing)
        assertContinuous(try record(mixer, seconds: 0.5).dc)
    }
}
