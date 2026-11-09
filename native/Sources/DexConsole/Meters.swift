import Foundation

/// The four meters in the centre strip, A · L · R · B (`METER` in the mockup),
/// all peaks in dBFS on one scale: A and B each deck before its LEVEL fader
/// and the crossfader (after TRIM, EQ and FILTER); L and R the master before the limiter.
public struct MeterLevels: Equatable, Sendable {
    public var a, l, r, b: Double
    public init(a: Double, l: Double, r: Double, b: Double) { self.a = a; self.l = l; self.r = r; self.b = b }
    /// What a silent meter holds.
    public static let floor = -90.0
    public static let silent = MeterLevels(a: floor, l: floor, r: floor, b: floor)
    subscript(_ id: String) -> Double {
        switch id { case "A": a; case "L": l; case "R": r; default: b }
    }
}

public struct Meters: Equatable, Sendable {
    public var level: MeterLevels
    /// The held segment's level: the highest of the last 2 s.
    public var hold: MeterLevels
    public init(level: MeterLevels, hold: MeterLevels) { self.level = level; self.hold = hold }
    public static let silent = Meters(level: .silent, hold: .silent)

    /// How far up a meter a level sits, in percent: −30 to +6 dBFS (`meterPct`).
    static func percent(_ value: Double) -> Double { max(0, min(100, (value + 30) / 36 * 100)) }

    /// True where the meter reached 0 dBFS within its 2 s hold: the red cap the
    /// bars draw, and the same window the held segment already uses.
    public func isClipping(_ id: String) -> Bool { hold[id] >= MeterZones.clip }
}

/// Where the zones fall on the −30…+6 dBFS scale, the figures the control map
/// gives: aim a deck at −6, the master at −3, and 0 is where the limiter works.
public enum MeterZones {
    public static let deckAim = -6.0
    public static let masterAim = -3.0
    public static let clip = 0.0
}

/// The ladder the bars draw: twelve rungs of 3 dB across the −30 … +6 dBFS scale, six
/// green at the foot, then four amber, then two red, so red still begins at 0 dBFS. Twelve
/// keeps the reference meter's amber and red bands and its blocky look: at 8 pt wide, more
/// rungs read as stripes rather than blocks.
public enum MeterLadder {
    /// The foot, then the top of each rung up to the ceiling: −30 … +6 dBFS, 3 dB apart.
    public static let bounds: [Double] = [-30, -27, -24, -21, -18, -15, -12, -9, -6, -3, 0, 3, 6]
    /// The first amber rung and the first red one, counting from the foot.
    public static let amber = 6, red = 10

    public struct Rung: Equatable, Sendable {
        public let low, high: Double
        public let ink: UInt32
        /// The block as drawn: its span of the scale, with a point of air over and under.
        func bar(in width: CGFloat, height: CGFloat) -> CGRect {
            let top = height * (1 - Meters.percent(high) / 100)
            let bottom = height * (1 - Meters.percent(low) / 100)
            return CGRect(x: 0, y: top + 1, width: width, height: max(1, bottom - top - 2))
        }
    }

    public static let rungs: [Rung] = (0..<(bounds.count - 1)).map { index in
        Rung(low: bounds[index], high: bounds[index + 1],
             ink: index >= red ? 0xD03A2C : index >= amber ? 0xD8A029 : 0x25A859)
    }

    /// The rung a value has reached, counting from the foot: −1 below the first.
    public static func rung(for value: Double) -> Int { rungs.lastIndex { value >= $0.low } ?? -1 }
}

/// The meters' movement: up at once, down 20 dB a second, and the top
/// segment held for 2 s (`meterLoop` in the mockup).
public struct MeterBallistics: Sendable {
    public private(set) var meters = Meters.silent
    private var heldAt = (a: 0.0, l: 0.0, r: 0.0, b: 0.0)
    public init() {}

    /// Takes a reading `dt` seconds after the last, at `now` seconds.
    public mutating func update(_ reading: MeterLevels, dt: Double, now: Double) {
        func step(_ read: Double, _ level: inout Double, _ hold: inout Double, _ at: inout Double) {
            let read = read.isFinite ? max(MeterLevels.floor, read) : MeterLevels.floor
            level = read >= level ? read : max(read, level - 20 * min(0.1, dt))
            if level >= hold || now - at > 2 { hold = level; at = now }
        }
        step(reading.a, &meters.level.a, &meters.hold.a, &heldAt.a)
        step(reading.l, &meters.level.l, &meters.hold.l, &heldAt.l)
        step(reading.r, &meters.level.r, &meters.hold.r, &heldAt.r)
        step(reading.b, &meters.level.b, &meters.hold.b, &heldAt.b)
    }
}
