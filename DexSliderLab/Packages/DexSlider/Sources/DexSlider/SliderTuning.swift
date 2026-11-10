import Foundation

/// Every number that shapes the look and feel, so they can be tuned live on the
/// device. Values the user approves become the defaults here: the current ones are
/// the user's iPad tuning of 10 November 2026.
public struct SliderTuning: Codable, Sendable, Equatable {
    public enum Placement: String, Codable, Sendable, CaseIterable {
        /// Beside the chip, away from the centre of the mixer.
        case outward
        /// Beside the chip, towards the centre.
        case inward
        /// Centred on the finger.
        case onFinger

        public var label: String {
            switch self {
            case .outward: "Outward"
            case .inward: "Inward"
            case .onFinger: "On finger"
            }
        }
    }

    public enum FaderStyle: String, Codable, Sendable, CaseIterable {
        /// The lab's bar, the fill showing the position.
        case bar
        /// A cap on a slim track, like hardware.
        case cap

        public var label: String { self == .bar ? "Open bar" : "Cap on a track" }
    }

    // The open panel.
    public var barWidth = 80.0
    /// The bar's height, which is also the drag: moving this far covers the whole range.
    public var barHeight = 140.0
    public var barCorner = 3.5
    public var placement = Placement.onFinger
    public var panelGap = 14.0
    public var numberSize = 46.0
    public var rungHeight = 16.0
    public var rungGap = 4.0
    public var backdrop = true

    // The feel.
    /// Sideways travel from the touch before the drag slows to ½.
    public var fineStart = 50.0
    /// Further sideways travel for each slower step: ¼, then ⅒.
    public var fineStep = 50.0
    /// How hard the bar resists being pulled past either end (0 none … 1 stiff).
    public var rubberBand = 0.30
    public var openResponse = 0.18
    public var openBounce = 0.15
    /// How long the panel stays up after the finger lifts.
    public var holdAfterRelease = 0.13
    public var doubleTapWindow = 0.25

    // The meter.
    /// The red rung lights at or above this.
    public var redDB = 0.0
    /// The gap between rungs, in dB.
    public var rungStepDB = 1.5
    /// How long the highest rung reached stays lit.
    public var peakHold = 2.0
    /// How fast the meter falls, in dB a second.
    public var releaseDBPerSecond = 20.0

    // The chip at rest.
    public var chipWidth = 105.0
    public var chipHeight = 58.0
    public var chipFill = true
    public var chipNumber = true
    /// The outline shows the meter: green, yellow near the top, red after a clip.
    public var chipStatus = true
    public var chipFillOpacity = 0.30

    // The always-visible faders: LEVEL and TEMPO.
    public var levelStyle = FaderStyle.cap
    public var tempoStyle = FaderStyle.cap
    public var faderWidth = 70.0
    public var levelHeight = 200.0
    public var tempoHeight = 240.0
    public var capHeight = 32.0
    /// LEVEL shows its percentage and the master meter above it while touched.
    public var levelReadout = true
    /// The readout beside the fader (outward), or above it.
    public var readoutBeside = false
    public var readoutNumberSize = 26.0
    /// TEMPO's percentage and BPM stay up; off shows them only while touched.
    public var tempoReadoutAlways = false
    // FX.
    /// Up is the high-pass side (thinner); off, up is low-pass.
    public var fxUpIsHighPass = true
    /// How long a finger must rest still on an FX chip to bring up the effect list.
    public var longPress = 0.5

    /// How many points of travel the detents (TEMPO's 0, CUE/MST's half, FX's OFF) hold for.
    public var detentPoints = 14.0

    // The lab.
    /// The sketch's grey background, or Dex's near-black stage.
    public var dexBackground = true

    public init() {}

    /// The drag's speed for how far the finger has moved sideways from the touch.
    public func fineFactor(sideways: Double) -> Double {
        let distance = abs(sideways)
        if distance < fineStart { return 1 }
        if distance < fineStart + fineStep { return 0.5 }
        if distance < fineStart + 2 * fineStep { return 0.25 }
        return 0.1
    }

    public var rungs: MeterRungs { MeterRungs(redDB: redDB, stepDB: rungStepDB) }

    /// A fader's style.
    public func style(_ role: SliderRole) -> FaderStyle { role == .tempo ? tempoStyle : levelStyle }

    /// A fader's drawn height.
    public func faderHeight(_ role: SliderRole) -> Double { role == .tempo ? tempoHeight : levelHeight }

    /// How far a fader's finger travels for the whole range: the bar's height, or the
    /// cap's run along its track.
    public func faderTravel(_ role: SliderRole) -> Double {
        faderHeight(role) - (style(role) == .cap ? capHeight : 0)
    }

    /// A missing or renamed key falls back to its default instead of failing the
    /// whole load, so saved tunings survive new settings.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? saved.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let base = SliderTuning()
        barWidth = read(.barWidth, base.barWidth)
        barHeight = read(.barHeight, base.barHeight)
        barCorner = read(.barCorner, base.barCorner)
        placement = read(.placement, base.placement)
        panelGap = read(.panelGap, base.panelGap)
        numberSize = read(.numberSize, base.numberSize)
        rungHeight = read(.rungHeight, base.rungHeight)
        rungGap = read(.rungGap, base.rungGap)
        backdrop = read(.backdrop, base.backdrop)
        fineStart = read(.fineStart, base.fineStart)
        fineStep = read(.fineStep, base.fineStep)
        rubberBand = read(.rubberBand, base.rubberBand)
        openResponse = read(.openResponse, base.openResponse)
        openBounce = read(.openBounce, base.openBounce)
        holdAfterRelease = read(.holdAfterRelease, base.holdAfterRelease)
        doubleTapWindow = read(.doubleTapWindow, base.doubleTapWindow)
        redDB = read(.redDB, base.redDB)
        rungStepDB = read(.rungStepDB, base.rungStepDB)
        peakHold = read(.peakHold, base.peakHold)
        releaseDBPerSecond = read(.releaseDBPerSecond, base.releaseDBPerSecond)
        chipWidth = read(.chipWidth, base.chipWidth)
        chipHeight = read(.chipHeight, base.chipHeight)
        chipFill = read(.chipFill, base.chipFill)
        chipNumber = read(.chipNumber, base.chipNumber)
        chipStatus = read(.chipStatus, base.chipStatus)
        chipFillOpacity = read(.chipFillOpacity, base.chipFillOpacity)
        levelStyle = read(.levelStyle, base.levelStyle)
        tempoStyle = read(.tempoStyle, base.tempoStyle)
        faderWidth = read(.faderWidth, base.faderWidth)
        levelHeight = read(.levelHeight, base.levelHeight)
        tempoHeight = read(.tempoHeight, base.tempoHeight)
        capHeight = read(.capHeight, base.capHeight)
        levelReadout = read(.levelReadout, base.levelReadout)
        readoutBeside = read(.readoutBeside, base.readoutBeside)
        readoutNumberSize = read(.readoutNumberSize, base.readoutNumberSize)
        tempoReadoutAlways = read(.tempoReadoutAlways, base.tempoReadoutAlways)
        fxUpIsHighPass = read(.fxUpIsHighPass, base.fxUpIsHighPass)
        longPress = read(.longPress, base.longPress)
        detentPoints = read(.detentPoints, base.detentPoints)
        dexBackground = read(.dexBackground, base.dexBackground)
    }
}
