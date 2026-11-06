import CDexEngine
import XCTest

/// Gate 1 of docs/ENGINE-REBUILD-SPEC.md: the engine on its own, with no device. Everything here
/// runs the same callback a device would call, and judges by clicks found in the sound. A limit
/// here is the spec's: don't loosen one to pass.
final class EngineGateTests: XCTestCase {
    static let tempos = [0.84, 0.92, 1.0, 1.08, 1.16]
    let rate = 48_000.0
    let limitMs = 1.0

    /// Every click's output frame, found from the sound alone.
    private func clicksFound(_ audio: [Float], rate: Double = 48_000, threshold: Float = 2, gapMs: Double = 40) -> [Double] {
        let envelope = Signal.envelope(audio, width: Int(rate / 1000))
        let gap = Int(gapMs * rate / 1000)
        var found: [Double] = []
        var i = 0
        while i < envelope.count {
            if envelope[i] > threshold, let peak = Signal.peak(envelope, from: i, to: i + gap, floor: threshold) {
                found.append(peak)
                i = Int(peak) + gap
            } else { i += 1 }
        }
        return found
    }

    // MARK: Clock against sound within 1 ms, at each tempo, key lock on and off

    func testClockAgainstSoundAtEveryTempo() throws {
        for keyLock in [true, false] {
            for tempo in Self.tempos {
                for bed in [0.0, 0.03] {
                    let clicks = Clicks(first: 24_000, spacing: 24_000, bed: bed)
                    let rig = Rig()
                    let offset = Signal.detectorOffset(clicks, rate: rate)
                    rig.load(clicks.track(seconds: 40, rate: rate))
                    dex_engine_set_tempo(rig.engine, 0, tempo)
                    dex_engine_set_key_lock(rig.engine, 0, keyLock)
                    dex_engine_play(rig.engine, 0, nil)
                    rig.render(seconds: 20)
                    let found = clicksFound(rig.tap(0))
                    var stats = ErrorStats()
                    for frame in found.dropFirst() {
                        let clock = rig.clock(deck: 0, at: Int(frame))
                        let nearest = ((clock.position - clicks.first) / clicks.spacing).rounded()
                        let truth = clicks.frame(of: Int(nearest)) + offset * clock.speed
                        stats.add((clock.position - truth) / (clock.speed * 48))
                    }
                    let label = "\(keyLock ? "key lock" : "free") \(tempo) bed \(bed)"
                    print("clock against sound:", label, stats)
                    XCTAssertGreaterThanOrEqual(stats.values.count, Int(19 * 2 * tempo) - 2, label)
                    XCTAssertLessThanOrEqual(stats.worst, limitMs, label)
                    XCTAssertEqual(rig.deckState(0).starvedBlocks, 0, label)
                }
            }
        }
    }

    /// The position describes the audio leaving the stretcher, through speed changes too. The
    /// tempo moves in steps while it plays, and every click must still be where the clock says.
    func testClockAgainstSoundThroughSpeedChanges() throws {
        for keyLock in [true, false] {
            for (label, tempos) in [("small steps", [1.0, 1.01, 1.02, 1.01, 0.99, 0.98]), ("large steps", [1.0, 1.08, 0.92, 1.16, 0.84, 1.04])] {
                let clicks = Clicks(first: 24_000, spacing: 24_000, bed: 0.02)
                let rig = Rig()
                let offset = Signal.detectorOffset(clicks, rate: rate)
                rig.load(clicks.track(seconds: 80, rate: rate))
                dex_engine_set_key_lock(rig.engine, 0, keyLock)
                dex_engine_play(rig.engine, 0, nil)
                var next: Int64 = 48_000
                var index = 0
                rig.run(to: Int64(40 * rate)) { r in
                    if r.now >= next {
                        dex_engine_set_tempo(r.engine, 0, tempos[index % tempos.count])
                        index += 1
                        next += 65_771 // lands at every point in the beat, in time
                    }
                }
                var stats = ErrorStats()
                for frame in clicksFound(rig.tap(0)).dropFirst() {
                    let clock = rig.clock(deck: 0, at: Int(frame))
                    let nearest = ((clock.position - clicks.first) / clicks.spacing).rounded()
                    stats.add((clock.position - clicks.frame(of: Int(nearest)) - offset * clock.speed) / (clock.speed * 48))
                }
                let what = "\(keyLock ? "key lock" : "free") \(label)"
                print("clock through speed changes:", what, stats)
                XCTAssertGreaterThan(stats.values.count, 60, what)
                XCTAssertLessThanOrEqual(stats.worst, limitMs, what)
            }
        }
    }

    /// And across loop wraps: every click inside a looping passage, read against the clock.
    func testClockAgainstSoundInsideLoops() throws {
        for keyLock in [true, false] {
            for tempo in [0.92, 1.0, 1.16] {
                for beats in [1.0, 4.0] {
                    let beat = 24_000.0
                    let clicks = Clicks(first: beat, spacing: beat / 4, bed: 0.02)
                    let rig = Rig()
                    let offset = Signal.detectorOffset(clicks, rate: rate)
                    let loopIn = beat * 8, loopOut = loopIn + beats * beat
                    rig.load(clicks.track(seconds: 30, rate: rate))
                    dex_engine_set_tempo(rig.engine, 0, tempo)
                    dex_engine_set_key_lock(rig.engine, 0, keyLock)
                    dex_engine_set_loop(rig.engine, 0, true, loopIn, loopOut)
                    dex_engine_play(rig.engine, 0, [jump(to: loopIn, at: 4800)])
                    rig.render(seconds: 15)
                    var stats = ErrorStats()
                    for frame in clicksFound(rig.tap(0), gapMs: 30).dropFirst(2) {
                        let clock = rig.clock(deck: 0, at: Int(frame))
                        // A block holding a wrap can't describe both sides, so its readings only
                        // count from the wrap's own frame.
                        let state = rig.states.last { $0.outputFrame <= UInt64(frame) }!
                        if state.deck.0.lastLandingFrame > Int64(state.outputFrame) { continue }
                        if abs(frame - Double(state.deck.0.lastLandingFrame)) < 1000 { continue }
                        let nearest = ((clock.position - clicks.first) / clicks.spacing).rounded()
                        stats.add((clock.position - clicks.frame(of: Int(nearest)) - offset * clock.speed) / (clock.speed * 48))
                    }
                    let what = "\(keyLock ? "key lock" : "free") \(tempo) \(beats) beats"
                    print("clock in loops:", what, stats)
                    XCTAssertGreaterThan(stats.values.count, 20, what)
                    XCTAssertLessThanOrEqual(stats.worst, limitMs, what)
                }
            }
        }
    }

    /// The same check on what leaves the engine: the limiter's look-ahead is the only difference
    /// between a deck and the output, and the state says exactly how long it is.
    func testClockAgainstMasterOutput() throws {
        let clicks = Clicks(first: 24_000, spacing: 24_000)
        let rig = Rig()
        let offset = Signal.detectorOffset(clicks, rate: rate)
        rig.load(clicks.track(seconds: 30, rate: rate))
        dex_engine_set_tempo(rig.engine, 0, 1.08)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 15)
        let delay = Double(rig.states.last!.engineDelayFrames)
        XCTAssertGreaterThan(delay, 0)
        var stats = ErrorStats()
        for frame in clicksFound(rig.master[0]).dropFirst() {
            let clock = rig.clock(deck: 0, at: Int(frame - delay))
            let nearest = ((clock.position - clicks.first) / clicks.spacing).rounded()
            stats.add((clock.position - clicks.frame(of: Int(nearest)) - offset * clock.speed) / (clock.speed * 48))
        }
        print("clock against master output:", stats)
        XCTAssertGreaterThanOrEqual(stats.values.count, 25)
        XCTAssertLessThanOrEqual(stats.worst, limitMs)
    }

    /// A file at any rate plays at the right speed on any output rate, clock and sound agreeing.
    func testAnySourceRateOnAnyOutputRate() throws {
        for outputRate in [44_100.0, 48_000.0] {
            for sourceRate in [44_100.0, 48_000.0, 96_000.0] {
                for keyLock in [true, false] {
                    for tempo in [1.0, 1.08] {
                        let spacingSeconds = 0.5
                        let clicks = Clicks(first: sourceRate * 0.5, spacing: sourceRate * spacingSeconds)
                        let rig = Rig(rate: outputRate)
                        rig.load(clicks.track(seconds: 20, rate: sourceRate))
                        dex_engine_set_tempo(rig.engine, 0, tempo)
                        dex_engine_set_key_lock(rig.engine, 0, keyLock)
                        dex_engine_play(rig.engine, 0, nil)
                        rig.render(seconds: 10)
                        let found = clicksFound(rig.tap(0), rate: outputRate)
                        let label = "\(sourceRate) on \(outputRate), \(keyLock ? "key lock" : "free"), \(tempo)"
                        XCTAssertGreaterThanOrEqual(found.count, 15, label)
                        // Right speed: clicks a known distance apart, in output time.
                        let wanted = spacingSeconds / tempo * outputRate
                        let measured = (found.last! - found.first!) / Double(found.count - 1)
                        XCTAssertEqual(measured / wanted, 1, accuracy: 0.0005, label)
                        // Right clock: the clock's own idea of where each one is. The detector reads a
                        // click a little after it starts, by the same time at any rate.
                        let probe = Clicks(first: outputRate * 0.5, spacing: outputRate * 0.5)
                        let offsetMs = Signal.detectorOffset(probe, rate: outputRate, width: Int(outputRate / 1000)) * 1000 / outputRate
                        var stats = ErrorStats()
                        for frame in found.dropFirst() {
                            let clock = rig.clock(deck: 0, at: Int(frame))
                            let nearest = ((clock.position - clicks.first) / clicks.spacing).rounded()
                            let msPerFrame = 1000 / (clock.speed * outputRate)
                            stats.add((clock.position - clicks.frame(of: Int(nearest))) * msPerFrame - offsetMs)
                        }
                        print("rates:", label, stats)
                        XCTAssertLessThanOrEqual(stats.worst, limitMs, label)
                        XCTAssertEqual(rig.deckState(0).speed / (tempo * sourceRate / outputRate), 1, accuracy: 0.002, label)
                    }
                }
            }
        }
    }

    // MARK: Seeks and hot cues land within 1 ms of the chosen frame

    func testSeeksAndHotCuesLandOnTheChosenFrame() throws {
        for keyLock in [true, false] {
            for tempo in Self.tempos {
                let clicks = Clicks(first: 24_000, spacing: 24_000, bed: 0.02)
                let rig = Rig()
                let offset = Signal.detectorOffset(clicks, rate: rate)
                rig.load(clicks.track(seconds: 120, rate: rate))
                dex_engine_set_tempo(rig.engine, 0, tempo)
                dex_engine_set_key_lock(rig.engine, 0, keyLock)
                dex_engine_play(rig.engine, 0, nil)
                rig.render(seconds: 1)
                var targets: [(frame: Int64, index: Int)] = []
                var index = 150
                // Every 1.17 s, somewhere else in the track, on a click, on a chosen frame.
                for hop in 0..<20 {
                    let frame = rig.now + 8_192 + Int64(hop * 37)
                    dex_engine_jump(rig.engine, 0, [jump(to: clicks.frame(of: index), at: frame)])
                    targets.append((frame, index))
                    index = (index + 67) % 230 + 3
                    rig.run(to: frame + Int64(1.17 * rate) - 8_192)
                }
                rig.render(seconds: 0.3)
                let e = Signal.envelope(rig.tap(0))
                var stats = ErrorStats()
                for target in targets {
                    guard let found = Signal.peak(e, from: Int(target.frame) - 96, to: Int(target.frame) + 480, floor: 2) else {
                        XCTFail("no click at a landing")
                        continue
                    }
                    stats.add((found - offset - Double(target.frame)) / 48)
                }
                let label = "\(keyLock ? "key lock" : "free") \(tempo)"
                print("landing:", label, stats, "late", rig.deckState(0).lateLandings)
                XCTAssertEqual(stats.values.count, targets.count, label)
                XCTAssertLessThanOrEqual(stats.worst, limitMs, label)
                XCTAssertEqual(rig.deckState(0).lateLandings, 0, label)
                XCTAssertEqual(rig.deckState(0).lastLandingFrame, targets.last!.frame, label)
            }
        }
    }

    // MARK: Loops: no click, no drift, at ½, 1, 4 and 64 beats

    func testLoopsDoNotDrift() throws {
        for keyLock in [true, false] {
            for tempo in [0.92, 1.0, 1.16] {
                for beats in [0.5, 1, 4, 64] {
                    let beatFrames = 24_000.0
                    // A click on every half beat, so a loop of any length has one at its start.
                    let clicks = Clicks(first: beatFrames, spacing: beatFrames / 2)
                    let rig = Rig()
                    let offset = Signal.detectorOffset(clicks, rate: rate)
                    let loopIn = beatFrames * 8
                    let loopOut = loopIn + beats * beatFrames
                    rig.load(clicks.track(seconds: 70, rate: rate))
                    dex_engine_set_tempo(rig.engine, 0, tempo)
                    dex_engine_set_key_lock(rig.engine, 0, keyLock)
                    dex_engine_set_loop(rig.engine, 0, true, loopIn, loopOut)
                    dex_engine_play(rig.engine, 0, [jump(to: loopIn, at: 4800)])
                    let passFrames = (loopOut - loopIn) / tempo
                    // Long loops get at least 3 passes; short ones run 60 s, plenty of wraps.
                    let seconds = max(60, passFrames * 3 / rate + 1)
                    rig.render(seconds: seconds)
                    let e = Signal.envelope(rig.tap(0))
                    var stats = ErrorStats()
                    let passes = Int((Double(rig.tap(0).count) - 4800) / passFrames) - 1
                    for pass in 0..<passes {
                        let expected = 4800 + Double(pass) * passFrames
                        guard let found = Signal.peak(e, from: Int(expected) - 96, to: Int(expected) + 480, floor: 2) else {
                            XCTFail("\(beats) missing click at pass \(pass)")
                            break
                        }
                        stats.add((found - offset - expected) / 48)
                    }
                    let label = "\(keyLock ? "key lock" : "free") \(tempo) \(beats) beats"
                    print("loop drift:", label, stats, "wraps", rig.deckState(0).landings, "late", rig.deckState(0).lateLandings)
                    XCTAssertGreaterThanOrEqual(stats.values.count, 2, label)
                    XCTAssertLessThanOrEqual(stats.worst, limitMs, label)
                    XCTAssertEqual(rig.deckState(0).lateLandings, 0, label)
                    XCTAssertEqual(rig.deckState(0).starvedBlocks, 0, label)
                    // The clock stays inside the loop, and says so.
                    for state in rig.states.suffix(2000) {
                        XCTAssertGreaterThanOrEqual(state.deck.0.position, loopIn - 1000, label)
                        XCTAssertLessThanOrEqual(state.deck.0.position, loopOut + 1, label)
                    }
                }
            }
        }
    }

    /// A click is a jump in the waveform, so it shows in the second difference: compare the
    /// worst around the wraps with the worst of the same tone away from any wrap.
    func testLoopsDoNotClick() throws {
        for keyLock in [true, false] {
            for beats in [0.5, 1, 4, 64] {
                let beatFrames = 24_000.0
                // Two tones that don't fit the loop, so every wrap joins them out of phase.
                let w1 = 2 * Double.pi * 217 / rate, w2 = 2 * Double.pi * 1013 / rate
                let track = SynthTrack(frames: Int64(70 * rate), rate: rate) { frame, count, left, right in
                    for k in 0..<count {
                        let t = Double(frame + Int64(k))
                        let v = Float(0.3 * sin(w1 * t) + 0.1 * sin(w2 * t))
                        left[k] = v
                        right[k] = v
                    }
                }
                let rig = Rig()
                let loopIn = beatFrames * 8, loopOut = loopIn + beats * beatFrames
                rig.load(track)
                dex_engine_set_tempo(rig.engine, 0, 1.08)
                dex_engine_set_key_lock(rig.engine, 0, keyLock)
                dex_engine_play(rig.engine, 0, [jump(to: loopIn - 96_000, at: 4800)])
                rig.render(seconds: 1.5) // settle on the steady tone
                let baselineFrom = 24_000, baselineTo = rig.tap(0).count
                dex_engine_set_loop(rig.engine, 0, true, loopIn, loopOut)
                let seconds = max(20, loopOut - loopIn > 0 ? (loopOut - loopIn) / 1.08 * 2.5 / rate : 20)
                rig.render(seconds: seconds)
                let x = rig.tap(0)
                func worstSecondDifference(_ from: Int, _ to: Int) -> Double {
                    var worst = 0.0
                    for i in max(2, from)..<min(x.count, to) {
                        worst = max(worst, abs(Double(x[i]) - 2 * Double(x[i - 1]) + Double(x[i - 2])))
                    }
                    return worst
                }
                let baseline = worstSecondDifference(baselineFrom, baselineTo)
                let during = worstSecondDifference(baselineTo, x.count)
                let label = "\(keyLock ? "key lock" : "free") \(beats) beats"
                print("loop click:", label, String(format: "second difference %.5f, steady tone %.5f, wraps %llu", during, baseline, rig.deckState(0).landings))
                XCTAssertGreaterThan(rig.deckState(0).landings, 2, label)
                // A step of even 1% of full scale would read 0.01 or more.
                XCTAssertLessThan(during, max(baseline * 2, 0.006), label)
            }
        }
    }

    // MARK: Two decks stay within 1 ms for 180 s, through jumps, loops and master changes

    private func nearestGap(_ a: [Double], _ b: [Double], limit: Double) -> [Double] {
        var gaps: [Double] = []
        var j = 0
        for frame in a {
            while j + 1 < b.count, abs(b[j + 1] - frame) <= abs(b[j] - frame) { j += 1 }
            guard j < b.count, abs(b[j] - frame) < limit else { continue }
            gaps.append(b[j] - frame)
        }
        return gaps
    }

    func testTwoDecksStayLockedThroughASet() throws {
        for keyLock in [true, false] {
            let beatA = rate * 60 / 147, beatB = rate * 60 / 136
            let clicksA = Clicks(first: 12_000, spacing: beatA)
            let clicksB = Clicks(first: 6_000, spacing: beatB)
            let rig = Rig()
            rig.load(clicksA.track(seconds: 400, rate: rate), deck: 0)
            rig.load(clicksB.track(seconds: 400, rate: rate), deck: 1)
            let e = rig.engine
            dex_engine_set_grid(e, 0, clicksA.first, beatA)
            dex_engine_set_grid(e, 1, clicksB.first, beatB)
            dex_engine_set_key_lock(e, 0, keyLock)
            dex_engine_set_key_lock(e, 1, keyLock)
            dex_engine_set_master(e, 0)
            dex_engine_set_sync(e, 1, true)
            dex_engine_play(e, 0, [jump(to: clicksA.frame(of: 8), at: 2400)])
            dex_engine_play(e, 1, [jump(to: clicksB.frame(of: 12), at: 2400, align: true)])

            func follower() -> (deck: Int32, clicks: Clicks, beat: Double) {
                rig.states.last!.deck.0.isMaster ? (1, clicksB, beatB) : (0, clicksA, beatA)
            }
            func masterDeck() -> (deck: Int32, clicks: Clicks, beat: Double) {
                rig.states.last!.deck.0.isMaster ? (0, clicksA, beatA) : (1, clicksB, beatB)
            }
            func barJump(_ who: (deck: Int32, clicks: Clicks, beat: Double), bars: Double) {
                let frame = rig.now + 9_600
                let state = who.deck == 0 ? rig.states.last!.deck.0 : rig.states.last!.deck.1
                let there = state.positionEnd + state.speed * Double(frame - rig.now)
                dex_engine_jump(e, who.deck, [jump(to: there + bars * 4 * who.beat, at: frame, fadeEnds: false)])
            }
            var fired = Set<Int>()
            let step = { (at: Double, action: () -> Void) in
                let key = Int(at * 10)
                if !fired.contains(key), Double(rig.now) >= at * self.rate { fired.insert(key); action() }
            }
            var loopFollowerIn = 0.0
            rig.run(to: Int64(180 * rate)) { _ in
                step(20) { barJump(follower(), bars: 4) }                 // bar jump on the follower
                step(30) { barJump(masterDeck(), bars: -2) }              // bar jump on the master
                step(40) {                                                // 4-beat loop on the follower
                    let s = rig.states.last!.deck.1
                    let beats = ((s.position - clicksB.first) / beatB).rounded(.up)
                    loopFollowerIn = clicksB.first + beats * beatB
                    dex_engine_set_loop(e, 1, true, loopFollowerIn, loopFollowerIn + 4 * beatB)
                }
                step(80) { dex_engine_set_loop(e, 1, false, 0, 0) }
                step(85) {                                                // 1-beat loop on the master
                    let s = rig.states.last!.deck.0
                    let beats = ((s.position - clicksA.first) / beatA).rounded(.up)
                    let start = clicksA.first + beats * beatA
                    dex_engine_set_loop(e, 0, true, start, start + beatA)
                }
                step(105) { dex_engine_set_loop(e, 0, false, 0, 0) }
                step(110) { dex_engine_set_tempo(e, 0, 1.03) }            // the master moves
                step(120) {                                               // hand-over to B
                    dex_engine_set_tempo(e, 1, rig.states.last!.deck.1.tempo)
                    dex_engine_set_sync(e, 0, true)
                    dex_engine_set_sync(e, 1, false)
                    dex_engine_set_master(e, 1)
                }
                step(135) { barJump(masterDeck(), bars: 1.0 / 8) }        // half a beat: a real jump on the master
                step(150) {                                               // and back to A
                    dex_engine_set_tempo(e, 0, rig.states.last!.deck.0.tempo)
                    dex_engine_set_sync(e, 1, true)
                    dex_engine_set_sync(e, 0, false)
                    dex_engine_set_master(e, 0)
                }
                step(160) { dex_engine_set_tempo(e, 0, 0.97) }
                step(170) { barJump(follower(), bars: -1) }
            }
            let a = clicksFound(rig.tap(0)), b = clicksFound(rig.tap(1))
            // Allow a beat for the half-beat jump to land and any steering to take hold.
            let gaps = nearestGap(a, b, limit: 4800).map { $0 / 48 }
            var stats = ErrorStats()
            stats.values = gaps
            let label = "\(keyLock ? "key lock" : "free")"
            let sorted = gaps.map(abs).sorted()
            let settledClockError = rig.states.suffix(4000).map { abs($0.deck.1.phaseErrorMs) }.max() ?? .infinity
            print("two decks:", label, stats,
                  String(format: "p99 %.3f ms", sorted.isEmpty ? 0 : sorted[sorted.count * 99 / 100]),
                  "beats A \(a.count) B \(b.count)", "relocks", rig.deckState(0).relocks, rig.deckState(1).relocks,
                  "late", rig.deckState(0).lateLandings, rig.deckState(1).lateLandings,
                  String(format: "clock error end %.3f ms", settledClockError))
            XCTAssertGreaterThan(gaps.count, 400, label)
            XCTAssertLessThanOrEqual(stats.worst, limitMs, label)
            XCTAssertEqual(rig.deckState(0).starvedBlocks + rig.deckState(1).starvedBlocks, 0, label)
        }
    }
}
