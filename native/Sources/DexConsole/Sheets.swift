import SwiftUI
import DexCore

/// The sheets over the whole console: the beat grid, keyboard shortcuts,
/// TAP tempo and the (i) instructions. Ports `GridSheet` in `Sheets.tsx`,
/// `SheetLayer.tsx`, `Help.tsx` and their CSS.

// MARK: - Shared keys

/// `.btn`: the console's text key, in its looks.
struct SheetButton: View {
    enum Style { case plain, ghost, on, done, accent, outline, danger, dangerArmed }
    let title: String
    var style: Style = .plain
    var height: CGFloat = 40
    var minWidth: CGFloat = 0
    var disabled = false
    /// A glyph before the title, on the outlined keys.
    var glyph: String?
    var glyphSize: CGFloat = 20
    /// The glyph's width in Chromium, which picks its fallback font differently.
    var glyphWidth: CGFloat = 16.86
    let action: () -> Void

    private var outlined: Bool { [.done, .outline, .danger, .dangerArmed].contains(style) }

    var body: some View {
        let (fill, border, text) = colours
        Button(action: action) {
            HStack(spacing: 8) {
                if let glyph { Text(glyph).font(.custom("HelveticaNeue", fixedSize: glyphSize)).foregroundStyle(text).fixedSize().frame(width: glyphWidth, height: 16) }
                Label(title.uppercased(), .cond(16, tracking: 1.6)).foregroundStyle(text).frame(height: 16)
            }
                .padding(.horizontal, outlined ? 14 : 13)
                .frame(minWidth: minWidth).frame(height: height)
                .box(fill: fill, border: border, radius: 3, width: outlined ? 2 : 1)
        }
        .buttonStyle(.plain)
        // `.btn` has no disabled look: a disabled key only stops answering.
        .allowsHitTesting(!disabled)
        .accessibilityAddTraits(disabled ? [] : .isButton)
    }

    private var colours: (Color, Color, Color) {
        switch style {
        case .plain: (Color(hex: 0x17171A), Color(hex: 0x3B3B41), Color(hex: 0xE9E9EC))
        case .ghost: (.clear, Color(hex: 0x333338), Color(hex: 0xA0A0A6))
        case .on: (Color(hex: 0xE07000), Color(hex: 0xFFB455), Color(hex: 0x1A0E00))
        case .done: (.clear, Palette.outlineGreen, Palette.outlineGreen)
        case .outline: (.clear, Palette.outlineYellow, Palette.outlineYellow)
        case .danger: (.clear, Palette.red, Palette.removeRed)
        case .dangerArmed: (mix(0xE8402F, 0.22, 0x111113), Palette.red, Palette.removeRed)
        case .accent: (Palette.led, Palette.led, Color(hex: 0x1A0E00))
        }
    }
}

/// `.btn.info`: the round (i) key next to DONE / CLOSE.
struct InfoKey: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { context, canvas in
                let s = canvas.width / 20
                var icon = Path(ellipseIn: CGRect(x: 7.9 * s, y: 2.4 * s, width: 4.2 * s, height: 4.2 * s))
                icon.addRoundedRect(in: CGRect(x: 8 * s, y: 8 * s, width: 4 * s, height: 9.5 * s), cornerSize: CGSize(width: s, height: s))
                context.fill(icon, with: .color(Palette.outlineYellow))
            }
            .frame(width: 20, height: 20)
            .frame(width: size, height: size)
            .overlay(Circle().inset(by: 1).stroke(Palette.outlineYellow, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Instructions")
    }
}

// MARK: - Sheet chrome

/// `.gsheet`: the sheet's box.
struct SheetPanel<Content: View>: View {
    let width: CGFloat
    var spacing: CGFloat = 12
    var border = Color(hex: 0x3A3A40)
    var borderWidth: CGFloat = 1
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(EdgeInsets(top: 14 + borderWidth, leading: 16 + borderWidth, bottom: 16 + borderWidth, trailing: 16 + borderWidth))
            .frame(width: width)
            .box(fill: Color(hex: 0x111113), border: border, radius: 4, width: borderWidth)
            .compositingGroup()
            .shadow(color: .black.opacity(0.8), radius: 45, y: 34)
            .contentShape(Rectangle())
            .onTapGesture {}
    }
}

/// `.gsheet-head`: the title, its accent part, then (i) and CLOSE at the right.
struct SheetHead<Badge: View>: View {
    let title: String
    var accentPart = ""
    var accent = Palette.accent("A")
    var help: ConsoleState.HelpTopic?
    let actions: ConsoleActions
    @ViewBuilder var badge: Badge
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            let face = Face.cond(22, tracking: 3.52)
            let words = title.uppercased().split(separator: " ").map { (String($0), Palette.text) }
                + accentPart.uppercased().split(separator: " ").map { (String($0), accent) }
            // The title shrinks (and wraps) only once everything else has its width.
            WrappedLine(space: face.width(of: " "), lineHeight: 22) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in Label(word.0, face).foregroundStyle(word.1).frame(height: 22) }
            }
            .layoutPriority(1)
            badge
            Spacer(minLength: 0)
            if let help { InfoKey(size: 44) { actions.setHelp(help) } }
            SheetButton(title: "Close", style: .done, minWidth: 88, action: close)
        }
        // As tall as CLOSE, or the 44 pt (i) key.
        .frame(minHeight: help == nil ? 40 : 44)
    }
}

extension SheetHead where Badge == EmptyView {
    init(title: String, accentPart: String = "", accent: Color = Palette.accent("A"), help: ConsoleState.HelpTopic? = nil,
         actions: ConsoleActions, close: @escaping () -> Void) {
        self.init(title: title, accentPart: accentPart, accent: accent, help: help, actions: actions, badge: { EmptyView() }, close: close)
    }
}

/// `.sheet-layer` / `.gridsheet` / `.help-layer`: the console dimmed and
/// blurred under a sheet; a tap outside the sheet closes it.
struct SheetLayer<Content: View>: View {
    var dim = 0.78
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color(.sRGB, red: 4 / 255, green: 4 / 255, blue: 5 / 255, opacity: dim)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            content.padding(26)
        }
    }
}

/// `.gstat`: a big readout over its label. The label sits on the body
/// text's line box (17 pt at 1.3), as the inline span does in CSS.
struct Stat: View {
    let value: Text
    let label: String
    var valueFace = Face.cond(32, tracking: 0.64, tabular: true)
    var valueLine: CGFloat = 1.05

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            value.font(valueFace.font).tracking(valueFace.tracking).lineLimit(1)
                .frame(height: valueFace.size * valueLine)
            Label(label.uppercased(), .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk)
                .frame(height: 22.1, alignment: .center).offset(y: 2)
        }
        .padding(EdgeInsets(top: 8, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .box(fill: Color(hex: 0x161618), border: Color(hex: 0x2A2A2E), radius: 3)
    }
}

/// `.gact`: a big square key with its caption.
struct ActionKey<Title: View>: View {
    var tall = false
    var minHeight: CGFloat = 64
    var border = Color(hex: 0x3A3A40)
    var disabled = false
    let caption: String
    let action: () -> Void
    @ViewBuilder let title: Title

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                title
                Label(caption.uppercased(), .cond(12, tracking: 0.96)).foregroundStyle(tall ? Color(hex: 0x4A2600) : Palette.silk).frame(height: 13.2)
            }
            .foregroundStyle(tall ? Color(hex: 0x1A0E00) : Palette.text)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
            .box(fill: tall ? Color(hex: 0xD26A00) : Color(hex: 0x141416), border: tall ? Color(hex: 0xFFB455) : border, radius: 3)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!disabled)
    }
}

// MARK: - Help

/// The instructions behind each (i) key: a term per control and one plain
/// sentence for it. `HELP` in Help.tsx.
enum HelpText {
    static func topic(_ topic: ConsoleState.HelpTopic) -> (title: String, rows: [(String, String)], foot: String?) {
        switch topic {
        case .grid:
            ("How the beat grid works", [
                ("Drag", "Drag the waveform until the beat sits on a line. The lines stay still."),
                ("− +", "Zoom in until you can see the attack of the beat."),
                ("◀ Beat ▶", "Step to the line before or after. The strip below the wave moves along the track."),
                ("Set downbeat", "Arm it, then tap the first beat of a bar."),
                ("Tap", "Tap along with the beat. Three taps set the tempo."),
                ("±0.1 · 1 ms", "Trim the tempo, or slide the grid earlier or later."),
                ("÷2 · ×2", "Fix a half-time or double-time reading."),
                ("Other tempos", "Swap in a tempo the analysis turned down. It brings its own downbeat.")
            ], "Every edit saves to the library straight away. There is no Apply step.")
        case .tap:
            ("How TAP tempo works", [
                ("Input", "Pick what to listen to. To follow another app, send its output to a loopback device such as BlackHole."),
                ("Listening", "A tempo shows after about 8 seconds of rhythm."),
                ("Match deck", "Sets that deck's tempo to the one TAP hears.")
            ], "Nothing is recorded or sent to the mix. TAP only reads a tempo.")
        case .trim:
            ("Trim", [
                ("AUTO", "Dex sets the trim when a track loads, so every track plays as loud as the last."),
                ("Trim", "Change it if a track still sounds off. Dex remembers your trim for that track."),
                ("Reset", "Back to AUTO.")
            ], nil)
        case .band:
            ("EQ band", [
                ("Slider", "Full left kills the band. The right end is 0 dB."),
                ("Fine", "Drag up or down off the slider for fine moves."),
                ("Long ride", "Longer travel than the fader, for 16- and 32-bar rides. Same curve, same kills."),
                ("Link lows", "Linked, one drag trades A's low for B's: the bass swap in one move.")
            ], nil)
        case .volume:
            ("Volume", [
                ("Master", "The main output level."),
                ("Cue mix", "Blends the headphones from the cued deck (left) to the master (right).")
            ], nil)
        case .library:
            ("How the library works", [
                ("Load", "Tap a track, then tap a deck's album art. Or drag the track onto the deck."),
                ("Playlists", "Drag a track onto a playlist, or switch it on in MORE on its row."),
                ("Keys", "Tap a key to show it and its harmonic matches."),
                ("Sort", "Tap a column heading.")
            ], "Files stay on this machine.")
        }
    }
}

/// The open topic's instructions, over everything.
struct HelpSheet: View {
    let topic: ConsoleState.HelpTopic
    let actions: ConsoleActions

    var body: some View {
        let help = HelpText.topic(topic)
        SheetPanel(width: 600, spacing: 16) {
            SheetHead(title: help.title, actions: actions) { actions.setHelp(nil) }
            VStack(spacing: 0) {
                ForEach(help.rows, id: \.0) { term, text in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Para(term.uppercased(), .cond(17, tracking: 1.36), lineHeight: 1.2).foregroundStyle(mix(Palette.blueHex, 0.40, 0xFFFFFF))
                            .frame(width: 150, alignment: .leading)
                        Para(text, .ui(17), lineHeight: 1.35).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) { Color(hex: 0x222226).frame(height: 1) }
                    .padding(.top, 1)
                }
            }
            if let foot = help.foot {
                Para(foot, .ui(16), lineHeight: 1.4).foregroundStyle(Color(hex: 0xA0A0A6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 13)
                    .overlay(alignment: .top) { Color(hex: 0x222226).frame(height: 1) }
            }
        }
    }
}

// MARK: - Shortcuts

/// The keyboard shortcuts, in two columns.
struct ShortcutsSheet: View {
    let actions: ConsoleActions
    private typealias Group = (name: String, rows: [([String], String)])
    private static let groups: [Group] = [
        ("TRANSPORT", [
            (["1", "2"], "Play or pause deck A or B"),
            (["SPACE"], "Play or pause the focused deck"),
            (["C"], "CUE on the focused deck: set, return, hold to preview"),
            (["L"], "Start or leave a loop at the stepper size"),
            (["⇧", "L"], "Halve the running loop"),
            (["Q", "W"], "Beat jump deck A back / forward"),
            (["O", "P"], "Beat jump deck B back / forward")
        ]),
        ("SYNC · TEMPO", [
            (["S"], "Sync the other deck to this one"),
            (["⇧", "S"], "Sync this deck to the other"),
            (["[", "]"], "Tempo −0.1 % / +0.1 %")
        ]),
        ("MIXER", [(["M"], "Headphone CUE on the focused deck")]),
        ("BEAT GRID", [
            (["←", "→"], "Nudge the grid 1 ms"),
            (["⇧", "← →"], "Nudge the grid 10 ms")
        ]),
        ("CONSOLE", [
            (["ESC"], "Close the open sheet, or stop both decks"),
            (["?"], "This list")
        ])
    ]

    var body: some View {
        SheetPanel(width: 860) {
            SheetHead(title: "Keyboard", accentPart: " · shortcuts", actions: actions) { actions.setSheet(nil) }
            HStack(alignment: .top, spacing: 24) {
                column([0, 2])
                column([1, 3, 4])
            }
            Para([Para.Run("The", .ui(14), Color(hex: 0xA0A0A6)), Para.Run("focused deck", .ui(14, bold: true), Palette.text),
                  Para.Run("is the last one you touched. Shortcuts never fire while you type in the library's search.", .ui(14), Color(hex: 0xA0A0A6))],
                 lineHeight: 1.45)
        }
    }

    private func column(_ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(indices, id: \.self) { index in
                let group = Self.groups[index]
                VStack(alignment: .leading, spacing: 2) {
                    Label(group.name, .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(height: 12).padding(.bottom, 5)
                    ForEach(group.rows, id: \.1) { keys, text in
                        // `grid-template-columns: 120px minmax(0, 1fr)`, gap 10.
                        HStack(spacing: 10) {
                            // The keys' line box is 25.5 pt, the caps 1.5 pt down it.
                            HStack(spacing: 4) { ForEach(keys, id: \.self, content: Kbd.init) }
                                .frame(width: 120, height: 25.5, alignment: .leading).offset(y: 0.75)
                            // A flexible width here wraps the text short of its column.
                            Para(text, .ui(16), lineHeight: 1.3).foregroundStyle(Color(hex: 0xA0A0A6))
                                .frame(width: (860 - 34 - 24) / 2 - 120 - 10, alignment: .leading)
                        }
                        .frame(minHeight: 30)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `kbd`: a key cap.
private struct Kbd: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Label(key, .cond(13, tracking: 1.04)).foregroundStyle(Color(hex: 0xCDCDD3)).frame(height: 13)
            .padding(.horizontal, 8).frame(minWidth: 28).frame(height: 24)
            .box(fill: Color(hex: 0x151517), border: .white.opacity(0.13), radius: 3)
    }
}

// MARK: - TAP

/// TAP: reads the tempo of an audio input so a deck can be matched to it.
/// Analysis only: it never reaches the outputs, and closing the sheet
/// releases the input.
struct TapSheet: View {
    let state: ConsoleState
    let actions: ConsoleActions
    @State private var deviceID: String?

    var body: some View {
        let tap = state.tap
        let device = tap.devices.first { $0.id == (tap.listening ? tap.deviceID : chosen) }
        SheetPanel(width: 600) {
            SheetHead(title: "Tap tempo", accentPart: " · audio input", help: .tap, actions: actions, badge: {
                Label("EXPERIMENTAL", .cond(12, tracking: 0.96)).foregroundStyle(Color(hex: 0xFFB45E)).frame(height: 12)
                    .padding(.horizontal, 8).frame(height: 22)
                    .box(fill: Color(hex: 0x171008), border: Color(hex: 0x4A3418), radius: 2)
                    .padding(.leading, 2)
            }) { actions.setSheet(nil) }
            HStack(spacing: 6) {
                picker(device, tap: tap)
                SheetButton(title: "Refresh", style: .ghost, disabled: tap.listening, action: actions.tap.refresh)
                if tap.listening {
                    SheetButton(title: "Stop", style: .on, action: actions.tap.stop)
                } else {
                    SheetButton(title: "Listen", disabled: tap.devices.isEmpty) { actions.tap.listen(chosen) }
                }
            }
            HStack(spacing: 6) {
                Stat(value: Text(tap.bpm.map { String(format: "%.1f", $0) } ?? "—").foregroundColor(Palette.text),
                     label: tap.bpm.map { _ in "BPM · \(Int((tap.confidence * 100).rounded()))% confidence" } ?? "BPM",
                     valueFace: .cond(50, tracking: 0.5, weight: .regular), valueLine: 1)
                    .frame(width: 170)
                level(tap)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(state.decks, id: \.id) { deck in match(deck, tap: tap) }
            }
        }
        .onAppear(perform: actions.tap.refresh)
        .onDisappear(perform: actions.tap.stop)
    }

    /// The input picked, or the first loopback device, or the first input.
    private var chosen: String? {
        let devices = state.tap.devices
        if let deviceID, devices.contains(where: { $0.id == deviceID }) { return deviceID }
        return (devices.first(where: \.loopback) ?? devices.first)?.id
    }

    private func picker(_ device: ConsoleState.Tap.Device?, tap: ConsoleState.Tap) -> some View {
        Menu {
            ForEach(tap.devices) { entry in
                Button(entry.loopback ? "\(entry.label) · loopback" : entry.label) { deviceID = entry.id }
            }
        } label: {
            HStack(spacing: 8) {
                Text(device?.label ?? "No audio inputs").font(Face.ui(16).font).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if device?.loopback == true {
                    Label("LOOPBACK", .cond(12, tracking: 0.96)).foregroundStyle(Color(hex: 0x7EE0A2)).frame(height: 12)
                }
                Text("▾").font(Face.ui(16).font).foregroundStyle(Color(hex: 0x74747B))
            }
            .padding(.horizontal, 13).frame(height: 40)
            .box(fill: Color(hex: 0x141416), border: Color(hex: 0x3A3A40), radius: 3)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .allowsHitTesting(!tap.listening && !tap.devices.isEmpty)
        .accessibilityLabel("Audio input")
    }

    private func level(_ tap: ConsoleState.Tap) -> some View {
        let listening = tap.status == .listening
        let reading = listening ? (tap.levelDb > -59 ? "\(signed(tap.levelDb.rounded(), 0)) dB" : "−∞ dB") : "— dB"
        let windows = "\(tap.windows) \(tap.windows == 1 ? "window" : "windows")"
        let note = tap.error
            ?? (tap.devices.isEmpty ? "No audio inputs are visible. Connect an interface or install a loopback device, then Refresh."
                : tap.listening ? "Listening · \(windows)" : "Pick an input and listen.")
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                LevelMeter(percent: listening ? max(0, min(100, (tap.levelDb + 60) / 60 * 100)) : 0)
                Label(reading, .cond(14, tracking: 0.56)).foregroundStyle(Color(hex: 0xA0A0A6)).frame(width: 48, alignment: .trailing)
            }
            Para(note, .ui(14), lineHeight: 1.3).foregroundStyle(Color(hex: 0xA0A0A6))
        }
        .padding(EdgeInsets(top: 8, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .box(fill: Color(hex: 0x161618), border: Color(hex: 0x2A2A2E), radius: 3)
    }

    private func match(_ deck: ConsoleState.Deck, tap: ConsoleState.Tap) -> some View {
        let ratio = tap.bpm.flatMap { bpm in deck.grid.flatMap { tapTempoRatio(bpm, $0.bpm) } }
        let detail = deck.grid.map { grid in
            ratio.map { String(format: "%.1f → %.1f · ", grid.bpm, grid.bpm * $0) + signed(($0 - 1) * 100, 2) + "%" }
                ?? String(format: "%.1f BPM", grid.bpm)
        } ?? "No track loaded"
        return Button { actions.tap.match(deck.id) } label: {
            HStack(spacing: 10) {
                DeckLetter(id: deck.id, size: 20, face: .cond(16, tracking: 0.32))
                VStack(alignment: .leading, spacing: 4) {
                    Label("MATCH DECK \(deck.id)", .cond(18, tracking: 1.08)).foregroundStyle(Palette.text).frame(height: 19.8)
                    Label(detail, .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(height: 13.2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13).frame(minHeight: 64)
            .box(fill: Color(hex: 0x141416), border: Color(hex: 0x3A3A40), radius: 3)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(ratio != nil)
    }
}

/// `tapTempoRatio` in tap.ts: the deck's rate for the tapped BPM, within
/// the tempo fader's ±16 %.
func tapTempoRatio(_ tapped: Double, _ deckBpm: Double) -> Double? {
    guard tapped > 0, deckBpm > 0 else { return nil }
    return max(0.84, min(1.16, tapped / deckBpm))
}

/// "+1.20", "−3.76": a sign and fixed digits, with a true minus.
func signed(_ value: Double, _ digits: Int) -> String {
    (value < 0 ? "−" : "+") + String(format: "%.\(digits)f", abs(value))
}

/// `.meter-h`: a segmented horizontal level, −60 dB to 0 dB.
private struct LevelMeter: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            let width = (geometry.size.width - 2) * percent / 100
            Canvas { context, size in
                var stripes = Path()
                var x: CGFloat = 0
                while x < size.width { stripes.addRect(CGRect(x: x, y: 0, width: min(4, size.width - x), height: size.height)); x += 6 }
                context.clip(to: stripes)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(stops: [.init(color: Color(hex: 0x2FD36F), location: 0), .init(color: Color(hex: 0x2FD36F), location: 0.64),
                                     .init(color: Color(hex: 0xFFC531), location: 0.78), .init(color: Color(hex: 0xFF7A1A), location: 0.9),
                                     .init(color: Color(hex: 0xFF3B2F), location: 1)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            }
            .frame(width: max(0, width), height: geometry.size.height - 2)
            .offset(x: 1, y: 1)
        }
        .frame(height: 10)
        .box(fill: Color(hex: 0x0A0A0B), border: Color(hex: 0x26262A), radius: 1)
    }
}

// MARK: - Beat grid

/// The grid edits of `shared/grid.ts`: offsets fold at the bar so the
/// downbeat keeps its phase; tempo changes keep the downbeat's audio time.
enum GridEdits {
    static func barMs(_ bpm: Double) -> Double { 60_000 / bpm * 4 }
    static func normalize(_ offsetMs: Double, period: Double) -> Double {
        let r = offsetMs.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }
    static func nudge(_ grid: ConsoleState.Grid, _ ms: Double) -> ConsoleState.Grid {
        grid.with { $0.offsetMs = normalize(grid.offsetMs + ms, period: barMs(grid.bpm)) }
    }
    static func offset(_ grid: ConsoleState.Grid, _ ms: Double) -> ConsoleState.Grid {
        grid.with { $0.offsetMs = normalize(ms, period: barMs(grid.bpm)) }
    }
    static func tempo(_ grid: ConsoleState.Grid, _ bpm: Double) -> ConsoleState.Grid {
        let clamped = min(300, max(40, bpm))
        return ConsoleState.Grid(bpm: clamped, offsetMs: normalize(grid.offsetMs, period: barMs(clamped)), confidence: grid.confidence)
    }
    /// "2/3" → "3/2", "2" → "1/2".
    static func invert(_ relation: String) -> String {
        let parts = relation.split(separator: "/").map(String.init)
        let n = parts[0], d = parts.count > 1 ? parts[1] : "1"
        return d == "1" ? "1/\(n)" : n == "1" ? d : "\(d)/\(n)"
    }
    /// A tempo over another as the simplest ratio of small numbers, e.g. "4/3".
    static func relation(_ bpm: Double, over base: Double) -> String {
        let ratio = bpm / base
        for d in 1...8 {
            let n = (ratio * Double(d)).rounded()
            if n > 0, abs(n / Double(d) - ratio) < 0.005 * ratio { return d == 1 ? String(Int(n)) : "\(Int(n))/\(d)" }
        }
        return String(format: "%.2f", ratio)
    }
    /// Another reading taken; the one it replaces joins the list, so it is one tap back.
    static func take(_ alternate: ConsoleState.Library.Alternate, from grid: ConsoleState.Grid,
                     alternates: [ConsoleState.Library.Alternate]) -> (ConsoleState.Grid, [ConsoleState.Library.Alternate]) {
        let previous = ConsoleState.Library.Alternate(bpm: grid.bpm, offsetMs: grid.offsetMs, relation: invert(alternate.relation))
        let list = alternates.map { entry in
            entry == alternate ? previous : ConsoleState.Library.Alternate(bpm: entry.bpm, offsetMs: entry.offsetMs,
                                                                         relation: relation(entry.bpm, over: alternate.bpm))
        }
        return (ConsoleState.Grid(bpm: alternate.bpm, offsetMs: alternate.offsetMs, confidence: grid.confidence), list)
    }
}

extension ConsoleState.Grid {
    func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Beat grid editing for one deck: drag the waveform to pull the grid onto
/// the beat, or arm SET DOWNBEAT and tap the first beat of a bar. Every edit
/// goes straight to the library.
struct GridSheet: View {
    let deck: ConsoleState.Deck
    let track: ConsoleState.Library.Track?
    let actions: ConsoleActions
    /// Left edge of the window, seconds; nil until it moves from where the sheet opened.
    @State private var movedStart: Double?
    @State private var zoom = GridWindow.startingZoom
    @State private var armed = false
    @State private var taps: [Double] = []
    @State private var dragOffset: Double?
    @State private var dragStart: (x: CGFloat, offsetMs: Double, start: Double, moved: Bool)?
    @State private var samples: GridSamples?
    @State private var waveWidth: CGFloat = 0

    /// The demo's playhead is the mockup's, 24 s in.
    private var demo: Bool { if case .demo = deck.wave { true } else { false } }
    private var openedAt: Double { demo ? 24 : deck.position }
    private var span: Double { GridWindow.spans[zoom] }
    private var start: Double {
        movedStart ?? GridWindow.start(centred: openedAt, span: span, duration: deck.durationSec)
    }

    var body: some View {
        let grid = deck.grid, shown = grid.map { grid in dragOffset.map { offset in grid.with { $0.offsetMs = offset } } ?? grid }
        let accent = Palette.accent(deck.id)
        SheetPanel(width: 1100) {
            SheetHead(title: "Beat grid", accentPart: " · deck \(deck.id)", accent: accent, help: .grid, actions: actions, close: actions.closeGrid)
            HStack(spacing: 6) {
                Stat(value: Text(grid.map { String(format: "%.1f", $0.bpm) } ?? "—").foregroundColor(Palette.text), label: "BPM")
                Stat(value: Text(grid.map { "\(Int(($0.confidence * 100).rounded()))%" + (track?.gridUncertain == true ? "?" : "") } ?? "—")
                    .foregroundColor(track?.gridUncertain == true ? Color(hex: 0xFFB455) : (grid?.confidence ?? 0) >= 0.6 ? Palette.green : Palette.text),
                     label: "confidence")
                Stat(value: Text(shown.map { ($0.offsetMs >= 0 ? "+" : "") + String(format: "%.1f", $0.offsetMs) } ?? "—").foregroundColor(Palette.text),
                     label: "offset ms")
            }
            VStack(spacing: 7) {
                head(grid)
                wave(shown)
                strip.padding(.top, 6)
            }
            actionsRow(grid)
            if let grid, let track, !track.alternates.isEmpty { alternatesRow(grid, track: track) }
        }
        .onAppear { if movedStart == nil { movedStart = start } }
        .task(id: GridSamples.Key(span: span, page: Int((start / span).rounded(.down)), width: waveWidth)) { await readSamples() }
    }

    private func head(_ grid: ConsoleState.Grid?) -> some View {
        HStack(spacing: 8) {
            Label("GRID · 4/4", .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(height: 12)
            Text(armed ? "Tap the first beat of a bar" : "Drag the waveform onto the lines").font(Face.ui(14).font)
                .foregroundStyle(Color(hex: 0xA0A0A6)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                headKey("◀ BEAT", width: 74, disabled: grid == nil) { step(-1) }
                headKey("BEAT ▶", width: 74, disabled: grid == nil) { step(1) }
            }
            HStack(spacing: 4) {
                headKey("−", width: 44, size: 24, disabled: zoom == 0) { setZoom(zoom - 1) }
                Label(span >= 1 ? "\(Int(span)) S" : "\(Int(span * 1000)) MS", .cond(15, tracking: 0.9)).foregroundStyle(Palette.text)
                    .frame(width: 66, height: 15)
                headKey("+", width: 44, size: 24, disabled: zoom == GridWindow.spans.count - 1) { setZoom(zoom + 1) }
            }
            Button { armed.toggle() } label: {
                Label(armed ? "TAP THE FIRST BEAT" : "SET DOWNBEAT", .cond(15, tracking: 1.2)).frame(height: 15)
                    .foregroundStyle(armed ? Color(hex: 0x2A1A00) : Color(hex: 0xA0A0A6))
                    .padding(.horizontal, 11).frame(height: 36)
                    .box(fill: armed ? Palette.led : Color(hex: 0x141416), border: armed ? .clear : Color(hex: 0x3A3A40), radius: 2)
            }
            .buttonStyle(.plain).disabled(grid == nil)
        }
    }

    private func headKey(_ title: String, width: CGFloat, size: CGFloat = 15, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, size == 15 ? .cond(size, tracking: 0.9) : .cond(size, tracking: 1.44, weight: .medium))
                .foregroundStyle(Color(hex: 0xE9E9EC)).frame(width: width, height: 36)
                .box(fill: Color(hex: 0x141416), border: Color(hex: 0x3A3A40), radius: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1)
    }

    private func wave(_ shown: ConsoleState.Grid?) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            ZStack(alignment: .topLeading) {
                GridWaveCanvas(columns: columns(width), width: width, height: height)
                if let shown { lines(shown, width: width, height: height) }
                let now = (((demo ? 24 : deck.position) - start) / span * 100 * 100).rounded() / 100
                if now >= 0, now <= 100 {
                    GridPlayhead().frame(width: 10, height: height).offset(x: width * now / 100 - 5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag(changed: $0, width: width) }
                .onEnded { drag(ended: $0, width: width) })
            .onAppear { waveWidth = width }
        }
        .frame(height: 268)
        .clipped()
        .padding(1)
        .box(fill: Color(hex: 0x060607), border: Color(hex: 0x3A3A40), radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Lowest and highest per column, at two columns a point: the audio when
    /// it has been read for this zoom, the stored envelope until then.
    private func columns(_ width: CGFloat) -> [(Float, Float)] {
        let count = Int(width * 2), perColumn = span / Double(max(1, count))
        if demo {
            let audio = deck.id == "A" ? (bpm: 133.0, offsetMs: 489.9) : (bpm: 130.0, offsetMs: 247.3)
            return GridWindow.demoColumns(bpm: audio.bpm, offsetMs: audio.offsetMs, start: start, perColumn: perColumn, count: count)
        }
        if let samples, samples.perColumn == perColumn { return samples.columns(from: start, count: count) }
        guard case .track(let data)? = deck.wave else { return [] }
        return GridWindow.envelopeColumns(data, start: start, perColumn: perColumn, count: count)
    }

    /// The window and the one either side, so a drag has audio to show at once.
    private func readSamples() async {
        guard !demo, waveWidth > 0 else { return }
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        let count = Int(waveWidth * 2), perColumn = span / Double(count)
        let first = Double(Int((start / span).rounded(.down)) - 1) * span
        guard let read = await actions.gridWave(deck.id, first, perColumn, count * 3), !Task.isCancelled else { return }
        samples = GridSamples(start: first, perColumn: perColumn, values: read)
    }

    private func lines(_ grid: ConsoleState.Grid, width: CGFloat, height: CGFloat) -> some View {
        let period = 60 / grid.bpm, offset = grid.offsetMs / 1000
        let first = Int(((start - offset) / period).rounded(.down)) - 1
        let last = Int(((start + span - offset) / period).rounded(.up)) + 1
        let beats = (first...max(first, last)).compactMap { beat -> (Int, Double)? in
            let pct = ((offset + Double(beat) * period - start) / span * 100 * 100).rounded() / 100
            return pct < -0.5 || pct > 100.5 ? nil : (beat, pct)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(beats, id: \.0) { beat, pct in
                let downbeat = ((beat % 4) + 4) % 4 == 0
                let x = width * pct / 100
                Color(.sRGB, red: 1, green: 176 / 255, blue: 32 / 255, opacity: downbeat ? 1 : 0.85)
                    .frame(width: downbeat ? 2 : 1, height: height).offset(x: x)
                if downbeat {
                    Text(String(Int((Double(beat) / 4).rounded(.down)) + 1))
                        .font(.custom("Menlo-Bold", fixedSize: 12)).foregroundStyle(Palette.led)
                        .padding(.horizontal, 3).frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.62)))
                        .offset(x: x + 4, y: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// `.gstripbox`: the whole track and where the window is. Tap or drag to move it.
    private var strip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let duration = max(0.001, deck.durationSec)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var path = Path()
                    for (x, level) in stripLevels(width: width, height: height).enumerated() {
                        path.addRect(CGRect(x: CGFloat(x) * 2, y: (height - level) / 2, width: 1, height: level))
                    }
                    context.fill(path, with: .color(Color(hex: 0x6A6E71)))
                }
                let spot = max(8, width * span / duration)
                Palette.blue.opacity(0.3)
                    .overlay(Rectangle().inset(by: 1).stroke(Palette.blue, lineWidth: 2))
                    .frame(width: spot, height: height)
                    .offset(x: width * start / duration)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let x = min(1, max(0, Double(gesture.location.x / max(1, width))))
                movedStart = GridWindow.start(centred: x * duration, span: span, duration: deck.durationSec)
            })
        }
        .frame(height: 38)
        .clipped()
        .padding(1)
        .box(fill: Color(hex: 0x060607), border: Color(hex: 0x3A3A40), radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// One bar height every other point: the mockup's made-up sections, or the track's peaks.
    private func stripLevels(width: CGFloat, height: CGFloat) -> [CGFloat] {
        let count = Int(width) / 2 + (Int(width) % 2)
        if case .demo(let seed) = deck.wave {
            var state = seed
            return (0..<count).map { index in
                state = (state * 9301 + 49297) % 233_280
                let section = 0.45 + 0.4 * abs(sin(Double(index * 2) / Double(Int(width)) * 9 + Double(seed)))
                return max(2, CGFloat(section * (0.75 + 0.25 * Double(state) / 233_280)) * (height - 6))
            }
        }
        guard case .track(let data)? = deck.wave else { return [] }
        var levels = [CGFloat](repeating: 0, count: count)
        let perBar = data.duration / Double(max(1, count))
        data.level(secondsPerPixel: perBar).visit(start: 0, end: data.duration) { time, bin in
            let bar = Int(time / perBar)
            if levels.indices.contains(bar) { levels[bar] = max(levels[bar], CGFloat(bin.peak) * (height - 6)) }
        }
        return levels.map { max(2, $0) }
    }

    private func setZoom(_ next: Int) {
        let centre = start + span / 2
        zoom = max(0, min(GridWindow.spans.count - 1, next))
        movedStart = GridWindow.start(centred: centre, span: span, duration: deck.durationSec)
    }

    private func step(_ direction: Int) {
        guard let grid = deck.grid else { return }
        let line = GridWindow.line(after: start + span / 2, direction: direction, bpm: grid.bpm, offsetMs: grid.offsetMs)
        movedStart = GridWindow.start(centred: line, span: span, duration: deck.durationSec)
    }

    private func drag(changed gesture: DragGesture.Value, width: CGFloat) {
        guard let grid = deck.grid else { return }
        if dragStart == nil { dragStart = (gesture.startLocation.x, grid.offsetMs, start, false) }
        guard var d = dragStart, !armed else { return }
        let dx = gesture.location.x - d.x
        if !d.moved, abs(dx) < 3 { return }
        d.moved = true
        dragStart = d
        // The waveform follows the finger and the lines stay where they are.
        let seconds = Double(dx / max(1, width)) * span
        dragOffset = d.offsetMs - seconds * 1000
        movedStart = d.start - seconds
    }

    private func drag(ended gesture: DragGesture.Value, width: CGFloat) {
        defer { dragStart = nil; dragOffset = nil }
        guard let grid = deck.grid, let d = dragStart else { return }
        if armed, !d.moved {
            let x = min(1, max(0, Double(gesture.location.x / max(1, width))))
            apply(GridEdits.offset(grid, (start + x * span) * 1000))
            armed = false
        } else if d.moved, let dragOffset {
            apply(GridEdits.offset(grid, dragOffset))
        }
    }

    /// `◀ 1 ms`: the grid moves against the audio; on screen the lines stay and the waveform slides.
    private func nudge(_ grid: ConsoleState.Grid, _ ms: Double) {
        movedStart = start + ms / 1000
        apply(GridEdits.nudge(grid, ms))
    }

    private func apply(_ grid: ConsoleState.Grid, alternates: [ConsoleState.Library.Alternate]? = nil) {
        actions.setGrid(deck.id, grid, alternates)
    }

    private func tapTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = Array((taps.filter { now - $0 < 2.6 } + [now]).suffix(8))
        taps = recent
        guard recent.count >= 3 else { return }
        let average = (recent.last! - recent.first!) / Double(recent.count - 1)
        if average > 0.15 {
            apply(ConsoleState.Grid(bpm: min(200, max(60, 60 / average)), offsetMs: deck.grid?.offsetMs ?? 0, confidence: 0.5))
        }
    }

    private func actionsRow(_ grid: ConsoleState.Grid?) -> some View {
        let none = grid == nil
        return GeometryReader { geometry in
            // 1.16fr, then six of 1fr, 6 pt apart.
            let unit = (geometry.size.width - 36) / 7.16
            HStack(spacing: 6) {
                ActionKey(tall: true, disabled: !deck.loaded, caption: taps.isEmpty ? "3 taps" : "\(taps.count) \(taps.count == 1 ? "tap" : "taps")",
                          action: tapTempo) { keyTitle("TAP", size: 22, tracking: 3.08) }
                    .frame(width: unit * 1.16)
                key("−0.1", "BPM", none) { if let grid { apply(GridEdits.tempo(grid, grid.bpm - 0.1)) } }.frame(width: unit)
                key("+0.1", "BPM", none) { if let grid { apply(GridEdits.tempo(grid, grid.bpm + 0.1)) } }.frame(width: unit)
                key("◀ 1 ms", "earlier", none) { if let grid { nudge(grid, -1) } }.frame(width: unit)
                key("1 ms ▶", "later", none) { if let grid { nudge(grid, 1) } }.frame(width: unit)
                key("÷2", "half", none) { if let grid { apply(GridEdits.tempo(grid, grid.bpm / 2)) } }.frame(width: unit)
                key("×2", "double", none) { if let grid { apply(GridEdits.tempo(grid, grid.bpm * 2)) } }.frame(width: unit)
            }
        }
        .frame(height: 86)
    }

    private func key(_ title: String, _ caption: String, _ disabled: Bool, action: @escaping () -> Void) -> some View {
        ActionKey(disabled: disabled, caption: caption, action: action) { keyTitle(title, size: 18, tracking: 1.08) }
    }

    private func keyTitle(_ title: String, size: CGFloat, tracking: CGFloat) -> some View {
        Label(title, .cond(size, tracking: tracking)).frame(height: size * 1.1)
    }

    private func alternatesRow(_ grid: ConsoleState.Grid, track: ConsoleState.Library.Track) -> some View {
        HStack(spacing: 6) {
            Label(track.gridUncertain ? "NOT SURE OF THIS TEMPO · IT MAY BE" : "OTHER READINGS", .cond(12, tracking: 0.96))
                .foregroundStyle(track.gridUncertain ? Color(hex: 0xFFB455) : Palette.silk).frame(height: 15.6)
            Spacer(minLength: 0)
            ForEach(track.alternates, id: \.bpm) { alternate in
                ActionKey(minHeight: 52, border: track.gridUncertain ? Color(hex: 0x8A5A1C) : Color(hex: 0x3A3A40), caption: "\(alternate.relation)×", action: {
                    let (next, list) = GridEdits.take(alternate, from: grid, alternates: track.alternates)
                    apply(next, alternates: list)
                }) { keyTitle(String(format: "%.2f", alternate.bpm), size: 20, tracking: 1.2) }
                    .frame(width: 88)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `.gnow`: the playhead in the grid sheet, a 1 pt line with a notch.
private struct GridPlayhead: View {
    var body: some View {
        let red = Color(hex: 0xFF4A3D)
        ZStack(alignment: .topLeading) {
            red.frame(width: 1).offset(x: 5)
            Path { path in
                path.move(to: .zero); path.addLine(to: CGPoint(x: 10, y: 0)); path.addLine(to: CGPoint(x: 5, y: 5)); path.closeSubpath()
            }
            .fill(red).frame(width: 10, height: 5)
        }
    }
}

/// `#gcanvas`: one column per half point, its lowest to its highest sample.
private struct GridWaveCanvas: View {
    let columns: [(Float, Float)]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, _ in
            let middle = height / 2, reach = middle - 6
            var path = Path()
            for (index, column) in columns.enumerated() {
                let top = middle - CGFloat(column.1) * reach
                path.addRect(CGRect(x: CGFloat(index) / 2, y: top, width: 0.5, height: max(0.5, CGFloat(column.1 - column.0) * reach)))
            }
            context.fill(path, with: .color(Color(hex: 0xDFE2E4)))
        }
    }
}

/// What the grid sheet read from the audio: three windows' worth, from `start`.
struct GridSamples {
    struct Key: Hashable { let span: Double; let page: Int; let width: CGFloat }
    let start: Double
    let perColumn: Double
    let values: [Float]

    func columns(from time: Double, count: Int) -> [(Float, Float)] {
        let first = Int(((time - start) / perColumn).rounded())
        return (first..<(first + count)).map { index in
            guard index >= 0, index * 2 + 1 < values.count else { return (0, 0) }
            return (values[index * 2], values[index * 2 + 1])
        }
    }
}

/// The grid sheet's window on the track: where it sits and how much it shows.
enum GridWindow {
    /// Seconds across, widest first.
    static let spans: [Double] = [8, 4, 2, 1, 0.5, 0.25]
    static let startingZoom = 2

    static func start(centred centre: Double, span: Double, duration: Double) -> Double {
        max(0, min(duration - span, centre - span / 2))
    }

    /// The grid line next after `time`, or before it for a negative direction; a line at `time` doesn't count.
    static func line(after time: Double, direction: Int, bpm: Double, offsetMs: Double) -> Double {
        let period = 60 / bpm, offset = offsetMs / 1000
        let beat = (time - offset) / period
        let next = direction > 0 ? (beat + 0.001).rounded(.down) + 1 : (beat - 0.001).rounded(.up) - 1
        return offset + next * period
    }

    /// The stored envelope, drawn evenly about the middle, until the audio has been read.
    static func envelopeColumns(_ data: WaveformData, start: Double, perColumn: Double, count: Int) -> [(Float, Float)] {
        var columns = [(Float, Float)](repeating: (0, 0), count: count)
        let level = data.level(secondsPerPixel: perColumn)
        let bin = level.secondsPerBin
        for index in 0..<count {
            let time = start + Double(index) * perColumn
            guard time >= 0, let value = level.sample(at: Int(time / bin)) else { continue }
            columns[index] = (-value.peak, value.peak)
        }
        return columns
    }

    /// The mockup's synthetic signal (`gridSignal`).
    static func demoColumns(bpm: Double, offsetMs: Double, start: Double, perColumn: Double, count: Int) -> [(Float, Float)] {
        func noise(_ ms: Double) -> Double {
            let x = sin((ms * 8).rounded(.down) * 12.9898) * 43758.5453
            return (x - x.rounded(.down)) * 2 - 1
        }
        func signal(_ ms: Double) -> Double {
            let period = 60_000 / bpm
            let beat = ((ms - offsetMs) / period).rounded(.down)
            let since = ms - (offsetMs + beat * period)
            let downbeat = (Int(beat) % 4 + 4) % 4 == 0
            let pitch = 58 + 190 * exp(-since / 14)
            let kick = (downbeat ? 1 : 0.84) * exp(-since / 95) * sin(2 * .pi * pitch * since / 1000)
            let off = since - period / 2
            let hat = off >= 0 ? 0.3 * exp(-off / 20) * noise(ms) : 0
            return kick + hat + 0.05 * noise(ms)
        }
        return (0..<count).map { column in
            var low = 0.0, high = 0.0
            for sample in 0..<6 {
                let value = signal((start + (Double(column) + Double(sample) / 6) * perColumn) * 1000)
                low = min(low, value); high = max(high, value)
            }
            return (Float(low), Float(high))
        }
    }
}
