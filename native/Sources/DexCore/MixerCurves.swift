import Foundation

/// The mixer's control curves, ported from `src/shared/mixer.ts` and
/// `curves.ts` so both apps' faders and filter sound and read the same.
public enum FaderLaw {
    /// Position (0 foot … 1 top) to dB, shared by LEVEL and the cut-only EQ.
    static let points: [(position: Double, db: Double)] = [(1, 0), (0.8, -3), (0.6, -6), (0.4, -12), (0.2, -24), (0.03, -48)]
    /// At or below this the fader mutes.
    static let floor = 0.005

    public static func db(_ position: Double) -> Double {
        let p = min(1, max(0, position))
        if p <= floor { return -.infinity }
        let last = points[points.count - 1]
        // The last stretch runs from −48 dB down towards −70 dB before the mute.
        if p < last.position { return last.db - (last.position - p) / (last.position - floor) * 22 }
        for index in 1..<points.count {
            let (p0, d0) = points[index - 1], (p1, d1) = points[index]
            if p >= p1 { return d1 + (d0 - d1) * (p - p1) / (p0 - p1) }
        }
        return last.db
    }
    public static func gain(_ position: Double) -> Double {
        let db = db(position)
        return db == -.infinity ? 0 : pow(10, db / 20)
    }
    /// LINK LOWS: the other deck's LOW moves the opposite way.
    public static func linkedLow(_ otherStart: Double, delta: Double) -> Double { min(1, max(0, otherStart - delta)) }
}

/// The three EQ kills.
public struct EQKills: Equatable, Sendable {
    public var low, mid, high: Bool
    public init(low: Bool = false, mid: Bool = false, high: Bool = false) { self.low = low; self.mid = mid; self.high = high }
}

/// The one-knob DJ sweep (`filterSetting`): centre is transparent, the left
/// half sweeps a low-pass down to 120 Hz, the right half a high-pass up to
/// 9 kHz, both exponentially, with the resonance rising as it bites.
public struct FilterSetting: Equatable, Sendable {
    public static let lowPassFlatHz = 20_000.0, lowPassFloorHz = 120.0
    public static let highPassFloorHz = 20.0, highPassCeilingHz = 9_000.0
    public let highPass: Bool
    public let frequency: Double
    public let q: Double

    public init(knob: Double) {
        let v = min(1, max(-1, knob.isFinite ? knob : 0))
        highPass = v > 0
        frequency = v < 0 ? Self.lowPassFlatHz * pow(Self.lowPassFloorHz / Self.lowPassFlatHz, -v)
            : v > 0 ? Self.highPassFloorHz * pow(Self.highPassCeilingHz / Self.highPassFloorHz, v) : Self.lowPassFlatHz
        q = 0.7 + 0.6 * abs(v)
    }
    /// Centre: the filter is out of the signal.
    public var flat: Bool { !highPass && frequency >= Self.lowPassFlatHz }
}
