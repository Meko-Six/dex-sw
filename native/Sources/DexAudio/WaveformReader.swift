import AVFoundation
import DexCore

public struct WaveformOverview: Sendable {
    public let duration: Double
    public let peaks: [Float]
    public let decodedFrames: Int64
    public let bufferCapacity: UInt32
    public let detection: DetectedGrid
    public let waveform: TrackWaveform?
    /// Nil when the read was asked not to look for the key.
    public let key: TrackKey?
    /// Nil for a cached overview, which doesn't decode the audio.
    public let loudness: TrackLoudness?
    public init(duration: Double, peaks: [Float], decodedFrames: Int64, bufferCapacity: UInt32,
                detection: DetectedGrid, waveform: TrackWaveform? = nil, key: TrackKey? = nil, loudness: TrackLoudness? = nil) {
        self.duration = duration; self.peaks = peaks; self.decodedFrames = decodedFrames
        self.bufferCapacity = bufferCapacity; self.detection = detection; self.waveform = waveform; self.key = key
        self.loudness = loudness
    }
}

/// Independent file handle, fixed PCM allocation and bounded output. Never decodes
/// a full track into RAM. This reader is called off the UI/audio render threads.
public enum WaveformReader {
    public static func read(url: URL, bins: Int = 2048, chunkFrames: UInt32 = 16_384,
                            analyzeRhythm: Bool = true, analyzeKey: Bool = false,
                            progress: (@Sendable (Double) -> Void)? = nil) throws -> WaveformOverview {
        try Task.checkCancellation()
        guard (1...16_384).contains(bins), (256...65_536).contains(chunkFrames) else {
            throw ReadError.invalidBudget
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, (1...2).contains(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ReadError.unsupportedAudio
        }
        // Includes geometric feature-array growth and refinement scratch. This
        // is shared preparation accounting, not a total process-RSS guarantee.
        let seconds = min(RhythmReader.maximumSeconds, Double(file.length) / format.sampleRate)
        let analysisLease = analyzeRhythm && seconds >= 6
            ? try AudioMemoryBudget.shared.reserve(Int64(seconds * 22050 / 11 * 3 * 4 * 2) + 8 * 1024 * 1024) : nil
        defer { withExtendedLifetime(analysisLease) {} }
        let envelope = try WaveformEnvelopeBuilder(format: format, frames: file.length, chunkFrames: chunkFrames)
        var peaks = [Float](repeating: 0, count: bins)
        let rhythm = analyzeRhythm && Double(file.length) / format.sampleRate >= 6 ? RhythmReader(format: format) : nil
        let key = analyzeKey ? KeyReader(format: format, frames: file.length, capacity: chunkFrames) : nil
        let loudness = LoudnessMeter(sampleRate: format.sampleRate)
        var cursor: Int64 = 0
        var reported = 0.0
        while cursor < file.length {
            try Task.checkCancellation()
            try autoreleasepool {
                try file.read(into: buffer, frameCount: UInt32(min(Int64(chunkFrames), file.length - cursor)))
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw ReadError.unsupportedAudio
            }
            try rhythm?.consume(buffer)
            key?.consume(buffer)
            loudness.consume(buffer)
            try envelope.consume(buffer)
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(bins - 1, Int(Double(cursor + Int64(frame)) / Double(file.length) * Double(bins)))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][frame])
                    if value.isFinite { peaks[bin] = max(peaks[bin], value) }
                }
            }
            cursor += Int64(buffer.frameLength)
            if let progress {
                let fraction = Double(cursor) / Double(file.length)
                if fraction >= reported + 0.05 || cursor == file.length {
                    reported = fraction
                    progress(fraction)
                }
            }
        }
        return WaveformOverview(duration: Double(cursor) / format.sampleRate, peaks: peaks,
                                decodedFrames: cursor, bufferCapacity: chunkFrames, detection: try rhythm?.detect() ?? .unavailable,
                                waveform: try envelope.finish(frames: cursor), key: key?.finish(), loudness: loudness.finish())
    }

    /// The loudness alone, for tracks imported before the library measured it.
    public static func readLoudness(url: URL, chunkFrames: UInt32 = 16_384) throws -> TrackLoudness {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, (1...2).contains(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ReadError.unsupportedAudio
        }
        let meter = LoudnessMeter(sampleRate: format.sampleRate)
        var cursor: Int64 = 0
        while cursor < file.length {
            try Task.checkCancellation()
            try autoreleasepool {
                try file.read(into: buffer, frameCount: UInt32(min(Int64(chunkFrames), file.length - cursor)))
            }
            guard buffer.frameLength > 0 else { throw ReadError.unsupportedAudio }
            meter.consume(buffer)
            cursor += Int64(buffer.frameLength)
        }
        return meter.finish()
    }

    /// The key alone, for tracks imported before the library analysed keys.
    public static func readKey(url: URL, chunkFrames: UInt32 = 16_384) throws -> TrackKey {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, (1...2).contains(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ReadError.unsupportedAudio
        }
        let key = KeyReader(format: format, frames: file.length, capacity: chunkFrames)
        var cursor: Int64 = 0
        while cursor < file.length {
            try Task.checkCancellation()
            try autoreleasepool {
                try file.read(into: buffer, frameCount: UInt32(min(Int64(chunkFrames), file.length - cursor)))
            }
            guard buffer.frameLength > 0 else { throw ReadError.unsupportedAudio }
            key.consume(buffer)
            cursor += Int64(buffer.frameLength)
        }
        return key.finish()
    }
    public enum ReadError: Error { case invalidBudget, unsupportedAudio }
}

extension LoudnessMeter {
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        consume(left: UnsafeBufferPointer(start: channels[0], count: frames),
                right: buffer.format.channelCount > 1 ? UnsafeBufferPointer(start: channels[1], count: frames) : nil)
    }
}

/// Feeds the key analysis the channel average, as `toMono` does, through one
/// fixed block of scratch.
final class KeyReader {
    private let accumulator: ChromaAccumulator
    private var mono: [Float]
    init(format: AVAudioFormat, frames: Int64, capacity: UInt32) {
        accumulator = ChromaAccumulator(sampleRate: format.sampleRate, frames: Int(frames))
        mono = [Float](repeating: 0, count: Int(capacity))
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = min(Int(buffer.frameLength), mono.count), count = Int(buffer.format.channelCount)
        if count == 1 {
            for i in 0..<frames { mono[i] = channels[0][i] }
        } else {
            for i in 0..<frames { mono[i] = Float((Double(channels[0][i]) + Double(channels[1][i])) / 2) }
        }
        mono.withUnsafeBufferPointer { accumulator.consume(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
    }
    func finish() -> TrackKey { KeyDetector.trackKey(chroma: accumulator.finish()) }
}

/// Admit one expensive file scan/refinement at a time across both decks.
/// Cancelled queued selections fail before opening/decoding their source.
actor TrackPreparation {
    static let shared = TrackPreparation()
    func read(_ url: URL) throws -> WaveformOverview {
        try Task.checkCancellation()
        return try WaveformReader.read(url: url)
    }
}
