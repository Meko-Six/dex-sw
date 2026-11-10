import CoreGraphics
import Foundation

/// One finger's drag on one control. The drag is relative: touching changes
/// nothing, and only movement does. Up is more. Moving the bar's height covers the
/// whole range; moving sideways from the touch slows it for fine work.
public struct SliderDrag: Sendable {
    public let spec: SliderSpec
    public let start: CGPoint
    /// The value before clamping, so pulling past an end and coming back first
    /// undoes the stretch, as Control Centre does.
    public private(set) var raw: Double
    public private(set) var factor = 1.0
    /// True once the finger has moved far enough not to be a tap.
    public private(set) var moved = false
    private var last: CGPoint

    public static let tapSlop = 6.0

    public init(spec: SliderSpec, value: Double, at point: CGPoint) {
        self.spec = spec
        self.start = point
        self.raw = spec.clamp(value)
        self.last = point
    }

    public var value: Double { spec.snap(spec.clamp(raw)) }

    @discardableResult
    public mutating func move(to point: CGPoint, travel: Double, tuning: SliderTuning) -> Double {
        factor = tuning.fineFactor(sideways: Double(point.x - start.x))
        let dy = Double(point.y - last.y)
        if travel > 0 { raw -= dy / travel * spec.span * factor }
        last = point
        if hypot(Double(point.x - start.x), Double(point.y - start.y)) > Self.tapSlop { moved = true }
        return value
    }

    /// How far past an end the finger has pulled, in points: positive above the top,
    /// negative below the foot, 0 inside the range.
    public func overshoot(travel: Double) -> Double {
        guard spec.span > 0 else { return 0 }
        return (raw - spec.clamp(raw)) / spec.span * travel
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
