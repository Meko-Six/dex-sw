import AVFoundation
import Foundation
#if os(iOS)
import AVFAudio
#endif

/// Apple's time-pitch on the real output, muted: the volume is zero and a tap reads the signal
/// straight after the time-pitch. Offline renders don't show its live delay, so this is the only
/// fair baseline. Nothing is sent to the speakers.
public enum LiveApple {
    public struct DelayResult: Sendable {
        public var tempo: Double
        public var delayMs: [Double]
        public var row: String {
            let values = delayMs.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            return String(format: "| %.2f | %@ |", tempo, values)
        }
    }

    public struct JumpResult: Sendable {
        public var tempo: Double
        public var pressToAttackMs: [Double]
        public var row: String {
            let sorted = pressToAttackMs.sorted()
            guard !sorted.isEmpty else { return String(format: "| %.2f | none landed |", tempo) }
            return String(format: "| %.2f | %.1f | %.1f | %.1f |", tempo, sorted[0], sorted[sorted.count / 2], sorted.last!)
        }
    }

    public static var outputDescription: String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ") + String(format: ", %.0f Hz, buffer %.1f ms", session.sampleRate, session.ioBufferDuration * 1000)
        #else
        let engine = AVAudioEngine()
        return String(format: "default output, %.0f Hz", engine.outputNode.outputFormat(forBus: 0).sampleRate)
        #endif
    }

    private final class Onsets: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [UInt64] = []
        private var lastHost: UInt64 = 0
        private let gapTicks: UInt64
        init(gapSeconds: Double) { gapTicks = AVAudioTime.hostTime(forSeconds: gapSeconds) }
        func listen(to node: AVAudioNode) {
            node.installTap(onBus: 0, bufferSize: 512, format: nil) { [self] buffer, when in
                guard when.isHostTimeValid, let samples = buffer.floatChannelData?[0] else { return }
                let rate = buffer.format.sampleRate
                for i in 0..<Int(buffer.frameLength) where abs(samples[i]) > 0.2 {
                    let host = when.hostTime + AVAudioTime.hostTime(forSeconds: Double(i) / rate)
                    lock.lock()
                    if host > lastHost + gapTicks { found.append(host); lastHost = host } else { lastHost = max(lastHost, host) }
                    lock.unlock()
                    break
                }
            }
        }
        func take() -> [UInt64] {
            lock.lock(); defer { lock.unlock() }
            let out = found
            found = []
            return out
        }
    }

    private static func clickBuffer(format: AVAudioFormat, seconds: Double, every: Double) -> AVAudioPCMBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * format.sampleRate))!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<Int(format.channelCount) { pcm.floatChannelData![c].update(repeating: 0, count: Int(pcm.frameLength)) }
        var at = every * format.sampleRate
        while Int(at) + 1000 < Int(pcm.frameLength) {
            for k in 0..<720 {
                let v = Float(0.8 * sin(2 * .pi * 3000 * Double(k) / format.sampleRate) * exp(-Double(k) / (0.003 * format.sampleRate)))
                for c in 0..<Int(format.channelCount) { pcm.floatChannelData![c][Int(at) + k] = v }
            }
            at += every * format.sampleRate
        }
        return pcm
    }

    private static func prepareSession() {
        #if os(iOS)
        // Mixes with others, so a measurement never interrupts anything else on the iPad.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private static func makeGraph() throws -> (AVAudioEngine, AVAudioPlayerNode, AVAudioUnitTimePitch, AVAudioFormat) {
        prepareSession()
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)!
        let player = AVAudioPlayerNode(), stretch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0 // Muted: no sound leaves the machine.
        engine.prepare()
        try engine.start()
        return (engine, player, stretch, format)
    }

    /// How much later than asked each click comes out of the time-pitch.
    public static func delay(tempo: Double, runs: Int = 3) throws -> DelayResult {
        var results: [Double] = []
        for _ in 0..<runs {
            let (engine, player, stretch, format) = try makeGraph()
            defer { engine.stop() }
            stretch.rate = Float(tempo)
            let every = 0.4
            let pcm = clickBuffer(format: format, seconds: 12, every: every)
            let onsets = Onsets(gapSeconds: every * 0.5 / max(tempo, 1))
            onsets.listen(to: stretch)
            defer { stretch.removeTap(onBus: 0) }
            let start = AVAudioTime.seconds(forHostTime: mach_absolute_time()) + 0.3
            player.scheduleBuffer(pcm, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)), options: [])
            player.play()
            Thread.sleep(forTimeInterval: 5)
            player.stop()
            let found = onsets.take().map { AVAudioTime.seconds(forHostTime: $0) }
            let actualRate = (Double(stretch.rate) * 512).rounded() / 512
            var delays: [Double] = []
            for host in found {
                let index = ((host - start) * actualRate / every).rounded()
                guard index >= 1 else { continue }
                delays.append(host - (start + index * every / actualRate))
            }
            delays.sort()
            if !delays.isEmpty { results.append(delays[delays.count / 2] * 1000) }
        }
        return DelayResult(tempo: tempo, delayMs: results)
    }

    /// A hand-pressed jump on a plain player and time-pitch, as fast as it can go: stop, schedule
    /// from just before an attack, play. The current engine adds its 120 ms lead on top of this.
    public static func jump(tempo: Double, presses: Int = 10) throws -> JumpResult {
        let (engine, player, stretch, format) = try makeGraph()
        defer { engine.stop() }
        stretch.rate = Float(tempo)
        let every = 0.5
        let pcm = clickBuffer(format: format, seconds: 60, every: every)
        let onsets = Onsets(gapSeconds: 0.2)
        onsets.listen(to: stretch)
        defer { stretch.removeTap(onBus: 0) }
        let rate = format.sampleRate
        player.scheduleBuffer(pcm, at: nil, options: .loops)
        player.play()
        Thread.sleep(forTimeInterval: 1.1)
        var results: [Double] = []
        for press in 0..<presses {
            _ = onsets.take()
            // The segment starts exactly on a click, so the first thing out of it is the attack.
            let startFrame = AVAudioFrameCount((Double(press % 40 + 4) * every) * rate)
            let remaining = pcm.frameLength - startFrame
            let segment = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining)!
            segment.frameLength = remaining
            for c in 0..<2 { segment.floatChannelData![c].update(from: pcm.floatChannelData![c] + Int(startFrame), count: Int(remaining)) }
            let pressed = mach_absolute_time()
            player.stop()
            stretch.reset()
            player.scheduleBuffer(segment, at: nil)
            player.play()
            Thread.sleep(forTimeInterval: 0.22)
            if let first = onsets.take().first(where: { $0 >= pressed }) {
                results.append((AVAudioTime.seconds(forHostTime: first) - AVAudioTime.seconds(forHostTime: pressed)) * 1000)
            }
        }
        return JumpResult(tempo: tempo, pressToAttackMs: results)
    }
}
