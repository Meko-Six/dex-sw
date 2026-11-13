import XCTest
import AVFoundation
import CDexEngine
@testable import DexAudio

/// Muted live checks of the engine on the real output device. The sound is
/// silenced after the engine, limiter included, so the whole of its output is measured
/// without anything reaching the speakers. Never opens the microphone.
///
/// DEX_NATIVE_LIVE_CHECKS=1 runs them; DEX_LIVE_MINUTES sets the length (3 by default).
final class LiveOutputTests: XCTestCase {
    /// Clicks on the beat, on one side only, so the two decks can be told apart in the master.
    private func clicks(bpm: Double, seconds: Double, left: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexLive-" + UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 48_000
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
        let beat = 60 / bpm * 48_000
        let total = Int(seconds * 48_000)
        var written = 0
        while written < total {
            let count = min(block, total - written)
            pcm.frameLength = AVAudioFrameCount(count)
            let side = pcm.floatChannelData![left ? 0 : 1], other = pcm.floatChannelData![left ? 1 : 0]
            side.update(repeating: 0, count: count); other.update(repeating: 0, count: count)
            var n = Int(ceil(Double(written) / beat))
            while true {
                let start = Int((Double(n) * beat).rounded())
                if start >= written + count { break }
                for i in 0..<720 where start + i >= written && start + i < written + count {
                    side[start + i - written] = Float(0.7 * cos(2 * .pi * Double(i) / 16) * exp(-Double(i) / 144))
                }
                n += 1
            }
            try file.write(from: pcm)
            written += count
        }
        return url
    }

    /// Two decks, key lock on both, B synced to A from a different tempo, for minutes.
    @MainActor
    func testTwoKeyLockedDecksStayOnTheClockAndTogetherForMinutes() async throws {
        guard ProcessInfo.processInfo.environment["DEX_NATIVE_LIVE_CHECKS"] == "1" else {
            throw XCTSkip("Set DEX_NATIVE_LIVE_CHECKS=1 for the muted live checks of the engine.")
        }
        let minutes = Double(ProcessInfo.processInfo.environment["DEX_LIVE_MINUTES"] ?? "") ?? 3
        let seconds = minutes * 60
        let urlA = try clicks(bpm: 120, seconds: seconds + 40, left: true)
        let urlB = try clicks(bpm: 126, seconds: seconds * 1.1 + 40, left: false)
        defer { try? FileManager.default.removeItem(at: urlA); try? FileManager.default.removeItem(at: urlB) }

        let mixer = NativeMixer(mutedAfterEngine: true)
        defer { mixer.shutdown() }
        mixer.volume = 1; mixer.crossfader = 0.5
        mixer.a.load(urlA); mixer.b.load(urlB)
        for _ in 0..<2000 where mixer.a.loading || mixer.b.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(mixer.a.error); XCTAssertNil(mixer.b.error)
        mixer.a.setGrid(bpm: 120); mixer.b.setGrid(bpm: 126)
        mixer.a.level = 1; mixer.b.level = 1
        mixer.a.keyLock = true; mixer.b.keyLock = true
        mixer.start()
        for _ in 0..<2000 where mixer.audioState != .ready || !mixer.a.audioAvailable { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(mixer.audioState, .ready)
        print("LIVE output delay ms=\(mixer.a.outputDelay * 1000)")

        let node = mixer.engineOutputNode
        let onsets = StereoOnsets(gap: 0.2)
        node.installTap(onBus: 0, bufferSize: 512, format: nil, block: onsets.tap)
        defer { node.removeTap(onBus: 0) }

        mixer.a.togglePlay()
        try await Task.sleep(for: .milliseconds(700))
        mixer.b.toggleSync()
        mixer.b.togglePlay()
        let startState = try XCTUnwrap(mixer.engineState)
        let started = ProcessInfo.processInfo.systemUptime

        var clockA: [(Double, Double)] = [], clockB: [(Double, Double)] = []
        let end = started + seconds
        var lastReport = started
        while ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(20))
            let now = mixer.a.audioNow()
            // The position at this engine time: heard time plus the delay after the engine.
            clockA.append((now, mixer.a.heardPosition(ahead: mixer.a.outputDelay)))
            clockB.append((now, mixer.b.heardPosition(ahead: mixer.b.outputDelay)))
            if ProcessInfo.processInfo.systemUptime - lastReport > 30 {
                lastReport = ProcessInfo.processInfo.systemUptime
                print("LIVE progress \(Int(lastReport - started)) s, \(mixer.engineReport)")
            }
        }
        let endState = try XCTUnwrap(mixer.engineState)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertTrue(mixer.a.playing); XCTAssertTrue(mixer.b.playing)
        XCTAssertTrue(mixer.b.syncLocked)

        // Underruns and CPU, from the engine's own counters.
        let gaps = endState.outputGaps - startState.outputGaps
        let starvedA = endState.deck.0.starvedBlocks, starvedB = endState.deck.1.starvedBlocks
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let ticks = Double(endState.renderTicks - startState.renderTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let worstMs = Double(endState.worstRenderTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
        let blockMs = Double(endState.blockFrames) / endState.sampleRate * 1000
        print("LIVE underruns outputGaps=\(gaps) starvedA=\(starvedA) starvedB=\(starvedB) waitedA=\(endState.deck.0.waitedBlocks) waitedB=\(endState.deck.1.waitedBlocks)")
        print(String(format: "LIVE cpu %.2f%% of one core, worst block %.3f ms of %.2f ms", ticks / elapsed * 100, worstMs, blockMs))
        XCTAssertEqual(gaps, 0, "The device must never have missed a block")
        XCTAssertEqual(starvedA, 0); XCTAssertEqual(starvedB, 0)

        // Clock against sound: where each deck's clock says it was when its click came out.
        let delay = Double(endState.engineDelayFrames) / endState.sampleRate
        func errors(_ times: [Double], clock: [(Double, Double)], beat: Double, rate: Double) -> [Double] {
            var result: [Double] = []
            var j = 0
            for time in times {
                let t = time - delay
                while j + 1 < clock.count && clock[j + 1].0 < t { j += 1 }
                guard j + 1 < clock.count, clock[j].0 <= t else { continue }
                let (t0, p0) = clock[j], (t1, p1) = clock[j + 1]
                guard t1 - t0 < 0.1, p1 > p0 else { continue }
                let position = p0 + (p1 - p0) * (t - t0) / (t1 - t0)
                let nearest = (position / beat).rounded() * beat
                result.append((position - nearest) / rate * 1000)
            }
            return result
        }
        let (left, right) = onsets.all
        let settleA = left.filter { $0 > left.first! + 2 }, settleB = right.filter { $0 > right.first! + 4 }
        let errA = errors(settleA, clock: clockA, beat: 0.5, rate: 1)
        let errB = errors(settleB, clock: clockB, beat: 60.0 / 126, rate: mixer.b.tempo)
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "none" }
            let sorted = values.map(abs).sorted()
            let mean = values.reduce(0, +) / Double(values.count)
            return String(format: "n=%d mean=%.3f ms p99=%.3f ms max=%.3f ms", values.count, mean,
                          sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last!)
        }
        print("LIVE clock vs sound A (straight key lock) \(summary(errA))")
        print("LIVE clock vs sound B (stretched, synced) \(summary(errB))")
        XCTAssertGreaterThan(errA.count, Int(seconds * 1.5))
        XCTAssertGreaterThan(errB.count, Int(seconds * 1.5))
        XCTAssertLessThan(errA.map(abs).max() ?? .infinity, 2, "Deck A's waveform must stay within 2 ms of its sound")
        XCTAssertLessThan(errB.map(abs).max() ?? .infinity, 3, "Deck B's waveform must stay within 3 ms of its sound")

        // The decks against each other: B's click against A's nearest one, through the run.
        var pairs: [(Double, Double)] = []
        var k = 0
        for time in settleB {
            while k + 1 < settleA.count && abs(settleA[k + 1] - time) < abs(settleA[k] - time) { k += 1 }
            guard k < settleA.count, abs(settleA[k] - time) < 0.1 else { continue }
            pairs.append((time, (time - settleA[k]) * 1000))
        }
        XCTAssertGreaterThan(pairs.count, Int(seconds * 1.5), "The decks' beats must line up")
        let window = 30.0
        let first = pairs.filter { $0.0 < pairs.first!.0 + window }.map(\.1)
        let last = pairs.filter { $0.0 > pairs.last!.0 - window }.map(\.1)
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(1, v.count)) }
        print(String(format: "LIVE decks B-A first %.0f s mean=%.3f ms, last %.0f s mean=%.3f ms, drift=%.3f ms over %.1f min; %@",
                     window, mean(first), window, mean(last), mean(last) - mean(first), elapsed / 60, summary(pairs.map(\.1))))
        XCTAssertLessThan(abs(mean(last) - mean(first)), 1, "No drift between the decks")
        XCTAssertLessThan(pairs.map { abs($0.1) }.max() ?? .infinity, 5, "The beats stay together")
    }
}

extension LiveOutputTests {
    /// Starts and seeks, at three tempos with key lock on: each click after one must come out
    /// where the deck's clock says it is, through the real output.
    @MainActor
    func testLiveStartsAndSeeksAreOnTheClockByClick() async throws {
        guard ProcessInfo.processInfo.environment["DEX_NATIVE_LIVE_CHECKS"] == "1" else {
            throw XCTSkip("Set DEX_NATIVE_LIVE_CHECKS=1 for the muted live checks of the engine.")
        }
        let url = try clicks(bpm: 150, seconds: 30, left: true) // a click every 0.4 s
        defer { try? FileManager.default.removeItem(at: url) }
        var worst = 0.0, count = 0
        for (name, tempo) in [("start", 1.0), ("start", 1.08), ("start", 0.92), ("seek", 1.0), ("seek", 1.08), ("seek", 0.92)] {
            let mixer = NativeMixer(mutedAfterEngine: true)
            defer { mixer.shutdown() }
            mixer.volume = 1; mixer.crossfader = 0
            mixer.a.load(url)
            for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
            mixer.a.level = 1; mixer.a.keyLock = true; mixer.a.tempo = tempo
            mixer.start()
            // A Bluetooth output can take seconds to open; a press before then is rightly ignored.
            for _ in 0..<2000 where mixer.audioState != .ready || !mixer.a.audioAvailable { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(mixer.audioState, .ready, "\(name) \(tempo): the output must be open before the press")
            XCTAssertFalse(mixer.a.loading, "\(name) \(tempo): the track must be loaded before the press")
            XCTAssertNil(mixer.a.error, "\(name) \(tempo)")
            let node = mixer.engineOutputNode
            let onsets = StereoOnsets(gap: 0.2)
            node.installTap(onBus: 0, bufferSize: 512, format: nil, block: onsets.tap)
            defer { node.removeTap(onBus: 0) }
            try await Task.sleep(for: .milliseconds(300))
            if name == "seek" {
                mixer.a.seek(to: 2.13); mixer.a.togglePlay()
                try await Task.sleep(for: .milliseconds(900))
                mixer.a.seek(to: 11.37)
            } else {
                mixer.a.seek(to: 3.21); mixer.a.togglePlay()
            }
            let pressed = mixer.a.audioNow()
            var clock: [(Double, Double)] = []
            let end = ProcessInfo.processInfo.systemUptime + 2.5
            while ProcessInfo.processInfo.systemUptime < end {
                try await Task.sleep(for: .milliseconds(10))
                clock.append((mixer.a.audioNow(), mixer.a.heardPosition(ahead: mixer.a.outputDelay)))
            }
            let state = try XCTUnwrap(mixer.engineState)
            let delay = Double(state.engineDelayFrames) / state.sampleRate
            var errors: [Double] = []
            var j = 0
            for time in onsets.all.0 where time - delay > pressed + 0.15 {
                let t = time - delay
                while j + 1 < clock.count && clock[j + 1].0 < t { j += 1 }
                guard j + 1 < clock.count, clock[j].0 <= t, clock[j + 1].0 - clock[j].0 < 0.1 else { continue }
                let (t0, p0) = clock[j], (t1, p1) = clock[j + 1]
                let position = p0 + (p1 - p0) * (t - t0) / (t1 - t0)
                errors.append((position - (position / 0.4).rounded() * 0.4) / tempo * 1000)
            }
            print(String(format: "LIVE %@ tempo %.2f: %d clicks, worst %.3f ms, output gaps %llu", name, tempo, errors.count,
                         errors.map(abs).max() ?? -1, state.outputGaps)
                  + "; playing \(mixer.a.playing), audio \(mixer.audioState), error \(mixer.a.error.map(String.init(describing:)) ?? "none"), clicks heard \(onsets.all.0.count)")
            XCTAssertGreaterThanOrEqual(errors.count, 4, "\(name) \(tempo)")
            for error in errors { XCTAssertEqual(error, 0, accuracy: 2, "\(name) \(tempo): clock against the click, ms") }
            XCTAssertEqual(state.outputGaps, 0)
            worst = max(worst, errors.map(abs).max() ?? 0); count += errors.count
        }
        print(String(format: "LIVE starts and seeks: %d clicks, worst %.3f ms", count, worst))
    }
}

/// Click onsets on each side of the master, in host seconds.
private final class StereoOnsets: @unchecked Sendable {
    private let lock = NSLock()
    private let gap: Double
    private var left: [Double] = [], right: [Double] = []
    init(gap: Double) { self.gap = gap }
    var all: ([Double], [Double]) { lock.withLock { (left, right) } }
    var tap: AVAudioNodeTapBlock {
        { [self] buffer, when in
            guard when.isHostTimeValid, let data = buffer.floatChannelData, buffer.format.channelCount >= 2 else { return }
            let start = AVAudioTime.seconds(forHostTime: when.hostTime)
            let rate = buffer.format.sampleRate
            for channel in 0..<2 {
                let samples = data[channel]
                for i in 0..<Int(buffer.frameLength) where abs(samples[i]) > 0.05 {
                    let time = start + Double(i) / rate
                    lock.withLock {
                        if channel == 0 { if time > (left.last ?? 0) + gap { left.append(time) } }
                        else if time > (right.last ?? 0) + gap { right.append(time) }
                    }
                    break
                }
            }
        }
    }
}
