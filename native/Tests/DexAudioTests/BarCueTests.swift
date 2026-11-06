import XCTest
import AVFoundation
@testable import DexAudio

final class BarCueTests: XCTestCase {
    private let tones = [900.0, 1300, 1700, 2100]
    private func attacks(_ samples: [Float]) -> [Double] {
        var times: [Double] = []
        for i in stride(from: 0, to: samples.count - 96, by: 96) {
            let rms = sqrt(samples[i..<(i + 96)].reduce(0.0) { $0 + Double($1 * $1) } / 96)
            let time = Double(i) / 48000
            if rms > 0.025, time - (times.last ?? -1) > 0.25 { times.append(time) }
        }
        return times
    }
    /// Each beat has a distinct audible accent/pitch: identify 1/2/3/4 from the
    /// recorded PCM itself, rather than inferring success from grid metadata.
    private func accent(_ samples: [Float], at time: Double) -> Int {
        let start = Int(time * 48000), end = min(samples.count, start + 960)
        let powers = tones.map { hz -> Double in
            var real = 0.0, imaginary = 0.0
            for i in start..<end {
                let angle = 2 * .pi * hz * Double(i - start) / 48000
                real += Double(samples[i]) * cos(angle)
                imaginary += Double(samples[i]) * sin(angle)
            }
            return hypot(real, imaginary)
        }
        return powers.firstIndex(of: powers.max()!)!
    }
    private func audio(marker: Double, offset: Double, period: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            pcm.frameLength = 48000
            for second in 0..<20 {
                for frame in 0..<48000 {
                    let absolute = Double(second) + Double(frame) / 48000
                    let time = absolute - offset, beat = floor(time / period)
                    let phase = time - beat * period
                    let index = (Int(beat) % 4 + 4) % 4
                    let pulse = time >= 0 && phase < 0.03
                        ? Float(sin(phase * 2 * .pi * tones[index]) * exp(-phase * 190) * 0.4) : 0
                    pcm.floatChannelData![0][frame] = absolute < marker ? pulse : 0
                    pcm.floatChannelData![1][frame] = absolute >= marker ? pulse : 0
                }
                try file.write(from: pcm)
            }
        }
        return url
    }
    @MainActor
    func testStoredCuePreservesAudibleOneTwoThreeFourAcrossTheJump() async throws {
        for (cueBeat, rate) in [(0, 1.0), (1, 1.0), (2, 1.0), (3, 1.0), (0, 0.84), (0, 1.16)] {
            let bpm = 120.0, offset = 0.137, period = 60 / bpm
            let marker = offset + Double(16 + cueBeat) * period
            let url = try audio(marker: marker, offset: offset, period: period)
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try mixer.enableOfflineRendering()
            mixer.a.load(url)
            for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
            mixer.a.setGrid(bpm: bpm, offsetMs: offset * 1000)
            mixer.a.tempo = rate; mixer.a.level = 1; mixer.volume = 1; mixer.crossfader = 0
            mixer.a.seek(to: marker + 0.1); mixer.a.hotCue(0)
            mixer.a.seek(to: mixer.a.cuePoint)
            mixer.start(); mixer.a.togglePlay()
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            var old: [Float] = [], incoming: [Float] = []
            var triggered = false, earliest = 0.0
            while old.count < 7 * 48000 {
                if !triggered && old.count >= Int(1.23 * 48000) {
                    earliest = Double(old.count) / 48000 + 0.12
                    mixer.a.hotCue(0); triggered = true
                }
                await AudioControlExecutor.shared.drain()
                if try mixer.renderOffline(into: pcm) == .success {
                    old.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                    incoming.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
                }
                await Task.yield()
            }
            let oldBeats = attacks(old), newBeats = attacks(incoming)
            let first = try XCTUnwrap(newBeats.first), start = try XCTUnwrap(oldBeats.first)
            let outputPeriod = period / rate
            let expected = try XCTUnwrap((0..<24).first { $0 % 4 == cueBeat && start + Double($0) * outputPeriod >= earliest - 0.002 })
            XCTAssertEqual(first, start + Double(expected) * outputPeriod, accuracy: 0.015)
            let previous = try XCTUnwrap(oldBeats.last { $0 < first - outputPeriod / 2 })
            XCTAssertEqual(first - previous, outputPeriod, accuracy: 0.015, "No shortened, repeated or missing beat at the bar transition")
            XCTAssertEqual(accent(old, at: previous), (cueBeat + 3) % 4, "Outgoing count must reach the beat immediately before the saved cue")
            XCTAssertGreaterThan(newBeats.count, 4)
            let count = newBeats.prefix(4).map { accent(incoming, at: $0) }
            XCTAssertEqual(count, (0..<4).map { (cueBeat + $0) % 4 }, "Audible accents must continue the correct 1-2-3-4 count")
            XCTAssertEqual(mixer.a.hotCues[0]!, marker, accuracy: 1e-9)
            print("BAR CUE beat=\(cueBeat + 1) rate=\(rate) old=\(accent(old, at: previous) + 1) incoming=\(count.map { $0 + 1 }) boundaryMs=\(abs(first - previous - outputPeriod) * 1000)")
        }
    }
    @MainActor
    func testEarlyAndLatePressesJoinTheIntendedBarWithoutReplayingItsDownbeat() async throws {
        for (delta, rate, sameBar) in [
            (-0.20, 1.0, true), (-0.08, 1.0, true), (-0.02, 1.0, true),
            (0.0, 1.0, true), (0.02, 1.0, true), (0.08, 1.0, true), (0.14, 1.0, false),
            (-0.06, 1.16, true), (0.06, 1.16, true), (-0.08, 0.84, true), (0.08, 0.84, true)
        ] {
            let offset = 0.137, period = 0.5, marker = offset + 8
            let url = try audio(marker: marker, offset: offset, period: period)
            defer { try? FileManager.default.removeItem(at: url) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let mixer = NativeMixer(); defer { mixer.shutdown() }
            try mixer.enableOfflineRendering()
            mixer.a.load(url)
            for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
            mixer.a.setGrid(bpm: 120, offsetMs: offset * 1000)
            mixer.a.tempo = rate; mixer.a.level = 1; mixer.volume = 1; mixer.crossfader = 0
            mixer.a.seek(to: marker); mixer.a.hotCue(0); mixer.a.seek(to: mixer.a.cuePoint)
            mixer.start()
            // The bar starts when the press from stopped comes out.
            let startDelay = mixer.a.startDelay
            mixer.a.togglePlay()
            let beatDuration = period / rate
            let intendedBoundary = startDelay + 4 * beatDuration
            let press = intendedBoundary + delta
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
            var old: [Float] = [], incoming: [Float] = []
            var triggered = false, pressed = 0.0
            while old.count < 7 * 48000 {
                if !triggered && Double(old.count) / 48000 >= press - 1e-9 {
                    pressed = Double(old.count) / 48000
                    mixer.a.hotCue(0); triggered = true
                }
                await AudioControlExecutor.shared.drain()
                if try mixer.renderOffline(into: pcm) == .success {
                    old.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                    incoming.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
                }
                await Task.yield()
            }
            let combined = zip(old, incoming).map { $0 + $1 }
            let allBeats = attacks(combined)
            let bar = allBeats.filter { $0 >= intendedBoundary - 0.015 && $0 < intendedBoundary + 3.5 * beatDuration }
            XCTAssertEqual(bar.count, 4, "No doubled or missing beats around a human-timed press")
            XCTAssertEqual(bar.map { accent(combined, at: $0) }, [0, 1, 2, 3])
            for (a, b) in zip(bar, bar.dropFirst()) { XCTAssertEqual(b - a, beatDuration, accuracy: 0.015) }
            let incomingBeats = attacks(incoming)
            if sameBar {
                let second = try XCTUnwrap(incomingBeats.first { abs($0 - intendedBoundary - beatDuration) < 0.015 })
                XCTAssertEqual(accent(incoming, at: second), 1, "Beat 2 must already come from the saved cue's bar, not four beats later")
                if delta >= 0 {
                    let start = Int((pressed + 0.12) * 48000)
                    let end = min(incoming.count, start + 2400)
                    let peak = incoming[start..<end].map { abs($0) }.max() ?? 0
                    XCTAssertLessThan(peak, 0.01, "A late press must not replay the saved downbeat late")
                }
            } else {
                let first = try XCTUnwrap(incomingBeats.first)
                XCTAssertEqual(first, intendedBoundary + 4 * beatDuration, accuracy: 0.015)
            }
            XCTAssertTrue(mixer.a.playing)
            XCTAssertEqual(mixer.a.hotCues[0]!, marker, accuracy: 1e-9)
            print("HUMAN CUE deltaMs=\(delta * 1000) rate=\(rate) sameBar=\(sameBar) count=\(bar.map { accent(combined, at: $0) + 1 })")
        }
    }

}
