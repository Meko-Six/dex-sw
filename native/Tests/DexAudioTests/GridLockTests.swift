import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

/// The master's grid is the truth, and a synced deck's sound stays on it. Each deck is a click
/// track on its own channel, so what's measured is the sound, over minutes, not the clocks.
final class GridLockTests: XCTestCase {
    static func clicks(bpm: Double, seconds: Int, tone: Double, channel: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        pcm.frameLength = 48_000
        let period = 60 / bpm
        for second in 0..<seconds {
            for i in 0..<48_000 {
                let time = Double(second) + Double(i) / 48_000
                let phase = time - floor(time / period) * period
                let value = phase < 0.03 ? Float(sin(phase * 2 * .pi * tone) * exp(-phase * 190) * 0.5) : 0
                pcm.floatChannelData![channel][i] = value; pcm.floatChannelData![1 - channel][i] = 0
            }
            try file.write(from: pcm)
        }
        return url
    }
    private static func onsets(_ samples: [Float], gap: Double = 0.1) -> [Double] {
        var result = [Double](), last = -1.0
        for i in samples.indices where abs(samples[i]) > 0.08 {
            let time = Double(i) / 48_000
            if time - last > gap { result.append(time) }
            last = time
        }
        return result
    }

    @MainActor private final class Rig {
        let mixer = NativeMixer()
        var a: NativeDeck { mixer.a }
        var b: NativeDeck { mixer.b }
        var urls = [URL]()
        let block = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 1024)!
        var left = [Float](), right = [Float]()
        init(aBPM: Double = 147, bBPM: Double = 136, seconds: Int) async throws {
            try mixer.enableOfflineRendering()
            urls = [try GridLockTests.clicks(bpm: aBPM, seconds: seconds, tone: 900, channel: 0),
                    try GridLockTests.clicks(bpm: bBPM, seconds: seconds, tone: 3000, channel: 1)]
            a.load(urls[0]); b.load(urls[1])
            for _ in 0..<4000 where a.loading || b.loading { try await Task.sleep(for: .milliseconds(5)) }
            a.setGrid(bpm: aBPM); b.setGrid(bpm: bBPM)
            a.level = 1; b.level = 1; mixer.volume = 1
            mixer.start()
        }
        func finish() {
            mixer.shutdown()
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        /// Renders on, keeping only what is asked for.
        func render(_ seconds: Double, keep: Bool = true) throws {
            var frames = Int(seconds * 48_000)
            while frames > 0 {
                guard try mixer.renderOffline(into: block) == .success else { continue }
                let count = Int(block.frameLength)
                if keep {
                    left.append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![0], count: count))
                    right.append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![1], count: count))
                }
                frames -= count
            }
        }
        /// B's beats against A's over the last render, in ms: positive is B late. Clears the capture.
        func gaps(period: Double? = nil, unit: Double = 1) -> [Double] {
            defer { left.removeAll(keepingCapacity: true); right.removeAll(keepingCapacity: true) }
            let beat = (period ?? 60 / (a.grid!.bpm * a.tempo)) * unit
            let master = GridLockTests.onsets(left), follower = GridLockTests.onsets(right)
            guard let first = master.first else { return [] }
            return follower.map { time in
                var gap = (time - first).truncatingRemainder(dividingBy: beat)
                if gap > beat / 2 { gap -= beat }
                if gap < -beat / 2 { gap += beat }
                return gap * 1000
            }
        }
    }
    private func assertLocked(_ gaps: [Double], within limit: Double, _ label: String, line: UInt = #line) {
        XCTAssertFalse(gaps.isEmpty, label, line: line)
        let sorted = gaps.sorted()
        print(String(format: "LOCK %@: B against A median %+.1f ms, %+.1f to %+.1f, %d beats", label, sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0, sorted.count))
        XCTAssertEqual(sorted[sorted.count / 2], 0, accuracy: limit, label, line: line)
    }

    /// Before the lock this slipped 22 ms every 30 s, past half a beat in under five minutes.
    @MainActor func testFollowerStaysOnTheMastersGridForMinutes() async throws {
        let rig = try await Rig(seconds: 200); defer { rig.finish() }
        rig.b.seek(to: 1.7)
        rig.a.togglePlay(); rig.b.togglePlay()
        try rig.render(1, keep: false)
        rig.b.toggleSync()
        for minute in stride(from: 30, through: 180, by: 30) {
            try rig.render(24, keep: false)
            try rig.render(6)
            assertLocked(rig.gaps(), within: 4, "\(minute) s")
        }
    }
    /// The master off zero: its own rounded speed is the truth the follower takes.
    @MainActor func testFollowerStaysOnAMasterOffItsOwnTempo() async throws {
        let rig = try await Rig(seconds: 100); defer { rig.finish() }
        rig.a.tempo = 1.03
        rig.a.togglePlay(); rig.b.togglePlay()
        try rig.render(1, keep: false)
        rig.b.toggleSync()
        try rig.render(84, keep: false)
        try rig.render(6)
        assertLocked(rig.gaps(period: 60 / (147 * 1.03)), within: 4, "master +3%")
    }
    /// A deck off zero on its own stays with its waveform, with nothing to follow.
    @MainActor func testClockStaysWithTheSoundOffZero() async throws {
        let rig = try await Rig(aBPM: 120, seconds: 130); defer { rig.finish() }
        rig.a.tempo = 1.03
        rig.a.togglePlay()
        try rig.render(90, keep: false)
        try rig.render(4)
        let onset = try XCTUnwrap(GridLockTests.onsets(rig.left).last)
        let end = Double(rig.left.count) / 48_000
        rig.a.refreshPosition()
        let shown = rig.a.heardPosition(ahead: 0)
        let beat = 0.5
        // The clock's beat phase at the moment of the last click, against the click.
        var error = (shown - (end - onset) * rig.a.playRate).truncatingRemainder(dividingBy: beat)
        if error > beat / 2 { error -= beat }
        print(String(format: "LOCK clock against sound after 94 s at +3%%: %+.1f ms", error * 1000))
        XCTAssertEqual(error, 0, accuracy: 0.01)
    }
    @MainActor func testSyncOnTheMasterMovesTheMasterAndLands() async throws {
        let rig = try await Rig(seconds: 40); defer { rig.finish() }
        rig.b.seek(to: 1.7)
        rig.a.togglePlay(); rig.b.togglePlay()
        try rig.render(1, keep: false)
        rig.a.toggleSync()
        XCTAssertTrue(rig.b.isMaster)
        // The follower's TEMPO is the engine's lock, from its next block.
        try rig.render(1, keep: false)
        XCTAssertEqual(rig.a.tempo, 136.0 / 147, accuracy: 1e-9)
        try rig.render(10)
        assertLocked(rig.gaps(period: 60.0 / 136), within: 4, "SYNC on the master")
    }
    /// The master's TEMPO carries the follower's with it: what the engine's lock chose, shown.
    @MainActor func testTheFollowersTempoFollowsTheMasters() async throws {
        let rig = try await Rig(seconds: 20); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(1, keep: false)
        XCTAssertTrue(rig.a.isMaster)
        XCTAssertEqual(rig.b.tempo, 147.0 / 136, accuracy: 1e-9)
        rig.a.tempo = 1.04
        try rig.render(0.5, keep: false)
        XCTAssertEqual(rig.b.tempo, 147.0 * 1.04 / 136, accuracy: 1e-9)
        // SYNC off: the follower stays where the lock left it.
        rig.b.toggleSync()
        rig.a.tempo = 1
        try rig.render(0.5, keep: false)
        XCTAssertEqual(rig.b.tempo, 147.0 * 1.04 / 136, accuracy: 1e-9)
        XCTAssertEqual(rig.b.playRate, rig.b.tempo, accuracy: 1e-9)
    }
    @MainActor func testPressingMasterHandsTheLockOver() async throws {
        let rig = try await Rig(seconds: 70); defer { rig.finish() }
        rig.b.seek(to: 1.7)
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(1, keep: false)
        rig.a.toggleSync() // On the master beside a playing deck: B leads, and A now follows.
        XCTAssertTrue(rig.b.isMaster)
        try rig.render(20, keep: false)
        try rig.render(6)
        var period = 60 / (rig.b.grid!.bpm * rig.b.tempo)
        assertLocked(rig.gaps(period: period), within: 4, "B master")
        rig.mixer.setMaster(rig.a) // Both synced: MASTER hands the lock straight back.
        XCTAssertTrue(rig.a.isMaster)
        try rig.render(20, keep: false)
        try rig.render(6)
        period = 60 / (rig.a.grid!.bpm * rig.a.tempo)
        assertLocked(rig.gaps(period: period), within: 4, "A master again")
    }
    /// A start must not move the deck already being heard.
    @MainActor func testStartingBesideAPlayingDeckLeavesItInCharge() async throws {
        let rig = try await Rig(seconds: 30); defer { rig.finish() }
        rig.b.toggleSync() // A is master, B follows; B plays alone, so it leads.
        rig.b.togglePlay()
        try rig.render(1, keep: false)
        XCTAssertTrue(rig.b.isMaster)
        let heard = rig.b.heardPosition(ahead: 0)
        rig.a.toggleSync()
        rig.a.seek(to: 2.2)
        rig.a.togglePlay()
        XCTAssertTrue(rig.b.isMaster)
        try rig.render(1, keep: false)
        XCTAssertEqual(rig.b.heardPosition(ahead: 0) - heard, rig.b.tempo, accuracy: 0.05)
        try rig.render(8)
        let period = 60 / (136 * rig.b.tempo)
        assertLocked(rig.gaps(period: period), within: 4, "start beside a playing deck")
    }
    /// A plain seek on the master moves the truth; the follower lands with it.
    @MainActor func testASeekOnTheMasterTakesTheFollowerWithIt() async throws {
        let rig = try await Rig(seconds: 40); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(2, keep: false)
        let follower = rig.b.heardPosition(ahead: 0)
        rig.a.seek(to: 14.13) // Well off A's beat.
        try rig.render(0.3, keep: false)
        try rig.render(6)
        XCTAssertGreaterThan(rig.b.heardPosition(ahead: 0), follower)
        assertLocked(rig.gaps(), within: 4, "after a seek on the master")
    }
    @MainActor func testLoopsAndJumpsStayOnTheGrid() async throws {
        let rig = try await Rig(seconds: 120); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(2, keep: false)
        rig.b.jumpBars = 4
        rig.b.jump(direction: 1)
        try rig.render(10, keep: false)
        try rig.render(4)
        assertLocked(rig.gaps(), within: 4, "bar jump on the follower")

        rig.b.setLoopBeats(4)
        rig.b.toggleLoop()
        XCTAssertTrue(rig.b.loopActive)
        try rig.render(40, keep: false)
        try rig.render(6)
        assertLocked(rig.gaps(), within: 4, "40 s in a 4-beat loop on the follower")
        rig.b.toggleLoop()
        try rig.render(2, keep: false)

        rig.a.setLoopBeats(1)
        rig.a.toggleLoop()
        XCTAssertTrue(rig.a.loopActive)
        try rig.render(20, keep: false)
        try rig.render(6)
        assertLocked(rig.gaps(), within: 4, "20 s in a 1-beat loop on the master")
    }
    /// Half a beat repeats inside the beat, so it must not be read as half a beat out.
    @MainActor func testAHalfBeatLoopOnTheFollowerIsNotChased() async throws {
        let rig = try await Rig(seconds: 60); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(2, keep: false)
        rig.b.setLoopBeats(0.5)
        rig.b.toggleLoop()
        XCTAssertTrue(rig.b.loopActive)
        try rig.render(1, keep: false)
        let relocks = rig.b.engineDeckState?.relocks
        try rig.render(20, keep: false)
        XCTAssertEqual(rig.b.engineDeckState?.relocks, relocks, "A locked deck in a short loop must not keep landing back on the grid")
    }
    /// Out of tempo range the grids can't lock, and must not be chased.
    @MainActor func testBeyondTheTempoRangeNothingIsChased() async throws {
        let rig = try await Rig(aBPM: 174, bBPM: 120, seconds: 30); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(1, keep: false)
        XCTAssertEqual(rig.b.tempo, 1.16, accuracy: 1e-9)
        let landings = rig.b.engineLandings
        try rig.render(8, keep: false)
        XCTAssertEqual(rig.b.engineLandings, landings, "Nothing may jump the deck to chase a grid it can't reach")
        XCTAssertEqual(rig.b.playRate, 1.16)
    }
    @MainActor func testSyncOffReturnsToItsOwnSpeed() async throws {
        let rig = try await Rig(seconds: 30); defer { rig.finish() }
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(5, keep: false)
        rig.b.toggleSync()
        XCTAssertEqual(rig.b.playRate, rig.b.tempo)
        try rig.render(1, keep: false)
        XCTAssertEqual(rig.b.playRate, rig.b.tempo)
    }
    /// Holding the lock moves between speed steps; a held tone must stay level through them.
    @MainActor func testHoldingTheLockIsSeamless() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            pcm.frameLength = 48_000
            for second in 0..<40 {
                for i in 0..<48_000 {
                    let value = Float(sin(2 * .pi * 220 * (Double(second) + Double(i) / 48_000)) * 0.4)
                    pcm.floatChannelData![0][i] = 0.15 // Shows a dip of a couple of ms, whatever the phase.
                    pcm.floatChannelData![1][i] = value
                }
                try file.write(from: pcm)
            }
        }
        let rig = try await Rig(seconds: 30); defer { rig.finish() }
        rig.b.load(url)
        for _ in 0..<4000 where rig.b.loading { try await Task.sleep(for: .milliseconds(5)) }
        rig.b.setGrid(bpm: 136)
        rig.a.level = 0
        rig.a.togglePlay(); rig.b.togglePlay()
        rig.b.toggleSync()
        try rig.render(2, keep: false)
        rig.left.removeAll()
        var rates = Set<Double>()
        for _ in 0..<200 { try rig.render(0.1); rates.insert(rig.b.playRate) }
        print("LOCK speeds used while holding: \(rates.sorted())")
        XCTAssertGreaterThan(rates.count, 1, "147 from 136 sits between two steps")
        let samples = rig.right
        let windows = stride(from: 0, to: samples.count - 2400, by: 2400).map { start -> Double in
            (samples[start..<(start + 2400)].reduce(0.0) { $0 + Double($1 * $1) } / 2400).squareRoot()
        }
        let level = windows.sorted()[windows.count / 2]
        print(String(format: "LOCK tone level median %.4f, lowest %.4f, highest %.4f", level, windows.min() ?? 0, windows.max() ?? 0))
        XCTAssertGreaterThan(windows.min() ?? 0, level * 0.9)
        XCTAssertLessThan(windows.max() ?? 0, level * 1.1)
        let steady = stride(from: 0, to: rig.left.count - 96, by: 96).map { start -> Double in
            (rig.left[start..<(start + 96)].reduce(0.0) { $0 + Double($1 * $1) } / 96).squareRoot()
        }
        let usual = steady.sorted()[steady.count / 2]
        print(String(format: "LOCK 2 ms level median %.4f, lowest %.4f, highest %.4f", usual, steady.min() ?? 0, steady.max() ?? 0))
        XCTAssertGreaterThan(steady.min() ?? 0, usual * 0.95, "A speed step must not leave a dip")
    }
}
