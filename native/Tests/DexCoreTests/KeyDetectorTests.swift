import XCTest
@testable import DexCore

/// Ports `tests/key.test.ts`, plus the streaming accumulator's own checks.
final class KeyDetectorTests: XCTestCase {
    private let rate = 22050.0

    /// `renderChord` from `src/shared/synth.ts`.
    private func chord(root: Int, _ mode: KeyDetector.Mode, seconds: Double, sampleRate: Double = 22050,
                       partials: Int = 1) -> [Float] {
        let rootMidi = 12 * 5 + root, gain = 0.25
        let length = max(1, Int(seconds * sampleRate))
        var buffer = [Float](repeating: 0, count: length)
        let fade = min(Int(sampleRate * 0.03), length / 2)
        for interval in mode == .major ? [0, 4, 7] : [0, 3, 7] {
            let frequency = 440 * pow(2, Double(rootMidi + interval - 69) / 12)
            for partial in 1...max(1, partials) {
                let amplitude = gain / pow(Double(partial), 1.6), hz = frequency * Double(partial)
                if hz >= sampleRate / 2 { break }
                let phase = 2 * Double.pi * hz / sampleRate
                for i in 0..<length {
                    let envelope = i < fade ? Double(i) / Double(fade) : i > length - fade ? Double(length - i) / Double(fade) : 1
                    buffer[i] = Float(Double(buffer[i]) + sin(phase * Double(i)) * amplitude * envelope)
                }
            }
        }
        return buffer
    }

    func testCamelotMapping() {
        XCTAssertEqual(KeyDetector.camelot(0, .major), "8B")
        XCTAssertEqual(KeyDetector.camelot(9, .minor), "8A")
        XCTAssertEqual(KeyDetector.camelot(6, .minor), "11A")
        XCTAssertEqual(KeyDetector.camelot(2, .major), "10B")
        XCTAssertEqual(KeyDetector.camelot(1, .minor), "12A")
        XCTAssertEqual(KeyDetector.camelot(11, .major), "1B")
        let codes = Set((0..<12).flatMap { [KeyDetector.camelot($0, .major), KeyDetector.camelot($0, .minor)] })
        XCTAssertEqual(codes.count, 24)
        XCTAssertEqual(KeyDetector.keyName(6, .minor), "F# minor")
        XCTAssertEqual(KeyDetector.keyName(0, .major), "C major")
    }

    func testChromaPutsEnergyOnTheTriad() {
        let chroma = KeyDetector.chroma(chord(root: 0, .major, seconds: 4), sampleRate: rate)
        let top = chroma.indices.sorted { chroma[$0] > chroma[$1] }.prefix(3)
        XCTAssertEqual(Set(top), [0, 4, 7])
    }

    func testBassBelowTheBandIsSlopeNotAPeak() {
        let bass = (0..<Int(rate * 4)).map { Float(0.8 * sin(2 * Double.pi * 90 * Double($0) / rate)) }
        XCTAssertLessThan(KeyDetector.chroma(bass, sampleRate: rate)[9], 0.2)
    }

    func testSilenceIsAllZeroAndNotFound() {
        let chroma = KeyDetector.chroma([Float](repeating: 0, count: Int(rate * 2)), sampleRate: rate)
        XCTAssertTrue(chroma.allSatisfy { $0 == 0 })
        XCTAssertEqual(KeyDetector.trackKey(chroma: chroma), .notFound)
    }

    func testPureTriads() {
        let cases: [(Int, KeyDetector.Mode, String)] = [(0, .major, "8B"), (9, .minor, "8A"), (6, .minor, "11A"),
                                                        (7, .major, "9B"), (4, .minor, "9A"), (3, .major, "5B")]
        for (root, mode, camelot) in cases {
            let estimate = KeyDetector.estimate(chord(root: root, mode, seconds: 6), sampleRate: rate)
            XCTAssertEqual(estimate.camelot, camelot, KeyDetector.keyName(root, mode))
            XCTAssertGreaterThan(estimate.confidence, 0.3)
            XCTAssertEqual(estimate.candidates.count, 3)
        }
    }

    func testNoThirdIsMinorAndAClearThirdStaysMajor() {
        var noThird = [Float](repeating: 0, count: 12)
        for pitch in [0, 2, 5, 7, 9, 11] { noThird[pitch] = 1 }
        noThird[0] = 2; noThird[7] = 1.5
        XCTAssertEqual(KeyDetector.estimate(chroma: noThird).key, "C minor")
        XCTAssertEqual(KeyDetector.estimate(chroma: noThird).candidates.count, 3)
        var withThird = noThird
        withThird[4] = 1.2
        XCTAssertEqual(KeyDetector.estimate(chroma: withThird).key, "C major")
    }

    func testHarmonicRichTriad() {
        XCTAssertEqual(KeyDetector.estimate(chord(root: 6, .minor, seconds: 6, partials: 4), sampleRate: rate).key, "F# minor")
    }

    func testKickFundamentalOutsideTheKey() {
        let withKick = chord(root: 6, .minor, seconds: 6).enumerated().map { i, value -> Float in
            let t = Double(i) / rate
            return Float(Double(value) + sin(2 * Double.pi * 48 * t) * 0.35 * exp(-(t.truncatingRemainder(dividingBy: 0.5) * 8)))
        }
        XCTAssertEqual(KeyDetector.estimate(withKick, sampleRate: rate).key, "F# minor")
    }

    func testNoiseIsLowConfidence() {
        for seed in [1, 7, 42, 1234, 99991] {
            var state = UInt32(seed)
            let noise = (0..<Int(rate * 6)).map { _ -> Float in
                state = state &* 1664525 &+ 1013904223
                return Float((Double(state) / 4294967296 * 2 - 1) * 0.3)
            }
            XCTAssertLessThan(KeyDetector.estimate(noise, sampleRate: rate).confidence, 0.6, "seed \(seed)")
        }
    }

    /// The library feeds blocks as they decode; any split gives the same vector.
    func testStreamingInBlocksMatchesWholeSignal() {
        let audio = chord(root: 6, .minor, seconds: 8, sampleRate: 48000, partials: 4)
        let whole = KeyDetector.chroma(audio, sampleRate: 48000)
        let streamed = ChromaAccumulator(sampleRate: 48000, frames: audio.count)
        var cursor = 0
        for size in [1, 777, 16_384, 3] + Array(repeating: 16_384, count: 40) where cursor < audio.count {
            let end = min(audio.count, cursor + size)
            audio[cursor..<end].withUnsafeBufferPointer { streamed.consume($0) }
            cursor = end
        }
        audio[cursor...].withUnsafeBufferPointer { streamed.consume($0) }
        XCTAssertEqual(streamed.finish(), whole)
        XCTAssertEqual(KeyDetector.estimate(chroma: whole).key, "F# minor")
    }

    /// `resampleLinear`'s length and end handling, through the accumulator.
    func testResampledTriadsKeepTheirKey() {
        for sampleRate in [44100.0, 48000, 96000, 16000] {
            let estimate = KeyDetector.estimate(chord(root: 9, .minor, seconds: 6, sampleRate: sampleRate), sampleRate: sampleRate)
            XCTAssertEqual(estimate.camelot, "8A", "\(sampleRate) Hz")
        }
    }
}
