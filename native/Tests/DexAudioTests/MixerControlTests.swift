import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

/// The console's kills, sweep filter and master meter: what the deck sends the engine.
@MainActor
final class MixerControlTests: XCTestCase {
    func testKillsMuteTheirBandOverTheFader() {
        let deck = ToneTest.deck()
        deck.midDB = -6
        deck.kills.mid = true
        XCTAssertEqual(deck.toneGains, [1, 0, 1, 1])
        deck.kills.mid = false
        XCTAssertEqual(deck.toneGains[1], pow(10, -6 / 20), accuracy: 1e-6)
        // A muted fader, or one on the −96 dB floor, is silence like a kill.
        deck.lowDB = -.infinity
        XCTAssertEqual(deck.toneGains[0], 0)
        deck.lowDB = -96
        XCTAssertEqual(deck.toneGains[0], 0)
        // Trim runs ahead of the tone section, so it reaches the cue tap too.
        deck.trimDB = 6
        XCTAssertEqual(deck.toneGains[3], pow(10, 6 / 20), accuracy: 1e-6)
    }

    func testFilterIsOutAtCentreAndSweepsBothWays() {
        let deck = ToneTest.deck()
        XCTAssertEqual(deck.sweep, 0)
        deck.filter = -1
        XCTAssertEqual(deck.sweep, -1)
        XCTAssertEqual(FilterSetting(knob: -1).frequency, 120, accuracy: 0.01)
        deck.filter = 1
        XCTAssertEqual(deck.sweep, 1)
        XCTAssertEqual(FilterSetting(knob: 1).frequency, 9_000, accuracy: 0.1)
        deck.filter = 0
        XCTAssertEqual(deck.sweep, 0)
    }

    /// The meter is the engine's master after its limiter: a ±0.5 square reads −6 dB.
    func testMeterReadsTheOutputRMS() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000
            for channel in 0..<2 { for frame in 0..<96_000 { buffer.floatChannelData![channel][frame] = frame.isMultiple(of: 2) ? 0.5 : -0.5 } }
            try file.write(from: buffer)
        }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        XCTAssertEqual(mixer.meterDb, -120)
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        mixer.crossfader = 0; mixer.a.level = 1; mixer.volume = 1
        mixer.start(); mixer.a.togglePlay()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for _ in 0..<20 { _ = try mixer.renderOffline(into: out) }
        XCTAssertEqual(mixer.meterDb, 20 * log10(0.5), accuracy: 0.05)
    }
}
