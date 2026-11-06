import Foundation

/// A track's analysed key as the library keeps it. Ports the `key`, `camelot`
/// and `keyConfidence` fields of `src/shared/types.ts`: a key with no name is
/// one the analysis looked for and could not find.
public struct TrackKey: Codable, Equatable, Sendable {
    /// e.g. "F# minor".
    public var name: String?
    /// e.g. "11A".
    public var camelot: String?
    /// 0…1 margin over the runner-up key.
    public var confidence: Double
    public init(name: String?, camelot: String?, confidence: Double) {
        self.name = name; self.camelot = camelot; self.confidence = confidence
    }
    /// Too little pitched material to say anything (silence, a short clip).
    public static let notFound = TrackKey(name: nil, camelot: nil, confidence: 0)
}

/// Musical key estimation and Camelot mapping, ported from `src/shared/key.ts`
/// constant for constant. The reasons behind each choice (the 110 Hz floor,
/// power-weighted peaks, Sha'ath's profiles, the major-third rule) are in that
/// file; they were tuned on the accuracy bench.
public enum KeyDetector {
    public static let analysisRate = 22050.0
    static let frameSize = 4096
    static let hopSize = 2048
    static let minHz = 110.0
    static let maxHz = 2000.0
    /// Frames analysed per track; spread evenly so long tracks stay fast.
    static let maxFrames = 800
    static let peakPower = 0.75
    static let majorThirdRatio = 1.25

    static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// Sha'ath's key profiles (KeyFinder, 2011), indexed from the tonic.
    static let majorProfile = [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
    static let minorProfile = [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]
    /// Camelot codes by pitch class: 8B is C major, 8A is A minor.
    static let majorCamelot = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
    static let minorCamelot = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]

    public enum Mode: String, Sendable { case major, minor }

    public struct Candidate: Equatable, Sendable {
        public let tonic: Int
        public let mode: Mode
        public let score: Double
        public var key: String { KeyDetector.keyName(tonic, mode) }
        public var camelot: String { KeyDetector.camelot(tonic, mode) }
    }

    public struct Estimate: Equatable, Sendable {
        public let key: String
        public let camelot: String
        public let mode: Mode
        public let confidence: Double
        /// The top three readings, best first.
        public let candidates: [Candidate]
        public var trackKey: TrackKey { TrackKey(name: key, camelot: camelot, confidence: confidence) }
    }

    public static func camelot(_ tonic: Int, _ mode: Mode) -> String {
        let index = ((tonic % 12) + 12) % 12
        return mode == .major ? majorCamelot[index] : minorCamelot[index]
    }

    public static func keyName(_ tonic: Int, _ mode: Mode) -> String {
        "\(pitchNames[((tonic % 12) + 12) % 12]) \(mode.rawValue)"
    }

    /// `chromaVector`: the whole signal at once. The library streams through
    /// `ChromaAccumulator` instead, which gives the same vector.
    public static func chroma(_ samples: [Float], sampleRate: Double) -> [Float] {
        let accumulator = ChromaAccumulator(sampleRate: sampleRate, frames: samples.count)
        samples.withUnsafeBufferPointer { accumulator.consume($0) }
        return accumulator.finish()
    }

    public static func estimate(_ samples: [Float], sampleRate: Double) -> Estimate {
        estimate(chroma: chroma(samples, sampleRate: sampleRate))
    }

    /// The library's reading of a chroma vector; `.notFound` when it is empty.
    public static func trackKey(chroma: [Float]) -> TrackKey {
        chroma.contains { $0 > 0 } ? estimate(chroma: chroma).trackKey : .notFound
    }

    public static func estimate(chroma: [Float]) -> Estimate {
        var scored: [Candidate] = []
        for mode in [Mode.major, .minor] {
            let profile = mode == .major ? majorProfile : minorProfile
            for tonic in 0..<12 {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                scored.append(Candidate(tonic: tonic, mode: mode, score: pearson(chroma, rotated)))
            }
        }
        // Stable, as JavaScript's sort is: ties keep major before minor, C first.
        scored = scored.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)

        // Minor unless the major third clearly wins: much of this music has no
        // third at all, and the profiles then call the mode on noise.
        let top = scored[0]
        let parallelMinor = scored.firstIndex { $0.tonic == top.tonic && $0.mode == .minor }
        if top.mode == .major, let parallelMinor,
           Double(chroma[(top.tonic + 4) % 12]) <= majorThirdRatio * Double(chroma[(top.tonic + 3) % 12]) {
            scored.insert(scored.remove(at: parallelMinor), at: 0)
        }
        let best = scored[0]
        // Against the best *different* key, on the profiles' own margin, so a
        // mode called by the third rule keeps the confidence of its tonic.
        let runnerUp = scored.first { $0.key != top.key } ?? top
        let confidence = max(0, min(1, (top.score - runnerUp.score) / 0.2))
        return Estimate(key: best.key, camelot: best.camelot, mode: best.mode, confidence: confidence,
                        candidates: Array(scored.prefix(3)))
    }

    static func pearson(_ a: [Float], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0.0) { $0 + Double($1) } / n, meanB = b.reduce(0, +) / n
        var num = 0.0, denA = 0.0, denB = 0.0
        for i in a.indices {
            let da = Double(a[i]) - meanA, db = b[i] - meanB
            num += da * db; denA += da * da; denB += db * db
        }
        if denA <= 1e-12 || denB <= 1e-12 { return 0 }
        return num / (denA * denB).squareRoot()
    }
}

/// `chromaVector` fed a block at a time: linear resampling to 22.05 kHz, then
/// the same frames, peak picking and per-frame normalisation, keeping only a
/// 4096-sample window. Float32 where the TypeScript stores Float32Array.
public final class ChromaAccumulator {
    private typealias K = KeyDetector
    private let ratio: Double
    private let inputFrames: Int
    private let outputLength: Int
    private let totalFrames: Int
    private let stride: Int
    private let minBin: Int
    private let maxBin: Int
    private let binHz = KeyDetector.analysisRate / Double(KeyDetector.frameSize)
    private var consumed = 0, produced = 0, nextFrame = 0, usedFrames = 0
    private var previous: Float = 0
    private var ring = [Float](repeating: 0, count: KeyDetector.frameSize)
    private let window: [Float]
    private let fft = RadixTwoFFT(size: KeyDetector.frameSize)
    private var real = [Double](repeating: 0, count: KeyDetector.frameSize)
    private var imaginary = [Double](repeating: 0, count: KeyDetector.frameSize)
    private var magnitude: [Float]
    private var chroma = [Float](repeating: 0, count: 12)

    /// `frames` is the input's whole length at `sampleRate`, which sets the
    /// resampled length and the spread of analysed frames up front.
    public init(sampleRate: Double, frames: Int) {
        ratio = sampleRate == K.analysisRate ? 1 : sampleRate / K.analysisRate
        inputFrames = frames
        outputLength = ratio == 1 ? frames : max(1, Int((Double(frames) / ratio).rounded(.down)))
        let analysable = frames >= K.frameSize * 4
        totalFrames = analysable ? Int((Double(outputLength - K.frameSize) / Double(K.hopSize)).rounded(.down)) + 1 : 0
        stride = max(1, Int((Double(totalFrames) / Double(K.maxFrames)).rounded(.up)))
        minBin = max(2, Int((K.minHz / binHz).rounded(.down)))
        maxBin = min(K.frameSize / 2 - 2, Int((K.maxHz / binHz).rounded(.up)))
        magnitude = [Float](repeating: 0, count: maxBin + 2)
        let size = K.frameSize
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size - 1))) }
    }

    /// Mono samples at the input rate, in order.
    public func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard totalFrames > 0 else { consumed += samples.count; return }
        for sample in samples {
            let value = sample.isFinite ? sample : 0
            if ratio == 1 { push(value) }
            else {
                // Outputs whose left neighbour is the previous input sample.
                while produced < outputLength {
                    let position = Double(produced) * ratio
                    let left = Int(position)
                    guard left + 1 <= consumed else { break }
                    push(Float(Double(previous) + (Double(value) - Double(previous)) * (position - Double(left))))
                }
            }
            previous = value
            consumed += 1
        }
    }

    /// The normalised 12-bin vector, all zero when nothing pitched was found.
    public func finish() -> [Float] {
        if totalFrames > 0, ratio != 1 {
            // The last outputs have no right neighbour and hold the last input.
            while produced < outputLength { push(previous) }
        }
        guard usedFrames > 0 else { return [Float](repeating: 0, count: 12) }
        let total = chroma.reduce(0.0) { $0 + Double($1) }
        return total > 0 ? chroma.map { Float(Double($0) / total) } : chroma
    }

    private func push(_ value: Float) {
        ring[produced & (K.frameSize - 1)] = value
        produced += 1
        if nextFrame < totalFrames, produced == nextFrame * K.hopSize + K.frameSize {
            analyseFrame(start: nextFrame * K.hopSize)
            nextFrame += stride
        }
    }

    private func analyseFrame(start: Int) {
        let size = K.frameSize
        var energy = 0.0
        for i in 0..<size {
            let value = ring[(start + i) & (size - 1)]
            energy += Double(value) * Double(value)
            real[i] = Double(value) * Double(window[i])
            imaginary[i] = 0
        }
        // Skip near-silence: it adds noise, not pitch.
        if energy / Double(size) < 1e-6 { return }
        fft.transform(&real, &imaginary)
        // One bin either side too, so the band's edge bins are peaks only
        // against their real neighbours.
        for bin in (minBin - 1)...(maxBin + 1) {
            magnitude[bin] = Float(pow(hypot(real[bin], imaginary[bin]), K.peakPower))
        }
        // Spectral peaks only: a harmonic series is one pitch, not six.
        var frameChroma = [Float](repeating: 0, count: 12)
        var peakSum = 0.0
        for bin in minBin...maxBin {
            let value = magnitude[bin]
            if value <= magnitude[bin - 1] || value < magnitude[bin + 1] { continue }
            let midi = 69 + 12 * log2(Double(bin) * binHz / 440)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            frameChroma[pitchClass] += value
            peakSum += Double(value)
        }
        if peakSum <= 0 { return }
        for i in 0..<12 { chroma[i] = Float(Double(chroma[i]) + Double(frameChroma[i]) / peakSum) }
        usedFrames += 1
    }
}

/// `src/shared/fft.ts`: in-place radix-2 complex FFT with precomputed tables,
/// so the key analysis matches the TypeScript's arithmetic.
final class RadixTwoFFT {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let reverse: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosTable = (0..<size / 2).map { cos(-2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(-2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reverse = (0..<size).map { i in (0..<bits).reduce(0) { $0 | (((i >> $1) & 1) << (bits - 1 - $1)) } }
    }

    /// Forward transform in place; `imaginary` must be zero for real input.
    func transform(_ real: inout [Double], _ imaginary: inout [Double]) {
        for i in 0..<size {
            let j = reverse[i]
            if j > i { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var length = 2
        while length <= size {
            let half = length / 2, step = size / length
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosTable[k * step], wi = sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = real[b] * wr - imaginary[b] * wi
                    let ti = real[b] * wi + imaginary[b] * wr
                    real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti
                    real[a] += tr; imaginary[a] += ti
                }
                start += length
            }
            length *= 2
        }
    }
}
