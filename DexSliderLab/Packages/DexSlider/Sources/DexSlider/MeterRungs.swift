import Foundation

/// A meter as the display shows it, in dBFS: where it is now and the highest it
/// reached within the hold.
public struct MeterValue: Sendable, Equatable {
    public var level: Double
    public var hold: Double
    public init(level: Double, hold: Double) {
        self.level = level
        self.hold = hold
    }
    public static let floor = -90.0
    public static let silent = MeterValue(level: floor, hold: floor)

    /// The louder of two meters, for the master pair.
    public static func louder(_ a: MeterValue, _ b: MeterValue) -> MeterValue {
        MeterValue(level: max(a.level, b.level), hold: max(a.hold, b.hold))
    }
}

public enum MeterTone: Sendable, Equatable {
    case green, yellow, red
}

/// The top of the meter as six rungs, as in the sketch: two green, three yellow,
/// one red. Only the top matters here, where the signal is close to clipping.
public struct MeterRungs: Sendable, Equatable {
    /// Each rung's threshold, foot first: a rung lights at or above its threshold.
    public let thresholds: [Double]

    public static let tones: [MeterTone] = [.green, .green, .yellow, .yellow, .yellow, .red]
    public static let count = 6

    public init(redDB: Double, stepDB: Double) {
        thresholds = (0..<Self.count).map { redDB - Double(Self.count - 1 - $0) * stepDB }
    }

    /// How many rungs a level lights, from the foot.
    public func reached(_ db: Double) -> Int {
        thresholds.lastIndex { db >= $0 }.map { $0 + 1 } ?? 0
    }

    /// Whether rung `index` (0 = foot) is lit: at or under the level, or the held rung.
    public func isLit(_ index: Int, _ value: MeterValue) -> Bool {
        index < reached(value.level) || index == reached(value.hold) - 1
    }

    /// The chip outline: red after reaching the red rung within the hold, yellow
    /// in the yellow rungs, green below them.
    public func tone(_ value: MeterValue) -> MeterTone {
        let top = reached(value.hold)
        if top >= Self.count { return .red }
        if top >= 3 { return .yellow }
        return .green
    }
}
