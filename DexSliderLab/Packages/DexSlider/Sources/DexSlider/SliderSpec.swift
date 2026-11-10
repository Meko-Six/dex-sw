import Foundation

/// The mixer controls a chip can be.
public enum SliderRole: String, Sendable, Hashable, CaseIterable, Codable {
    case trim, hi, mid, low, level

    public var title: String {
        switch self {
        case .trim: "TRIM"
        case .hi: "HI"
        case .mid: "MID"
        case .low: "LOW"
        case .level: "LEVEL"
        }
    }
}

/// One chip: a deck ("A" or "B") and its role.
public struct SliderID: Hashable, Sendable, CustomStringConvertible {
    public let deck: String
    public let role: SliderRole
    public init(_ deck: String, _ role: SliderRole) {
        self.deck = deck
        self.role = role
    }
    public var description: String { "\(deck).\(role.rawValue)" }
}

/// The meters a panel can show.
public enum MeterKey: String, Sendable, Hashable, Codable {
    case deckA, deckB, masterL, masterR

    public static func deck(_ deck: String) -> MeterKey { deck == "B" ? .deckB : .deckA }
}

/// What the open panel draws above its number: one deck's meter, or the master pair.
public enum PanelMeter: Sendable, Equatable {
    case deck(MeterKey)
    case master
}

/// How a control's value reads, fills and resets.
public struct SliderSpec: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// Signed decibels to a tenth: "+1.3", "0", "−2.4".
        case decibels
        /// A position as a percentage: "75%".
        case percent
        /// A cut-only EQ position: a percentage, and "KILL" at the foot.
        case eq
    }

    public var range: ClosedRange<Double>
    /// Values land on multiples of this (TRIM moves in 0.1 dB); nil is continuous.
    public var step: Double?
    /// Where a double-tap returns it; nil means a double-tap does nothing.
    public var reset: Double?
    /// A mark drawn on the chip and the bar (TRIM's AUTO); nil draws none.
    public var mark: Double?
    public var meter: PanelMeter
    public var format: Format

    public init(range: ClosedRange<Double>, step: Double? = nil, reset: Double? = nil,
                mark: Double? = nil, meter: PanelMeter, format: Format) {
        self.range = range
        self.step = step
        self.reset = reset
        self.mark = mark
        self.meter = meter
        self.format = format
    }

    /// TRIM: absolute dB, ±12, a tenth at a time; double-tap goes back to AUTO.
    public static func trim(deck: String, auto: Double) -> SliderSpec {
        SliderSpec(range: -12...12, step: 0.1, reset: auto, mark: auto,
                   meter: .deck(.deck(deck)), format: .decibels)
    }

    /// HI, MID or LOW: a cut-only position, full is flat; double-tap goes back to flat.
    public static func eq(deck: String) -> SliderSpec {
        SliderSpec(range: 0...1, reset: 1, meter: .deck(.deck(deck)), format: .eq)
    }

    /// LEVEL: a position, 0 silent to 1 full. No double-tap reset: a stray double-tap
    /// must never throw a deck to full in the middle of a mix.
    public static func level(deck: String) -> SliderSpec {
        SliderSpec(range: 0...1, reset: nil, meter: .master, format: .percent)
    }

    public var span: Double { range.upperBound - range.lowerBound }

    public func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    public func snap(_ value: Double) -> Double {
        guard let step else { return value }
        let snapped = (value / step).rounded() * step
        return snapped == 0 ? 0 : snapped // no −0
    }

    /// How full the chip and the bar are, 0…1.
    public func fill(_ value: Double) -> Double {
        span > 0 ? (clamp(value) - range.lowerBound) / span : 0
    }

    public func readout(_ value: Double) -> String {
        switch format {
        case .decibels: Self.decibels(value)
        case .percent: "\(Int((clamp(value) * 100).rounded()))%"
        case .eq: value <= 0.005 ? "KILL" : "\(Int((clamp(value) * 100).rounded()))%"
        }
    }

    /// "+1.3", "0", "−2.4", with a true minus sign.
    public static func decibels(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        if tenths == 0 { return "0" }
        let text = String(format: "%.1f", abs(tenths) / 10)
        return (tenths > 0 ? "+" : "\u{2212}") + text
    }
}
