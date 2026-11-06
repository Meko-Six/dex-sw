import XCTest
import AVFoundation
import AudioToolbox
import Dispatch
@testable import DexAudio

/// The defects the audio audit reproduced, as assertions (docs/audio-audit/AuditProbe.swift).
final class AudioAuditRegressionTests: XCTestCase {
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private func ramp(seconds: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexAudit-" + UUID().uuidString + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(seconds * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][i] = 0.01 + Float(i) / 48_000 * 0.01 }
        }
        try file.write(from: buffer)
        return url
    }

    @MainActor private func load(_ mixer: NativeMixer, _ url: URL) async throws {
        mixer.a.load(url)
        for _ in 0..<1000 where mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(mixer.a.duration, 0); XCTAssertNil(mixer.a.error)
        mixer.crossfader = 0; mixer.a.level = 1; mixer.volume = 1
        mixer.start()
    }

    private func peak(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> Float {
        (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(buffer.floatChannelData![channel][$1])) }
    }

    // MARK: Custom unit reset

    private static var impulse: AURenderPullInputBlock { { _, _, frames, _, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) { samples[i] = i == 0 ? 1 : 0 }
        }
        return noErr
    } }
    private static var silence: AURenderPullInputBlock { { _, _, frames, _, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
        }
        return noErr
    } }

    /// Filter history from before a reset must not ring on into what follows it.
    @MainActor func testResetClearsIsolatorHistory() throws {
        let deck = ToneTest.deck()
        deck.filter = -0.9
        let unit = try XCTUnwrap(IsolatorUnit.makeNode().auAudioUnit as? IsolatorUnit)
        unit.follow(deck); unit.snap()
        let render = unit.internalRenderBlock
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 16))
        output.frameLength = 16
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        XCTAssertEqual(render(&flags, &time, 16, 0, output.mutableAudioBufferList, nil, Self.impulse), noErr)
        unit.reset()
        time.mSampleTime = 16
        XCTAssertEqual(render(&flags, &time, 16, 0, output.mutableAudioBufferList, nil, Self.silence), noErr)
        XCTAssertEqual(peak(output), 0, "The reset left the sweep's history ringing")
    }

    /// A reset keeps where the controls are: only history goes, not the settings.
    @MainActor func testResetKeepsIsolatorControls() throws {
        let deck = ToneTest.deck()
        deck.filter = -0.9
        let unit = try XCTUnwrap(IsolatorUnit.makeNode().auAudioUnit as? IsolatorUnit)
        unit.follow(deck); unit.snap()
        let sweep = unit.sweep, gains = unit.gains
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        unit.reset()
        XCTAssertEqual(unit.sweep, sweep)
        XCTAssertEqual(unit.gains, gains)
        // Still filtering: a high tone stays well down through the low-pass.
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4096))
        output.frameLength = 4096
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        let tone: AURenderPullInputBlock = { _, _, frames, _, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frames) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
            }
            return noErr
        }
        XCTAssertEqual(unit.internalRenderBlock(&flags, &time, 4096, 0, output.mutableAudioBufferList, nil, tone), noErr)
        XCTAssertLessThan(peak(output), 0.05)
    }

    // MARK: Router errors

    private func renderRouter(_ pull: @escaping AURenderPullInputBlock) throws -> (status: AUAudioUnitStatus, unit: OutputRouterUnit, output: AVAudioPCMBuffer) {
        let unit = try XCTUnwrap(OutputRouterUnit.makeNode().auAudioUnit as? OutputRouterUnit)
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 64))
        output.frameLength = 64
        for channel in 0..<2 { output.floatChannelData![channel].update(repeating: 0.5, count: 64) }
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        let status = unit.internalRenderBlock(&flags, &time, 64, 0, output.mutableAudioBufferList, nil, pull)
        return (status, unit, output)
    }

    /// The master is what the audience hears: its failure is the render's failure.
    func testRouterReportsFailedMasterPull() throws {
        let result = try renderRouter { _, _, frames, bus, list in
            if bus == 0 { return -50 }
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
            }
            return noErr
        }
        XCTAssertEqual(result.status, -50)
        XCTAssertEqual(result.unit.pullFailures, [1, 0, 0])
        XCTAssertEqual(peak(result.output, channel: 0), 0)
        XCTAssertEqual(peak(result.output, channel: 1), 0)
    }

    /// A cue branch must not take the master down with it, but must be countable.
    func testRouterCountsFailedCuePullAndKeepsTheMaster() throws {
        let result = try renderRouter { _, _, frames, bus, list in
            if bus == 1 { return -50 }
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.25, count: Int(frames))
            }
            return noErr
        }
        XCTAssertEqual(result.status, noErr)
        XCTAssertEqual(result.unit.pullFailures, [0, 1, 0])
        XCTAssertGreaterThan(peak(result.output), 0.2)
    }

    /// A silent master with the cue playing must not mark the whole output silent.
    func testRouterDoesNotPassOnOneInputsSilenceFlag() throws {
        let unit = try XCTUnwrap(OutputRouterUnit.makeNode().auAudioUnit as? OutputRouterUnit)
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 64))
        output.frameLength = 64
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        let status = unit.internalRenderBlock(&flags, &time, 64, 0, output.mutableAudioBufferList, nil) { actions, _, frames, bus, list in
            if bus == 0 { actions.pointee.insert(.unitRenderAction_OutputIsSilence) }
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
            }
            return noErr
        }
        XCTAssertEqual(status, noErr)
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    // MARK: Cue pulls

    /// Request sizes vary on real hardware; none may leave the cue bus silent.
    @MainActor func testCueSurvivesVaryingRenderSizes() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering(channels: 4, split: false)
        try await load(mixer, url)
        mixer.crossfader = 1; mixer.cueMix = 1; mixer.a.headphoneCue = true
        mixer.a.togglePlay()
        let sizes: [AVAudioFrameCount] = [64, 128, 256, 480, 512, 960, 1024]
        var silent = 0
        for cycle in 0..<200 {
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: CueRouting.format(channels: 4), frameCapacity: sizes[cycle % sizes.count]))
            XCTAssertEqual(try mixer.renderOffline(into: out), .success)
            if cycle > 30, peak(out, channel: 2) < 1e-6 { silent += 1 }
        }
        XCTAssertEqual(silent, 0)
        mixer.a.level = 0; mixer.volume = 0
        for _ in 0..<12 {
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: CueRouting.format(channels: 4), frameCapacity: 1024))
            _ = try mixer.renderOffline(into: out)
            XCTAssertGreaterThan(peak(out, channel: 2), 1e-6, "The cue is before the fader and the master volume")
        }
        mixer.shutdown(); await AudioControlExecutor.shared.drain()
    }

    // MARK: Scheduling

    /// The clock must not run ahead of a player that has not started. The full matrix
    /// of delays and transport actions is in `LaunchTransactionTests`.
    @MainActor func testStalledDiskCannotAdvanceThePlayheadOverSilence() async throws {
        let url = try ramp(); defer { try? FileManager.default.removeItem(at: url) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        try await load(mixer, url)
        // The stall is audio that hasn't been read from disk yet.
        mixer.loaderHeld = true
        mixer.a.togglePlay()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1024))
        var loudest: Float = 0
        for _ in 0..<16 {
            _ = try mixer.renderOffline(into: out)
            loudest = max(loudest, peak(out))
        }
        mixer.a.refreshPosition()
        let position = mixer.a.position
        XCTAssertEqual(loudest, 0, "The stall must hold the audio back for this test to mean anything")
        XCTAssertEqual(position, 0, accuracy: 0.02)
        // Once the audio is there it starts where the press asked, from the top.
        mixer.loaderHeld = false
        var first: Float?
        for _ in 0..<16 {
            _ = try mixer.renderOffline(into: out)
            if first == nil, let i = (0..<Int(out.frameLength)).first(where: { out.floatChannelData![0][$0] > 0.005 }) {
                first = out.floatChannelData![0][min(Int(out.frameLength) - 1, i + 600)]
            }
        }
        // The ramp is 0.01 at the top; 0.0101 at 10 ms in, once the fade is through.
        XCTAssertEqual(try XCTUnwrap(first), 0.0101, accuracy: 0.0005, "It must start at the cue, not where the clock ran to")
        mixer.a.refreshPosition()
        XCTAssertEqual(mixer.a.position, Double(16 * 1024) / 48_000, accuracy: 0.03)
        mixer.shutdown(); await AudioControlExecutor.shared.drain()
    }
}
