import XCTest
import AVFoundation
@testable import DexAudio
import CDexEngine
import DexCore

final class JogAudioTests: XCTestCase {
    /// A rising saw distinguishes direction; a sine exposes playback pitch. The
    /// saw stays slow so the isolator's 220 Hz all-pass phase can't bend its ramp.
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        pcm.frameLength = 48_000
        for i in 0..<48_000 {
            let phase = (Double(i) * 10 / 48_000).truncatingRemainder(dividingBy: 1)
            pcm.floatChannelData![0][i] = Float(phase * 0.4 - 0.2)
            pcm.floatChannelData![1][i] = Float(sin(2 * .pi * 440 * Double(i) / 48_000)) * 0.2
        }
        for _ in 0..<32 { try file.write(from: pcm) }
        return url
    }
    @MainActor
    private func prepare(_ mixer: NativeMixer, url: URL) async throws {
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
        mixer.a.setGrid(bpm: 120)
        mixer.a.seek(to: 6)
        mixer.a.level = 1; mixer.crossfader = 0; mixer.volume = 1
        mixer.start()
    }
    @MainActor
    private func window(_ deck: NativeDeck) async throws {
        for _ in 0..<500 where !deck.jog.ready { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(deck.jog.ready)
    }
    @MainActor
    private func record(_ mixer: NativeMixer, seconds: Double, move: ((Double) -> Void)? = nil) async throws -> (left: [Float], right: [Float]) {
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 256)!
        var left: [Float] = [], right: [Float] = []
        for _ in 0..<Int(ceil(seconds * 48_000 / 256)) {
            move?(Double(left.count) / 48_000)
            await AudioControlExecutor.shared.drain()
            XCTAssertEqual(try mixer.renderOffline(into: pcm), .success)
            left.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
            await Task.yield()
        }
        mixer.a.refreshPosition()
        return (left, right)
    }
    private func frequency(_ samples: ArraySlice<Float>) -> Double {
        var crossings = 0
        for i in samples.indices.dropFirst() where samples[i - 1] <= 0 && samples[i] > 0 { crossings += 1 }
        return Double(crossings) * 48_000 / Double(samples.count)
    }
    @MainActor
    func testRecordedJogDirectionAndPitchFollowFingerInsteadOfNormalTempo() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        for speed in [-2.0, 0.5, 2] {
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try await prepare(mixer, url: url)
            mixer.a.tempo = speed < 0 ? 0.84 : 1.16
            mixer.a.keyLock = speed > 0
            mixer.a.beginJog(); try await window(mixer.a)
            let output = try await record(mixer, seconds: 0.5) { mixer.a.jog.move(displacement: $0 * speed) }
            let tone = output.right.suffix(12_000)
            XCTAssertEqual(frequency(tone), 440 * abs(speed), accuracy: 12)
            let saw = output.left.suffix(12_000)
            let positive = saw.indices.dropFirst().filter { saw[$0] > saw[$0 - 1] }.count
            let fraction = Double(positive) / Double(saw.count - 1)
            if speed > 0 { XCTAssertGreaterThan(fraction, 0.85) }
            else { XCTAssertLessThan(fraction, 0.15, "Negative motion must reverse source content, not merely play it forward at the same pitch") }
            if speed == 2 {
                let offset = Double(output.left.count - 256) / 48_000 * speed
                let reverse = try await record(mixer, seconds: 0.12) { mixer.a.jog.move(displacement: offset - $0 * 2) }
                let early = reverse.left.prefix(2400)
                let negative = early.indices.dropFirst().filter { early[$0] < early[$0 - 1] }.count
                XCTAssertGreaterThan(Double(negative) / Double(early.count - 1), 0.65,
                                     "A reversed scratch must not retain the old stroke's direction")
            }
            XCTAssertFalse(mixer.a.playing)
            XCTAssertTrue(mixer.a.jog.active)
        }
    }
    @MainActor
    func testCoastAudiblySlowsAndRestoresOnlyTheOriginalPlayLatch() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        for wasPlaying in [false, true] {
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try await prepare(mixer, url: url)
            if wasPlaying { mixer.a.togglePlay(); _ = try await record(mixer, seconds: 0.2) }
            mixer.a.beginJog(); try await window(mixer.a)
            _ = try await record(mixer, seconds: 0.3) { mixer.a.jog.move(displacement: $0 * 2) }
            let released = mixer.a.position
            mixer.a.jog.release()
            XCTAssertTrue(mixer.a.jog.coasting)
            let output = try await record(mixer, seconds: 3.5)
            XCTAssertGreaterThan(mixer.a.position, released)
            XCTAssertFalse(mixer.a.jog.active)
            XCTAssertEqual(mixer.a.playing, wasPlaying)
            let early = frequency(output.right[2400..<4800]), later = frequency(output.right[24_000..<26_400])
            XCTAssertGreaterThan(early, later + 250)
            if wasPlaying { XCTAssertEqual(frequency(output.right.suffix(9600)), 440, accuracy: 12) }
            else { XCTAssertLessThan(output.right.suffix(9600).map { abs($0) }.max() ?? 1, 0.001) }
            XCTAssertNil(mixer.a.error)
        }
    }
    @MainActor
    func testCuePlaySeekLoadAndRecoveryCancelStaleCoastOrRead() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        for action in ["cue", "play", "seek", "load", "reset", "hotcue", "grid", "sync", "loop", "tempo", "jump"] {
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try await prepare(mixer, url: url)
            mixer.a.seek(to: 12); mixer.a.hotCue(0); mixer.a.seek(to: 6)
            if action != "load" { mixer.a.togglePlay(); _ = try await record(mixer, seconds: 0.1) }
            mixer.a.beginJog(); try await window(mixer.a)
            _ = try await record(mixer, seconds: 0.15) { mixer.a.jog.move(displacement: $0 * 2) }
            mixer.a.jog.release()
            switch action {
            case "cue": mixer.a.cueDown(); mixer.a.cueUp()
            case "play": mixer.a.togglePlay()
            case "seek": mixer.a.seek(to: 12)
            case "load": mixer.a.load(url)
            case "hotcue": mixer.a.hotCue(0)
            case "grid": mixer.a.setGrid(bpm: 124, offsetMs: 17)
            case "sync": mixer.a.toggleSync()
            case "loop": mixer.a.toggleLoop()
            case "tempo": mixer.a.tempo = 1.1
            case "jump": mixer.a.jump(direction: 1)
            default: mixer.handle(.servicesLost); mixer.handle(.servicesReset)
            }
            XCTAssertFalse(mixer.a.jog.active)
            for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(2)) }
            _ = try await record(mixer, seconds: 1.4)
            if action == "seek" { XCTAssertGreaterThan(mixer.a.position, 13); XCTAssertTrue(mixer.a.playing) }
            else if ["cue", "play", "load", "reset"].contains(action) { XCTAssertFalse(mixer.a.playing) }
            else { XCTAssertTrue(mixer.a.playing) }
            if action == "hotcue" { XCTAssertGreaterThan(mixer.a.position, 12) }
            if action == "cue" { XCTAssertEqual(mixer.a.position, mixer.a.cuePoint, accuracy: 1e-9) }
            XCTAssertFalse(mixer.a.jog.active)
        }
        // Cancel before the preparation completes; it must not install later.
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.beginJog(); mixer.a.seek(to: 18)
        for _ in 0..<20 { await Task.yield() }
        _ = try await record(mixer, seconds: 0.2)
        XCTAssertFalse(mixer.a.jog.active); XCTAssertEqual(mixer.a.position, 18)
    }
    @MainActor
    func testScrubbingHoldsNoMemoryAndShutdownGivesTheEnginesBack() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let budget = AudioMemoryBudget.shared.reservedBytes
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        let loaded = AudioMemoryBudget.shared.reservedBytes
        mixer.a.beginJog(); try await window(mixer.a)
        _ = try await record(mixer, seconds: 0.6) { mixer.a.jog.move(displacement: $0 * 2) }
        XCTAssertLessThanOrEqual(AudioMemoryBudget.shared.reservedBytes - loaded, 8 * 48_000 * 8 * 2)
        mixer.a.cancelJog(resume: false)
        _ = try await record(mixer, seconds: 0.05)
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, loaded, "Scrubbing reads from the engine's cache: no memory of its own")
        mixer.a.beginJog(); try await window(mixer.a)
        mixer.shutdown()
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, budget)
    }
    @MainActor
    func testStationaryHoldDoesNotReuseStaleFling() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.seek(to: 0.1)
        mixer.a.beginJog(); try await window(mixer.a)
        _ = try await record(mixer, seconds: 0.2) { mixer.a.jog.move(displacement: $0) }
        let held = mixer.a.position
        _ = try await record(mixer, seconds: 0.12)
        mixer.a.jog.move(displacement: held - 0.1) // unchanged end event
        mixer.a.jog.release()
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertEqual(mixer.a.position, held, accuracy: 1e-9)
        mixer.a.beginJog(at: 6); try await window(mixer.a)
        // The UI may deliver several coalesced events at one processing time.
        // A native gesture velocity must still launch an audible coast.
        mixer.a.jog.move(displacement: 0.2, velocity: 2)
        mixer.a.jog.release(velocity: 2)
        XCTAssertTrue(mixer.a.jog.coasting)
        let coalesced = try await record(mixer, seconds: 3.2)
        XCTAssertGreaterThan(coalesced.right.prefix(12_000).map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertFalse(mixer.a.jog.active); XCTAssertFalse(mixer.a.playing)
        mixer.a.beginJog(at: 6); try await window(mixer.a)
        mixer.a.jog.move(displacement: 0.2, velocity: 2)
        mixer.a.jog.release(velocity: 0) // native input reports a stationary lift
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertEqual(mixer.a.position, 6.2, accuracy: 1e-9)
    }
    @MainActor
    func testReleasedScrubCarriesOnForSeconds() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.beginJog(at: 2); try await window(mixer.a)
        mixer.a.jog.release(velocity: 4)
        _ = try await record(mixer, seconds: 1)
        XCTAssertTrue(mixer.a.jog.coasting, "A flick at half speed is still moving a second later")
        let midway = try XCTUnwrap(mixer.a.jog.position)
        let damping = JogFling.referenceDamping
        XCTAssertEqual(midway, 2 + 4 / damping * (1 - exp(-damping)), accuracy: 0.1)
        let tail = try await record(mixer, seconds: 1)
        XCTAssertGreaterThan(tail.right.prefix(6_000).map { abs($0) }.max() ?? 0, 0.001, "The coast stays audible")
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertEqual(mixer.a.position, 2 + (4 - 0.06) / damping, accuracy: 0.05)
    }
    @MainActor
    func testZoomedInLaneCoastsAtItsOwnSpeedToTheSameTrackDistance() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        // 300 points a second at 3 s across a lane of 1050 points.
        let velocity = 300.0 / 1050 * 3
        mixer.a.beginJog(at: 2); try await window(mixer.a)
        mixer.a.jog.release(velocity: velocity, span: 3)
        XCTAssertTrue(mixer.a.jog.coasting)
        _ = try await record(mixer, seconds: 5)
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertEqual(mixer.a.position, 2 + JogFling.distance(velocity: velocity, span: 3), accuracy: 0.15)
    }
    @MainActor
    func testFreshTouchCatchesACoastAndLiftingResumesPlayback() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.togglePlay(); _ = try await record(mixer, seconds: 0.1)
        mixer.a.beginJog(); try await window(mixer.a)
        mixer.a.jog.release(velocity: 4)
        _ = try await record(mixer, seconds: 0.5)
        let caught = try XCTUnwrap(mixer.a.jog.currentPosition)
        mixer.a.beginJog()
        XCTAssertFalse(mixer.a.jog.coasting)
        XCTAssertEqual(mixer.a.position, caught, accuracy: 0.02)
        try await window(mixer.a)
        mixer.a.jog.release() // lifted without moving
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertTrue(mixer.a.playing, "The deck was playing before the scrub")
    }
    @MainActor
    func testJogExitsLoopWithoutGhostWrapAndIsNotAnotherDeckBeatReference() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.b.load(url)
        for _ in 0..<500 where mixer.b.loading { try await Task.sleep(for: .milliseconds(2)) }
        mixer.b.setGrid(bpm: 120)
        mixer.a.setLoopBeats(1); mixer.a.toggleLoop()
        mixer.a.togglePlay()
        _ = try await record(mixer, seconds: 0.2)
        mixer.a.beginJog(); try await window(mixer.a)
        _ = try await record(mixer, seconds: 0.4) { mixer.a.jog.move(displacement: $0 * 2) }
        XCTAssertFalse(mixer.a.loopActive)
        mixer.b.cueDown()
        _ = try await record(mixer, seconds: 0.08)
        mixer.b.refreshPosition()
        XCTAssertGreaterThan(mixer.b.position, mixer.b.cuePoint + 0.02, "A jogging deck must not delay the other deck's audition to a fabricated beat")
        mixer.b.cueUp()
        XCTAssertTrue(mixer.a.jog.active)
        mixer.a.cancelJog()
        let target = mixer.a.position
        _ = try await record(mixer, seconds: 0.2)
        XCTAssertGreaterThan(mixer.a.position, target)
        XCTAssertTrue(mixer.a.playing); XCTAssertFalse(mixer.a.loopActive)
        XCTAssertNil(mixer.a.error)
    }

    @MainActor
    func testFullCommandQueueCancelsTheJogAndTheEngineCatchesUp() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.beginJog(); try await window(mixer.a)
        // Deliberately withhold render consumption until the bounded queue fills.
        // Cancellation must be effective even when no ordinary command fits.
        // The jog only sends a changed speed, so moves alone can't fill the engine's 1024-command
        // queue, which both decks share. The other deck's tempo changes do; then this deck's
        // next change of speed can't fit.
        for i in 0..<1_100 { mixer.b.tempo = 1 + Double(i % 2) * 0.01 }
        mixer.a.jog.move(displacement: 0.002, velocity: 0.5)
        mixer.a.jog.move(displacement: 0.004, velocity: 1.5)
        XCTAssertFalse(mixer.a.jog.active)
        XCTAssertNotNil(mixer.a.error)
        mixer.a.cueDown(); mixer.a.cueUp() // These may not fit either, and must still be obeyed.
        _ = try await record(mixer, seconds: 0.2)
        _ = try await record(mixer, seconds: 0.2)
        let engine = try XCTUnwrap(mixer.a.engineDeckState)
        XCTAssertFalse(engine.scrubbing, "The engine must have let go of the platter")
        XCTAssertFalse(engine.playing, "The engine must be stopped, as the deck says")
        XCTAssertEqual(engine.position / 48_000, mixer.a.cuePoint, accuracy: 0.001)
        XCTAssertFalse(mixer.a.playing)
        XCTAssertFalse(mixer.a.jog.active)
    }

    @MainActor
    func testInterruptedCoastFreezesAtRenderedPositionRatherThanElapsedWallTime() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await prepare(mixer, url: url)
        mixer.a.togglePlay(); _ = try await record(mixer, seconds: 0.1)
        mixer.a.beginJog(); try await window(mixer.a)
        _ = try await record(mixer, seconds: 0.2) { mixer.a.jog.move(displacement: $0 * 2) }
        mixer.a.jog.release()
        _ = try await record(mixer, seconds: 0.1)
        let rendered = try XCTUnwrap(mixer.a.jog.renderedPosition)
        let actualNow = mixer.a.audioNow
        mixer.a.audioNow = { actualNow() + 100 } // delayed system notification
        mixer.handle(.interruptionBegan)
        XCTAssertEqual(mixer.a.position, rendered, accuracy: 1e-9)
        XCTAssertFalse(mixer.a.jog.active); XCTAssertFalse(mixer.a.playing)
        mixer.a.audioNow = actualNow
        mixer.handle(.interruptionEnded(shouldResume: true))
        _ = try await record(mixer, seconds: 0.2)
        XCTAssertTrue(mixer.a.playing)
        XCTAssertGreaterThan(mixer.a.position, rendered)
        XCTAssertFalse(mixer.a.jog.active)
    }

}
