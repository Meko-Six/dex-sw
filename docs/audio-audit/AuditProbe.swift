import AVFoundation
import AudioToolbox
import Dispatch
import DexCore
@testable import DexAudio

@main struct AuditProbe {
    @MainActor static func main() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let url = URL(fileURLWithPath: "/private/tmp/dex-audio-audit-ramp.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
            buffer.frameLength = buffer.frameCapacity
            for c in 0..<2 { for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = 0.01 + Float(i) / 48_000 * 0.01
            }}
            try file.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try resetProbe(format)
        try routerErrorProbe(format)
        try await delayedScheduleProbe(url, format)
        try await variableQuantumProbe(url)
    }

    @MainActor static func resetProbe(_ format: AVAudioFormat) throws {
        let deck = NativeDeck(label: "reset-probe")
        deck.filter = -0.9
        deck.isolatorUnit.snap()
        let unit = deck.isolatorUnit, render = unit.internalRenderBlock
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        output.frameLength = 16
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        let first: AURenderPullInputBlock = { _, _, frames, _, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                let p = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frames) { p[i] = i == 0 ? 1 : 0 }
            }; return noErr
        }
        let silence: AURenderPullInputBlock = { _, _, frames, _, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
            }; return noErr
        }
        _ = render(&flags, &time, 16, 0, output.mutableAudioBufferList, nil, first)
        unit.reset()
        time.mSampleTime = 16
        _ = render(&flags, &time, 16, 0, output.mutableAudioBufferList, nil, silence)
        let residual = (0..<16).map { abs(output.floatChannelData![0][$0]) }.max()!
        print("AUDIT reset residual after impulse+reset+silence: \(residual)")
    }

    @MainActor static func routerErrorProbe(_ format: AVAudioFormat) throws {
        let node = OutputRouterUnit.makeNode(), unit = node.auAudioUnit as! OutputRouterUnit
        if !unit.renderResourcesAllocated { try unit.allocateRenderResources() }
        defer { unit.deallocateRenderResources() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        output.frameLength = 64
        var flags: AudioUnitRenderActionFlags = []
        var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
        let fail: AURenderPullInputBlock = { _, _, _, _, _ in -50 }
        let result = unit.internalRenderBlock(&flags, &time, 64, 0, output.mutableAudioBufferList, nil, fail)
        print("AUDIT router input status=-50, returned status=\(result)")
    }

    @MainActor static func load(_ mixer: NativeMixer, _ url: URL) async throws {
        mixer.a.load(url)
        while mixer.a.loading { try await Task.sleep(for: .milliseconds(5)) }
        guard mixer.a.duration > 0, mixer.a.error == nil else { fatalError("load: \(String(describing: mixer.a.error))") }
        mixer.crossfader = 0; mixer.a.level = 1; mixer.volume = 1
        mixer.start()
    }

    @MainActor static func delayedScheduleProbe(_ url: URL, _ format: AVAudioFormat) async throws {
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering()
        try await load(mixer, url)
        for voice in mixer.a.voices { voice.synchronousCommands = false }
        let gate = DispatchSemaphore(value: 0)
        let signal = AsyncStream<Void>.makeStream()
        AudioControlExecutor.shared.submit {
            signal.continuation.yield(); signal.continuation.finish()
            _ = gate.wait(timeout: .now() + 5)
        }
        var iterator = signal.stream.makeAsyncIterator(); _ = await iterator.next()
        mixer.a.togglePlay()
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var peak: Float = 0
        for _ in 0..<16 {
            _ = try mixer.renderOffline(into: out)
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
        }
        mixer.a.refreshPosition()
        print("AUDIT blocked schedule: display=\(mixer.a.position), audio peak=\(peak)")
        gate.signal(); await AudioControlExecutor.shared.drain()
        for _ in 0..<16 { _ = try mixer.renderOffline(into: out) }
        mixer.a.refreshPosition()
        let sample = out.floatChannelData![0][Int(out.frameLength) - 1]
        print("AUDIT after queue release: display=\(mixer.a.position), source time inferred from ramp=\((sample - 0.01) / 0.01)")
        mixer.shutdown(); await AudioControlExecutor.shared.drain()
    }

    @MainActor static func variableQuantumProbe(_ url: URL) async throws {
        let mixer = NativeMixer()
        try mixer.enableOfflineRendering(channels: 4, split: false)
        try await load(mixer, url)
        mixer.crossfader = 1; mixer.cueMix = 1; mixer.a.headphoneCue = true
        mixer.a.togglePlay()
        let sizes: [AVAudioFrameCount] = [64, 128, 256, 480, 512, 960, 1024]
        var silent = 0, observed = 0
        for cycle in 0..<200 {
            let out = AVAudioPCMBuffer(pcmFormat: CueRouting.format(channels: 4), frameCapacity: sizes[cycle % sizes.count])!
            let result = try mixer.renderOffline(into: out)
            guard result == .success else { print("AUDIT render failed: \(result)"); continue }
            if cycle > 30 {
                observed += 1
                if (0..<Int(out.frameLength)).allSatisfy({ abs(out.floatChannelData![2][$0]) < 1e-6 }) { silent += 1 }
            }
        }
        print("AUDIT variable quantum cue silent blocks=\(silent)/\(observed)")
        mixer.a.level = 0; mixer.volume = 0
        var silentMuted = 0
        for _ in 0..<12 {
            let out = AVAudioPCMBuffer(pcmFormat: CueRouting.format(channels: 4), frameCapacity: 1024)!
            _ = try mixer.renderOffline(into: out)
            if (0..<Int(out.frameLength)).allSatisfy({ abs(out.floatChannelData![2][$0]) < 1e-6 }) { silentMuted += 1 }
        }
        print("AUDIT cue with exact zero fader+master silent blocks=\(silentMuted)/12")
        mixer.shutdown(); await AudioControlExecutor.shared.drain()
    }

}
