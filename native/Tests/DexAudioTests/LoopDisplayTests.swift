import XCTest
import AVFoundation
@testable import DexAudio

/// What a deck shows inside a loop stays on the beat it plays, on both decks.
final class LoopDisplayTests: XCTestCase {
    private func fixture(rate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * 16)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let value = Float(sin(2 * .pi * 330 * Double(i) / rate)) * 0.2
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        try file.write(from: buffer)
        return url
    }

    @MainActor
    private func load(_ deck: NativeDeck, _ url: URL) async throws {
        deck.load(url)
        for _ in 0..<1000 where deck.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(deck.loading)
        XCTAssertNil(deck.error)
        deck.setGrid(bpm: 120)
    }

    /// The worst distance, in ms of output, between what the deck shows and the beat it should be on.
    @MainActor
    private func worstDrift(_ mixer: NativeMixer, decks: [NativeDeck], seconds: Double) throws -> [Double] {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var samples: [[(Double, Double)]] = decks.map { _ in [] }
        var rendered = 0
        while rendered < Int(seconds * 48_000) {
            guard try mixer.renderOffline(into: buffer) == .success else { continue }
            rendered += Int(buffer.frameLength)
            for (i, deck) in decks.enumerated() {
                samples[i].append((deck.audioNow(), deck.heardPosition(ahead: 0)))
            }
        }
        return zip(decks, samples).map { deck, trace in
            let grid = deck.grid!, beat = grid.beatSeconds
            // Skip the first second, while the start comes out and settles.
            let steady = trace.filter { $0.0 > trace[0].0 + 1 }
            guard let first = steady.first, let bounds = deck.loopBounds else { return .infinity }
            var worst = 0.0
            for (time, shown) in steady {
                XCTAssertTrue(bounds.lowerBound - 1e-3...bounds.upperBound + 1e-3 ~= shown, "\(deck.label) shows \(shown) outside \(bounds)")
                let expected = grid.beat(at: first.1) + (time - first.0) * deck.playRate / beat
                var error = (grid.beat(at: shown) - expected).truncatingRemainder(dividingBy: 1)
                if error > 0.5 { error -= 1 }
                if error < -0.5 { error += 1 }
                worst = max(worst, abs(error) * beat / deck.playRate * 1000)
            }
            return worst
        }
    }

    @MainActor
    private func run(sync: Bool, rateA: Double = 48_000, rateB: Double = 48_000) async throws -> [Double] {
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering()
        try await load(mixer.a, fixture(rate: rateA))
        try await load(mixer.b, fixture(rate: rateB))
        mixer.start()
        mixer.a.seek(to: 2.1)
        mixer.b.seek(to: 3.3)
        mixer.a.togglePlay()
        mixer.b.togglePlay()
        if sync { mixer.b.toggleSync() }
        let warm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 256)!
        for _ in 0..<200 { _ = try mixer.renderOffline(into: warm) }
        for deck in [mixer.a, mixer.b] {
            deck.setLoopBeats(1)
            deck.toggleLoop()
            XCTAssertTrue(deck.loopActive, deck.label)
        }
        return try worstDrift(mixer, decks: [mixer.a, mixer.b], seconds: 4)
    }

    @MainActor
    func testBothDecksShowTheLoopOnTheBeat() async throws {
        for (sync, rateA, rateB) in [(false, 48_000.0, 48_000.0), (true, 48_000, 48_000), (false, 44_100, 48_000), (true, 44_100, 44_100)] {
            let drift = try await run(sync: sync, rateA: rateA, rateB: rateB)
            print("loop display sync=\(sync) rates=\(rateA)/\(rateB): A \(drift[0]) ms, B \(drift[1]) ms")
            XCTAssertLessThan(drift[0], 3, "deck A, sync \(sync)")
            XCTAssertLessThan(drift[1], 3, "deck B, sync \(sync)")
        }
    }
}
