import DexSlider
import SwiftUI

/// One screen: deck A and deck B, each TRIM, HI, MID, LOW and LEVEL, with the A · L · R · B
/// meters between them as Dex's centre strip has them.
struct LabView: View {
    @State private var bank: SliderBank
    @State private var signal: TestSignal
    @State private var showTuning = false

    init() {
        let bank = SliderBank(tuning: TuningStore.load())
        _bank = State(initialValue: bank)
        _signal = State(initialValue: TestSignal(bank: bank))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            SliderStage(bank: bank) {
                HStack(alignment: .top, spacing: 36) {
                    DeckColumn(bank: bank, deck: "A")
                    CentreMeters(bank: bank)
                        .padding(.top, 8)
                    DeckColumn(bank: bank, deck: "B")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Touch and drag a chip up or down · slide sideways while dragging for fine · double-tap TRIM or EQ to reset")
                .font(SliderTheme.cond(14, "DemiBold"))
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(.bottom, 12)
        }
        .background(bank.tuning.dexBackground ? SliderTheme.dexBackground : SliderTheme.sketchBackground)
        .inspector(isPresented: $showTuning) {
            TuningView(tuning: $bank.tuning)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .onChange(of: bank.tuning) { _, tuning in TuningStore.save(tuning) }
        .onAppear { signal.start() }
        .onDisappear { signal.stop() }
        .task { await demo() }
    }

    /// `-demo trim | levels | stretch` holds pretend fingers down, for screenshots
    /// where real touches can't be sent.
    private func demo() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-demo"), index + 1 < args.count else { return }
        try? await Task.sleep(for: .seconds(1.5))
        func hold(_ key: Int, _ id: SliderID, up: Double, sideways: Double = 0) {
            guard let frame = bank.frame(id) else { return }
            let start = CGPoint(x: frame.midX, y: frame.midY)
            bank.touchDown(key, at: start, time: 0)
            for step in 1...10 {
                let t = Double(step) / 10
                bank.touchMoved(key, to: CGPoint(x: start.x + sideways * t, y: start.y - up * t))
            }
        }
        switch args[index + 1] {
        case "trim": hold(1, SliderID("A", .trim), up: 12)
        case "levels":
            hold(1, SliderID("A", .level), up: -70)
            hold(2, SliderID("B", .level), up: 90)
        case "stretch": hold(1, SliderID("A", .level), up: 140)
        case "fine": hold(1, SliderID("B", .trim), up: 30, sideways: 130)
        default: break
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Text("SLIDER LAB")
                .font(SliderTheme.cond(22))
                .fixedSize()
                .foregroundStyle(.white)
            Spacer()
            DeckTransport(signal: signal, deck: "A")
            DeckTransport(signal: signal, deck: "B")
            Spacer()
            Button {
                showTuning.toggle()
            } label: {
                Text("TUNE")
                    .font(SliderTheme.cond(18))
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(showTuning ? Color.white : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(showTuning ? Color.black : Color.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// One deck's chips, top to bottom as on Dex's mixer.
private struct DeckColumn: View {
    let bank: SliderBank
    let deck: String

    var body: some View {
        VStack(spacing: 14) {
            Text(deck)
                .font(SliderTheme.cond(22))
                .foregroundStyle(deck == "A" ? Color(red: 0.153, green: 0.435, blue: 1) : Color(red: 1, green: 0.541, blue: 0.122))
            SliderChip(bank: bank, id: SliderID(deck, .trim))
            Spacer().frame(height: 18)
            SliderChip(bank: bank, id: SliderID(deck, .hi))
            SliderChip(bank: bank, id: SliderID(deck, .mid))
            SliderChip(bank: bank, id: SliderID(deck, .low))
            Spacer().frame(height: 18)
            SliderChip(bank: bank, id: SliderID(deck, .level))
        }
        .padding(.top, 24)
    }
}

/// Play and pick a test track for one deck.
private struct DeckTransport: View {
    let signal: TestSignal
    let deck: String

    var body: some View {
        let state = signal.decks[deck] ?? TestSignal.Deck()
        HStack(spacing: 8) {
            Text(deck)
                .font(SliderTheme.cond(18))
                .foregroundStyle(.white)
            Button {
                signal.togglePlay(deck)
            } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 32)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Picker("Track", selection: Binding(get: { state.source }, set: { signal.load($0, on: deck) })) {
                ForEach(TestSignal.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
    }
}

/// Dex's centre meters, A · L · R · B, on its twelve-rung −30…+6 dBFS ladder, to
/// compare against the panels' close-up of the top.
private struct CentreMeters: View {
    let bank: SliderBank

    static let bounds: [Double] = [-30, -27, -24, -21, -18, -15, -12, -9, -6, -3, 0, 3, 6]

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            bar("A", .deckA)
            bar("L", .masterL)
            bar("R", .masterR)
            bar("B", .deckB)
        }
    }

    private func bar(_ label: String, _ key: MeterKey) -> some View {
        let value = bank.meter(key)
        let rungs = Self.bounds.count - 1
        let reached = Self.bounds.dropLast().lastIndex { value.level >= $0 }.map { $0 + 1 } ?? 0
        let held = Self.bounds.dropLast().lastIndex { value.hold >= $0 } ?? -1
        return VStack(spacing: 6) {
            VStack(spacing: 3) {
                ForEach((0..<rungs).reversed(), id: \.self) { index in
                    let colour = index >= 10 ? Color(red: 0.816, green: 0.227, blue: 0.173)
                        : index >= 6 ? Color(red: 0.847, green: 0.627, blue: 0.161)
                        : Color(red: 0.145, green: 0.659, blue: 0.349)
                    let lit = index < reached || index == held
                    Rectangle()
                        .fill(lit ? colour : colour.opacity(0.15))
                        .frame(width: 14, height: 20)
                }
            }
            Text(label)
                .font(SliderTheme.cond(14))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }
}

enum TuningStore {
    static let key = "DexSliderLab.tuning"

    static func load() -> SliderTuning {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tuning = try? JSONDecoder().decode(SliderTuning.self, from: data) else { return SliderTuning() }
        return tuning
    }

    static func save(_ tuning: SliderTuning) {
        if let data = try? JSONEncoder().encode(tuning) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func json(_ tuning: SliderTuning) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(tuning)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
