import Foundation

/// Every number that shapes the look and feel, so they can be tuned live on the
/// device. Values the user approves become the defaults here.
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

    // The open panel.
    public var barWidth = 86.0
    /// The bar's height, which is also the drag: moving this far covers the whole range.
    public var barHeight = 216.0
    public var barCorner = 4.0
    public var placement = Placement.outward
    public var panelGap = 14.0
    public var numberSize = 46.0
    public var rungHeight = 16.0
    public var rungGap = 8.0
    public var backdrop = true

    // The feel.
    /// Sideways travel from the touch before the drag slows to ½.
    public var fineStart = 50.0
    /// Further sideways travel for each slower step: ¼, then ⅒.
    public var fineStep = 50.0
    /// How hard the bar resists being pulled past either end (0 none … 1 stiff).
    public var rubberBand = 0.55
    public var openResponse = 0.24
    public var openBounce = 0.15
    /// How long the panel stays up after the finger lifts.
    public var holdAfterRelease = 0.6
    public var doubleTapWindow = 0.3

    // The meter.
    /// The red rung lights at or above this.
    public var redDB = 0.0
    /// The gap between rungs, in dB.
    public var rungStepDB = 2.0
    /// How long the highest rung reached stays lit.
    public var peakHold = 2.0
    /// How fast the meter falls, in dB a second.
    public var releaseDBPerSecond = 20.0

    // The chip at rest.
    public var chipWidth = 92.0
    public var chipHeight = 52.0
    public var chipFill = true
    public var chipNumber = true
    /// The outline shows the meter: green, yellow near the top, red after a clip.
    public var chipStatus = true
    public var chipFillOpacity = 0.32

    // The lab.
    /// The sketch's grey background, or Dex's near-black stage.
    public var dexBackground = false

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
        dexBackground = read(.dexBackground, base.dexBackground)
    }
}
