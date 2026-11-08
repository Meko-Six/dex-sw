import CDexEngine
import Foundation
import XCTest

/// The mixer's four meters, all peaks: A and B what each deck sends into the master, after LEVEL and
/// the crossfader; L and R the master before the limiter.
final class EngineMeterTests: XCTestCase {
    let rate = 48_000.0

    /// A 997 Hz sine at `level` (peak), on the given sides.
    private func sine(seconds: Double = 20, level: Double, left: Bool = true, right: Bool = true) -> SynthTrack {
        let w = 2 * Double.pi * 997 / rate
        return SynthTrack(frames: Int64(seconds * rate), rate: rate) { frame, count, l, r in
            for k in 0..<count {
                let v = Float(level * sin(w * Double(frame + Int64(k))))
                l[k] = left ? v : 0
                r[k] = right ? v : 0
            }
        }
    }

    /// Peaks since the last read, in dBFS: decks A and B, master L and R.
    private func read(_ rig: Rig) -> (deck: [Double], master: [Double]) {
        var reading = DexMeterReading()
        dex_engine_read_meters(rig.engine, &reading)
        func db(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -.infinity }
        return ([db(reading.deck.0), db(reading.deck.1)], [db(reading.master.0), db(reading.master.1)])
    }

    /// Settles a change, discards the peaks of the glide, and reads what's there now.
    private func settled(_ rig: Rig) -> (deck: [Double], master: [Double]) {
        rig.render(seconds: 0.5)
        _ = read(rig)
        rig.render(seconds: 0.2)
        return read(rig)
    }

    func testAChannelReadsWhatItSendsAndTheMasterTheSum() {
        let rig = Rig()
        rig.load(sine(level: 0.25)) // −12.04 dBFS
        dex_engine_play(rig.engine, 0, nil)
        let open = settled(rig)
        XCTAssertEqual(open.deck[0], -12.04, accuracy: 0.3)
        XCTAssertEqual(open.deck[1], -.infinity, "deck B holds nothing")
        XCTAssertEqual(open.master[0], -12.04, accuracy: 0.3)
        XCTAssertEqual(open.master[1], -12.04, accuracy: 0.3)
    }

    /// LEVEL, the crossfader and TRIM all move the channel meter, as they move what goes in.
    func testTheChannelMeterFollowsItsFaderTheCrossfaderAndTrim() {
        let rig = Rig()
        rig.load(sine(level: 0.25))
        dex_engine_play(rig.engine, 0, nil)
        let open = settled(rig).deck[0]

        dex_engine_set_fader(rig.engine, 0, 0.5, 1)
        XCTAssertEqual(settled(rig).deck[0], open - 6.02, accuracy: 0.2, "LEVEL at half")
        dex_engine_set_fader(rig.engine, 0, 1, 0)
        let cut = settled(rig)
        XCTAssertLessThan(cut.deck[0], -60, "crossfaded out, nothing goes in")
        XCTAssertLessThan(cut.master[0], -60)
        dex_engine_set_fader(rig.engine, 0, 1, 1)
        dex_engine_set_tone(rig.engine, 0, 1, 1, 1, Float(pow(10, 6.0 / 20)))
        XCTAssertEqual(settled(rig).deck[0], open + 6, accuracy: 0.2, "TRIM +6")
    }

    func testLeftAndRightAreMeteredApart() {
        let rig = Rig()
        rig.load(sine(level: 0.5, right: false))
        dex_engine_play(rig.engine, 0, nil)
        let meters = settled(rig)
        XCTAssertEqual(meters.deck[0], -6.02, accuracy: 0.3, "a channel meter reads either side")
        XCTAssertEqual(meters.master[0], -6.02, accuracy: 0.3)
        XCTAssertLessThan(meters.master[1], -60)
    }

    /// Two hot decks fully open overload the master. The meters see it before the limiter does.
    func testTwoFullDecksOverloadTheMasterMeter() {
        let rig = Rig()
        rig.load(sine(level: 0.8), deck: 0)
        rig.load(sine(level: 0.8), deck: 1)
        dex_engine_play(rig.engine, 0, nil)
        dex_engine_play(rig.engine, 1, nil)
        let meters = settled(rig)
        XCTAssertEqual(meters.deck[0], 20 * log10(0.8), accuracy: 0.3)
        XCTAssertEqual(meters.deck[1], 20 * log10(0.8), accuracy: 0.3)
        XCTAssertGreaterThan(meters.master[0], 3, "in phase, about +4 dBFS; the limiter would hold it to −0.1")
        let out = rig.master[0].suffix(4800).map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(out, 0.995, "and the output is still limited")
    }

    /// A peak waits for the meters however long they take to look, and each look takes it.
    func testAPeakIsHeldUntilTheMetersReadIt() {
        let rig = Rig()
        let burst = SynthTrack(frames: Int64(10 * rate), rate: rate) { frame, count, l, r in
            for k in 0..<count {
                let v: Float = (4800..<4848).contains(frame + Int64(k)) ? 0.7 : 0.01
                l[k] = v; r[k] = v
            }
        }
        rig.load(burst)
        dex_engine_play(rig.engine, 0, nil)
        rig.render(seconds: 1)
        let first = read(rig)
        XCTAssertEqual(first.deck[0], 20 * log10(0.7), accuracy: 0.5)
        XCTAssertEqual(first.master[0], 20 * log10(0.7), accuracy: 0.5)
        rig.render(seconds: 0.2)
        let next = read(rig)
        XCTAssertEqual(next.deck[0], -40, accuracy: 0.5, "the burst was taken by the last look")
        XCTAssertEqual(next.master[0], -40, accuracy: 0.5)
    }
}
