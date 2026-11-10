import CoreGraphics
import Foundation

/// One finger's drag on one control. The drag is relative: touching changes
/// nothing, and only movement does. Moving the control's travel covers the whole
/// range; moving sideways from the touch slows it for fine work. Where the spec has
/// a detent, the value holds there for a few points of travel on its way through.
public struct SliderDrag: Sendable {
    public let spec: SliderSpec
    public let start: CGPoint
    /// The finger's position in value units, before the detent and clamping, so
    /// pulling past an end and coming back first undoes the stretch.
    public private(set) var raw: Double
    public private(set) var factor = 1.0
    /// True once the finger has moved far enough not to be a tap.
    public private(set) var moved = false
    /// The detent's width in value units; 0 for none.
    public let detentWidth: Double
    private var last: CGPoint

    public static let tapSlop = 6.0

    public init(spec: SliderSpec, value: Double, at point: CGPoint, detentWidth: Double = 0) {
        self.spec = spec
        self.start = point
        self.last = point
        self.detentWidth = spec.detent == nil ? 0 : max(0, detentWidth)
        self.raw = 0
        self.raw = toRaw(spec.clamp(value))
    }

    public var value: Double { spec.snap(spec.clamp(output)) }

    /// True while the drag is held in the detent.
    public var inDetent: Bool {
        guard let detent = spec.detent, detentWidth > 0 else { return false }
        return abs(raw - detent) <= detentWidth / 2
    }

    @discardableResult
    public mutating func move(to point: CGPoint, travel: Double, tuning: SliderTuning) -> Double {
        factor = tuning.fineFactor(sideways: Double(point.x - start.x))
        let dy = Double(point.y - last.y)
        let direction = spec.invert ? -1.0 : 1.0
        if travel > 0 { raw -= dy / travel * spec.span * factor * direction }
        last = point
        if hypot(Double(point.x - start.x), Double(point.y - start.y)) > Self.tapSlop { moved = true }
        return value
    }

    /// How far past an end the finger has pulled, in points: positive above the top,
    /// negative below the foot, 0 inside the range.
    public func overshoot(travel: Double) -> Double {
        guard spec.span > 0 else { return 0 }
        let past = (output - spec.clamp(output)) / spec.span * travel
        return spec.invert ? -past : past
    }

    private var output: Double {
        guard let detent = spec.detent, detentWidth > 0 else { return raw }
        let half = detentWidth / 2
        if raw > detent + half { return raw - half }
        if raw < detent - half { return raw + half }
        return detent
    }

    private func toRaw(_ value: Double) -> Double {
        guard let detent = spec.detent, detentWidth > 0 else { return value }
        if value > detent { return value + detentWidth / 2 }
        if value < detent { return value - detentWidth / 2 }
        return detent
    }
}

/// The stretch a pull past the end shows: UIScrollView's curve, close to the pull at
/// first and never more than `dimension`.
public func rubberBand(_ offset: Double, dimension: Double, coefficient: Double) -> Double {
    guard dimension > 0, coefficient > 0 else { return 0 }
    let pull = abs(offset)
    let stretch = (1 - 1 / (pull * coefficient / dimension + 1)) * dimension
    return offset < 0 ? -stretch : stretch
}
