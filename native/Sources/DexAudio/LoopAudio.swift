import Foundation

/// A loop's bounds, on the file's own frames. The engine plays it from its own cache, so a
/// loop holds no audio of its own and commits at once.
struct LoopAudio: Sendable, Equatable {
    let start: Double
    let end: Double

    /// Bounds rounded to the file's frames, as the engine plays them.
    init(start: Double, end: Double, sampleRate: Double) {
        self.start = (start * sampleRate).rounded() / sampleRate
        self.end = (end * sampleRate).rounded() / sampleRate
    }

    /// The same beat phase inside this loop, for a position on either side of it.
    func folding(_ position: Double) -> Double {
        let length = end - start
        guard length > 0, position < start || position >= end else { return position }
        let offset = (position - start).truncatingRemainder(dividingBy: length)
        return start + (offset < 0 ? offset + length : offset)
    }
}
