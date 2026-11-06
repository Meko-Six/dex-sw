import SwiftUI

/// The popovers anchored on the console: VOLUME under the header, TRIM and
/// the band sheet over the mixer, the hot cue bank over a platter, and the
/// alert line. Ports `VolumePop` in `Sheets.tsx`, `TrimPop`, `BandPop` and
/// `HotCuePop` in `Chassis.tsx`, `Alert` in `Band.tsx` and their CSS.

/// `.mixpop` / `.volpop`: the popover box.
struct PopBox<Content: View>: View {
    var padding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .box(fill: Color(hex: 0x111113), border: Color(hex: 0x3A3A40), radius: 4)
            .compositingGroup()
            .shadow(color: .black.opacity(0.8), radius: 30, y: 24)
    }
}

/// `.mixpop h4` / `.volpop h3`: the title, then (i) and DONE at the right.
struct PopHead: View {
    let title: String
    var help: ConsoleState.HelpTopic?
    /// `.mixpop h4` spaces its keys 8 pt; `.volpop h3` sets them edge to edge.
    var spacing: CGFloat = 8
    let actions: ConsoleActions
    let done: () -> Void

    var body: some View {
        HStack(spacing: spacing) {
            Label(title.uppercased(), .cond(16, tracking: 2.88)).foregroundStyle(Palette.text).frame(height: 16)
            Spacer(minLength: 0)
            if let help { InfoKey(size: 40) { actions.setHelp(help) } }
            // `.btn.info + .btn`: a gap of its own beside the (i) key.
            SheetButton(title: "Done", style: .done, action: done).padding(.leading, help == nil ? 0 : 8)
        }
        .frame(height: 40)
    }
}

// MARK: - Volume

/// Master, and the headphone blend from the cued deck to the master.
struct VolumePop: View {
    let state: ConsoleState
    let actions: ConsoleActions

    var body: some View {
        PopBox(padding: EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14)) {
            PopHead(title: "Volume", help: .volume, spacing: 0, actions: actions) { actions.toggleVolume() }
            row("master", state.masterVolume / 1.2, percent: state.masterVolume, key: "master") { actions.setMasterVolume($0 * 1.2) }
            row("cue mix", state.cueMix, percent: state.cueMix, key: "cuemix", set: actions.setCueMix)
        }
        .frame(width: 360, height: 180)
    }

    /// `.vrow`: 70 pt label, the fader, a 48 pt value.
    private func row(_ name: String, _ value: Double, percent: Double, key: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Label(name.uppercased(), .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(width: 70, alignment: .leading)
            GeometryReader { geometry in
                // The volume caps overhang the ends, so the whole width is travel.
                WideFader(position: (value * 100).rounded() / 100)
                    .relativeDrag(key, horizontal: true, travel: geometry.size.width, value: value, reset: 1, set: set)
            }
            .frame(height: 46)
            Label("\(Int((percent * 100).rounded()))%", .cond(14, tracking: 0.56))
                .foregroundStyle(Color(hex: 0xA0A0A6)).frame(width: 48, alignment: .trailing)
        }
    }
}

/// `.fader-h`: the volume fader, its 58 × 36 cap centred on the position.
private struct WideFader: View {
    let position: Double
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.black).frame(width: size.width - 16, height: 8).offset(x: 8, y: size.height / 2 - 4)
                Color.white.opacity(0.18).frame(width: 1, height: size.height - 16).offset(x: snap(size.width / 2, scale), y: 8)
                Cap(width: 58, height: 36, line: Color(hex: 0xE9E9EE), vertical: true)
                    .offset(x: snap(CGFloat(position) * size.width - 29, scale), y: size.height / 2 - 18)
            }
        }
    }
}

// MARK: - Trim and band

/// TRIM: the deck's input gain, ±12 dB, set once when the track loads.
struct TrimPop: View {
    let deck: ConsoleState.Deck
    let actions: ConsoleActions

    var body: some View {
        let id = deck.id, value = (deck.trimDb + 12) / 24
        PopBox {
            PopHead(title: "Trim \(id)", help: .trim, actions: actions) { actions.setMixPop(nil) }
            HStack(spacing: 10) {
                GeometryReader { geometry in
                    HorizontalFader(position: value, thumbWidth: 40, label: nil)
                        .relativeDrag("\(id)-trim", horizontal: true, travel: geometry.size.width - 40, value: value, reset: 0.5) {
                            let db = (($0 * 24 - 12) * 10).rounded() / 10
                            actions.deck.setTrim(id, abs(db) < 0.25 ? 0 : db)
                        }
                }
                .frame(height: 44)
                Label(MixerMath.formatTrim(deck.trimDb) + " dB", .cond(16, tracking: 0.64))
                    .foregroundStyle(Color(hex: 0xB6B6BB)).frame(width: 58, alignment: .trailing)
                SheetButton(title: "Reset", height: 44) { actions.deck.setTrim(id, 0) }
            }
        }
        .frame(width: 300, height: 124)
    }
}

/// One band for both decks: a longer fader than the channel's, its kill,
/// and LINK LOWS under LOW.
struct BandPop: View {
    let band: String
    let state: ConsoleState
    let actions: ConsoleActions
    @EnvironmentObject private var touches: ControlTouches

    private var name: String { band == "high" ? "HI" : band.uppercased() }

    var body: some View {
        PopBox {
            PopHead(title: "\(name) · both decks", help: .band, actions: actions) { actions.setMixPop(nil) }
            ForEach(state.decks, id: \.id) { deck in row(deck) }
            if band == "low" {
                let colours: KeyColours = state.linkLows ? .lit(0xFF8A00) : .off
                Button(action: actions.toggleLinkLows) {
                    VStack(spacing: 4) {
                        Circle().fill(state.linkLows ? Palette.led : Color(hex: 0x43434A))
                            .overlay(Circle().inset(by: 0.5).stroke(Color.black.opacity(0.7), lineWidth: 1)).frame(width: 5, height: 5)
                        Label("LINK LOWS", .cond(12, tracking: 0.96)).padding(.leading, 1.68).foregroundStyle(colours.legend).frame(height: 13.8)
                    }
                    .frame(width: 120, height: 44)
                    .box(fill: colours.face, border: colours.border, radius: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 490, height: band == "low" ? 252 : 196)
    }

    private func row(_ deck: ConsoleState.Deck) -> some View {
        let id = deck.id, key = "\(id)-\(band)"
        let value = band == "high" ? deck.eq.high : band == "mid" ? deck.eq.mid : deck.eq.low
        let killed = band == "high" ? deck.kills.high : band == "mid" ? deck.kills.mid : deck.kills.low
        let speed = touches.speeds[key]
        return HStack(spacing: 10) {
            DeckLetter(id: id, size: 20, face: .cond(16, tracking: 0.32))
            GeometryReader { geometry in
                HorizontalFader(position: value, thumbWidth: 40, label: nil,
                                line: killed ? Color(hex: 0xFF6A52) : Palette.accent(id),
                                capBorder: killed ? Color(.sRGB, red: 232 / 255, green: 64 / 255, blue: 47 / 255, opacity: 0.55) : nil,
                                centreMark: false)
                    .relativeDrag(key, horizontal: true, travel: geometry.size.width - 40, value: value, reset: 1) {
                        actions.deck.setFader(id, band, $0)
                    }
            }
            .frame(height: 52)
            Label(killed ? "KILL" : ((speed ?? 1) < 1 ? "· " : "") + MixerMath.formatDb(MixerMath.faderDb(value)), .cond(16, tracking: 0.64))
                .foregroundStyle(killed ? Color(hex: 0xFF6A52) : Color(hex: 0xB6B6BB)).frame(width: 58, alignment: .trailing)
            KillPad(deck: id, band: band, on: killed, set: actions.deck.setKill).frame(width: 52, height: 52)
        }
    }
}

// MARK: - Hot cues

/// Hot cues: a 4 × 2 bank over the platter, opened by HOT CUE. An empty pad
/// captures the playhead, a set pad jumps; DELETE turns set pads into
/// erasers until it is pressed again or nothing is left.
struct HotCuePop: View {
    let deck: ConsoleState.Deck
    let actions: DeckActions

    var body: some View {
        let id = deck.id, deleting = deck.hotCueDeleting
        let anySet = deck.hotCues.contains { $0 != nil }
        PopBox {
            HStack(spacing: 8) {
                Label("HOT CUES \(id)", .cond(16, tracking: 2.88)).foregroundStyle(Palette.text).frame(height: 16)
                // DELETE and DONE both take margin-left: auto, so they split the free space.
                Spacer(minLength: 0)
                Button { actions.setHotCueDelete(id, !deleting) } label: {
                    Label(deleting ? "KEEP" : "DELETE", .cond(12, tracking: 0.96))
                        .foregroundStyle(deleting ? Color(hex: 0xFF8A7A) : Color(hex: 0xA9A9B0))
                        .padding(.horizontal, 10).frame(minWidth: 50).frame(height: 30)
                        .box(fill: deleting ? mix(0xE8402F, 0.12, 0x151517) : Color(hex: 0x151517),
                             border: deleting ? Color(.sRGB, red: 232 / 255, green: 64 / 255, blue: 47 / 255, opacity: 0.7) : .white.opacity(0.13), radius: 2)
                }
                .buttonStyle(.plain).disabled(!anySet).opacity(anySet ? 1 : 0.35)
                Spacer(minLength: 0)
                SheetButton(title: "Done", style: .done) { actions.toggleHotCues(id) }
            }
            .frame(height: 40)
            Grid(horizontalSpacing: 5, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { column in pad(row * 4 + column) }
                    }
                }
            }
        }
        .frame(width: 300, height: 236)
    }

    /// `.hc`: the slot over its time, or "set".
    private func pad(_ slot: Int) -> some View {
        let seconds = deck.hotCues[slot], set = seconds != nil
        let disabled = !set && deck.hotCueDeleting
        let blue = Palette.blueHex
        return Button { actions.hotCue(deck.id, slot) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Label(String(slot + 1), .cond(16)).frame(height: 16)
                Spacer(minLength: 0)
                Label(seconds.map(cueTime) ?? "set", .ui(12, bold: true)).opacity(0.8).frame(height: 12)
            }
            .foregroundStyle(set ? Color.black : mix(blue, 0.70, 0x6F6F76))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .box(fill: set ? Color(hex: blue) : Color(hex: 0x101012), border: set ? .clear : mix(blue, 0.55, 0x151517), radius: 3)
            .overlay {
                if set && deck.hotCueDeleting {
                    RoundedRectangle(cornerRadius: 1).inset(by: 5)
                        .stroke(Color(.sRGB, red: 10 / 255, green: 7 / 255, blue: 22 / 255, opacity: 0.55),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// `cueTime` in format.ts: "1:44.7".
func cueTime(_ seconds: Double) -> String {
    let tenths = max(0, Int((seconds * 10).rounded(.down)))
    let whole = tenths / 10
    return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths % 10)
}

// MARK: - Alert

/// `.alert`: a failure on one line under the header, red like a lit KILL.
struct AlertBar: View {
    let alert: ConsoleState.Alert
    let dismiss: () -> Void

    var body: some View {
        let title = Face.cond(14, tracking: 1.12)
        // max-width 780 less the padding, the title, the gaps and ✕.
        let room = 780 - 2 - 13 - 7 - title.width(of: alert.title.uppercased()) - 10 - (alert.dismissable ? 46 : 0)
        HStack(spacing: 10) {
            Label(alert.title.uppercased(), title).foregroundStyle(Color(hex: 0xFF8A7A)).frame(height: 14)
            let natural = LineBreaker(runs: [Para.Run(alert.message, .ui(16))]).natural
            Para(alert.message, .ui(16), lineHeight: 1.3).foregroundStyle(Palette.text).frame(width: min(natural, room), alignment: .leading)
            if alert.dismissable {
                Button(action: dismiss) {
                    Label("✕", .cond(18, weight: .regular)).foregroundStyle(Color(hex: 0xCDCDD3))
                        .frame(width: 36, height: 34)
                        .box(fill: Color(hex: 0x151517), border: .white.opacity(0.13), radius: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(EdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 7))
        .frame(minHeight: 40)
        .box(fill: mix(0xE8402F, 0.18, 0x151517), border: mix(0xE8402F, 0.62, 0x26262B), radius: 3)
        .compositingGroup()
        .shadow(color: .black.opacity(0.6), radius: 20, y: 16)
    }
}

// MARK: - Drop

/// `.zdrop`: a file or library row held over a deck. A playing deck refuses,
/// amber and solid, and says why.
struct DropCover: View {
    let deck: ConsoleState.Deck
    let label: String

    var body: some View {
        let blocked = deck.playing
        let accent: UInt32 = blocked ? 0xFFB45E : deck.id == "B" ? 0xFF8A1F : Palette.blueHex
        VStack(spacing: 7) {
            Label(blocked ? "DECK \(deck.id) IS PLAYING" : "DROP TO LOAD ON \(deck.id)", .cond(16, tracking: 3.52))
                .padding(.leading, 3.52).foregroundStyle(mix(accent, 0.76, 0xFFFFFF)).frame(height: 16)
            Para(blocked ? "Pause it to load here, or drop on deck \(deck.id == "A" ? "B" : "A")" : label, .ui(11), lineHeight: 1.3)
                .foregroundStyle(Color(hex: 0xA0A0A6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 3).fill(mixOver(accent)))
        .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 1)
            .stroke(Color(hex: accent), style: StrokeStyle(lineWidth: 2, dash: blocked ? [] : [6, 4])))
        .allowsHitTesting(false)
    }

    /// `color-mix(in srgb, accent 12%, rgba(5, 5, 6, .96))`.
    private func mixOver(_ accent: UInt32) -> Color {
        let alpha = 0.12 + 0.88 * 0.96
        func channel(_ shift: UInt32, _ base: Double) -> Double {
            (Double(accent >> shift & 0xFF) / 255 * 0.12 + base / 255 * 0.96 * 0.88) / alpha
        }
        return Color(.sRGB, red: channel(16, 5), green: channel(8, 5), blue: channel(0, 6), opacity: alpha)
    }
}
