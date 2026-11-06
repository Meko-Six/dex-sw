import XCTest
import AVFoundation
@testable import DexAudio

final class SyncMeasurementTests: XCTestCase {
    private func clicks(bpm: Double, offset: Double, channel: Int, audibleFrom: Double = 0, accented: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        pcm.frameLength = 48_000
        for second in 0..<12 {
            for i in 0..<48_000 {
                let time = Double(second) + Double(i) / 48_000 - offset
                let phase = time - floor(time / (60 / bpm)) * (60 / bpm)
                let attack = time >= 0 && time + offset >= audibleFrom && phase < 0.03 ? exp(-phase * 190) : 0
                let beat = Int(floor(time / (60 / bpm)))
                let tone = accented ? [900.0, 1300, 1700, 2100][(beat % 4 + 4) % 4] : 1800
                pcm.floatChannelData![channel][i] = Float(sin(time * 2 * .pi * tone) * attack * 0.4)
                pcm.floatChannelData![1 - channel][i] = 0
            }
            try file.write(from: pcm)
        }
        return url
    }
    private func attacks(_ samples: [Float]) -> [Double] {
        var result = [Double]()
        for start in stride(from: 0, to: samples.count - 96, by: 96) {
            let power = samples[start..<(start + 96)].reduce(0.0) { $0 + Double($1 * $1) }
            let time = Double(start) / 48_000
            if sqrt(power / 96) > 0.025, time - (result.last ?? -1) > 0.25 { result.append(time) }
        }
        return result
    }
    @MainActor
    private func measure(lateStart: Bool, tempoChange: Bool = false, enableSync: Bool = true, action: String = "play", reverseDecks: Bool = false, masterRate: Double = 1, cueRate: Double = 1, queuedControls: Bool = false) async throws -> (median: Double, worst: Double) {
        let leftURL = try clicks(bpm: 120, offset: 0, channel: 0)
        let sourceOffset = action == "cueZero" ? 0.0 : 0.04
        let rightURL = try clicks(bpm: 128, offset: sourceOffset, channel: 1)
        defer { try? FileManager.default.removeItem(at: leftURL); try? FileManager.default.removeItem(at: rightURL) }
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        let leftDeck = reverseDecks ? mixer.b : mixer.a
        let rightDeck = reverseDecks ? mixer.a : mixer.b
        try mixer.enableOfflineRendering()
        if queuedControls {
        }
        leftDeck.load(leftURL)
        rightDeck.load(rightURL)
        for _ in 0..<500 where leftDeck.loading || rightDeck.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(leftDeck.error); XCTAssertNil(rightDeck.error)
        leftDeck.setGrid(bpm: 120)
        rightDeck.setGrid(bpm: 128, offsetMs: sourceOffset * 1000)
        leftDeck.level = 1; rightDeck.level = 1; mixer.volume = 1
        if action == "loop" {
            rightDeck.seek(to: 0.04)
            rightDeck.setLoopBeats(4)
            rightDeck.toggleLoop()
            XCTAssertTrue(rightDeck.loopActive)
        }
        if action == "hotcue" {
            rightDeck.seek(to: 3.17)
            rightDeck.hotCue(0)
            rightDeck.seek(to: 0)
        }
        leftDeck.tempo = masterRate; rightDeck.tempo = cueRate
        mixer.start()
        leftDeck.togglePlay()
        if lateStart {
            if enableSync { rightDeck.toggleSync() }
        } else { rightDeck.togglePlay() }
        let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 1024)!
        var left = [Float](), right = [Float]()
        var triggered = false, changed = false, acted = false, latched = false
        var cueEarliest = 0.0, lead = 0.12
        while left.count < 8 * 48_000 {
            if !triggered && left.count >= Int(1.23 * 48_000) {
                if action.hasPrefix("cue") {
                    rightDeck.seek(to: sourceOffset)
                    lead = rightDeck.startDelay
                    cueEarliest = Double(left.count) / 48000 + 0.12
                    rightDeck.cueDown()
                } else if lateStart { rightDeck.togglePlay() }
                else if enableSync { rightDeck.toggleSync() }
                triggered = true
            }
            if action.hasPrefix("cue") && !latched && left.count >= Int(1.8 * 48_000) {
                rightDeck.togglePlay()
                rightDeck.cueUp()
                latched = true
            }
            if !acted && left.count >= Int(2.31 * 48_000) {
                if action == "seek" { rightDeck.seek(to: 3.17) }
                if action == "hotcue" {
                    rightDeck.refreshPosition(); let outgoing = rightDeck.position
                    rightDeck.hotCue(0)
                    XCTAssertEqual(rightDeck.position, outgoing, accuracy: 1e-9, "The display must follow outgoing audio until the quantized jump")
                }
                acted = true
            }
            if tempoChange && !changed && left.count >= Int(3.2 * 48_000) {
                leftDeck.tempo = 1.08
                changed = true
            }
            if queuedControls { await AudioControlExecutor.shared.drain() }
            if try mixer.renderOffline(into: output) == .success {
                left.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                right.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![1], count: Int(output.frameLength)))
            }
            await Task.yield()
        }
        if lateStart {
            XCTAssertLessThan(right.prefix(48_000).map { abs($0) }.max() ?? 1, 0.00001,
                              "Deck A must not bleed into the recorded Deck B channel")
        }
        let master = attacks(left)
        if action.hasPrefix("cue") {
            XCTAssertEqual(rightDeck.cuePoint, sourceOffset, accuracy: 1e-9)
            if !enableSync {
                XCTAssertFalse(rightDeck.syncLocked)
                XCTAssertEqual(rightDeck.tempo, cueRate)
            }
            let first = try XCTUnwrap(attacks(right).first)
            let press = cueEarliest - 0.12
            let referencePeriod = 0.5 / masterRate
            let tolerance = min(0.150, referencePeriod * 0.30)
            let previous = master.last { $0 <= press + 0.002 }
            let intended: Double
            if let previous, press - previous <= tolerance + 0.002 { intended = previous }
            else { intended = try XCTUnwrap(master.first { $0 >= press - 0.002 }) }
            // An accepted late/early-preparation press joins partway through
            // its source beat. Compare the first full attack on that source's
            // clock, including unmatched tempos with SYNC off.
            let incomingPeriod = (60.0 / 128) / rightDeck.tempo
            var expected = intended
            // A beat still to come is met whole, as soon as it can sound; a beat already gone
            // is joined 120 ms in, past its attack.
            let earliest = intended >= press + lead - 0.002 ? press + lead : cueEarliest
            while expected < earliest - 0.015 { expected += incomingPeriod }
            XCTAssertEqual(first, expected, accuracy: 0.015, "Cue attacks must follow the selected beat without replaying a missed attack")
            print("CUE ATTACK sync=\(enableSync) reverse=\(reverseDecks) masterRate=\(masterRate) cueRate=\(rightDeck.tempo) firstErrorMs=\(abs(first - expected) * 1000)")
            XCTAssertTrue(rightDeck.playing, "PLAY must latch held CUE without restarting")
        }
        let follower = attacks(right).filter { $0 > 1.8 && $0 < 7.5 }
        XCTAssertGreaterThan(follower.count, 8)
        let errors = follower.map { beat in master.map { abs($0 - beat) }.min()! }.sorted()
        let result = (errors[errors.count / 2], errors.last!)
        print("SYNC action=\(action) enabled=\(enableSync) late=\(lateStart) tempoChange=\(tempoChange) medianMs=\(result.0 * 1000) worstMs=\(result.1 * 1000)")
        return result
    }
    @MainActor
    func testLateSyncedStartRecordsAlignedAttacks() async throws {
        let result = try await measure(lateStart: true)
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }
    @MainActor
    func testEnablingSyncDuringPlaybackRecordsAlignedAttacks() async throws {
        let result = try await measure(lateStart: false)
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }
    @MainActor
    func testMasterTempoChangeMaintainsRecordedPhase() async throws {
        let result = try await measure(lateStart: true, tempoChange: true)
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }
    @MainActor
    func testUnsyncedNegativeControlDetectsDrift() async throws {
        let result = try await measure(lateStart: false, enableSync: false)
        XCTAssertGreaterThan(result.worst, 0.1, "The measurement must distinguish two unaligned decks")
    }

    @MainActor
    func testSyncedCueRetainsFirstAttackAndLatchesPlayback() async throws {
        let result = try await measure(lateStart: true, action: "cue")
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }
    @MainActor
    func testSyncedLoopMaintainsRecordedPhase() async throws {
        let result = try await measure(lateStart: true, action: "loop")
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }
    @MainActor
    func testSyncedSeekAndHotCueMaintainRecordedPhase() async throws {
        for action in ["seek", "hotcue"] {
            let result = try await measure(lateStart: true, action: action)
            XCTAssertLessThan(result.median, 0.015)
            XCTAssertLessThan(result.worst, 0.025)
        }
    }

    @MainActor
    func testCueAtFileStartPreservesFirstAttack() async throws {
        let result = try await measure(lateStart: true, action: "cueZero")
        XCTAssertLessThan(result.median, 0.015)
        XCTAssertLessThan(result.worst, 0.025)
    }

    @MainActor
    func testCueAlignsFirstAttackWithoutSyncInEitherDeckRoleAndAcrossRates() async throws {
        for (reverse, masterRate, cueRate) in [(false, 1.0, 1.0), (true, 1.0, 1.0), (false, 0.84, 1.16), (true, 1.16, 0.84)] {
            _ = try await measure(lateStart: true, enableSync: false, action: "cue", reverseDecks: reverse,
                                  masterRate: masterRate, cueRate: cueRate)
        }
    }

    @MainActor
    func testReleasingCueBeforeQuantizedStartCancelsPendingAudio() async throws {
        let left = try clicks(bpm: 120, offset: 0, channel: 0)
        let right = try clicks(bpm: 128, offset: 0.04, channel: 1)
        defer { try? FileManager.default.removeItem(at: left); try? FileManager.default.removeItem(at: right) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(left); mixer.b.load(right)
        for _ in 0..<500 where mixer.a.loading || mixer.b.loading { try await Task.sleep(for: .milliseconds(5)) }
        mixer.a.setGrid(bpm: 120); mixer.b.setGrid(bpm: 128, offsetMs: 40)
        mixer.start(); mixer.a.togglePlay()
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, frameCapacity: 1024)!
        func render(_ blocks: Int) throws -> Float {
            var peak: Float = 0
            for _ in 0..<blocks where try mixer.renderOffline(into: buffer) == .success {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![1][i])) }
            }
            return peak
        }
        _ = try render(10)
        mixer.b.cueDown()
        XCTAssertTrue(mixer.b.previewing)
        XCTAssertLessThan(try render(3), 0.00001, "No audio before the quantized beat")
        mixer.b.cueUp()
        XCTAssertLessThan(try render(40), 0.00001, "Release must cancel a waiting cue, including after its former start time")
        XCTAssertFalse(mixer.b.playing)
        XCTAssertEqual(mixer.b.position, 0.04, accuracy: 1e-9)
    }

    @MainActor
    func testQueuedControlLaneRetainsCueAndHotCueAttackAlignment() async throws {
        for action in ["cue", "hotcue"] {
            let result = try await measure(lateStart: true, action: action, queuedControls: true)
            XCTAssertLessThan(result.median, 0.015)
            XCTAssertLessThan(result.worst, 0.025)
        }
    }

    /// Keep the old source silent until beyond the recall marker. Its beat can
    /// therefore never mask a mistimed incoming hot-cue attack in the recording.
    @MainActor
    func testStoredHotCueIncomingAttackAlignsAcrossDeckRolesSyncAndRates() async throws {
        for (reverse, sync, referenceRate, cueRate) in [
            (false, true, 1.0, 1.0), (true, true, 1.08, 1.0),
            (false, false, 1.0, 0.9375), (true, false, 1.16, 1.0875)
        ] {
            let marker = 0.04 + 8 * 60.0 / 128
            let referenceURL = try clicks(bpm: 120, offset: 0.137, channel: 0)
            let cueURL = try clicks(bpm: 128, offset: 0.04, channel: 1, audibleFrom: marker)
            defer { try? FileManager.default.removeItem(at: referenceURL); try? FileManager.default.removeItem(at: cueURL) }
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            let reference = reverse ? mixer.b : mixer.a
            let recalled = reverse ? mixer.a : mixer.b
            try mixer.enableOfflineRendering()
            reference.load(referenceURL); recalled.load(cueURL)
            for _ in 0..<500 where reference.loading || recalled.loading { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(reference.error); XCTAssertNil(recalled.error)
            reference.setGrid(bpm: 120, offsetMs: 137)
            recalled.setGrid(bpm: 128, offsetMs: 40)
            reference.tempo = referenceRate; recalled.tempo = cueRate
            reference.level = 1; recalled.level = 1; mixer.volume = 1
            recalled.seek(to: marker + 0.12); recalled.hotCue(0)
            XCTAssertEqual(recalled.hotCues[0]!, marker, accuracy: 1e-9)
            recalled.seek(to: 0.04)
            if sync { mixer.setMaster(reference); recalled.toggleSync() }
            mixer.start(); reference.togglePlay(); recalled.togglePlay()
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!, frameCapacity: 1024)!
            var left: [Float] = [], right: [Float] = []
            var triggered = false, earliest = 0.0
            while left.count < 6 * 48000 {
                if !triggered && left.count >= Int(2.31 * 48000) {
                    earliest = Double(left.count) / 48000 + 0.12
                    recalled.refreshPosition(); let outgoing = recalled.position
                    recalled.hotCue(0); triggered = true
                    XCTAssertTrue(recalled.playing)
                    XCTAssertEqual(recalled.position, outgoing, accuracy: 1e-9)
                }
                await AudioControlExecutor.shared.drain()
                if try mixer.renderOffline(into: buffer) == .success {
                    left.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    right.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
                }
                await Task.yield()
            }
            let referenceAttacks = attacks(left)
            let first = try XCTUnwrap(attacks(right).first)
            let expected = try XCTUnwrap(referenceAttacks.enumerated().first { $0.offset.isMultiple(of: 4) && $0.element >= earliest - 0.002 }?.element)
            XCTAssertEqual(first, expected, accuracy: 0.015, "The incoming saved marker's own first attack must land on the reference beat")
            print("HOT RECALL sync=\(sync) reverse=\(reverse) referenceRate=\(referenceRate) cueRate=\(recalled.tempo) firstErrorMs=\(abs(first - expected) * 1000)")
            if abs(120 * referenceRate - 128 * recalled.tempo) < 0.001 {
                for attack in attacks(right) {
                    XCTAssertLessThan(referenceAttacks.map { abs($0 - attack) }.min()!, 0.025)
                }
            }
            XCTAssertEqual(recalled.hotCues[0]!, marker, accuracy: 1e-9)
        }
    }

    /// One deck carries the dance-floor pulse before AND after the jump. Split
    /// its source regions into different output channels to identify the exact
    /// first recalled beat, with no second deck needed to hide a phase break.
    @MainActor
    func testPlayingHotCueKeepsOwnAudibleBeatWithNoReferenceOrUnmatchedOtherDeck() async throws {
        for (bpm, offset, rate, otherPlaying) in [
            (120.0, 0.137, 1.0, false), (128.0, 0.04, 1.16, false),
            (100.0, 0.173, 0.84, false), (123.4, -0.042, 1.0, false),
            (120.0, 0.137, 1.0, true)
        ] {
            let marker = offset + 8 * 60 / bpm
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                for second in 0..<12 {
                    for i in 0..<48000 {
                        let absolute = Double(second) + Double(i) / 48000
                        let time = absolute - offset
                        let period = 60 / bpm
                        let phase = time - floor(time / period) * period
                        let attack = time >= 0 && phase < 0.03 ? exp(-phase * 190) : 0
                        let pulse = Float(sin(time * 2 * .pi * 1800) * attack * 0.4)
                        buffer.floatChannelData![0][i] = absolute < marker ? pulse : 0
                        buffer.floatChannelData![1][i] = absolute >= marker ? pulse : 0
                    }
                    try file.write(from: buffer)
                }
            }
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try mixer.enableOfflineRendering()
            mixer.a.load(url)
            if otherPlaying { mixer.b.load(url) }
            for _ in 0..<500 where mixer.a.loading || mixer.b.loading { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(mixer.a.error)
            mixer.a.setGrid(bpm: bpm, offsetMs: offset * 1000); mixer.a.tempo = rate
            mixer.a.level = 1; mixer.volume = 1
            mixer.a.seek(to: marker + 0.12); mixer.a.hotCue(0)
            mixer.a.seek(to: mixer.a.cuePoint)
            if otherPlaying {
                mixer.b.setGrid(bpm: 94, offsetMs: 311)
                mixer.b.seek(to: 1.234); mixer.b.level = 0
            }
            mixer.start(); mixer.a.togglePlay()
            if otherPlaying { mixer.b.togglePlay() }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            var before: [Float] = [], after: [Float] = []
            var jumped = false, triggerTime = 0.0
            while before.count < 7 * 48000 {
                if !jumped && before.count >= Int(1.23 * 48000) {
                    triggerTime = Double(before.count) / 48000
                    mixer.a.refreshPosition(); let outgoing = mixer.a.position
                    mixer.a.hotCue(0); jumped = true
                    XCTAssertTrue(mixer.a.playing)
                    XCTAssertEqual(mixer.a.position, outgoing, accuracy: 1e-9)
                }
                await AudioControlExecutor.shared.drain()
                if try mixer.renderOffline(into: buffer) == .success {
                    before.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    after.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
                }
                await Task.yield()
            }
            let oldBeats = attacks(before), newBeats = attacks(after)
            XCTAssertGreaterThan(oldBeats.count, 1); XCTAssertGreaterThan(newBeats.count, 3)
            let first = try XCTUnwrap(newBeats.first)
            let period = 60 / bpm / rate
            let firstSourceBeat = Int(ceil(-offset / (60 / bpm)))
            let firstOutput = try XCTUnwrap(oldBeats.first)
            let expected = try XCTUnwrap((0..<32).map { index -> Double? in
                guard (firstSourceBeat + index).isMultiple(of: 4) else { return nil }
                let time = firstOutput + Double(index) * period
                return time >= triggerTime + 0.12 - 0.002 ? time : nil
            }.compactMap { $0 }.first)
            XCTAssertEqual(first, expected, accuracy: 0.015, "The first saved-cue attack must land on the ongoing audible beat, not one beat later")
            // Both sides of one crossfade may detect this same transient a few
            // milliseconds apart. Compare with the previous distinct pulse.
            let last = try XCTUnwrap(oldBeats.last { $0 < first - period / 2 })
            XCTAssertEqual(first - last, period, accuracy: 0.015, "A stored-cue jump must not insert a short or long beat")
            XCTAssertTrue(oldBeats.filter { $0 > last + period / 2 }.allSatisfy { abs($0 - first) < 0.015 })
            for (a, b) in zip(newBeats, newBeats.dropFirst()) {
                XCTAssertEqual(b - a, period, accuracy: 0.015)
            }
            XCTAssertFalse(mixer.a.syncLocked)
            XCTAssertEqual(mixer.a.tempo, rate)
            XCTAssertEqual(mixer.a.hotCues[0]!, marker, accuracy: 1e-9)
            print("OWN HOT RECALL bpm=\(bpm) rate=\(rate) otherPlaying=\(otherPlaying) boundaryErrorMs=\(abs(first - last - period) * 1000)")
        }
    }

    @MainActor
    func testMainCueHumanWindowJoinsIntendedBeatAndReleaseReturnsToSavedCue() async throws {
        let tones = [900.0, 1300, 1700, 2100]
        func accent(_ samples: [Float], time: Double) -> Int {
            let start = Int(time * 48_000), end = min(samples.count, start + 960)
            let powers = tones.map { hz -> Double in
                var re = 0.0, im = 0.0
                for i in start..<end {
                    let angle = 2 * .pi * hz * Double(i - start) / 48_000
                    re += Double(samples[i]) * cos(angle); im += Double(samples[i]) * sin(angle)
                }
                return hypot(re, im)
            }
            return powers.firstIndex(of: powers.max()!)!
        }
        for (delta, rate, accepted, reverse) in [
            (-0.08, 1.0, true, false), (0.0, 1.0, true, false),
            (0.08, 1.0, true, false), (0.13, 1.0, true, true), (0.18, 1.0, false, true),
            (0.10, 1.16, true, true), (0.14, 1.16, false, false),
            (0.14, 0.84, true, false), (0.16, 0.84, false, true)
        ] {
            let referenceURL = try clicks(bpm: 120, offset: 0, channel: 0, accented: true)
            let cueURL = try clicks(bpm: 120, offset: 0.173, channel: 1, accented: true)
            defer { try? FileManager.default.removeItem(at: referenceURL); try? FileManager.default.removeItem(at: cueURL) }
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try mixer.enableOfflineRendering()
            let reference = reverse ? mixer.b : mixer.a, incoming = reverse ? mixer.a : mixer.b
            reference.load(referenceURL); incoming.load(cueURL)
            for _ in 0..<500 where reference.loading || incoming.loading { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNil(reference.error); XCTAssertNil(incoming.error)
            reference.setGrid(bpm: 120); incoming.setGrid(bpm: 120, offsetMs: 173)
            reference.tempo = rate; incoming.tempo = rate
            reference.level = 1; incoming.level = 1; mixer.volume = 1
            mixer.start()
            // The bar starts when the press from stopped comes out.
            let startDelay = reference.startDelay
            reference.togglePlay()
            let period = 0.5 / rate, boundary = startDelay + 4 * period
            let press = boundary + delta, release = boundary + 2.4 * period
            let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 240)!
            var left: [Float] = [], right: [Float] = []
            var pressed = false, released = false, lead = 0.12
            while left.count < 7 * 48_000 {
                let time = Double(left.count) / 48_000
                if !pressed && time >= press - 1e-9 {
                    lead = incoming.startDelay
                    incoming.cueDown(); pressed = true
                    XCTAssertTrue(incoming.previewing)
                }
                if !released && time >= release {
                    incoming.cueUp(); released = true
                    XCTAssertFalse(incoming.playing); XCTAssertFalse(incoming.previewing)
                    XCTAssertEqual(incoming.position, 0.173, accuracy: 1e-9)
                    XCTAssertEqual(incoming.cuePoint, 0.173, accuracy: 1e-9)
                }
                await AudioControlExecutor.shared.drain()
                if try mixer.renderOffline(into: pcm) == .success {
                    left.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                    right.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
                }
                await Task.yield()
            }
            let heard = attacks(right)
            let first = try XCTUnwrap(heard.first)
            // A press early enough meets the downbeat itself, whole.
            let whole = press + lead <= boundary + 0.002
            XCTAssertEqual(first, whole ? boundary : boundary + period, accuracy: 0.015)
            XCTAssertEqual(accent(right, time: first), whole ? 0 : accepted ? 1 : 0,
                           "Accepted late CUE must already be on beat two of its saved bar; outside the window starts beat one on the next reference beat")
            let second = try XCTUnwrap(heard.dropFirst().first)
            XCTAssertEqual(second - first, period, accuracy: 0.015)
            XCTAssertEqual(accent(right, time: second), whole ? 1 : accepted ? 2 : 1)
            let entry = Int((press + 0.12) * 48_000)
            if accepted {
                XCTAssertLessThan(right[entry..<min(entry + 960, right.count)].map { abs($0) }.max() ?? 0, 0.01,
                                  "No late replay of the saved downbeat")
            }
            XCTAssertLessThan(right[Int((release + 0.1) * 48_000)...].map { abs($0) }.max() ?? 0, 0.001)
            XCTAssertFalse(incoming.syncLocked)
            XCTAssertEqual(incoming.tempo, rate)
            print("MAIN CUE deltaMs=\(delta * 1000) rate=\(rate) accepted=\(accepted) firstAccent=\(accent(right, time: first) + 1)")
        }
    }

}
