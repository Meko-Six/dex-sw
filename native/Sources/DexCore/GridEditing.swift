import Foundation

/// Corrections fold at four beats so normalizing an offset never rotates the
/// 1–2–3–4 count. Tempo changes match the Electron grid editor's interpretation.
public enum GridEditing {
    public static func offset(_ grid: BeatGrid, milliseconds: Double) throws -> BeatGrid {
        guard milliseconds.isFinite else { throw BeatGrid.GridError.invalidGrid }
        let period = grid.beatSeconds * 4000
        let remainder = milliseconds.truncatingRemainder(dividingBy: period)
        return try BeatGrid(bpm: grid.bpm, offsetMs: remainder < 0 ? remainder + period : remainder, confidence: 1)
    }
    public static func tempo(_ grid: BeatGrid, bpm: Double) throws -> BeatGrid {
        guard bpm.isFinite else { throw BeatGrid.GridError.invalidGrid }
        return try offset(BeatGrid(bpm: min(300, max(40, bpm)), confidence: 1), milliseconds: grid.offsetMs)
    }
}

/// Monotonic input timestamps, bounded to eight taps within 2.6 seconds, matching
/// the reference editor. Three taps are required before publishing a reading.
public struct GridTapTempo: Sendable {
    private var times: [Double] = []
    public var count: Int { times.count }
    public init() {}
    public mutating func tap(at time: Double) -> Double? {
        guard time.isFinite else { return nil }
        if let last = times.last, time <= last { times = [] }
        times = Array(times.filter { time - $0 < 2.6 }.suffix(7))
        times.append(time)
        guard times.count >= 3 else { return nil }
        let average = (time - times[0]) / Double(times.count - 1)
        guard average > 0.15 else { return nil }
        return min(200, max(60, 60 / average))
    }
}
