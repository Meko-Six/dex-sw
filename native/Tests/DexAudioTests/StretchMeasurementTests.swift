import XCTest
import AVFoundation
@testable import DexAudio

/// These measurements record the production graph, never the visual clock.
final class StretchMeasurementTests: XCTestCase {
    @MainActor
    private func record(url: URL, rate: Double, keyLock: Bool, seconds: Double, loopBeats: Int? = nil) async throws -> [Float] {
        let mixer = NativeMixer()
        defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(mixer.a.loading)
        XCTAssertNil(mixer.a.error)
        mixer.a.tempo = rate
        mixer.a.keyLock = keyLock
        mixer.a.level = 1
        mixer.crossfader = 0
        mixer.volume = 1
        mixer.start()
        XCTAssertNil(mixer.error)
        if let loopBeats {
            mixer.a.setGrid(bpm: 120)
            mixer.a.setLoopBeats(Double(loopBeats))
            mixer.a.toggleLoop()
            XCTAssertNil(mixer.a.error)
            XCTAssertTrue(mixer.a.loopActive)
        }
        mixer.a.togglePlay()
        let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 1024)!
        var samples = [Float]()
        let count = Int(seconds * 48_000)
        var attempts = 0
        while samples.count < count && attempts < count / 1024 * 4 {
            attempts += 1
            if try mixer.renderOffline(into: output) == .success {
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(samples.count, count)
        return samples
    }

    private func fixture(pulses: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        // Write in bounded chunks, including distinguishable accented beats.
        for second in 0..<12 {
            for i in 0..<48_000 {
                let frame = second * 48_000 + i
                let beatFrame = frame % 24_000
                let envelope = pulses ? (beatFrame < 1440 ? exp(-Double(beatFrame) / 250) : 0) : 1
                let hz = pulses ? 1000.0 + Double(frame / 24_000) * 67 : 440.0
                buffer.floatChannelData![0][i] = Float(sin(Double(frame) * 2 * .pi * hz / 48_000) * envelope * 0.4)
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func frequency(_ samples: [Float], from seconds: Double, length: Double = 2) -> Double {
        let start = Int(seconds * 48_000)
        let end = min(samples.count - 1, start + Int(length * 48_000))
        var crossings = 0
        for i in (start + 1)..<end where samples[i-1] <= 0 && samples[i] > 0 { crossings += 1 }
        return Double(crossings) * 48_000 / Double(end - start)
    }

    private func attacks(_ samples: [Float]) -> [Double] {
        let window = 96 // 2 ms RMS; reject the time-pitch startup/tail.
        var result = [Double]()
        for start in stride(from: 0, to: samples.count - window, by: window) {
            var power = 0.0
            for i in start..<(start + window) { power += Double(samples[i] * samples[i]) }
            let time = Double(start) / 48_000
            if sqrt(power / Double(window)) > 0.025 && time > 0.15 && time < 7,
               time - (result.last ?? -1) > 0.25 { result.append(time) }
        }
        return result
    }

    @MainActor
    func testKeyLockAndVinylPitchAcrossTempoRange() async throws {
        let url = try fixture(pulses: false)
        defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            for locked in [true, false] {
                let samples = try await record(url: url, rate: rate, keyLock: locked, seconds: 5)
                let measured = frequency(samples, from: 1)
                let expected = locked ? 440 : 440 * rate
                print("STRETCH pitch rate=\(rate) keyLock=\(locked) measured=\(measured) expected=\(expected)")
                XCTAssertEqual(measured, expected, accuracy: 2)
            }
        }
    }

    @MainActor
    func testRecordedBeatPeriodAcrossTempoRange() async throws {
        let url = try fixture(pulses: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            let samples = try await record(url: url, rate: rate, keyLock: true, seconds: 8)
            let beats = attacks(samples)
            XCTAssertGreaterThan(beats.count, 9)
            let periods = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            let expected = 0.5 / rate
            let median = periods[periods.count / 2]
            let worst = periods.map { abs($0 - expected) }.max() ?? 1
            print("STRETCH beat rate=\(rate) first=\(beats.first ?? -1) median=\(median) worstError=\(worst)")
            XCTAssertEqual(median, expected, accuracy: 0.005)
            XCTAssertLessThan(worst, 0.025)
        }
    }
    private func toneIDs(_ samples: [Float]) -> [Int] {
        attacks(samples).filter { $0 > 1 && $0 < 6 }.map { attack in
            let start = max(0, Int((attack - 0.005) * 48_000))
            let count = 2400
            return (0..<24).max { left, right in
                func power(_ id: Int) -> Double {
                    let coefficient = 2 * cos(2 * .pi * (1000 + Double(id) * 67) / 48_000)
                    var s1 = 0.0, s2 = 0.0
                    for i in start..<(start + count) {
                        let next = Double(samples[i]) + coefficient * s1 - s2
                        s2 = s1; s1 = next
                    }
                    return s1 * s1 + s2 * s2 - coefficient * s1 * s2
                }
                return power(left) < power(right)
            }!
        }
    }

    @MainActor
    func testLoopRepeatsSelectedContentThroughTimeStretch() async throws {
        let url = try fixture(pulses: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for rate in [0.84, 1.0, 1.16] {
            let samples = try await record(url: url, rate: rate, keyLock: true, seconds: 8, loopBeats: 4)
            let sequence = toneIDs(samples)
            XCTAssertGreaterThan(sequence.count, 7)
            XCTAssertTrue(sequence.allSatisfy { (0..<4).contains($0) })
            for i in 4..<sequence.count { XCTAssertEqual(sequence[i], sequence[i - 4]) }
            print("LOOP rate=\(rate) recordedToneIDs=\(sequence)")
        }
        let uninterrupted = try await record(url: url, rate: 1, keyLock: true, seconds: 8)
        let plainSequence = toneIDs(uninterrupted)
        XCTAssertTrue(plainSequence.contains { $0 >= 4 }, "Uniquely pitched beats distinguish looping from playing on")
    }

}
