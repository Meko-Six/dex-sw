import SwiftUI

/// The open control, from the sketch: the top of the meter, the number, and the bar.
/// It grows out of the chip and shrinks back into it. It takes no touches itself:
/// the stage routes them, so the finger can stay on the chip or move anywhere.
struct SliderPanelView: View {
    let bank: SliderBank
    let id: SliderID
    @State private var appeared = false

    var body: some View {
        if let panel = bank.panels[id], let control = bank.controls[id] {
            let tuning = bank.tuning
            let open = appeared && !panel.closing
            let bar = open ? stretched(panel.layout.bar, panel.overshoot, tuning) : panel.origin
            // Pulled past the top, the number and meter ride up with the bar.
            let lift = open ? max(0, panel.layout.bar.minY - bar.minY) : 0
            let drop = open ? max(0, bar.maxY - panel.layout.bar.maxY) : 0
            let header = panel.layout.header.offsetBy(dx: 0, dy: -lift)
            let fill = control.spec.fill(control.value)

            ZStack(alignment: .topLeading) {
                if tuning.backdrop {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(SliderTheme.backdrop.opacity(0.94))
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                        .frame(width: header.width + 28, height: header.height + panel.layout.bar.height + lift + drop + 28)
                        .position(x: panel.layout.frame.midX, y: panel.layout.frame.midY + (drop - lift) / 2)
                        .opacity(open ? 1 : 0)
                }

                PanelHeader(bank: bank, id: id, control: control, panel: panel)
                    .frame(width: header.width, height: header.height)
                    .scaleEffect(open ? 1 : 0.6, anchor: .bottom)
                    .opacity(open ? 1 : 0)
                    .position(x: header.midX, y: header.midY)

                PanelBar(fill: fill, mark: control.spec.mark.map(control.spec.fill),
                         open: open, corner: open ? tuning.barCorner : 8,
                         chipFillOpacity: tuning.chipFillOpacity)
                    .frame(width: bar.width, height: bar.height)
                    .position(x: bar.midX, y: bar.midY)
            }
            .animation(.spring(response: tuning.openResponse, dampingFraction: 1 - tuning.openBounce), value: open)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { appeared = true }
        }
    }

    /// The bar pulled past an end: longer that way, and a little narrower, like
    /// Control Centre's.
    private func stretched(_ bar: CGRect, _ overshoot: Double, _ tuning: SliderTuning) -> CGRect {
        let stretch = rubberBand(overshoot, dimension: tuning.barHeight, coefficient: tuning.rubberBand)
        guard stretch != 0 else { return bar }
        let squeeze = 1 - min(abs(stretch) / tuning.barHeight, 0.4) * 0.3
        let width = bar.width * squeeze
        var rect = CGRect(x: bar.midX - width / 2, y: bar.minY, width: width, height: bar.height + abs(stretch))
        if stretch > 0 { rect.origin.y -= stretch }
        return rect
    }
}

private struct PanelBar: View {
    let fill: Double
    let mark: Double?
    let open: Bool
    let corner: Double
    let chipFillOpacity: Double

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(open ? SliderTheme.track : SliderTheme.chip)
                Rectangle()
                    .fill(open ? SliderTheme.fill : SliderTheme.chipFill.opacity(chipFillOpacity))
                    .frame(height: height * fill)
                if let mark {
                    Rectangle()
                        .fill(SliderTheme.mark)
                        .frame(height: 3)
                        .offset(y: -(height - 3) * mark)
                }
            }
            .frame(width: proxy.size.width, height: height)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct PanelHeader: View {
    let bank: SliderBank
    let id: SliderID
    let control: SliderBank.Control
    let panel: SliderBank.Panel

    var body: some View {
        let tuning = bank.tuning
        VStack(spacing: 0) {
            meter(tuning)
                .frame(width: tuning.barWidth * 0.64, height: PanelPlacer.meterHeight(tuning))
            Spacer(minLength: PanelPlacer.spacing)
            Text(control.spec.readout(control.value))
                .font(SliderTheme.cond(tuning.numberSize))
                .foregroundStyle(SliderTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(height: PanelPlacer.numberHeight(tuning))
            Text(caption)
                .font(SliderTheme.cond(14, "DemiBold"))
                .foregroundStyle(panel.factor < 1 ? SliderTheme.mark : SliderTheme.dim)
                .frame(height: PanelPlacer.captionHeight)
            Spacer(minLength: PanelPlacer.spacing)
        }
    }

    private var caption: String {
        if panel.factor < 1 {
            let speed = panel.factor == 0.5 ? "½" : panel.factor == 0.25 ? "¼" : "⅒"
            return "FINE \(speed)"
        }
        if id.role == .trim, let auto = control.spec.mark {
            return abs(control.value - auto) < 0.05 ? "AUTO" : "AUTO \(SliderSpec.decibels(auto))"
        }
        return ""
    }

    @ViewBuilder private func meter(_ tuning: SliderTuning) -> some View {
        let rungs = tuning.rungs
        switch control.spec.meter {
        case .deck(let key):
            RungColumn(rungs: rungs, value: bank.meter(key), height: tuning.rungHeight, gap: tuning.rungGap)
        case .master:
            HStack(spacing: 6) {
                RungColumn(rungs: rungs, value: bank.meter(.masterL), height: tuning.rungHeight, gap: tuning.rungGap)
                RungColumn(rungs: rungs, value: bank.meter(.masterR), height: tuning.rungHeight, gap: tuning.rungGap)
            }
        }
    }
}

/// Six rungs, foot at the bottom: lit up to the level, plus the held rung.
struct RungColumn: View {
    let rungs: MeterRungs
    let value: MeterValue
    let height: Double
    let gap: Double

    var body: some View {
        VStack(spacing: gap) {
            ForEach((0..<MeterRungs.count).reversed(), id: \.self) { index in
                let colour = SliderTheme.colour(MeterRungs.tones[index])
                RoundedRectangle(cornerRadius: 2)
                    .fill(rungs.isLit(index, value) ? colour : colour.opacity(0.16))
                    .frame(height: height)
            }
        }
    }
}
