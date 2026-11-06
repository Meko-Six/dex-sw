import Foundation

/// Frame-independent motion in caller-defined units (source seconds for a
/// waveform; the same curve can be driven by platter rotation later).
public struct JogCoast: Sendable {
    public struct Sample: Equatable, Sendable {
        public let position: Double
        public let velocity: Double
        public let finished: Bool
    }
    public let duration: Double
    private let origin: Double
    private let velocity: Double
    private let damping: Double
    private let bounds: ClosedRange<Double>

    public init?(position: Double, velocity: Double, bounds: ClosedRange<Double>,
                 damping: Double = 4, stopSpeed: Double, maximumDuration: Double = 2) {
        guard position.isFinite, velocity.isFinite, bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              damping.isFinite, damping > 0, stopSpeed.isFinite, stopSpeed > 0,
              maximumDuration.isFinite, maximumDuration > 0 else { return nil }
        self.origin = min(bounds.upperBound, max(bounds.lowerBound, position))
        self.velocity = velocity; self.damping = damping; self.bounds = bounds
        var duration = abs(velocity) > stopSpeed ? min(maximumDuration, log(abs(velocity) / stopSpeed) / damping) : 0
        if velocity != 0 {
            let distance = velocity > 0 ? bounds.upperBound - origin : origin - bounds.lowerBound
            let fraction = distance * damping / abs(velocity)
            if fraction <= 0 { duration = 0 }
            else if fraction < 1 { duration = min(duration, -log1p(-fraction) / damping) }
        }
        self.duration = duration
    }
    public func sample(at elapsed: Double) -> Sample {
        let time = min(duration, max(0, elapsed.isFinite ? elapsed : duration))
        let position = origin + velocity / damping * -expm1(-damping * time)
        let finished = time >= duration
        return Sample(position: min(bounds.upperBound, max(bounds.lowerBound, position)),
                      velocity: finished ? 0 : velocity * exp(-damping * time), finished: finished)
    }
}

/// A released lane carries the playhead the same distance at any zoom, as a platter
/// would: looks biggest zoomed in, smallest zoomed out. The hand's speed sets the
/// distance. The lane's own speed at release still starts the coast, so pitch doesn't jump.
public enum JogFling {
    public static let referenceSpan = 12.0
    /// How quickly a coast slows at `referenceSpan`, per second.
    public static let referenceDamping = 2.4
    /// Source seconds covered by the hardest flick, at any zoom.
    public static let longestDistance = 8 / referenceDamping

    /// Source seconds a flick travels. `velocity` is the lane's source speed before
    /// any limit, and `span` the source seconds that lane shows.
    public static func distance(velocity: Double, span: Double) -> Double {
        min(longestDistance, abs(velocity) * referenceSpan / span / referenceDamping)
    }
    /// The damping that takes `speed`, the limited starting speed, that distance.
    public static func damping(velocity: Double, speed: Double, span: Double) -> Double {
        guard velocity.isFinite, speed.isFinite, span.isFinite, span > 0 else { return referenceDamping }
        let distance = distance(velocity: velocity, span: span)
        return distance > 0 && speed != 0 ? abs(speed) / distance : referenceDamping
    }
}

/// A small recent-motion window rejects stale fling velocity after a finger
/// pauses, and ignores duplicate timestamps instead of dividing by zero.
public struct JogVelocity: Sendable {
    private var samples: [(time: Double, position: Double)] = []
    public init() {}
    public mutating func add(position: Double, at time: Double) {
        guard position.isFinite, time.isFinite else { return }
        if let last = samples.last, time <= last.time { return }
        samples.removeAll { time - $0.time > 0.10 }
        if samples.count >= 2 {
            let last = samples[samples.count - 1], previous = samples[samples.count - 2]
            if (position - last.position) * (last.position - previous.position) < 0 {
                // A scratch reverses immediately; do not average the old
                // direction into the new stroke for another hundred ms.
                samples = [last]
            }
        }
        samples.append((time, position))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
    }
    public func velocity(at time: Double) -> Double {
        guard time.isFinite, let first = samples.first, let last = samples.last,
              time >= last.time, time - last.time <= 0.08, last.time - first.time >= 0.008 else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }
}
