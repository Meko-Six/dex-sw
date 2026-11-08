import XCTest
@testable import DexCore

final class LoudnessTests: XCTestCase {
    /// Sections of a stereo sine, each (seconds, peak dBFS), at 997 Hz.
    private func measure(_ sections: [(Double, Double)], rate: Double = 48_000, mono: Bool = false) -> TrackLoudness {
        let meter = LoudnessMeter(sampleRate: rate)
        var phase = 0.0
        for (seconds, db) in sections {
            let amplitude = pow(10, db / 20)
            var block = [Float](repeating: 0, count: 4096)
            var left = Int(seconds * rate)
            while left > 0 {
                let n = min(block.count, left)
                for i in 0..<n {
                    block[i] = Float(amplitude * sin(phase))
                    phase += 2 * .pi * 997 / rate
                }
                block.withUnsafeBufferPointer { all in
                    let part = UnsafeBufferPointer(rebasing: all[0..<n])
                    meter.consume(left: part, right: mono ? nil : part)
                }
                left -= n
            }
        }
        return meter.finish()
    }

    func testFortyEightKilohertzFiltersMatchTheStandardsTable() {
        let k = LoudnessMeter.kWeighting(sampleRate: 48_000)
        let shelfB = [1.53512485958697, -2.69169618940638, 1.19839281085285]
        let shelfA = [1, -1.69065929318241, 0.73248077421585]
        let highA = [1, -1.99004745483398, 0.99007225036621]
        for i in 0..<3 {
            XCTAssertEqual(k.shelf.b[i], shelfB[i], accuracy: 1e-6)
            XCTAssertEqual(k.shelf.a[i], shelfA[i], accuracy: 1e-6)
            XCTAssertEqual(k.highpass.a[i], highA[i], accuracy: 1e-6)
        }
        XCTAssertEqual(k.highpass.b, [1, -2, 1])
    }

    /// EBU Tech 3341's first case: a stereo sine at −23 dBFS reads −23 LUFS.
    func testAStereoSineReadsItsOwnLevel() {
        for rate in [44_100.0, 48_000, 96_000] {
            let reading = measure([(20, -23)], rate: rate)
            XCTAssertEqual(reading.integrated, -23, accuracy: 0.1, "\(rate)")
            XCTAssertEqual(reading.main, -23, accuracy: 0.1, "\(rate)")
            XCTAssertEqual(reading.peak, -23, accuracy: 0.05, "\(rate)")
        }
    }

    func testMonoCountsAsBothSpeakers() {
        XCTAssertEqual(measure([(10, -12)], mono: true).integrated, measure([(10, -12)]).integrated, accuracy: 0.01)
    }

    /// The relative gate drops a quiet ending 20 dB down.
    func testQuietPassagesFarBelowAreGatedOut() {
        XCTAssertEqual(measure([(20, -20), (20, -40)]).integrated, -20, accuracy: 0.1)
    }

    /// An intro 8 dB down is inside the gate and pulls the whole-track reading
    /// down; the main reading stays on the groove.
    func testMainReadsTheGrooveNotTheIntro() {
        let reading = measure([(60, -18), (60, -10)])
        XCTAssertEqual(reading.main, -10, accuracy: 0.15)
        XCTAssertLessThan(reading.integrated, -11.5)
    }

    func testAutoTrimBringsTheGrooveToTheTarget() {
        XCTAssertEqual(TrackLoudness(integrated: -8, main: -7.3, peak: -0.1).autoTrim(), -2.7)
        XCTAssertEqual(TrackLoudness(integrated: -14, main: -13, peak: -3).autoTrim(), 3)
        XCTAssertEqual(TrackLoudness(integrated: -40, main: -40, peak: -20).autoTrim(), 12)
        XCTAssertEqual(TrackLoudness(integrated: -70, main: -70, peak: -120).autoTrim(), 0)
    }

    func testSilenceReadsAsSilenceAndSavesAsJSON() throws {
        let reading = measure([(5, -200)])
        XCTAssertEqual(reading.main, TrackLoudness.silence)
        XCTAssertEqual(reading.autoTrim(), 0)
        let data = try JSONEncoder().encode(LoudnessMeter(sampleRate: 48_000).finish())
        XCTAssertEqual(try JSONDecoder().decode(TrackLoudness.self, from: data).main, TrackLoudness.silence)
    }
}
