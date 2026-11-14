import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

/// Offline renders of the deck's isolator and the cue router, held against the
/// Electron engine's maths (`src/shared/isolator.ts`, `routing.ts`).
@MainActor
final class MixerRenderTests: XCTestCase {
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    // MARK: Isolator

    /// The tone section, set as the deck sets the engine's, rendered from a unit impulse.
    private func impulseResponse(_ deck: NativeDeck, frames: Int = 16_384) throws -> [Float] {
        let isolator = IsolatorUnit.makeNode(), unit = isolator.auAudioUnit as! IsolatorUnit
        unit.follow(deck); unit.snap()
        let engine = AVAudioEngine(), sent = Counter()
        let source = AVAudioSourceNode(format: stereo) { _, _, count, output in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(count) { samples[i] = sent.value + i == 0 ? 1 : 0 }
            }
            sent.value += Int(count)
            return noErr
        }
        engine.attach(source); engine.attach(isolator)
        engine.connect(source, to: isolator, format: stereo)
        engine.connect(isolator, to: engine.outputNode, format: stereo)
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
        try engine.start(); defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1024)!
        var left: [Float] = [], right: [Float] = []
        while left.count < frames {
            XCTAssertEqual(try engine.renderOffline(1024, to: buffer), .success)
            left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
        }
        XCTAssertEqual(left, right, "Both channels run the same bands")
        return left
    }

    /// |H(f)| in dB from an impulse response.
    private func magnitudeDb(_ response: [Float], hz: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / 48_000
        for (n, h) in response.enumerated() { re += Double(h) * cos(w * Double(n)); im -= Double(h) * sin(w * Double(n)) }
        return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
    }

    private let sweep: [Double] = (0...48).map { 20 * pow(1_000, Double($0) / 48) } // 20 Hz … 20 kHz

    func testIsolatorIsFlatAtUnity() throws {
        let response = try impulseResponse(ToneTest.deck())
        for hz in sweep { XCTAssertEqual(magnitudeDb(response, hz: hz), 0, accuracy: 0.01, "\(Int(hz)) Hz") }
    }

    /// A phase-rotated kick peaks up to 5 dB higher, into the limiter. Flat must be the input itself.
    func testFlatIsolatorLeavesTheSignalUntouched() throws {
        let response = try impulseResponse(ToneTest.deck())
        XCTAssertEqual(response[0], 1)
        XCTAssertTrue(response.dropFirst().allSatisfy { $0 == 0 })
    }

    /// `signal` through the deck's isolator live, so `change` lands mid-render and glides.
    private func throughIsolator(_ deck: NativeDeck, signal: @escaping @Sendable (Int) -> Float, frames: Int,
                                 changeAt: Int, change: () -> Void) throws -> [Float] {
        let isolator = IsolatorUnit.makeNode(), unit = isolator.auAudioUnit as! IsolatorUnit
        unit.follow(deck); unit.snap()
        let engine = AVAudioEngine(), sent = Counter()
        let source = AVAudioSourceNode(format: stereo) { _, _, count, output in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(count) { samples[i] = signal(sent.value + i) }
            }
            sent.value += Int(count)
            return noErr
        }
        engine.attach(source); engine.attach(isolator)
        engine.connect(source, to: isolator, format: stereo)
        engine.connect(isolator, to: engine.outputNode, format: stereo)
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 256)
        try engine.start(); defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 256)!
        var out: [Float] = [], changed = false
        while out.count < frames {
            if !changed, out.count >= changeAt { change(); unit.follow(deck); changed = true }
            XCTAssertEqual(try engine.renderOffline(256, to: buffer), .success)
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return out
    }

    nonisolated private static func bass(_ frame: Int) -> Float { 0.8 * Float(sin(Double(frame) * 2 * .pi * 50 / 48_000)) }

    func testIsolatorGoesBackToUntouchedOnceFlat() throws {
        let deck = ToneTest.deck()
        deck.lowDB = -6
        let out = try throughIsolator(deck, signal: Self.bass, frames: 96_000, changeAt: 12_000) { deck.lowDB = 0 }
        XCTAssertLessThan(abs(out[8_000]), 0.42, "the cut is in")
        XCTAssertEqual(Array(out[72_000..<96_000]), (72_000..<96_000).map(Self.bass))
    }

    func testMovingABandFadesTheBandsInWithoutAJump() throws {
        let deck = ToneTest.deck()
        let out = try throughIsolator(deck, signal: Self.bass, frames: 48_000, changeAt: 12_000) { deck.lowDB = -6 }
        XCTAssertEqual(out[11_000], Self.bass(11_000), "untouched before the move")
        XCTAssertLessThan(out.reduce(0) { max($0, abs($1)) }, 0.85)
        var jump: Float = 0
        for frame in 1..<out.count { jump = max(jump, abs(out[frame] - out[frame - 1])) }
        XCTAssertLessThan(jump, 0.012, "The tone's own steepest step is 0.0052")
    }

    /// Web Audio's filter, as Electron's sweep runs it: Q dB of resonance at the cutoff.
    func testSweepMatchesTheElectronFilter() throws {
        for knob in [0.25, 0.5, 1, -0.25, -0.5, -1] {
            let deck = ToneTest.deck(), setting = FilterSetting(knob: knob)
            deck.filter = knob
            let response = try impulseResponse(deck, frames: 48_000)
            XCTAssertEqual(magnitudeDb(response, hz: setting.frequency), setting.q, accuracy: 0.02, "knob \(knob)")
            let stop = setting.highPass ? setting.frequency / 8 : setting.frequency * 8
            if stop < 24_000 { XCTAssertLessThan(magnitudeDb(response, hz: stop), -30, "knob \(knob)") }
        }
    }

    /// Touching the slider used to start a filter from nothing, mid-waveform: a 3.5 dB thump.
    func testEngagingTheSweepDoesNotThump() throws {
        for knob in [0.01, 0.2, -0.01, -0.2] {
            let deck = ToneTest.deck()
            let out = try throughIsolator(deck, signal: Self.bass, frames: 24_000, changeAt: 12_000) { deck.filter = knob }
            XCTAssertEqual(out[11_000], Self.bass(11_000), "untouched before the move")
            // No burst on top of what the filter settles to, resonance included.
            let settled = out[20_000...].reduce(0) { max($0, abs($1)) }
            XCTAssertLessThan(out[12_000..<20_000].reduce(0) { max($0, abs($1)) }, max(settled, 0.8) * 1.05, "knob \(knob)")
            var jump: Float = 0
            for frame in 1..<out.count { jump = max(jump, abs(out[frame] - out[frame - 1])) }
            XCTAssertLessThan(jump, 0.012, "knob \(knob)")
        }
    }

    func testSweepBackAtCentreIsUntouched() throws {
        let deck = ToneTest.deck()
        deck.filter = 0.3
        let out = try throughIsolator(deck, signal: Self.bass, frames: 96_000, changeAt: 12_000) { deck.filter = 0 }
        XCTAssertEqual(Array(out[72_000..<96_000]), (72_000..<96_000).map(Self.bass))
    }

    func testIsolatorMatchesTheElectronMaths() throws {
        let deck = ToneTest.deck()
        deck.lowDB = -6; deck.highDB = -12; deck.midDB = -3
        let response = try impulseResponse(deck)
        let gains = deck.toneGains.map(Double.init)
        for hz in sweep {
            let expected = Isolator.responseDb(low: gains[0], mid: gains[1], high: gains[2], hz: hz, sampleRate: 48_000)
            XCTAssertEqual(magnitudeDb(response, hz: hz), expected, accuracy: 0.01, "\(Int(hz)) Hz")
        }
    }

    /// Each band's heart, where the other two crossovers are far away.
    private let centres = (low: 50.0, mid: (Isolator.lowHz * Isolator.highHz).squareRoot(), high: 12_000.0)

    func testEachKillRemovesOnlyItsBand() throws {
        for band in ["low", "mid", "high"] {
            let deck = ToneTest.deck()
            switch band {
            case "low": deck.kills.low = true
            case "mid": deck.kills.mid = true
            default: deck.kills.high = true
            }
            let response = try impulseResponse(deck)
            let killed = band == "low" ? centres.low : band == "mid" ? centres.mid : centres.high
            XCTAssertLessThan(magnitudeDb(response, hz: killed), -40, "\(band) kill leaves its band")
            for hz in [centres.low, centres.mid, centres.high] where hz != killed {
                XCTAssertEqual(magnitudeDb(response, hz: hz), 0, accuracy: 0.5, "\(band) kill touches \(Int(hz)) Hz")
            }
            let gains = deck.toneGains.map(Double.init)
            for hz in sweep {
                let expected = Isolator.responseDb(low: gains[0], mid: gains[1], high: gains[2], hz: hz, sampleRate: 48_000)
                if expected > -80 { XCTAssertEqual(magnitudeDb(response, hz: hz), expected, accuracy: 0.05, "\(band) at \(Int(hz)) Hz") }
            }
        }
    }

    func testAllKillsAreATrueMute() throws {
        let deck = ToneTest.deck()
        deck.kills = EQKills(low: true, mid: true, high: true)
        XCTAssertTrue(try impulseResponse(deck).allSatisfy { $0 == 0 })
    }

    // MARK: Router

    /// Constant per-channel levels into the router's master, A and B inputs.
    private func routed(channels: AVAudioChannelCount, frames: Int = 1024,
                        configure: (OutputRouterUnit) -> Void) throws -> [[Float]] {
        let engine = AVAudioEngine(), router = OutputRouterUnit.makeNode()
        let unit = router.auAudioUnit as! OutputRouterUnit
        engine.attach(router)
        for (bus, levels) in [(0, [Float(0.4), 0.2]), (1, [0.3, 0.1]), (2, [0.05, 0.05])] {
            let source = AVAudioSourceNode(format: stereo) { _, _, count, output in
                for (c, buffer) in UnsafeMutableAudioBufferListPointer(output).enumerated() {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(count) { samples[i] = levels[c] }
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: router, fromBus: 0, toBus: bus, format: stereo)
        }
        let format = CueRouting.format(channels: channels)
        engine.connect(router, to: engine.outputNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        configure(unit)
        try engine.start(); defer { engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var out = [[Float]](repeating: [], count: Int(channels))
        while out[0].count < frames {
            XCTAssertEqual(try engine.renderOffline(1024, to: buffer), .success)
            for c in 0..<Int(channels) { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return out
    }

    func testFourChannelPutsMasterOnOneTwoAndCueOnThreeFour() throws {
        var out = try routed(channels: 4) { $0.set(split: false, cueMix: 1, cueA: 1, cueB: 0); $0.snap() }
        XCTAssertEqual(out.map { $0[512] }, [0.4, 0.2, 0.3, 0.1])
        out = try routed(channels: 4) { $0.set(split: false, cueMix: 1, cueA: 1, cueB: 1); $0.snap() }
        XCTAssertEqual(out[2][512], 0.35, accuracy: 1e-6); XCTAssertEqual(out[3][512], 0.15, accuracy: 1e-6)
        // The cue mix blends the post-limiter master into the cue bus.
        out = try routed(channels: 4) { $0.set(split: false, cueMix: 0.25, cueA: 1, cueB: 0); $0.snap() }
        XCTAssertEqual(out[2][512], 0.25 * 0.3 + 0.75 * 0.4, accuracy: 1e-6)
        XCTAssertEqual(out[3][512], 0.25 * 0.1 + 0.75 * 0.2, accuracy: 1e-6)
        // No deck on CUE and the mix all the way to the decks: the cue is silent.
        out = try routed(channels: 4) { $0.set(split: false, cueMix: 1, cueA: 0, cueB: 0); $0.snap() }
        XCTAssertEqual(out[2][512], 0); XCTAssertEqual(out[3][512], 0)
    }

    func testPhonesTurnsDownTheCueAndNeverTheMaster() throws {
        var out = try routed(channels: 4) { $0.set(split: false, cueMix: 1, cueA: 1, cueB: 0); $0.set(phones: 0.5); $0.snap() }
        XCTAssertEqual(out.map { $0[512] }, [0.4, 0.2, 0.15, 0.05])
        out = try routed(channels: 2) { $0.set(split: true, cueMix: 1, cueA: 1, cueB: 0); $0.set(phones: 0.5); $0.snap() }
        XCTAssertEqual(out[0][512], 0.3, accuracy: 1e-6, "mono master, untouched")
        XCTAssertEqual(out[1][512], 0.1, accuracy: 1e-6, "mono cue at half")
        // A change glides rather than steps, as the cue mix does.
        out = try routed(channels: 4, frames: 9_600) {
            $0.set(split: false, cueMix: 1, cueA: 1, cueB: 0); $0.snap(); $0.set(phones: 0)
        }
        XCTAssertEqual(out[2][9_599], 0, accuracy: 1e-5)
        XCTAssertEqual(out[0][9_599], 0.4, accuracy: 1e-6)
        for frame in 1..<out[2].count { XCTAssertLessThan(abs(out[2][frame] - out[2][frame - 1]), 0.003) }
    }

    func testSplitCuePutsMonoMasterLeftAndMonoCueRight() throws {
        for channels: AVAudioChannelCount in [2, 4] {
            let out = try routed(channels: channels) { $0.set(split: true, cueMix: 1, cueA: 1, cueB: 0); $0.snap() }
            XCTAssertEqual(out[0][512], 0.3, accuracy: 1e-6, "mono master")
            XCTAssertEqual(out[1][512], 0.2, accuracy: 1e-6, "mono cue")
            for c in 2..<Int(channels) { XCTAssertEqual(out[c][512], 0) }
        }
    }

    func testSplitPlaysTheStereoMasterUntilADeckIsOnCue() throws {
        // The router's master input is 0.4 left, 0.2 right.
        var out = try routed(channels: 2) { $0.set(split: true, cueMix: 0.85, cueA: 0, cueB: 0); $0.snap() }
        XCTAssertEqual(out[0][512], 0.4); XCTAssertEqual(out[1][512], 0.2)

        // CUE folds to split without a click, from the stereo master's own values.
        out = try routed(channels: 2, frames: 9_600) {
            $0.set(split: true, cueMix: 1, cueA: 0, cueB: 0); $0.snap()
            $0.set(split: true, cueMix: 1, cueA: 1, cueB: 0)
        }
        XCTAssertEqual(out[0][0], 0.4, accuracy: 1e-3); XCTAssertEqual(out[1][0], 0.2, accuracy: 1e-3)
        XCTAssertEqual(out[0][9_599], 0.3, accuracy: 1e-5, "mono master")
        XCTAssertEqual(out[1][9_599], 0.2, accuracy: 1e-5, "mono cue")
        for c in 0..<2 { for frame in 1..<out[c].count { XCTAssertLessThan(abs(out[c][frame] - out[c][frame - 1]), 0.003) } }

        // Off CUE, it unfolds again.
        out = try routed(channels: 2, frames: 9_600) {
            $0.set(split: true, cueMix: 1, cueA: 1, cueB: 0); $0.snap()
            $0.set(split: true, cueMix: 1, cueA: 0, cueB: 0)
        }
        XCTAssertEqual(out[0][9_599], 0.4, accuracy: 1e-5); XCTAssertEqual(out[1][9_599], 0.2, accuracy: 1e-5)
    }

    func testCueTapGlidesLikeTheElectronGain() throws {
        // A's CUE turns on at the first frame and glides with a 10 ms constant.
        let out = try routed(channels: 4) {
            $0.set(split: false, cueMix: 1, cueA: 0, cueB: 0); $0.snap()
            $0.set(split: false, cueMix: 1, cueA: 1, cueB: 0)
        }
        XCTAssertEqual(out[2][479], 0.3 * Float(1 - exp(-1.0)), accuracy: 1e-3)
        XCTAssertEqual(out[0][0], 0.4, "The master never glides")
    }

    func testCuePeakGuardHoldsFullScaleAndLeavesTheMasterAlone() throws {
        let out = try routed(channels: 4) { $0.set(split: false, cueMix: 1, cueA: 5, cueB: 0); $0.snap() }
        XCTAssertEqual(out[2][512], 1, accuracy: 1e-6, "1.5 held at full scale")
        XCTAssertEqual(out[3][512], 0.5 / 1.5, accuracy: 1e-6, "the channels stay in balance")
        XCTAssertEqual(out[0][512], 0.4); XCTAssertEqual(out[1][512], 0.2)
    }

    func testFourChannelNeedsFourOutputs() {
        XCTAssertTrue(CueRouting.split(requested: false, outputChannels: 2))
        XCTAssertFalse(CueRouting.split(requested: false, outputChannels: 4))
        XCTAssertTrue(CueRouting.split(requested: true, outputChannels: 4))
        XCTAssertEqual(CueRouting.channels(hardware: 0), 2)
        XCTAssertEqual(CueRouting.channels(hardware: 2), 2)
        XCTAssertEqual(CueRouting.channels(hardware: 8), 4)
    }

    // MARK: Through the mixer

    private func track() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexCue-" + UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 96_000)!
        pcm.frameLength = 96_000
        for i in 0..<96_000 {
            pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 1_000 / 48_000)) * 0.2
            pcm.floatChannelData![1][i] = 0.15
        }
        try file.write(from: pcm)
        return url
    }

    private func playing(channels: AVAudioChannelCount, split: Bool, url: URL) async throws -> NativeMixer {
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering(channels: channels, split: split)
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(mixer.a.loading); XCTAssertNil(mixer.a.error)
        mixer.start(); XCTAssertNil(mixer.error)
        // Deck A's fader is closed by the crossfader: only its cue can be heard.
        mixer.crossfader = 1
        mixer.cueMix = 1
        mixer.a.headphoneCue = true
        mixer.a.togglePlay()
        return mixer
    }

    private func render(_ mixer: NativeMixer, channels: AVAudioChannelCount, seconds: Double) throws -> [[Float]] {
        let format = CueRouting.format(channels: channels)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var out = [[Float]](repeating: [], count: Int(channels))
        for _ in 0..<Int(ceil(seconds * 48_000 / 1024)) {
            XCTAssertEqual(try mixer.renderOffline(into: buffer), .success)
            for c in 0..<Int(channels) { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return out
    }

    private func mean(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) } / Double(max(1, x.count)) }
    private func rms(_ x: [Float]) -> Double { (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot() }
    private func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    private func hotBassTrack() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexHot-" + UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 240_000)!
        pcm.frameLength = 240_000
        for c in 0..<2 { for i in 0..<240_000 { pcm.floatChannelData![c][i] = 0.9 * Float(sin(Double(i) * 2 * .pi * 50 / 48_000)) } }
        try file.write(from: pcm)
        return url
    }

    func testVolumeGivesTheLimiterHeadroom() async throws {
        let url = try hotBassTrack(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering(channels: 2, split: false)
        mixer.a.load(url)
        for _ in 0..<500 where mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(mixer.a.error)
        mixer.start(); XCTAssertNil(mixer.error)
        // 1.8 at the sum: over full scale, but the volume brings it back under.
        mixer.crossfader = 0; mixer.a.level = 1; mixer.a.trimDB = 20 * log10(2); mixer.volume = 0.5
        mixer.a.togglePlay()
        _ = try render(mixer, channels: 2, seconds: 0.5)
        XCTAssertEqual(peak(try render(mixer, channels: 2, seconds: 0.5)[0]), 0.9, accuracy: 0.01, "The limiter never touched it")

        // Volume up, it is the limiter's to contain.
        mixer.volume = 1
        _ = try render(mixer, channels: 2, seconds: 0.5)
        let limited = peak(try render(mixer, channels: 2, seconds: 0.5)[0])
        XCTAssertLessThanOrEqual(limited, 1.001); XCTAssertGreaterThan(limited, 0.9)
    }

    func testHeadphoneCueTapsTheDeckBeforeItsFader() async throws {
        let url = try track(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = try await playing(channels: 4, split: false, url: url)
        defer { mixer.shutdown() }
        _ = try render(mixer, channels: 4, seconds: 0.3)
        var out = try render(mixer, channels: 4, seconds: 0.2)
        XCTAssertLessThan(peak(out[0]), 1e-4, "A's fader is closed"); XCTAssertLessThan(peak(out[1]), 1e-4)
        XCTAssertEqual(rms(out[2]), 0.2 / 2.squareRoot(), accuracy: 0.02, "the cue carries A's left")
        XCTAssertEqual(mean(out[3]), 0.15, accuracy: 0.01, "the cue carries A's right")

        mixer.a.headphoneCue = false
        _ = try render(mixer, channels: 4, seconds: 0.3)
        out = try render(mixer, channels: 4, seconds: 0.1)
        XCTAssertEqual(peak(out[2]), 0); XCTAssertEqual(peak(out[3]), 0)

        // CUE MIX at 0 hears the master alone, the same as channels 1/2.
        mixer.cueMix = 0; mixer.crossfader = 0; mixer.a.headphoneCue = true
        _ = try render(mixer, channels: 4, seconds: 0.3)
        out = try render(mixer, channels: 4, seconds: 0.1)
        XCTAssertGreaterThan(rms(out[0]), 0.05)
        XCTAssertEqual(zip(out[0], out[2]).map { abs($0 - $1) }.max()!, 0, accuracy: 1e-6)
        XCTAssertEqual(zip(out[1], out[3]).map { abs($0 - $1) }.max()!, 0, accuracy: 1e-6)
    }

    func testSplitCueThroughTheMixer() async throws {
        let url = try track(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = try await playing(channels: 2, split: true, url: url)
        defer { mixer.shutdown() }
        _ = try render(mixer, channels: 2, seconds: 0.3)
        var out = try render(mixer, channels: 2, seconds: 0.2)
        XCTAssertLessThan(peak(out[0]), 1e-4, "the master ear is silent")
        XCTAssertEqual(mean(out[1]), 0.075, accuracy: 0.01, "the cue ear is A in mono")
        XCTAssertEqual(rms(out[1]), (0.075 * 0.075 + 0.1 * 0.1 / 2).squareRoot(), accuracy: 0.01)

        // Open A's fader with the cue still on: A arrives on the left in mono.
        mixer.crossfader = 0
        _ = try render(mixer, channels: 2, seconds: 0.3)
        out = try render(mixer, channels: 2, seconds: 0.2)
        let fader = Double(mixer.a.level * mixer.volume)
        XCTAssertEqual(mean(out[0]), 0.075 * fader, accuracy: 0.01)

        // Nothing on CUE: A in stereo, its 1 kHz tone left and its offset right.
        mixer.a.headphoneCue = false
        _ = try render(mixer, channels: 2, seconds: 0.3)
        out = try render(mixer, channels: 2, seconds: 0.2)
        XCTAssertEqual(rms(out[0]), 0.2 * fader / 2.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(mean(out[0]), 0, accuracy: 0.01)
        XCTAssertEqual(mean(out[1]), 0.15 * fader, accuracy: 0.01)
    }
}

private final class Counter: @unchecked Sendable { var value = 0 }
