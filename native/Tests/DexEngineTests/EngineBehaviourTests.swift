import CDexDSP
import CDexEngine
import Foundation
import XCTest

/// What a DJ relies on from the loop beyond gate 1's numbers.
final class EngineBehaviourTests: XCTestCase {
    let rate = 48_000.0

    private func steady(seconds: Double, rate: Double = 48_000, hz: Double = 220, level: Double = 0.4) -> SynthTrack {
        let w = 2 * Double.pi * hz / rate
        return SynthTrack(frames: Int64(seconds * rate), rate: rate) { frame, count, left, right in
            for k in 0..<count {
                let v = Float(level * sin(w * Double(frame + Int64(k))))
                left[k] = v
                right[k] = v
            }
        }
    }

    /// A ramp is different at every frame, so any wrong frame shows.
    private func ramp(seconds: Double) -> SynthTrack {
        SynthTrack(frames: Int64(seconds * 48_000), rate: 48_000) { frame, count, left, right in
            for k in 0..<count {
                let v = Float(Double((frame + Int64(k)) % 4_800_000) / 4_800_000 * 0.9)
                left[k] = v
                right[k] = -v
            }
        }
    }

    private func quietestWindow(_ x: ArraySlice<Float>, window: Int = 96) -> Float {
        var lowest = Float.infinity
        var i = x.startIndex
        while i + window <= x.endIndex {
            var peak: Float = 0
            for k in i..<(i + window) { peak = max(peak, abs(x[k])) }
            lowest = min(lowest, peak)
            i += window
        }
        return lowest
    }

    // MARK: Audio data

    /// The spec's point 5: a target that isn't ready. The outgoing audio plays on, unbroken, the
    /// attack isn't lost, and the count says it happened.
    func testATargetNotReadyKeepsTheOutgoingAudioPlaying() throws {
        let clicks = Clicks(first: 24_000, spacing: 24_000, bed: 0.1)
        let rig = Rig()
        let offset = Signal.detectorOffset(clicks, rate: rate)
        rig.load(clicks.track(seconds: 300, rate: rate))
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 2)

        rig.pumping = false // the disk has gone slow
        let target = clicks.frame(of: 400)
        let askedFor = rig.now + 4800
        dex_engine_jump(rig.engine, 0, [jump(to: target, at: askedFor, late: DEX_LATE_PERIOD, period: 24_000)])
        rig.render(seconds: 0.7)
        XCTAssertTrue(rig.deckState(0).landingPending)
        XCTAssertGreaterThan(rig.deckState(0).waitedBlocks, 0)
        XCTAssertEqual(rig.deckState(0).starvedBlocks, 0)

        rig.pumping = true // it comes back
        rig.render(seconds: 1)
        XCTAssertFalse(rig.deckState(0).landingPending)
        XCTAssertEqual(rig.deckState(0).lateLandings, 1)
        let landed = rig.deckState(0).lastLandingFrame
        XCTAssertEqual((landed - askedFor) % 24_000, 0, "a late landing keeps to the beat")
        XCTAssertGreaterThan(landed, askedFor)

        // No gap anywhere, the bed tone never stops; the attack comes out whole, on its frame.
        XCTAssertGreaterThan(quietestWindow(rig.tap(0)[48_000..<rig.tap(0).count], window: 1200), 0.02)
        let e = Signal.envelope(rig.tap(0))
        let found = try XCTUnwrap(Signal.peak(e, from: Int(landed) - 96, to: Int(landed) + 480, floor: 2))
        XCTAssertEqual((found - offset - Double(landed)) / 48, 0, accuracy: 1)
    }

    func testLatePoliciesAndALaterPressWins() throws {
        let track = steady(seconds: 200)
        let rig = Rig()
        rig.load(track)
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 1)

        // A frame already gone, sliding: lands at once, on the source frame that's still in time.
        let missedBy: Int64 = 2400
        dex_engine_jump(rig.engine, 0, [jump(to: 480_000, at: rig.now - missedBy, fadeEnds: false, late: DEX_LATE_SLIDE)])
        let pressed = rig.now
        rig.render(frames: 256)
        var s = rig.deckState(0)
        XCTAssertEqual(s.lateLandings, 1)
        XCTAssertEqual(s.lastLandingFrame, pressed)
        XCTAssertEqual(s.lastLandingPosition, 480_000 + Double(missedBy), accuracy: 1)

        // The same, holding: the source frame asked for.
        rig.render(seconds: 0.1)
        dex_engine_jump(rig.engine, 0, [jump(to: 960_000, at: rig.now - missedBy, fadeEnds: false, late: DEX_LATE_HOLD)])
        rig.render(frames: 256)
        s = rig.deckState(0)
        XCTAssertEqual(s.lastLandingPosition, 960_000, accuracy: 0.01)

        // Rapid presses: the last one wins, the ones before it are never heard.
        rig.render(seconds: 0.1)
        let landings = s.landings
        for press in 0..<5 {
            dex_engine_jump(rig.engine, 0, [jump(to: 1_000_000 + Double(press) * 48_000, at: rig.now + 9600, fadeEnds: false)])
        }
        rig.render(seconds: 0.5)
        s = rig.deckState(0)
        XCTAssertEqual(s.landings, landings + 1)
        XCTAssertEqual(s.lastLandingPosition, 1_192_000, accuracy: 0.01)
    }

    func testALongTrackPlaysExactlyWithoutFittingInMemory() throws {
        // 600 s of audio with room for about 44 s: every frame must still be the right one.
        let track = ramp(seconds: 600)
        let rig = Rig(chunkFrames: 65_536, chunksPerDeck: 32)
        rig.keepAudio = false
        rig.load(track)
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        var checked = 0
        var buffer = [Float](repeating: 0, count: 4096), other = buffer
        var taps = [UnsafeMutablePointer<Float>?](repeating: nil, count: 2)
        buffer.withUnsafeMutableBufferPointer { l in
            other.withUnsafeMutableBufferPointer { r in
                taps[0] = l.baseAddress
                taps[1] = r.baseAddress
            }
        }
        var outs = [[Float]](repeating: [Float](repeating: 0, count: 4096), count: 2)
        var frame: Int64 = 0
        var first: Int64? = nil
        var mismatches = 0
        let total = Int64(120 * rate)
        while frame < total {
            dex_engine_pump_loader(rig.engine)
            outs.withUnsafeMutableBufferPointer { all in
                let p = (0..<2).map { i in all[i].withUnsafeMutableBufferPointer { Optional($0.baseAddress!) } }
                p.withUnsafeBufferPointer { list in
                    taps.withUnsafeBufferPointer { tap in
                        dex_engine_render_tapped(rig.engine, 1024, UInt64(frame), list.baseAddress!, 2, tap.baseAddress!, nil)
                    }
                }
            }
            var state = DexEngineState()
            XCTAssertTrue(dex_engine_read_state(rig.engine, &state))
            if frame > 4800 {
                if first == nil { first = Int64(state.deck.0.position) - frame }
                for k in 0..<1024 {
                    let source = frame + Int64(k) + first!
                    let wanted = Float(Double(source % 4_800_000) / 4_800_000 * 0.9)
                    if buffer[k] != wanted { mismatches += 1 }
                    checked += 1
                }
            }
            XCTAssertLessThanOrEqual(state.deck.0.chunksResident, 32)
            frame += 1024
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertGreaterThan(checked, 5_000_000)
        print("long track: \(checked) frames exact, chunks kept \(32), track needs \(track.frames / 65_536 + 1)")
    }

    func testEverythingADJCanReachIsReadyOnALongTrack() throws {
        let track = steady(seconds: 900)
        let rig = Rig(chunkFrames: 65_536, chunksPerDeck: 64)
        rig.load(track)
        let beat = 24_000.0
        let cues = [120.0, 180, 240, 300, 420, 500, 700, 800].map { $0 * rate }
        var hotspots = cues + [60 * rate] // the hot cues and the main cue
        dex_engine_set_hotspots(rig.engine, 0, &hotspots, UInt32(hotspots.count))
        var reach = [-16 * 4 * beat, 16 * 4 * beat]   // the selected bar jump, both ways
        dex_engine_set_reach(rig.engine, 0, &reach, 2)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 1)
        for cue in cues { XCTAssertTrue(dex_engine_is_ready(rig.engine, 0, cue), "hot cue at \(cue / rate) s") }
        XCTAssertTrue(dex_engine_is_ready(rig.engine, 0, 60 * rate))
        let head = rig.deckState(0).positionEnd
        XCTAssertTrue(dex_engine_is_ready(rig.engine, 0, head + 16 * 4 * beat))
        // Hit them all while playing: nothing waits, however far apart they are.
        rig.pumping = false
        for cue in cues {
            dex_engine_jump(rig.engine, 0, [jump(to: cue, at: rig.now + 2400)])
            rig.render(seconds: 0.2)
        }
        XCTAssertEqual(rig.deckState(0).lateLandings, 0)
        XCTAssertEqual(rig.deckState(0).waitedBlocks, 0)
        XCTAssertEqual(rig.deckState(0).starvedBlocks, 0)
    }

    /// With nothing coming from the loader the playhead runs out of data, the one way to a gap.
    /// It holds its place, says so and carries on from the same frame.
    func testRunningOutOfDataHoldsThePositionAndRecovers() throws {
        let rig = Rig(chunkFrames: 4096, chunksPerDeck: 256)
        rig.load(steady(seconds: 120))
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 0.5)
        rig.pumping = false
        rig.render(seconds: 15)
        var s = rig.deckState(0)
        XCTAssertGreaterThan(s.starvedBlocks, 0)
        XCTAssertTrue(s.waitingForData)
        let held = s.position
        rig.render(seconds: 0.5)
        XCTAssertEqual(rig.deckState(0).position, held, accuracy: 0.001, "the clock doesn't run on without sound")
        rig.pumping = true
        rig.render(seconds: 1)
        s = rig.deckState(0)
        XCTAssertFalse(s.waitingForData)
        XCTAssertEqual(s.position, held + rate, accuracy: 0.05 * rate)
    }

    func testAudioThatCannotBeReadIsMissingNotSilentAndComesBack() throws {
        let rig = Rig(chunkFrames: 4096, chunksPerDeck: 256)
        let track = steady(seconds: 120)
        track.failing = true
        rig.load(track)
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 0.5)
        var s = rig.deckState(0)
        XCTAssertGreaterThan(s.readFailures, 0)
        XCTAssertEqual(s.chunksResident, 0, "a failed read keeps nothing")
        XCTAssertTrue(s.landingPending, "the start waits, as for any audio that isn't there yet")
        XCTAssertEqual(s.position, 0, "and the clock doesn't run over audio that was never read")
        // The file is back: the reads are tried again and the start comes out.
        track.failing = false
        Thread.sleep(forTimeInterval: 0.3)
        rig.render(seconds: 1)
        s = rig.deckState(0)
        XCTAssertFalse(s.landingPending)
        XCTAssertGreaterThan(s.position, 0.5 * rate)
        XCTAssertGreaterThan(rig.tap(0).suffix(4800).map(abs).max() ?? 0, 0.01)
        // A new track starts the count again.
        rig.load(steady(seconds: 10))
        rig.render(seconds: 0.1)
        XCTAssertEqual(rig.deckState(0).readFailures, 0)
    }

    func testChangingTracksGivesTheMemoryBack() throws {
        let rig = Rig(chunkFrames: 65_536, chunksPerDeck: 8)
        for cycle in 0..<6 {
            rig.load(steady(seconds: 60, hz: 200 + Double(cycle) * 50))
            dex_engine_play(rig.engine, 0, nil)
            rig.render(seconds: 2)
            let s = rig.deckState(0)
            XCTAssertLessThanOrEqual(s.chunksResident, 8)
            XCTAssertEqual(s.starvedBlocks, 0, "cycle \(cycle)")
            XCTAssertGreaterThan(quietestWindow(rig.tap(0).suffix(4800), window: 480), 0.1, "cycle \(cycle)")
        }
        dex_engine_unload(rig.engine, 0)
        rig.render(seconds: 0.2)
        XCTAssertFalse(rig.deckState(0).loaded)
        XCTAssertEqual(quietestWindow(rig.tap(0).suffix(4800), window: 480), 0)
    }

    // MARK: Moving between stretcher and resampler

    func testKeyLockChangesDoNotShiftTime() throws {
        let clicks = Clicks(first: 12_000, spacing: 24_000, bed: 0.05)
        let offset = Signal.detectorOffset(clicks, rate: rate)
        let rig = Rig()
        rig.load(clicks.track(seconds: 100, rate: rate))
        let tempo = 1.08
        dex_engine_set_tempo(rig.engine, 0, tempo)
        dex_engine_play(rig.engine, 0, [jump(to: 12_000, at: 4800)])
        var on = true
        var nextToggle: Int64 = 48_000
        rig.run(to: Int64(30 * rate)) { r in
            if r.now >= nextToggle {
                on.toggle()
                dex_engine_set_key_lock(r.engine, 0, on)
                nextToggle += 53_000 // comes at every point in the beat, in time
            }
        }
        // Every click stays on the one straight line from the start, through every change.
        let e = Signal.envelope(rig.tap(0))
        var stats = ErrorStats()
        var index = 0
        while true {
            let expected = 4800 + Double(index) * 24_000 / tempo
            guard expected + 1000 < Double(rig.tap(0).count) else { break }
            if let found = Signal.peak(e, from: Int(expected) - 240, to: Int(expected) + 720, floor: 1) {
                stats.add((found - offset - expected) / 48)
            }
            index += 1
        }
        print("key lock changes:", String(cString: dex_engine_stretcher_name(rig.engine)), stats, "changes", rig.deckState(0).landings)
        XCTAssertGreaterThan(stats.values.count, 50)
        XCTAssertLessThanOrEqual(stats.worst, 1)
    }

    /// Entering or leaving a scrub used to risk an 85 ms shift. Scrubbing at playing speed must
    /// leave the music exactly where it would have been.
    func testScrubHandoversDoNotShiftTime() throws {
        for keyLock in [true, false] {
            for tempo in [1.0, 1.08, 0.92] {
                let clicks = Clicks(first: 12_000, spacing: 24_000, bed: 0.05)
                let offset = Signal.detectorOffset(clicks, rate: rate)
                let rig = Rig()
                rig.load(clicks.track(seconds: 60, rate: rate))
                dex_engine_set_key_lock(rig.engine, 0, keyLock)
                dex_engine_set_tempo(rig.engine, 0, tempo)
                dex_engine_play(rig.engine, 0, [jump(to: 12_000, at: 4800)])
                rig.render(seconds: 3)
                dex_engine_scrub(rig.engine, 0, true)
                dex_engine_scrub_velocity(rig.engine, 0, tempo, 0)
                rig.render(seconds: 3)
                dex_engine_scrub(rig.engine, 0, false)
                rig.render(seconds: 3)
                let e = Signal.envelope(rig.tap(0))
                var stats = ErrorStats()
                var index = 0
                while true {
                    let expected = 4800 + Double(index) * 24_000 / tempo
                    guard expected + 1000 < Double(rig.tap(0).count) else { break }
                    if let found = Signal.peak(e, from: Int(expected) - 240, to: Int(expected) + 720, floor: 1) {
                        stats.add((found - offset - expected) / 48)
                    }
                    index += 1
                }
                print("scrub handover:", String(cString: dex_engine_stretcher_name(rig.engine)), keyLock, tempo, stats)
                XCTAssertGreaterThan(stats.values.count, 14)
                XCTAssertLessThanOrEqual(stats.worst, 1)
                XCTAssertTrue(rig.deckState(0).playing)
            }
        }
    }

    func testScrubMovesBothWaysWithinItsLimitAndStopsSilent() throws {
        let rig = Rig()
        rig.load(steady(seconds: 60))
        dex_engine_jump(rig.engine, 0, [jump(to: 20 * rate)])
        rig.render(seconds: 0.05)
        XCTAssertEqual(rig.deckState(0).position, 20 * rate, accuracy: 0.01)
        dex_engine_scrub(rig.engine, 0, true)
        dex_engine_scrub_velocity(rig.engine, 0, 2, 0)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(0).speed, 2, accuracy: 0.001)
        XCTAssertEqual(rig.deckState(0).positionEnd, 22 * rate, accuracy: 0.03 * rate)
        dex_engine_scrub_velocity(rig.engine, 0, -2, 0)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(0).speed, -2, accuracy: 0.001)
        XCTAssertEqual(rig.deckState(0).positionEnd, 20 * rate, accuracy: 0.03 * rate)
        // The agreed limit, whatever is asked.
        dex_engine_scrub_velocity(rig.engine, 0, 50, 0)
        rig.render(seconds: 0.5)
        XCTAssertEqual(rig.deckState(0).speed, 8, accuracy: 0.001)
        // A coast dies away by itself.
        dex_engine_scrub_velocity(rig.engine, 0, 4, 6)
        rig.render(seconds: 3)
        XCTAssertLessThan(abs(rig.deckState(0).speed), 0.01)
        // Holding still is silent, and leaves nothing standing on the output.
        dex_engine_scrub_velocity(rig.engine, 0, 0, 0)
        rig.render(seconds: 0.5)
        XCTAssertLessThan(rig.tap(0).suffix(4800).map(abs).max()!, 1e-3)
        // It was paused before, so it stays paused and parked where the platter lifted.
        let lifted = rig.deckState(0).positionEnd
        dex_engine_scrub(rig.engine, 0, false)
        rig.render(seconds: 0.2)
        XCTAssertFalse(rig.deckState(0).playing)
        XCTAssertEqual(rig.deckState(0).positionEnd, lifted, accuracy: 1)
        XCTAssertEqual(rig.tap(0).suffix(4800).map(abs).max()!, 0)
        // Runs up against the end of the track and stops there, no matter how hard it's pushed.
        dex_engine_scrub(rig.engine, 0, true)
        dex_engine_scrub_velocity(rig.engine, 0, -8, 0)
        rig.render(seconds: 12)
        XCTAssertEqual(rig.deckState(0).positionEnd, 0, accuracy: 1)
    }

    // MARK: SYNC

    private func lockedPair(tempoA: Double = 1) -> (Rig, Clicks, Clicks) {
        let a = Clicks(first: 12_000, spacing: rate * 60 / 140), b = Clicks(first: 6_000, spacing: rate * 60 / 134)
        let rig = Rig()
        rig.load(a.track(seconds: 200, rate: rate), deck: 0)
        rig.load(b.track(seconds: 200, rate: rate), deck: 1)
        dex_engine_set_grid(rig.engine, 0, a.first, a.spacing)
        dex_engine_set_grid(rig.engine, 1, b.first, b.spacing)
        dex_engine_set_tempo(rig.engine, 0, tempoA)
        dex_engine_set_master(rig.engine, 0)
        dex_engine_set_sync(rig.engine, 1, true)
        dex_engine_play(rig.engine, 0, [jump(to: a.frame(of: 4))])
        dex_engine_play(rig.engine, 1, [jump(to: b.frame(of: 4), align: true)])
        return (rig, a, b)
    }

    /// The deck left playing on its own leads, only when what's playing changes, and a MASTER
    /// holds until then.
    func testTheDeckLeftPlayingAloneLeads() throws {
        let rig = Rig()
        rig.load(steady(seconds: 30), deck: 0)
        rig.load(steady(seconds: 30), deck: 1)
        func master() -> Int { rig.deckState(0).isMaster ? 0 : rig.deckState(1).isMaster ? 1 : -1 }
        dex_engine_set_master(rig.engine, 0)
        dex_engine_play(rig.engine, 1, nil)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 1, "B plays alone, so it leads")
        dex_engine_set_master(rig.engine, 0)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 0, "MASTER on stopped A holds")
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 0, "two playing: no election")
        dex_engine_pause(rig.engine, 0, -1)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 1, "A stopped, B left alone")
        // A held CUE isn't heard playing.
        dex_engine_set_preview(rig.engine, 0, true)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 1)
        // A deck unloaded while both play isn't playing any more.
        dex_engine_set_preview(rig.engine, 0, false)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 1, "two playing again: no election")
        dex_engine_unload(rig.engine, 0)
        rig.render(seconds: 0.1)
        XCTAssertEqual(master(), 1, "A unloaded, B left alone")
    }

    func testTheMasterIsNeverMovedAndSteeringStaysInItsLimit() throws {
        let (rig, _, _) = lockedPair(tempoA: 1.04)
        rig.render(seconds: 30)
        for state in rig.states.dropFirst(50) {
            XCTAssertEqual(state.deck.0.steer, 0)
            XCTAssertEqual(state.deck.0.tempo, 1.04)
            XCTAssertLessThanOrEqual(abs(state.deck.1.steer), 0.004 + 1e-9)
        }
        XCTAssertEqual(rig.deckState(1).tempo, 1.04 * 140 / 134, accuracy: 1e-9)
    }

    func testASmallErrorIsSteeredAndALargeOneReLands() throws {
        let (rig, _, b) = lockedPair()
        rig.render(seconds: 5)
        XCTAssertEqual(rig.deckState(1).relocks, 0)
        XCTAssertLessThan(abs(rig.deckState(1).phaseErrorMs), 0.5)
        // Nudge the follower 12 ms off: under the limit, so steered back with no jump.
        let beforeLandings = rig.deckState(1).landings
        var there = rig.deckState(1).positionEnd + rig.deckState(1).speed * 9600 + 0.012 * rate * rig.deckState(1).speed
        dex_engine_jump(rig.engine, 1, [jump(to: there, at: rig.now + 9600, fadeEnds: false)])
        rig.render(seconds: 0.5)
        XCTAssertGreaterThan(abs(rig.deckState(1).phaseErrorMs), 5, "the nudge took")
        XCTAssertEqual(rig.deckState(1).relocks, 0)
        rig.render(seconds: 8)
        XCTAssertEqual(rig.deckState(1).relocks, 0)
        XCTAssertEqual(rig.deckState(1).landings, beforeLandings + 1, "steered, no more landings")
        XCTAssertLessThan(abs(rig.deckState(1).phaseErrorMs), 0.2)
        // 30 ms off: a real jump, so it re-lands, once, and it's right straight after.
        there = rig.deckState(1).positionEnd + rig.deckState(1).speed * 9600 + 0.030 * rate * rig.deckState(1).speed
        dex_engine_jump(rig.engine, 1, [jump(to: there, at: rig.now + 9600, fadeEnds: false)])
        rig.render(seconds: 0.5)
        XCTAssertEqual(rig.deckState(1).relocks, 1)
        XCTAssertLessThan(abs(rig.deckState(1).phaseErrorMs), 1)
        _ = b
    }

    func testAJumpOnTheMasterLandsWithItsFollowerOnTheSameFrame() throws {
        let (rig, a, _) = lockedPair()
        rig.render(seconds: 3)
        // Half a beat: a real change in where the beat is.
        let frame = rig.now + 9600
        let s = rig.deckState(0)
        dex_engine_jump(rig.engine, 0, [jump(to: s.positionEnd + s.speed * 9600 + 0.5 * a.spacing, at: frame, fadeEnds: false)])
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(1).relocks, 1)
        XCTAssertEqual(rig.deckState(0).lastLandingFrame, frame)
        XCTAssertEqual(rig.deckState(1).lastLandingFrame, frame)
        XCTAssertLessThan(abs(rig.deckState(1).phaseErrorMs), 1)
    }

    func testNoLockBeyondTheTempoRange() throws {
        let (rig, _, _) = lockedPair()
        dex_engine_set_grid(rig.engine, 1, 6000, rate * 60 / 100) // 100 BPM against 140 can't lock
        dex_engine_set_tempo(rig.engine, 1, 1.02)
        rig.render(seconds: 3)
        XCTAssertEqual(rig.deckState(1).tempo, 1.02)
        XCTAssertEqual(rig.deckState(1).steer, 0)
        XCTAssertEqual(rig.deckState(1).relocks, 0)
    }

    func testAMastersCueHoldAndScrubAreNotFollowed() throws {
        let (rig, a, _) = lockedPair()
        rig.render(seconds: 2)
        // A held CUE isn't heard playing, which hands the lead to B; MASTER pressed after puts it back on A.
        dex_engine_set_preview(rig.engine, 0, true)
        rig.render(frames: rig.blockFrames)
        XCTAssertTrue(rig.deckState(1).isMaster)
        dex_engine_set_master(rig.engine, 0)
        let s = rig.deckState(0)
        dex_engine_jump(rig.engine, 0, [jump(to: s.positionEnd + 0.3 * a.spacing)])
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(1).relocks, 0)
        dex_engine_set_preview(rig.engine, 0, false)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(1).relocks, 1)
        dex_engine_scrub(rig.engine, 1, true)
        dex_engine_scrub_velocity(rig.engine, 1, 3, 0)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.deckState(1).relocks, 1, "a jog isn't chased")
    }

    func testALoopUnderABeatLocksToItsOwnLength() throws {
        let (rig, _, b) = lockedPair()
        rig.render(seconds: 3)
        let beats = ((rig.deckState(1).position - b.first) / b.spacing).rounded(.up)
        let start = b.first + beats * b.spacing
        dex_engine_set_loop(rig.engine, 1, true, start, start + b.spacing / 2)
        rig.render(seconds: 10)
        XCTAssertEqual(rig.deckState(1).relocks, 0, "half a beat apart is in time for a half-beat loop")
        XCTAssertLessThan(abs(rig.deckState(1).phaseErrorMs), 1)
    }

    // MARK: Device blocks

    /// The device picks the block size, and it can change. Landings and clocks mustn't care.
    func testBlockSizesDoNotMatter() throws {
        for block in [32, 64, 128, 333, 512, 1024, 4096] {
            let clicks = Clicks(first: 24_000, spacing: 24_000)
            let offset = Signal.detectorOffset(clicks, rate: rate)
            let rig = Rig(blockFrames: block)
            rig.load(clicks.track(seconds: 60, rate: rate))
            dex_engine_set_tempo(rig.engine, 0, 1.08)
            dex_engine_play(rig.engine, 0, nil)
            rig.render(seconds: 3)
            let frame = rig.now + 8192
            dex_engine_jump(rig.engine, 0, [jump(to: clicks.frame(of: 50), at: frame)])
            rig.render(seconds: 4)
            XCTAssertEqual(rig.deckState(0).lastLandingFrame, frame)
            let e = Signal.envelope(rig.tap(0))
            let found = try XCTUnwrap(Signal.peak(e, from: Int(frame) - 96, to: Int(frame) + 480, floor: 2))
            XCTAssertEqual((found - offset - Double(frame)) / 48, 0, accuracy: 1, "block \(block)")
            var stats = ErrorStats()
            for index in 51..<56 {
                let expected = Double(frame) + Double(index - 50) * 24_000 / 1.08
                if let at = Signal.peak(e, from: Int(expected) - 480, to: Int(expected) + 480, floor: 2) {
                    let clock = rig.clock(deck: 0, at: Int(at))
                    stats.add((clock.position - clicks.frame(of: index) - offset * clock.speed) / (clock.speed * 48))
                }
            }
            print("block \(block):", String(cString: dex_engine_stretcher_name(rig.engine)), stats)
            XCTAssertEqual(stats.values.count, 5)
            // A clock read from a large block is only as good as that block's speed reading.
            XCTAssertLessThanOrEqual(stats.worst, 1, "block \(block)")
        }
    }

    // MARK: The display

    func testTheDisplayExtrapolatesAndStopsWhenTheAudioStalls() throws {
        let rig = Rig(blockFrames: 512)
        rig.load(steady(seconds: 30))
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_set_tempo(rig.engine, 0, 1.08)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 2)
        let state = rig.states.last!
        let host = Double(state.hostTime)
        let speed = state.deck.0.speed
        XCTAssertEqual(speed, 1.08, accuracy: 1e-6)
        let delay = Double(state.engineDelayFrames) / rate

        func position(afterSeconds s: Double, delay d: Double = 0) -> Double {
            withUnsafePointer(to: state) { dex_engine_position_at($0, 0, UInt64(host + s * 1e9), 1e9, d) }
        }
        let base = state.deck.0.position
        XCTAssertEqual(position(afterSeconds: delay), base, accuracy: 0.01)
        XCTAssertEqual(position(afterSeconds: delay + 0.01), base + 0.01 * rate * speed, accuracy: 0.01)
        // The device's reported delay moves it back by exactly that.
        XCTAssertEqual(position(afterSeconds: delay + 0.01, delay: 0.25), base + (0.01 - 0.25) * rate * speed, accuracy: 0.01)
        // A stalled engine: the display stops within a block and 50 ms, however long it's been.
        let limit = Double(state.blockFrames) / rate + 0.05
        let frozen = position(afterSeconds: 10)
        XCTAssertEqual(frozen, base + limit * rate * speed, accuracy: 0.01)
        XCTAssertEqual(position(afterSeconds: 60), frozen, accuracy: 0.001)
        // A paused deck doesn't move.
        dex_engine_pause(rig.engine, 0, -1)
        rig.render(seconds: 0.2)
        let paused = rig.states.last!
        let p = withUnsafePointer(to: paused) { dex_engine_position_at($0, 0, paused.hostTime + 1_000_000_000, 1e9, 0) }
        XCTAssertEqual(p, paused.deck.0.positionEnd)
    }

    func testCommandsAreConfirmedAndTheQueueIsBounded() throws {
        let rig = Rig()
        rig.load(steady(seconds: 10))
        let sequence = dex_engine_set_tempo(rig.engine, 0, 1.01)
        XCTAssertGreaterThan(sequence, 0)
        rig.render(frames: 256)
        XCTAssertEqual(rig.states.last!.confirmedCommand, sequence)
        XCTAssertEqual(rig.deckState(0).tempo, 1.01)
        var sent = 0
        for _ in 0..<5000 where dex_engine_set_tempo(rig.engine, 0, 1.0) != 0 { sent += 1 }
        XCTAssertEqual(sent, 1024, "bounded: refused, never blocked or grown")
        XCTAssertEqual(dex_engine_set_tempo(rig.engine, 0, 1.0), 0)
        // A load that can't be sent takes nothing: the loader stays on the track the loop has.
        let other = steady(seconds: 10)
        rig.tracks.append(other)
        var source = other.source
        XCTAssertEqual(dex_engine_load(rig.engine, 0, &source, 0), 0)
        dex_engine_pump_loader(rig.engine)
        XCTAssertEqual(other.reads, 0, "nothing was read for a track the loop never took")
        rig.render(frames: 256)
        XCTAssertNotEqual(dex_engine_set_tempo(rig.engine, 0, 1.0), 0)
        XCTAssertNotEqual(dex_engine_load(rig.engine, 0, &source, 0), 0)
    }

    func testPausingFadesAndParksAndTheEndOfATrackStops() throws {
        let rig = Rig()
        rig.load(steady(seconds: 3))
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 1)
        let at = rig.now + 960
        dex_engine_pause(rig.engine, 0, at)
        rig.render(seconds: 0.2)
        XCTAssertFalse(rig.deckState(0).playing)
        let parked = rig.deckState(0).positionEnd
        XCTAssertEqual(parked, Double(at) + 480 - Double(rig.states.first!.deck.0.lastLandingFrame), accuracy: 1)
        // It fades over the agreed 10 ms, and it's fully silent after that.
        let x = rig.tap(0)
        XCTAssertGreaterThan(x[Int(at)..<Int(at) + 100].map(abs).max()!, 0.1)
        XCTAssertEqual(x[(Int(at) + 481)...].map(abs).max()!, 0)
        // Play carries on from there; the end of the track stops it for good.
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 3)
        XCTAssertFalse(rig.deckState(0).playing)
        XCTAssertTrue(rig.deckState(0).ended)
        XCTAssertEqual(rig.deckState(0).positionEnd, 3 * rate, accuracy: 1)
        dex_engine_jump(rig.engine, 0, [jump(to: 0)])
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 0.2)
        XCTAssertTrue(rig.deckState(0).playing)
    }

    // MARK: Tone and mix: DexMixer's logic as plain calls

    func testFlatToneIsBitTransparent() throws {
        let track = ramp(seconds: 20)
        let rig = Rig()
        rig.load(track)
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, [jump(to: 48_000, at: 480, fadeEnds: false)])
        rig.render(seconds: 2)
        let x = rig.tap(0)
        for i in 960..<x.count {
            let source = Float(Double(48_000 + i - 480) / 4_800_000 * 0.9)
            if x[i] != source { return XCTFail("frame \(i): \(x[i]) against \(source)") }
        }
    }

    func testKillsSweepGainsAndVolume() throws {
        let rig = Rig()
        rig.load(steady(seconds: 30, hz: 60, level: 0.4))
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 1)
        func tail(_ x: [Float]) -> Float { x.suffix(4800).map(abs).max()! }
        XCTAssertEqual(tail(rig.master[0]), 0.4, accuracy: 0.01)
        // A low-band kill takes a 60 Hz tone away, and the fader, crossfader and volume all scale.
        dex_engine_set_tone(rig.engine, 0, 0, 1, 1, 1)
        rig.render(seconds: 1)
        XCTAssertLessThan(tail(rig.tap(0)), 0.02)
        dex_engine_set_tone(rig.engine, 0, 1, 1, 1, 1)
        rig.render(seconds: 1)
        XCTAssertEqual(tail(rig.tap(0)), 0.4, accuracy: 0.01)
        dex_engine_set_fader(rig.engine, 0, 0.5, 0.5)
        rig.render(seconds: 0.2)
        XCTAssertEqual(tail(rig.tap(0)), 0.4, accuracy: 0.01, "the tap is before the fader")
        XCTAssertEqual(tail(rig.master[0]), 0.1, accuracy: 0.005)
        dex_engine_set_fader(rig.engine, 0, 1, 1)
        dex_engine_set_volume(rig.engine, 0.5)
        rig.render(seconds: 0.2)
        XCTAssertEqual(tail(rig.master[0]), 0.2, accuracy: 0.005)
        // The high-pass end of the sweep removes the same tone.
        dex_engine_set_volume(rig.engine, 1)
        dex_engine_set_sweep(rig.engine, 0, 1)
        rig.render(seconds: 1)
        XCTAssertLessThan(tail(rig.tap(0)), 0.05)
    }

    func testVolumeFeedsTheLimiterSoTheOutputNeverClips() throws {
        let rig = Rig()
        rig.load(steady(seconds: 30, hz: 80, level: 0.9), deck: 0)
        rig.load(steady(seconds: 30, hz: 120, level: 0.9), deck: 1)
        for deck in Int32(0)...1 {
            dex_engine_set_key_lock(rig.engine, deck, false)
            dex_engine_play(rig.engine, deck, nil)
        }
        dex_engine_set_volume(rig.engine, 1)
        rig.render(seconds: 3)
        XCTAssertLessThanOrEqual(rig.master[0].map(abs).max()!, 0.99 + 1e-4)
        XCTAssertGreaterThan(rig.master[0].suffix(9600).map(abs).max()!, 0.95)
        // Turned down, the limiter has headroom: what it passes is simply the sum.
        dex_engine_set_volume(rig.engine, 0.25)
        rig.render(seconds: 1)
        XCTAssertLessThanOrEqual(rig.master[0].suffix(9600).map(abs).max()!, 0.46)
        XCTAssertGreaterThan(rig.master[0].suffix(9600).map(abs).max()!, 0.4)
    }

    func testTheLimiterOnlyDelaysBelowFullScale() throws {
        let track = ramp(seconds: 20)
        let rig = Rig()
        rig.load(track)
        dex_engine_set_key_lock(rig.engine, 0, false)
        dex_engine_play(rig.engine, 0, [jump(to: 48_000, at: 480, fadeEnds: false)])
        rig.render(seconds: 1)
        let delay = Int(rig.states.last!.engineDelayFrames)
        for i in 2000..<40_000 {
            XCTAssertEqual(rig.master[0][i + delay], rig.tap(0)[i], accuracy: 1e-6)
        }
    }

    func testCueRoutingKeepsItsAgreedMeaning() throws {
        let rig = Rig()
        rig.load(steady(seconds: 20, hz: 500, level: 0.4), deck: 0)
        rig.load(steady(seconds: 20, hz: 2000, level: 0.2), deck: 1)
        for deck in Int32(0)...1 {
            dex_engine_set_key_lock(rig.engine, deck, false)
            dex_engine_play(rig.engine, deck, nil)
        }
        // Deck A on the master only, B silent there; with nothing on CUE, split is the stereo master.
        dex_engine_set_fader(rig.engine, 1, 0, 1)
        dex_engine_set_route(rig.engine, Int32(DEX_ROUTE_SPLIT), 1, 0, 0)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.master[0].suffix(4800).map(abs).max()!, 0.4, accuracy: 0.01)
        XCTAssertEqual(rig.master[1].suffix(4800).map(abs).max()!, 0.4, accuracy: 0.01)
        // B on CUE, cue mix all the way to cue: mono master left, cue alone right, at B's level.
        dex_engine_set_route(rig.engine, Int32(DEX_ROUTE_SPLIT), 1, 0, 1)
        rig.render(seconds: 1)
        XCTAssertEqual(rig.master[0].suffix(4800).map(abs).max()!, 0.4, accuracy: 0.01)
        XCTAssertEqual(rig.master[1].suffix(4800).map(abs).max()!, 0.2, accuracy: 0.01)
        // The cue is in step with the master: the look-ahead is on both.
        let delay = Int(rig.states.last!.engineDelayFrames)
        let cue = rig.master[1].suffix(4800), tap = rig.tap(1).suffix(4800 + delay).prefix(4800)
        for (a, b) in zip(cue, tap) { XCTAssertEqual(a, b, accuracy: 0.002) }
    }

    func testTheCuePeakGuardHoldsFullScale() throws {
        let rig = Rig()
        rig.load(steady(seconds: 20, hz: 200, level: 0.9), deck: 0)
        rig.load(steady(seconds: 20, hz: 300, level: 0.9), deck: 1)
        for deck in Int32(0)...1 {
            dex_engine_set_key_lock(rig.engine, deck, false)
            dex_engine_play(rig.engine, deck, nil)
        }
        dex_engine_set_route(rig.engine, Int32(DEX_ROUTE_SPLIT), 1, 1, 1)
        rig.render(seconds: 2)
        XCTAssertLessThanOrEqual(rig.master[1].suffix(48_000).map(abs).max()!, 1.0001)
    }

    // MARK: Real threads

    /// A loader on its own thread, a control thread, a render thread, all at once and flat out.
    /// Run this one under the Thread Sanitizer too: `swift test --sanitize=thread --filter ...`.
    func testThreadsTogether() throws {
        var config = DexEngineConfig()
        config.sampleRate = 48_000
        config.maxFrames = 1024
        config.chunkFrames = 8192
        config.chunksPerDeck = 64
        config.loaderThread = true
        config.hostTicksPerSecond = 1e9
        let engine = dex_engine_create(&config)!
        defer { dex_engine_destroy(engine) }
        let beat = 24_000.0
        let clicks = Clicks(first: beat, spacing: beat, bed: 0.1)
        var tracks: [SynthTrack] = []
        func loadSomething(_ deck: Int32) {
            let t = clicks.track(seconds: 120, rate: tracks.count % 2 == 0 ? 48_000 : 44_100)
            tracks.append(t)
            var s = t.source
            dex_engine_load(engine, deck, &s, 0)
        }
        loadSomething(0)
        loadSomething(1)
        nonisolated(unsafe) let unsafeEngine = engine
        let done = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var stop = false; let lock = NSLock()
            var value: Bool { get { lock.lock(); defer { lock.unlock() }; return stop } set { lock.lock(); stop = newValue; lock.unlock() } } }
        let flag = Flag()
        let render = Thread {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: 1024), r = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
            defer { l.deallocate(); r.deallocate() }
            var outs: [UnsafeMutablePointer<Float>?] = [l, r]
            var host: UInt64 = 0
            while !flag.value {
                outs.withUnsafeMutableBufferPointer { dex_engine_render(unsafeEngine, 256, host, $0.baseAddress!, 2) }
                host += 5_333_333
                // Four times real time, so the loader has to work but isn't simply outrun.
                usleep(1300)
            }
            done.signal()
        }
        render.start()
        dex_engine_play(engine, 0, nil)
        dex_engine_play(engine, 1, nil)
        var state = DexEngineState()
        let until = Date().addingTimeInterval(4)
        var step = 0
        while Date() < until {
            step += 1
            let deck = Int32(step % 2)
            switch step % 7 {
            case 0: dex_engine_jump(engine, deck, [jump(to: beat * Double(step % 200))])
            case 1: dex_engine_set_tempo(engine, deck, 0.9 + Double(step % 20) / 100)
            case 2: dex_engine_set_key_lock(engine, deck, step % 4 == 0)
            case 3: dex_engine_set_loop(engine, deck, step % 6 == 0, beat * 10, beat * 11)
            case 4: var spots = [beat * Double(step % 100), beat * 2]; dex_engine_set_hotspots(engine, deck, &spots, 2)
            case 5: if step % 70 == 5 { loadSomething(deck); dex_engine_play(engine, deck, nil) }
            default: _ = dex_engine_read_state(engine, &state)
            }
            usleep(2000)
        }
        flag.value = true
        done.wait()
        XCTAssertTrue(dex_engine_read_state(engine, &state))
    }
}
