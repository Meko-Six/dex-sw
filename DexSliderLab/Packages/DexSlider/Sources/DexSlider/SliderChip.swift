import SwiftUI

/// The control at rest: a chip that fills like a small bar and shows its setting,
/// so you can read where it is without opening it. It owns no gesture; the stage
/// routes touches to it by its frame.
public struct SliderChip: View {
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
        let width = tuning.chipWidth, height = tuning.chipHeight
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        ZStack(alignment: .bottom) {
            shape.fill(SliderTheme.chip)
            if tuning.chipFill {
                Rectangle()
                    .fill(SliderTheme.chipFill.opacity(tuning.chipFillOpacity))
                    .frame(height: height * spec.fill(value))
            }
            if let mark = spec.mark {
                Rectangle()
                    .fill(SliderTheme.mark)
                    .frame(width: 10, height: 2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: -(height - 2) * spec.fill(mark))
            }
            VStack(spacing: -2) {
                Text(id.role.title)
                    .font(SliderTheme.cond(tuning.chipNumber ? 16 : 18))
                if tuning.chipNumber {
                    Text(spec.readout(value))
                        .font(SliderTheme.cond(19))
                }
            }
            .foregroundStyle(SliderTheme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(outline(spec), lineWidth: 2))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(sliderStageSpace))
        } action: { frame in
            bank.setFrame(frame, for: id)
        }
        .accessibilityElement()
        .accessibilityLabel("\(id.deck) \(id.role.title)")
        .accessibilityValue(spec.readout(value))
    }

    private func outline(_ spec: SliderSpec) -> Color {
        if bank.panels[id] != nil && bank.panels[id]?.closing == false { return SliderTheme.text }
        guard bank.tuning.chipStatus, let meter = bank.meterValue(for: spec) else { return SliderTheme.outline }
        return SliderTheme.colour(bank.tuning.rungs.tone(meter))
    }
}
