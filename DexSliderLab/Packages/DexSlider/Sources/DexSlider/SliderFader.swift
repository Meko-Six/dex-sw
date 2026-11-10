import SwiftUI

/// LEVEL and TEMPO: always drawn, so the position can be read at a glance as on
/// hardware. The drag is the chips' (relative, fine sideways, stretch at the ends);
/// there is no expansion. LEVEL shows its percentage and the master meter above
/// itself while touched; TEMPO keeps its percentage and BPM above it.
public struct SliderFader: View {
    let bank: SliderBank
    let id: SliderID

    public init(bank: SliderBank, id: SliderID) {
        self.bank = bank
        self.id = id
    }

    public var body: some View {
        let tuning = bank.tuning
        let control = bank.controls[id]
        let spec = control?.spec ?? .level(deck: id.deck)
        let value = control?.value ?? 0
        let touch = bank.faders[id]
        let touching = touch?.touching ?? false
        let isLocked = bank.isLocked(id)
        let height = tuning.faderHeight(id.role)
        let stretch = rubberBand(touch?.overshoot ?? 0, dimension: height, coefficient: tuning.rubberBand)
        let squeeze = 1 - min(abs(stretch) / height, 0.4) * 0.3

        VStack(spacing: 6) {
            if id.role == .tempo {
                let shown = tuning.tempoReadoutAlways || touching
                VStack(spacing: -2) {
                    Text(spec.readout(value))
                        .font(SliderTheme.cond(24))
                        .foregroundStyle(SliderTheme.text)
                    Text(FineSpeed.label(touch?.factor ?? 1) ?? spec.caption(value) ?? "")
                        .font(SliderTheme.cond(14, "DemiBold"))
                        .foregroundStyle((touch?.factor ?? 1) < 1 ? SliderTheme.mark : SliderTheme.dim)
                }
                .lineLimit(1)
                .fixedSize()
                .frame(height: 46)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: shown)
            }
            FaderTrack(spec: spec, value: value, style: tuning.style(id.role), tuning: tuning, touching: touching)
                .frame(width: tuning.faderWidth, height: height)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(sliderStageSpace))
                } action: { frame in
                    bank.setFrame(frame, for: id)
                }
                .scaleEffect(x: squeeze, y: 1 + abs(stretch) / height, anchor: stretch > 0 ? .bottom : .top)
                .opacity(isLocked ? 0.45 : 1)
            Text(isLocked ? "SYNC" : id.role.title)
                .font(SliderTheme.cond(15))
                .foregroundStyle(isLocked ? SliderTheme.sync : SliderTheme.text)
        }
        .accessibilityElement()
        .accessibilityLabel("\(id.deck) \(id.role.title)")
        .accessibilityValue(spec.readout(value))
    }
}

/// The fader itself, as an open bar or a cap on a track.
struct FaderTrack: View {
    let spec: SliderSpec
    let value: Double
    let style: SliderTuning.FaderStyle
    let tuning: SliderTuning
    let touching: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            switch style {
            case .bar: bar(width, height)
            case .cap: cap(width, height)
            }
        }
    }

    private func bar(_ width: Double, _ height: Double) -> some View {
        let edge = height * (1 - spec.fill(value))
        let base = spec.origin.map { height * (1 - spec.fill($0)) } ?? height
        let shape = RoundedRectangle(cornerRadius: tuning.barCorner, style: .continuous)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(SliderTheme.track)
            Rectangle()
                .fill(SliderTheme.fill)
                .frame(width: width, height: abs(base - edge))
                .offset(y: min(base, edge))
            if let origin = spec.origin {
                Rectangle()
                    .fill(SliderTheme.mark)
                    .frame(width: width, height: 3)
                    .offset(y: height * (1 - spec.fill(origin)) - 1.5)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(touching ? SliderTheme.text : .clear, lineWidth: 2))
    }

    private func cap(_ width: Double, _ height: Double) -> some View {
        let capHeight = tuning.capHeight
        let run = height - capHeight
        let slot = 10.0
        let centre = capHeight / 2 + run * (1 - spec.fill(value))
        let base = spec.origin.map { capHeight / 2 + run * (1 - spec.fill($0)) } ?? height
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(SliderTheme.chip)
                .frame(width: slot, height: height)
                .offset(x: (width - slot) / 2)
            Rectangle()
                .fill(SliderTheme.chipFill)
                .frame(width: slot, height: abs(base - centre))
                .offset(x: (width - slot) / 2, y: min(base, centre))
            if let origin = spec.origin {
                Rectangle()
                    .fill(SliderTheme.mark)
                    .frame(width: width * 0.6, height: 3)
                    .offset(x: width * 0.2, y: capHeight / 2 + run * (1 - spec.fill(origin)) - 1.5)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(touching ? Color.white : SliderTheme.fill)
                .overlay(Rectangle().fill(SliderTheme.chip).frame(height: 2).padding(.horizontal, 5))
                .frame(width: width - 8, height: capHeight)
                .offset(x: 4, y: centre - capHeight / 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// LEVEL's readout while touched: the master meter and the percentage, sitting just
/// above the fader so nothing covers the fader itself.
struct FaderReadout: View {
    let bank: SliderBank
    let id: SliderID

    var body: some View {
        let tuning = bank.tuning
        if id.role != .tempo, tuning.levelReadout, let frame = bank.frame(id),
           let control = bank.controls[id], let touch = bank.faders[id] {
            VStack(spacing: 4) {
                meter(control.spec, tuning)
                Text(control.spec.readout(control.value))
                    .font(SliderTheme.cond(tuning.readoutNumberSize))
                    .foregroundStyle(SliderTheme.text)
                if let fine = FineSpeed.label(touch.factor) {
                    Text(fine)
                        .font(SliderTheme.cond(13, "DemiBold"))
                        .foregroundStyle(SliderTheme.mark)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SliderTheme.backdrop))
            .fixedSize()
            // A zero-size frame pins one corner of the box to a point beside or above
            // the fader, so the box never covers the fader or its neighbours.
            .frame(width: 0, height: 0, alignment: anchor(frame, tuning))
            .position(point(frame, tuning))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Beside: away from the centre of the stage, level with the fader's top.
    private var outwardIsLeft: Bool { (bank.frame(id)?.midX ?? 0) <= bank.bounds.midX }

    private func anchor(_ frame: CGRect, _ tuning: SliderTuning) -> Alignment {
        guard tuning.readoutBeside else { return .bottom }
        return outwardIsLeft ? .topTrailing : .topLeading
    }

    private func point(_ frame: CGRect, _ tuning: SliderTuning) -> CGPoint {
        guard tuning.readoutBeside else { return CGPoint(x: frame.midX, y: frame.minY - 10) }
        return CGPoint(x: outwardIsLeft ? frame.minX - 12 : frame.maxX + 12, y: frame.minY)
    }

    @ViewBuilder private func meter(_ spec: SliderSpec, _ tuning: SliderTuning) -> some View {
        let height = max(4, tuning.rungHeight * 0.55), gap = max(2, tuning.rungGap * 0.5)
        switch spec.meter {
        case .master:
            HStack(spacing: 4) {
                RungColumn(rungs: tuning.rungs, value: bank.meter(.masterL), height: height, gap: gap)
                RungColumn(rungs: tuning.rungs, value: bank.meter(.masterR), height: height, gap: gap)
            }
            .frame(width: tuning.faderWidth * 0.7)
        case .deck(let key):
            RungColumn(rungs: tuning.rungs, value: bank.meter(key), height: height, gap: gap)
                .frame(width: tuning.faderWidth * 0.4)
        case .none:
            EmptyView()
        }
    }
}

enum FineSpeed {
    /// "FINE ¼" while the drag is slowed; nil at full speed.
    static func label(_ factor: Double) -> String? {
        guard factor < 1 else { return nil }
        return "FINE " + (factor == 0.5 ? "½" : factor == 0.25 ? "¼" : "⅒")
    }
}
