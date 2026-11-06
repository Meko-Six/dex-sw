import Foundation

public struct BarJump: Equatable, Sendable {
    public let position: Double
    public let bars: Int

    /// Bounds admit whole bars only. A playing deck keeps its fractional beat;
    /// a paused deck starts from the nearest playable bar line.
    public static func plan(grid: BeatGrid, position: Double, duration: Double,
                            playing: Bool, bars: Int, loop: ClosedRange<Double>? = nil) -> BarJump? {
        let period = grid.beatSeconds * 4
        guard position.isFinite, duration.isFinite, duration > 0, period.isFinite, period > 0,
              bars != Int.min else { return nil }
        var origin = min(duration, max(0, position))
        if !playing {
            let first = ceil(grid.beat(at: 0) / 4)
            let last = floor(grid.beat(at: duration) / 4)
            guard first.isFinite, last.isFinite, first <= last else { return nil }
            origin = grid.time(atBeat: min(last, max(first, floor(grid.beat(at: origin) / 4 + 0.5))) * 4)
        }
        let forward = bars >= 0
        var room = forward ? duration - origin : origin
        if let loop {
            guard loop.lowerBound.isFinite, loop.upperBound.isFinite,
                  loop.lowerBound >= 0, loop.upperBound <= duration else { return nil }
            room = min(room, forward ? duration - loop.upperBound : loop.lowerBound)
        }
        let fit = min(Double(abs(bars)), max(0, floor(room / period + 1e-9)))
        // fit is bounded by the requested integer; avoiding a conversion of the
        // track's unbounded beat count keeps pathological metadata harmless.
        guard fit < Double(Int.max) else { return nil }
        let moved = Int(fit) * (forward ? 1 : -1)
        return BarJump(position: origin + Double(moved) * period, bars: moved)
    }
}
