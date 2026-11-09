import Foundation
import Accelerate

/// How loud a track sounds, for AUTO trim: ITU-R BS.1770 loudness (the
/// measure behind LUFS), read once when the track is analysed.
///
/// Psytrance and techno are mastered hot and limited, so two tracks can peak
/// at the same height and sit several dB apart to the ear. Loudness, not peak,
/// is what has to match between the playing track and the incoming one.
public struct TrackLoudness: Codable, Equatable, Sendable {
    /// BS.1770 integrated loudness of the whole track, LUFS.
    public var integrated: Double
    /// The loudest half of the track's 3 s stretches, LUFS: the main groove,
    /// so long intros and breakdowns don't make a track read quieter than it plays.
    public var main: Double
    /// The highest sample, dBFS.
    public var peak: Double

    /// The main-groove loudness AUTO aims for, in LUFS. The DJ can turn
    /// down tracks with unusually high peaks using TRIM.
    public static let target = -11.0
    /// Quieter than this is silence: BS.1770's absolute gate.
    public static let silence = -70.0

    public init(integrated: Double, main: Double, peak: Double) {
        self.integrated = integrated; self.main = main; self.peak = peak
    }

    /// The trim, in dB to 0.1, that brings the main groove to `target`, within the trim's ±12 dB.
    public func autoTrim(target: Double = Self.target, limit: Double = 12) -> Double {
        guard main > Self.silence, main.isFinite else { return 0 }
        return (min(limit, max(-limit, target - main)) * 10).rounded() / 10
    }
}

/// Streams a track's samples through BS.1770's K-weighting and keeps one mean
/// square per 100 ms, which is all the integrated and main readings need: about
/// 94 KiB for a 20-minute track. The filtering runs on Accelerate's biquads,
/// since it covers every sample of every import.
public final class LoudnessMeter {
    private let setup: vDSP_biquad_SetupD
    private var delay: [[Double]] = [[Double](repeating: 0, count: 6), [Double](repeating: 0, count: 6)]
    private var input = [Double](), output = [Double]()
    private let stepFrames: Int
    private var stepCount = 0
    private var stepSum = 0.0
    private var steps: [Double] = []
    private var peak: Float = 0

    public init(sampleRate: Double) {
        let k = Self.kWeighting(sampleRate: sampleRate)
        // Two sections, each b0 b1 b2 a1 a2.
        setup = vDSP_biquad_CreateSetupD([k.shelf.b[0], k.shelf.b[1], k.shelf.b[2], k.shelf.a[1], k.shelf.a[2],
                                          k.highpass.b[0], k.highpass.b[1], k.highpass.b[2], k.highpass.a[1], k.highpass.a[2]], 2)!
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        steps.reserveCapacity(12_000)
    }
    deinit { vDSP_biquad_DestroySetupD(setup) }

    /// BS.1770's two K-weighting stages for any sample rate, from the analog
    /// design behind the standard's 48 kHz table (the same derivation libebur128 uses).
    static func kWeighting(sampleRate fs: Double) -> (shelf: (b: [Double], a: [Double]), highpass: (b: [Double], a: [Double])) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let gain = 3.999843853973347
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = (b: [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
                     a: [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highpass = (b: [1.0, -2, 1], a: [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
        return (shelf, highpass)
    }

    /// One block of a mono or stereo track. Mono plays on both speakers, so it
    /// counts twice, as the same signal on both sides of a stereo file would.
    public func consume(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?) {
        let frames = right.map { min(left.count, $0.count) } ?? left.count
        guard frames > 0 else { return }
        if input.count < frames { input = [Double](repeating: 0, count: frames); output = input }
        // Each side's K-weighted square, summed into the 100 ms steps.
        var squares = [Double](repeating: 0, count: 0)
        for (side, channel) in [left, right ?? left].enumerated() {
            var top: Float = 0
            vDSP_maxmgv(channel.baseAddress!, 1, &top, vDSP_Length(frames))
            input.withUnsafeMutableBufferPointer { into in
                vDSP_vspdp(channel.baseAddress!, 1, into.baseAddress!, 1, vDSP_Length(frames))
                if !top.isFinite {
                    // A damaged block: its bad samples count as silence.
                    for i in 0..<frames where !into[i].isFinite { into[i] = 0 }
                    top = channel.prefix(frames).filter(\.isFinite).map(abs).max() ?? 0
                }
            }
            peak = max(peak, top)
            delay[side].withUnsafeMutableBufferPointer { state in
                vDSP_biquadD(setup, state.baseAddress!, input, 1, &output, 1, vDSP_Length(frames))
            }
            vDSP_vsqD(output, 1, &output, 1, vDSP_Length(frames))
            if squares.isEmpty { squares = Array(output[0..<frames]) }
            else { vDSP_vaddD(squares, 1, output, 1, &squares, 1, vDSP_Length(frames)) }
        }
        var at = 0
        while at < frames {
            let take = min(stepFrames - stepCount, frames - at)
            var part = 0.0
            squares.withUnsafeBufferPointer { vDSP_sveD($0.baseAddress! + at, 1, &part, vDSP_Length(take)) }
            stepSum += part; stepCount += take; at += take
            if stepCount == stepFrames {
                steps.append(stepSum / Double(stepFrames))
                stepSum = 0; stepCount = 0
            }
        }
    }

    public func finish() -> TrackLoudness {
        let peakDb = peak > 0 ? 20 * log10(Double(peak)) : -120
        let integrated = Self.gated(windows(of: 4, hop: 1))
        // Short-term (3 s) loudness each second; the main groove is the loudest half of it.
        let shortTerm = windows(of: 30, hop: 10).filter { Self.lufs($0) > TrackLoudness.silence }.sorted(by: >)
        let main = shortTerm.isEmpty ? integrated : Self.lufs(Self.mean(shortTerm.prefix((shortTerm.count + 1) / 2)))
        return TrackLoudness(integrated: max(TrackLoudness.silence, integrated), main: max(TrackLoudness.silence, main),
                             peak: peakDb)
    }

    private func windows(of length: Int, hop: Int) -> [Double] {
        guard steps.count >= length else { return [] }
        return stride(from: 0, through: steps.count - length, by: hop).map { Self.mean(steps[$0..<($0 + length)]) }
    }

    /// BS.1770's integrated loudness: blocks over −70 LUFS, then those within 10 LU of their mean.
    private static func gated(_ blocks: [Double]) -> Double {
        let loud = blocks.filter { lufs($0) > TrackLoudness.silence }
        guard !loud.isEmpty else { return TrackLoudness.silence }
        let gate = lufs(mean(loud)) - 10
        let kept = loud.filter { lufs($0) > gate }
        return kept.isEmpty ? TrackLoudness.silence : lufs(mean(kept))
    }

    private static func mean<C: Collection>(_ values: C) -> Double where C.Element == Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }
}
