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
