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
}
