import AVFoundation
import CDexEngine
import Foundation

/// Comparison clips, rendered to files and never played. Each clip of a set starts on the same
/// source frame and is matched in loudness, so switching between them is a fair test by ear.
public enum Clips {
    public struct Rendered {
        public var left, right: [Float]
        public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    }

    /// A deck's signal through the new engine, flat tone, no fader or limiter.
    public static func engine(url: URL, startSeconds: Double, seconds: Double, tempo: Double) throws -> Rendered {
        var config = DexEngineConfig()
        config.sampleRate = 48_000
        config.maxFrames = 4096
        config.hostTicksPerSecond = 1e9
        let engine = dex_engine_create(&config)!
        defer { dex_engine_destroy(engine) }
        let track = try FileTrack(url: url)
        var source = track.source
        let position = startSeconds * source.sampleRate
        dex_engine_load(engine, 0, &source, position)
        dex_engine_set_tempo(engine, 0, tempo)
        dex_engine_play(engine, 0, nil)
        let frames = Int(seconds * 48_000)
        var left = [Float](repeating: 0, count: frames), right = left
        var outs = [[Float]](repeating: [Float](repeating: 0, count: 1024), count: 2)
        var done = 0
        var host: UInt64 = 0
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                outs.withUnsafeMutableBufferPointer { o in
                    let op0 = o[0].withUnsafeMutableBufferPointer { $0.baseAddress! }, op1 = o[1].withUnsafeMutableBufferPointer { $0.baseAddress! }
                    let list: [UnsafeMutablePointer<Float>?] = [op0, op1]
                    list.withUnsafeBufferPointer { ol in
                        while done < frames {
                            let n = min(1024, frames - done)
                            dex_engine_pump_loader(engine)
                            let taps: [UnsafeMutablePointer<Float>?] = [lp.baseAddress! + done, rp.baseAddress! + done]
                            taps.withUnsafeBufferPointer { tl in
                                dex_engine_render_tapped(engine, UInt32(n), host, ol.baseAddress!, 2, tl.baseAddress!, nil)
                            }
                            done += n
                            host += 1
                        }
                    }
                }
            }
        }
        return Rendered(left: left, right: right)
    }

    /// The same passage through Apple's time-pitch, as the current engine plays it.
    public static func apple(url: URL, startSeconds: Double, seconds: Double, tempo: Double, extraSeconds: Double = 1) throws -> Rendered {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode(), stretch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        stretch.rate = Float(tempo)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        let startFrame = AVAudioFramePosition(startSeconds * file.processingFormat.sampleRate)
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)
        player.play()
        let frames = Int((seconds + extraSeconds) * 48_000)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        while left.count < frames {
            let status = try engine.renderOffline(1024, to: output)
            guard status == .success else { continue }
            left.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![1], count: Int(output.frameLength)))
        }
        engine.stop()
        return Rendered(left: left, right: right)
    }

    /// How many frames `other` runs late on `reference`, found on their loudness envelopes. Apple's
    /// delay isn't known to the frame, so its clip is trimmed to line up by this.
    public static func lag(of other: Rendered, on reference: Rendered, maxSeconds: Double = 0.5) -> Int {
        let hop = 16
        func envelope(_ x: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: x.count / hop)
            for i in out.indices {
                var sum: Float = 0
                for k in 0..<hop { sum += abs(x[i * hop + k]) }
                out[i] = sum
            }
            return out
        }
        let a = envelope(reference.left), b = envelope(other.left)
        let reach = Int(maxSeconds * 48_000) / hop
        var best = 0, bestScore = -Float.infinity
        for lag in 0...reach {
            let count = min(a.count, b.count - lag)
            guard count > 0 else { continue }
            var score: Float = 0
            for i in 0..<count { score += a[i] * b[i + lag] }
            if score > bestScore { bestScore = score; best = lag }
        }
        return best * hop
    }

    public static func rms(_ r: Rendered) -> Double {
        var sum = 0.0
        for i in r.left.indices { sum += Double(r.left[i] * r.left[i]) + Double(r.right[i] * r.right[i]) }
        return (sum / Double(max(1, r.left.count * 2))).squareRoot()
    }

    public static func write(_ r: Rendered, gain: Float, frames: Int, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        // A short fade each end, so a clip's edges can't be mistaken for a fault.
        let edge = 480
        for i in 0..<frames {
            let shape = Float(min(1, min(Double(i) / Double(edge), Double(frames - 1 - i) / Double(edge))))
            pcm.floatChannelData![0][i] = r.left[i] * gain * shape
            pcm.floatChannelData![1][i] = r.right[i] * gain * shape
        }
        try file.write(from: pcm)
    }

    public static func trimmed(_ r: Rendered, by frames: Int) -> Rendered {
        Rendered(left: Array(r.left.dropFirst(frames)), right: Array(r.right.dropFirst(frames)))
    }

    public static func peak(_ r: Rendered) -> Float {
        var p: Float = 0
        for i in r.left.indices { p = max(p, max(abs(r.left[i]), abs(r.right[i]))) }
        return p
    }
}
