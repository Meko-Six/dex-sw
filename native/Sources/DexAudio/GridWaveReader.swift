import AVFoundation
import Foundation

/// The beat grid window's waveform, read from the audio file: the stored
/// envelope stops at 5 ms a bin, too coarse to set a grid by. Own file handle,
/// fixed buffer, nothing kept but the result, so it never touches playback.
public enum GridWaveReader {
    /// Lowest and highest sample per column, in pairs, from `start` seconds,
    /// `perColumn` seconds each. Columns past either end of the file stay 0.
    public static func read(url: URL, start: Double, perColumn: Double, columns: Int) throws -> [Float] {
        guard perColumn > 0, columns > 0 else { return [] }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return [] }
        var result = [Float](repeating: 0, count: columns * 2)
        let framesPerColumn = perColumn * format.sampleRate, startFrame = start * format.sampleRate
        var cursor = max(0, Int64(startFrame))
        let end = min(file.length, Int64(ceil(startFrame + Double(columns) * framesPerColumn)))
        guard cursor < end else { return result }
        file.framePosition = cursor
        while cursor < end {
            try Task.checkCancellation()
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: UInt32(min(Int64(buffer.frameCapacity), end - cursor)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let count = Int(format.channelCount), scale = 1 / Float(max(1, count))
            for frame in 0..<frames {
                let column = Int((Double(cursor + Int64(frame)) - startFrame) / framesPerColumn)
                guard (0..<columns).contains(column) else { continue }
                var value: Float = 0
                for channel in 0..<count { value += channels[channel][frame] }
                value *= scale
                result[column * 2] = min(result[column * 2], value)
                result[column * 2 + 1] = max(result[column * 2 + 1], value)
            }
            cursor += Int64(frames)
        }
        return result
    }
}
