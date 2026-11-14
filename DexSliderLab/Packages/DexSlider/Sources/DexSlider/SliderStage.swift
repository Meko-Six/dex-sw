import SwiftUI

/// The coordinate space chips report their frames in and touches arrive in.
public let sliderStageSpace = "DexSliderStage"

/// The area the chips live in. It owns every touch inside it, routes each to the chip
/// it landed on, and draws the open panels over everything, so a panel can spill
/// past its column. Put only chips (and things that need no touches) inside.
public struct SliderStage<Content: View>: View {
    let bank: SliderBank
    let content: Content

    public init(bank: SliderBank, @ViewBuilder content: () -> Content) {
        self.bank = bank
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ForEach(bank.faders.keys.sorted { $0.description < $1.description }, id: \.self) { id in
                FaderReadout(bank: bank, id: id)
                    .transition(.opacity)
                    .zIndex(1)
            }
            ForEach(bank.panels.keys.sorted { $0.description < $1.description }, id: \.self) { id in
                SliderPanelView(bank: bank, id: id)
                    .zIndex(bank.panels[id]?.touching == true ? 3 : 2)
            }
            ForEach(bank.pickers.keys.sorted { $0.description < $1.description }, id: \.self) { id in
                EffectPickerView(bank: bank, id: id)
                    .transition(.opacity)
                    .zIndex(4)
            }
            // Over a host's own controls (Dex's), what's drawn on top must take the touch:
            // these shields keep a tap on the list or a panel from reaching what lies under
            // it, and leave it to the stage's gesture, which routes it to the bank.
            ForEach(shields, id: \.self) { frame in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(5)
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(.named(sliderStageSpace))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { proxy in
            CGRect(origin: .zero, size: proxy.size)
        } action: { bounds in
            bank.setBounds(bounds)
        }
        .gesture(
            SpatialEventGesture(coordinateSpace: .named(sliderStageSpace))
                .onChanged { events in bank.handle(events) }
                .onEnded { events in bank.handle(events, ended: true) }
        )
        .sensoryFeedback(.alignment, trigger: bank.ticks)
    }

    /// The effect lists, and the open panels' bars, with the slop the bank allows them.
    private var shields: [CGRect] {
        bank.pickers.values.map { $0.frame.insetBy(dx: -8, dy: -8) }
            + bank.panels.values.filter { !$0.closing }.map { $0.layout.bar.insetBy(dx: -8, dy: -8) }
    }
}
