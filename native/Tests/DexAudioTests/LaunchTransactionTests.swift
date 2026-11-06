import XCTest
import AVFoundation
import Dispatch
import DexCore
@testable import DexAudio

/// W1's gate: a stall can't falsely advance what is heard, or fade valid audio into a voice
/// that isn't ready. The stall is audio not yet read from disk; rendering carries on through
/// it, and the ramp fixture's level says which second of the track is actually sounding.
final class LaunchTransactionTests: XCTestCase {
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let delays = [0.01, 0.03, 0.12, 0.35]
    /// Long enough that a seek can land somewhere the engine hasn't read yet: it reads ahead
    /// ten seconds and more.
    private let seconds = 40
    /// Where a seek goes: into the far half, which the engine can't have read yet.
    private func far(_ position: Double) -> Double { position + 20 }
    /// The track second a sample from the far half came from.
    private func farSource(_ sample: Float) -> Double { far(source(sample)) }

    private func ramp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexLaunch-" + UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            // The far half starts the ramp again, so its level is read as closely as the near one:
            // the tone section is flat to 0.1%, which would read as 28 ms 28 s up a single ramp.
            let restart = 20 * 48_000
            for i in 0..<Int(buffer.frameLength) {
                let frame = i >= restart ? i - restart : i
                buffer.floatChannelData![channel][i] = 0.01 + Float(frame) / 48_000 * 0.01
            }
        }
        try file.write(from: buffer)
        return url
    }
    /// The track second a sample came from.
    private func source(_ sample: Float) -> Double { Double(sample - 0.01) / 0.01 }

    @MainActor private func deck(_ url: URL) async throws -> NativeMixer {
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(mixer.a.duration, 0); XCTAssertNil(mixer.a.error)
        mixer.crossfader = 0; mixer.a.level = 1; mixer.volume = 1
        mixer.start()
        return mixer
    }
    /// A stall: no audio is read from disk until it's released.
    @MainActor private final class Stall {
        let mixer: NativeMixer
        init(_ mixer: NativeMixer) { self.mixer = mixer; mixer.loaderHeld = true }
        func signal() { mixer.loaderHeld = false }
    }
    @MainActor private func stallDisk(_ mixer: NativeMixer) -> Stall { Stall(mixer) }
    private struct Block { let peak: Float; let last: Float; let position: Double }
    /// Renders with the control lane left alone, so a stall stays a stall.
    @MainActor private func render(_ mixer: NativeMixer, seconds: Double, drains: Bool = false) async throws -> [Block] {
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 256))
        var blocks = [Block]()
        for _ in 0..<Int((seconds * 48_000 / 256).rounded(.up)) {
            if drains { await settle(mixer) }
            _ = try mixer.renderOffline(into: out)
            mixer.a.refreshPosition()
            let samples = out.floatChannelData![0]
            let peak = (0..<256).reduce(Float(0)) { max($0, abs(samples[$1])) }
            blocks.append(Block(peak: peak, last: samples[255], position: mixer.a.position))
        }
        return blocks
    }
    /// Offline, time-pitch fills itself as soon as it's rendered, so a launch must reach the
    /// player between blocks or its timing depends on a race that only exists here. A live
    /// engine always renders first: `LiveClockTests` covers that.
    @MainActor private func settle(_ mixer: NativeMixer) async {
        await AudioControlExecutor.shared.drain(); await Task.yield()
        mixer.a.serviceTransitions()
        await AudioControlExecutor.shared.drain()
    }
    @MainActor private func finish(_ mixer: NativeMixer) async {
        mixer.shutdown(); await AudioControlExecutor.shared.drain()
    }

    // MARK: Starting from paused

    @MainActor func testStalledStartStaysPutThenStartsWhereTheClockSays() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            let gate = stallDisk(mixer)
            mixer.a.togglePlay()
            let stalled = try await render(mixer, seconds: delay)
            XCTAssertEqual(stalled.map(\.peak).max() ?? 1, 0, "\(delay): nothing can sound yet")
            XCTAssertEqual(stalled.last?.position ?? 1, 0, accuracy: 0.001, "\(delay): the clock must wait for the player")
            gate.signal()
            _ = try await render(mixer, seconds: 0.5, drains: true)
            let tail = try await render(mixer, seconds: 0.02, drains: true)
            let last = try XCTUnwrap(tail.last)
            XCTAssertGreaterThan(source(last.last), 0.2, "\(delay): the audio must have started")
            XCTAssertEqual(last.position, source(last.last), accuracy: 0.025, "\(delay): clock and sound must agree")
            await finish(mixer)
        }
    }

    /// Sharp clicks at known track positions, which time-pitch can't blur the way it can a
    /// level: when each one sounds against where the clock says the deck was.
    private func clicks(every spacing: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexClicks-" + UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: Int(buffer.frameLength)) }
        for index in stride(from: spacing, to: Double(seconds) - 0.1, by: spacing) {
            for i in 0..<720 {
                let value = Float(0.7 * cos(2 * .pi * Double(i) / 16) * exp(-Double(i) / 144))
                for channel in 0..<2 { buffer.floatChannelData![channel][Int(index * 48_000) + i] = value }
            }
        }
        try file.write(from: buffer)
        return url
    }
    /// Each click's error against the clock, in seconds: positive when the clock is ahead of the sound.
    @MainActor private func clockErrors(_ mixer: NativeMixer, seconds: Double, spacing: Double, skip: Double) async throws -> [Double] {
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 128))
        var samples = [Float](), trace = [(index: Int, position: Double)]()
        for _ in 0..<Int((seconds * 48_000 / 128).rounded(.up)) {
            await settle(mixer)
            _ = try mixer.renderOffline(into: out)
            samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: 128))
            trace.append((samples.count, mixer.a.heardPosition(ahead: 0)))
        }
        var errors = [Double](), index = Int(skip * 48_000)
        while index < samples.count {
            guard abs(samples[index]) > 0.1 else { index += 1; continue }
            if let after = trace.firstIndex(where: { $0.index >= index }), after > 0 {
                let (a, b) = (trace[after - 1], trace[after])
                let clock = a.position + (b.position - a.position) * Double(index - a.index) / Double(b.index - a.index)
                errors.append(clock - (clock / spacing).rounded() * spacing)
            }
            index += Int(spacing * 0.6 * 48_000)
        }
        return errors
    }

    @MainActor func testStartsAreOnTheClockByClickAtEveryDelay() async throws {
        let url = try clicks(every: 0.25); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            let gate = stallDisk(mixer)
            mixer.a.togglePlay()
            _ = try await render(mixer, seconds: delay)
            gate.signal()
            let errors = try await clockErrors(mixer, seconds: 3, spacing: 0.25, skip: 0.2)
            XCTAssertGreaterThanOrEqual(errors.count, 8, "\(delay)")
            for error in errors { XCTAssertEqual(error, 0, accuracy: 0.006, "\(delay): clock against the click") }
            await finish(mixer)
        }
    }

    @MainActor func testSeeksAreOnTheClockByClickAtEveryDelay() async throws {
        let url = try clicks(every: 0.25); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            mixer.a.togglePlay()
            _ = try await render(mixer, seconds: 0.5, drains: true)
            let gate = stallDisk(mixer)
            mixer.a.seek(to: far(6.06))
            _ = try await render(mixer, seconds: delay)
            gate.signal()
            let errors = try await clockErrors(mixer, seconds: 3, spacing: 0.25, skip: 0.3)
            XCTAssertGreaterThanOrEqual(errors.count, 8, "\(delay)")
            for error in errors { XCTAssertEqual(error, 0, accuracy: 0.006, "\(delay): clock against the click") }
            await finish(mixer)
        }
    }

    /// A disk that gives one chunk only every 60 ms, starting late, must still end up starting,
    /// where it was pressed: on the ramp, whose level says which second is sounding.
    @MainActor func testAPersistentlySlowDiskStillStarts() async throws {
        do {
            let rampURL = try ramp(); defer { try? FileManager.default.removeItem(at: rampURL) }
            let mixer = try await deck(rampURL)
            mixer.loaderHeld = true
            mixer.a.togglePlay()
            var waited = try await render(mixer, seconds: 0.2)
            var attempts = 0
            while attempts < 40, !waited.contains(where: { $0.peak > 0 }) {
                attempts += 1
                mixer.pumpLoaderOnce()
                waited = try await render(mixer, seconds: 0.06)
            }
            XCTAssertGreaterThan(mixer.a.engineDeckState?.waitedBlocks ?? 0, 0, "The start has to wait for this to mean anything")
            XCTAssertLessThan(attempts, 40, "It must get going in the end")
            let tail = try await render(mixer, seconds: 0.3)
            let last = try XCTUnwrap(tail.last)
            XCTAssertGreaterThan(last.peak, 0.01)
            let sounding = Double(tail.count + waited.count) * 256 / 48_000
            XCTAssertLessThan(source(last.last), sounding + 0.02, "It starts where it was pressed, not where the wait got to")
            XCTAssertEqual(last.position, source(last.last), accuracy: 0.025, "Clock and sound must agree")
            await finish(mixer)
        }
    }

    // MARK: Replacing what's playing

    @MainActor func testStalledSeekKeepsTheOutgoingAudioAndClockUntilTheNewVoiceIsReady() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            mixer.a.togglePlay()
            _ = try await render(mixer, seconds: 0.5, drains: true)
            let gate = stallDisk(mixer)
            mixer.a.seek(to: far(8))
            let stalled = try await render(mixer, seconds: delay)
            XCTAssertGreaterThan(stalled.map(\.peak).min() ?? 0, 0.01, "\(delay): the outgoing voice keeps sounding")
            let during = try XCTUnwrap(stalled.last)
            XCTAssertLessThan(source(during.last), 2, "\(delay): still the old audio")
            XCTAssertEqual(during.position, source(during.last), accuracy: 0.025, "\(delay): the clock stays on it")
            gate.signal()
            let after = try await render(mixer, seconds: 0.6, drains: true)
            XCTAssertGreaterThan(after.map(\.peak).min() ?? 0, 0.01, "\(delay): no gap on the way to the new voice")
            let last = try XCTUnwrap(after.last)
            XCTAssertEqual(farSource(last.last), far(8.45), accuracy: 0.25, "\(delay): the seek still lands")
            XCTAssertEqual(last.position, farSource(last.last), accuracy: 0.025, "\(delay): clock and sound must agree")
            await finish(mixer)
        }
    }

    // MARK: Quantized cues, bar jumps and loops

    @MainActor func testStalledHotCueKeepsTheBeatCount() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            mixer.a.setGrid(bpm: 120, offsetMs: 0)
            mixer.a.seek(to: 8); mixer.a.hotCue(0); mixer.a.seek(to: 0)
            mixer.a.togglePlay()
            var elapsed = 0.0
            let lead = try await render(mixer, seconds: 0.62, drains: true)
            elapsed += Double(lead.count) * 256 / 48_000
            let phase = (source(try XCTUnwrap(lead.last).last) - elapsed).truncatingRemainder(dividingBy: 0.5)
            let gate = stallDisk(mixer)
            mixer.a.hotCue(0)
            let stalled = try await render(mixer, seconds: delay)
            elapsed += Double(stalled.count) * 256 / 48_000
            XCTAssertGreaterThan(stalled.map(\.peak).min() ?? 0, 0.01, "\(delay): the old audio keeps sounding")
            gate.signal()
            let after = try await render(mixer, seconds: 2.6, drains: true)
            elapsed += Double(after.count) * 256 / 48_000
            let last = try XCTUnwrap(after.last)
            XCTAssertGreaterThan(after.map(\.peak).min() ?? 0, 0.01, "\(delay): no gap")
            XCTAssertGreaterThan(source(last.last), 7.9, "\(delay): the cue still lands")
            let shift = (source(last.last) - elapsed - phase).truncatingRemainder(dividingBy: 0.5)
            XCTAssertEqual(min(abs(shift), 0.5 - abs(shift)), 0, accuracy: 0.03, "\(delay): the beat count holds")
            XCTAssertEqual(last.position, source(last.last), accuracy: 0.03, "\(delay): clock and sound must agree")
            await finish(mixer)
        }
    }

    @MainActor func testStalledBarJumpMovesWholeBarsOnce() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            mixer.a.setGrid(bpm: 120, offsetMs: 0)
            mixer.a.jumpBars = 1
            mixer.a.togglePlay()
            let lead = try await render(mixer, seconds: 0.5, drains: true)
            let gate = stallDisk(mixer)
            mixer.a.jump(direction: 1)
            let stalled = try await render(mixer, seconds: delay)
            XCTAssertGreaterThan(stalled.map(\.peak).min() ?? 0, 0.01, "\(delay): the old audio keeps sounding")
            gate.signal()
            let after = try await render(mixer, seconds: 0.8, drains: true)
            XCTAssertGreaterThan(after.map(\.peak).min() ?? 0, 0.01, "\(delay): no gap")
            let last = try XCTUnwrap(after.last)
            let elapsed = Double(lead.count + stalled.count + after.count) * 256 / 48_000
            XCTAssertEqual(source(last.last) - elapsed, 2, accuracy: 0.06, "\(delay): one bar, not two")
            XCTAssertEqual(last.position, source(last.last), accuracy: 0.025, "\(delay): clock and sound must agree")
            await finish(mixer)
        }
    }

    @MainActor func testStalledLoopEntryStaysInsideTheLoop() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for delay in delays {
            let mixer = try await deck(url)
            mixer.a.setGrid(bpm: 120, offsetMs: 0)
            mixer.a.togglePlay()
            _ = try await render(mixer, seconds: 0.6, drains: true)
            let gate = stallDisk(mixer)
            mixer.a.toggleLoop()
            for _ in 0..<500 where mixer.a.loopBounds == nil { try await Task.sleep(for: .milliseconds(2)) }
            let bounds = try XCTUnwrap(mixer.a.loopBounds)
            let stalled = try await render(mixer, seconds: delay)
            XCTAssertGreaterThan(stalled.map(\.peak).min() ?? 0, 0.01, "\(delay): the old audio keeps sounding")
            gate.signal()
            let after = try await render(mixer, seconds: 2.5, drains: true)
            XCTAssertGreaterThan(after.map(\.peak).min() ?? 0, 0.01, "\(delay): no gap")
            for block in after.suffix(100) {
                XCTAssertGreaterThanOrEqual(source(block.last), bounds.lowerBound - 0.03, "\(delay)")
                XCTAssertLessThanOrEqual(source(block.last), bounds.upperBound + 0.03, "\(delay)")
            }
            let last = try XCTUnwrap(after.last)
            XCTAssertEqual(last.position, source(last.last), accuracy: 0.03, "\(delay): clock and sound must agree")
            await finish(mixer)
        }
    }

    // MARK: Cancellation

    @MainActor func testPausingDuringAStallLeavesNothingBehind() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = try await deck(url)
        let gate = stallDisk(mixer)
        mixer.a.seek(to: 3)
        mixer.a.togglePlay()
        _ = try await render(mixer, seconds: 0.2)
        mixer.a.togglePlay()
        gate.signal()
        let after = try await render(mixer, seconds: 0.4, drains: true)
        XCTAssertFalse(mixer.a.playing)
        XCTAssertEqual(mixer.a.engineDeckState?.playing, false)
        XCTAssertEqual(after.map(\.peak).max() ?? 1, 0)
        XCTAssertEqual(mixer.a.position, 3, accuracy: 0.001)
        await finish(mixer)
    }

    /// The first press waits for its audio, unread, and the later one arrives while it does.
    @MainActor func testALaterPressWinsWhileTheFirstWaitsForTheDisk() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        for replacing in [false, true] {
            let mixer = try await deck(url)
            if replacing {
                mixer.a.togglePlay()
                _ = try await render(mixer, seconds: 0.5, drains: true)
            }
            do {
                mixer.loaderHeld = true
                mixer.a.seek(to: replacing ? far(8) : 4)
                if !replacing { mixer.a.togglePlay() }
                _ = try await render(mixer, seconds: 0.1)
                mixer.a.seek(to: far(6))
                mixer.loaderHeld = false
                let after = try await render(mixer, seconds: 0.8, drains: true)
                let last = try XCTUnwrap(after.last)
                XCTAssertEqual(farSource(last.last), far(6) + 0.6, accuracy: 0.25, "replacing \(replacing): the later press wins")
                XCTAssertEqual(last.position, farSource(last.last), accuracy: 0.025)
                if replacing { XCTAssertGreaterThan(after.map(\.peak).min() ?? 0, 0.01, "no gap") }
                await finish(mixer)
            }
        }
    }

    // MARK: The engine's own confirmation

    @MainActor func testTheHeardPositionStopsWhereRenderingStopped() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = try await deck(url)
        mixer.a.togglePlay()
        let blocks = try await render(mixer, seconds: 0.5)
        let rendered = try XCTUnwrap(blocks.last)
        let actual = mixer.a.audioNow
        mixer.a.audioNow = { actual() + 5 } // Time passes but the engine has stalled.
        XCTAssertEqual(mixer.a.heardPosition(ahead: 0), rendered.position, accuracy: 0.06)
        mixer.a.audioNow = actual
        await finish(mixer)
    }
}
