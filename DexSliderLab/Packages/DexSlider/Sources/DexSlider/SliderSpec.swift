import Foundation

/// The mixer and deck controls.
public enum SliderRole: String, Sendable, Hashable, CaseIterable, Codable {
    case trim, hi, mid, low, fx, level, tempo, cueMix, phones, master

    public var title: String {
        switch self {
        case .trim: "TRIM"
        case .hi: "HI"
        case .mid: "MID"
        case .low: "LOW"
        case .fx: "FX"
        case .level: "LEVEL"
        case .tempo: "TEMPO"
        case .cueMix: "CUE/MST"
        case .phones: "PHONES"
        case .master: "MASTER"
        }
    }
}

/// One control: a deck ("A", "B", or "M" for the master section) and its role.
public struct SliderID: Hashable, Sendable, CustomStringConvertible {
    public let deck: String
    public let role: SliderRole
    public init(_ deck: String, _ role: SliderRole) {
        self.deck = deck
        self.role = role
    }
    public var description: String { "\(deck).\(role.rawValue)" }
}

/// What a deck's FX chip does: the filter, or an effect that takes its place, as on
/// Traktor's Mixer FX. Every one has OFF at the centre, the high-pass side one way
/// and the low-pass side the other; the further from the centre, the more effect.
public enum DeckEffect: String, Sendable, Hashable, CaseIterable, Codable {
    case filter, reverb, delay, gater

    public var title: String { rawValue.uppercased() }
}

/// The meters a panel can show.
public enum MeterKey: String, Sendable, Hashable, Codable {
    case deckA, deckB, masterL, masterR

    public static func deck(_ deck: String) -> MeterKey { deck == "B" ? .deckB : .deckA }
}

/// What a panel or readout draws above its number.
public enum PanelMeter: Sendable, Equatable {
    case deck(MeterKey)
    case master
    case none
}

/// How a control's value reads, fills, moves and resets.
public struct SliderSpec: Sendable, Equatable {
    public enum Format: Sendable, Equatable {
        /// Signed decibels to a tenth: "+1.3", "0", "−2.4".
        case decibels
        /// A position as a percentage: "75%".
        case percent
        /// A cut-only EQ position: a percentage, and "KILL" at the foot.
        case eq
        /// A tempo change in percent to a tenth, with the BPM it gives a track of `bpm`.
        case tempo(bpm: Double)
        /// The headphone blend, 0 all cue … 1 all master.
        case blend
        /// FILTER or an effect: −100 … +100 % about OFF, high-pass positive.
        case fx(DeckEffect)
    }

    public var range: ClosedRange<Double>
    /// Values land on multiples of this (TRIM and TEMPO move in tenths); nil is continuous.
    public var step: Double?
    /// Where a double-tap returns it; nil means a double-tap does nothing.
    public var reset: Double?
    /// A mark drawn on the chip and the bar (TRIM's AUTO); nil draws none.
    public var mark: Double?
    /// Up lowers the value: TEMPO, where up is slower as on a CDJ.
    public var invert = false
    /// The fill grows from here rather than from the foot (TEMPO's 0).
    public var origin: Double?
    /// The drag gently sticks here on its way through.
    public var detent: Double?
    public var meter: PanelMeter
    public var format: Format
    /// The chip's name when it isn't the role's: the FX chip shows its effect.
    public var title: String?

    public init(range: ClosedRange<Double>, step: Double? = nil, reset: Double? = nil, mark: Double? = nil,
                invert: Bool = false, origin: Double? = nil, detent: Double? = nil,
                meter: PanelMeter, format: Format, title: String? = nil) {
        self.range = range
        self.step = step
        self.reset = reset
        self.mark = mark
        self.invert = invert
        self.origin = origin
        self.detent = detent
        self.meter = meter
        self.format = format
        self.title = title
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
        SliderSpec(range: 0...1, meter: .master, format: .percent)
    }

    /// TEMPO: ±16 % in tenths, up slower, sticking gently at 0. No double-tap reset,
    /// for the same reason as LEVEL.
    public static func tempo(bpm: Double) -> SliderSpec {
        SliderSpec(range: -16...16, step: 0.1, invert: true, origin: 0, detent: 0,
                   meter: .none, format: .tempo(bpm: bpm))
    }

    /// CUE/MST: the headphone blend; sticks at half and half, and double-tap goes there.
    public static func cueMix() -> SliderSpec {
        SliderSpec(range: 0...1, reset: 0.5, detent: 0.5, meter: .none, format: .blend)
    }

    /// PHONES: headphone level. No double-tap reset: nothing should jump in your ears.
    public static func phones() -> SliderSpec {
        SliderSpec(range: 0...1, meter: .none, format: .percent)
    }

    /// MASTER: the output level, with the master meter. No double-tap reset.
    public static func master() -> SliderSpec {
        SliderSpec(range: 0...1, meter: .master, format: .percent)
    }

    /// FX: the filter or an effect, ±100 % in whole steps about OFF at the centre,
    /// where it sticks gently and a double-tap returns it. Positive is the high-pass
    /// side, which is up unless `upIsHighPass` is off. The meter is the deck's, which
    /// in Dex reads after the filter.
    public static func fx(deck: String, effect: DeckEffect = .filter, upIsHighPass: Bool = true) -> SliderSpec {
        SliderSpec(range: -100...100, step: 1, reset: 0, invert: !upIsHighPass, origin: 0, detent: 0,
                   meter: .deck(.deck(deck)), format: .fx(effect), title: effect.title)
    }

    /// The FX chip's effect; nil for every other control.
    public var effect: DeckEffect? {
        switch format {
        case .fx(let effect): effect
        default: nil
        }
    }

    /// The same FX chip with another effect, keeping its direction.
    public func with(_ effect: DeckEffect) -> SliderSpec {
        var spec = self
        spec.format = .fx(effect)
        spec.title = effect.title
        return spec
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

    /// How far up the chip or bar a value sits, 0 foot … 1 top.
    public func fill(_ value: Double) -> Double {
        guard span > 0 else { return 0 }
        let up = (clamp(value) - range.lowerBound) / span
        return invert ? 1 - up : up
    }

    public func readout(_ value: Double) -> String {
        let percent = Int((clamp(value) * 100).rounded())
        switch format {
        case .decibels:
            return Self.decibels(value)
        case .percent:
            return "\(percent)%"
        case .eq:
            return value <= 0.005 ? "KILL" : "\(percent)%"
        case .tempo:
            return Self.tenths(value) + "%"
        case .blend:
            if percent == 50 { return "50/50" }
            return percent < 50 ? "CUE \(100 - percent)" : "MST \(percent)"
        case .fx:
            let whole = Int(clamp(value).rounded())
            return whole == 0 ? "OFF" : (whole > 0 ? "+" : "\u{2212}") + "\(abs(whole))%"
        }
    }

    /// A second line under the number, where the control has one.
    public func caption(_ value: Double) -> String? {
        if case .tempo(let bpm) = format {
            return String(format: "%.1f BPM", bpm * (1 + snap(clamp(value)) / 100))
        }
        if case .fx(let effect) = format {
            let whole = clamp(value).rounded()
            return whole == 0 ? effect.title : effect.title + (whole > 0 ? " HP" : " LP")
        }
        return nil
    }

    /// "+1.3", "0", "−2.4", with a true minus sign.
    public static func decibels(_ value: Double) -> String {
        (value * 10).rounded() == 0 ? "0" : tenths(value)
    }

    /// "+2.4", "0.0", "−2.4", with a true minus sign.
    static func tenths(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        let text = String(format: "%.1f", abs(tenths) / 10)
        return tenths == 0 ? text : (tenths > 0 ? "+" : "\u{2212}") + text
    }
}
