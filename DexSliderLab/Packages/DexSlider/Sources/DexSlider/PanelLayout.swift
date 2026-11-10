import CoreGraphics
import Foundation

/// Where an open panel sits: the meter rungs and the number above, the bar below.
public struct PanelLayout: Sendable, Equatable {
    public var header: CGRect
    public var bar: CGRect
    public var frame: CGRect { header.union(bar) }
}

public enum PanelPlacer {
    /// Space under the number for one small line (AUTO, FINE).
    static let captionHeight = 18.0
    static let spacing = 8.0
    static let margin = 8.0

    public static func meterHeight(_ tuning: SliderTuning) -> Double {
        Double(MeterRungs.count) * tuning.rungHeight + Double(MeterRungs.count - 1) * tuning.rungGap
    }

    public static func numberHeight(_ tuning: SliderTuning) -> Double {
        (tuning.numberSize * 1.08).rounded()
    }

    /// The meter, the number and the caption; without a meter, the number and caption.
    public static func headerHeight(_ tuning: SliderTuning, meter: Bool = true) -> Double {
        (meter ? meterHeight(tuning) + spacing : 0) + numberHeight(tuning) + captionHeight + spacing
    }

    public static func width(_ tuning: SliderTuning) -> Double {
        max(tuning.barWidth, 72)
    }

    /// Places the panel for a touch on `chip` at `finger`, inside `bounds`.
    ///
    /// The bar is set so its fill edge is level with the finger, so the finger seems
    /// to hold the level, then the whole panel is kept inside `bounds`. Beside the
    /// chip it takes the side `tuning.placement` asks for, and the other side if that
    /// would cover a panel already open.
    public static func place(chip: CGRect, finger: CGPoint, fill: Double, bounds: CGRect,
                             tuning: SliderTuning, meter: Bool = true, avoiding others: [CGRect] = []) -> PanelLayout {
        let header = headerHeight(tuning, meter: meter)
        let width = width(tuning)
        let height = header + tuning.barHeight

        var top = Double(finger.y) - header - tuning.barHeight * (1 - fill)
        top = clamp(top, Double(bounds.minY) + margin, Double(bounds.maxY) - margin - height)

        let leftOfChip = Double(chip.minX) - tuning.panelGap - width
        let rightOfChip = Double(chip.maxX) + tuning.panelGap
        let chipIsLeft = chip.midX <= bounds.midX
        let candidates: [Double]
        switch tuning.placement {
        case .outward: candidates = chipIsLeft ? [leftOfChip, rightOfChip] : [rightOfChip, leftOfChip]
        case .inward: candidates = chipIsLeft ? [rightOfChip, leftOfChip] : [leftOfChip, rightOfChip]
        case .onFinger: candidates = [Double(finger.x) - width / 2]
        }

        func layout(_ left: Double) -> PanelLayout {
            let x = clamp(left, Double(bounds.minX) + margin, Double(bounds.maxX) - margin - width)
            let barX = x + (width - tuning.barWidth) / 2
            return PanelLayout(
                header: CGRect(x: x, y: top, width: width, height: header),
                bar: CGRect(x: barX, y: top + header, width: tuning.barWidth, height: tuning.barHeight))
        }

        let layouts = candidates.map(layout)
        return layouts.first { candidate in !others.contains { $0.intersects(candidate.frame) } } ?? layouts[0]
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        high < low ? low : min(high, max(low, value))
    }
}

/// Where the effect list sits: a column of rows centred on the finger, with the
/// current effect under it, so sliding up or down picks a neighbour.
public enum PickerPlacer {
    public static let rowHeight = 50.0
    public static let gap = 6.0

    public static func width(_ tuning: SliderTuning) -> Double {
        max(tuning.chipWidth + 16, 120)
    }

    public static func place(finger: CGPoint, count: Int, current: Int, bounds: CGRect,
                             tuning: SliderTuning) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = width(tuning)
        let pitch = rowHeight + gap
        let total = Double(count) * pitch - gap
        let margin = PanelPlacer.margin
        let top = PanelPlacer.clamp(Double(finger.y) - Double(current) * pitch - rowHeight / 2,
                                    Double(bounds.minY) + margin, Double(bounds.maxY) - margin - total)
        let left = PanelPlacer.clamp(Double(finger.x) - width / 2,
                                     Double(bounds.minX) + margin, Double(bounds.maxX) - margin - width)
        return (0..<count).map { CGRect(x: left, y: top + Double($0) * pitch, width: width, height: rowHeight) }
    }
}
