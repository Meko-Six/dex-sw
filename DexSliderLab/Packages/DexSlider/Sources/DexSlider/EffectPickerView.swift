import SwiftUI

/// The effect list over an FX chip: one row per effect, the one in use outlined in
/// green, the one under the finger lit. It takes no touches itself: the stage
/// routes them.
struct EffectPickerView: View {
    let bank: SliderBank
    let id: SliderID

    var body: some View {
        if let picker = bank.pickers[id] {
            let frame = picker.frame
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SliderTheme.backdrop)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    .frame(width: frame.width + 16, height: frame.height + 16)
                    .position(x: frame.midX, y: frame.midY)
                ForEach(Array(picker.options.enumerated()), id: \.offset) { index, effect in
                    let row = picker.rows[index]
                    let lit = picker.highlighted == index
                    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    Text(effect.title)
                        .font(SliderTheme.cond(20))
                        .foregroundStyle(lit ? Color.black : SliderTheme.text)
                        .frame(width: row.width, height: row.height)
                        .background(shape.fill(lit ? SliderTheme.fill : SliderTheme.chip))
                        .overlay(shape.strokeBorder(index == picker.current ? SliderTheme.green : SliderTheme.outline,
                                                    lineWidth: 2))
                        .position(x: row.midX, y: row.midY)
                }
            }
            .animation(.easeOut(duration: 0.08), value: picker.highlighted)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
