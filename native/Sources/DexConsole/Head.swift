import SwiftUI

/// The header bar: wordmark, library progress, SYNC/MASTER chips, waveform
/// mode, VOLUME, sample rate, cue output, TAP and shortcuts. Ports `Head` in
/// `src/renderer/console/Band.tsx` and the `.head` rules in `console.css`.
struct Head: View {
    let state: ConsoleState
    let actions: ConsoleActions

    var body: some View {
        HStack(spacing: 8) {
            Brand()
            Spacer(minLength: 0)
            if let status = state.status { StatusPill(status: status) }
            chips
            HeadButton(title: "3BAND", on: !state.energyEnabled) { if state.energyEnabled { actions.setEnergy(false) } }
            HeadButton(title: "ENERGY", on: state.energyEnabled, swatch: true) { actions.setEnergy(!state.energyEnabled) }
            VolumeButton(on: state.volumeOpen, action: actions.toggleVolume)
            Chip(text: String(format: "%.1f kHz", state.sampleRate / 1000))
            HeadButton(title: state.splitCue ? "SPLIT CUE" : "4-CH CUE", on: !state.splitCue, action: actions.toggleSplitCue)
            HeadButton(title: "TAP", on: state.sheet == .tap) { actions.setSheet(state.sheet == .tap ? nil : .tap) }
            ShortcutsKey { actions.setSheet(state.sheet == .shortcuts ? nil : .shortcuts) }
        }
        .padding(.horizontal, 10)
        .frame(width: Stage.width, height: 31)
        .overlay(alignment: .bottom) { Color.black.frame(height: 1).offset(y: 1) }
        .frame(height: 32, alignment: .top)
    }

    private var chips: some View {
        HStack(spacing: 5) {
            if state.saveState == .saving { Chip(text: "SAVING") }
            if state.saveState == .error {
                Button(action: actions.retrySave) { Chip(text: "NOT SAVED · RETRY") }.buttonStyle(.plain)
            }
            ForEach(state.decks.filter(\.syncLocked), id: \.id) { deck in Chip(text: "SYNC \(deck.id)", tone: .live) }
            if state.decks.contains(where: \.loaded), state.decks.indices.contains(state.masterDeck) {
                Chip(text: "MASTER \(state.decks[state.masterDeck].id)", tone: .master)
            }
        }
    }
}

private struct Brand: View {
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xE07000)).frame(width: 13, height: 13)
            Label("DEX", .cond(20, tracking: 4.4)).foregroundStyle(Palette.text).frame(height: 20)
        }
        .padding(.leading, 2)
    }
}

/// `.chip`, at the header's 3 × 6 padding.
struct Chip: View {
    enum Tone { case plain, live, master }
    let text: String
    var tone: Tone = .plain

    var body: some View {
        HStack(spacing: 5) {
            if tone != .plain { Circle().fill(tone == .live ? Palette.green : Palette.led).frame(width: 5, height: 5) }
            Label(text.uppercased(), .cond(12, tracking: 0.96)).frame(height: 12)
        }
        .foregroundStyle(colors.text)
        .padding(.vertical, 4).padding(.horizontal, 7) // CSS 3 × 6 inside a 1 pt border
        .box(fill: colors.fill, border: colors.border, radius: 2)
    }

    private var colors: (text: Color, fill: Color, border: Color) {
        switch tone {
        case .plain: (Palette.silk, Color(hex: 0x101012), Color(hex: 0x2C2C30))
        case .live: (Color(hex: 0x7EE0A2), Color(hex: 0x0F1611), Color(hex: 0x22402D))
        case .master: (Color(hex: 0xFFB25E), Color(hex: 0x171008), Color(hex: 0x4A3418))
        }
    }
}

/// `.btn.head-btn`: 24 pt tall, 9 pt sides, 13 pt type tracked 0.14 em.
private struct HeadButton: View {
    let title: String
    let on: Bool
    var swatch = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if swatch {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(hex: 0x457CE6), Color(hex: 0x2BCCD0), Color(hex: 0xF1C448), Color(hex: 0xFF5746)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 28, height: 5).opacity(on ? 1 : 0.45)
                }
                Label(title, .cond(13, tracking: 1.82))
            }
            .foregroundStyle(on ? Color(hex: 0xFFAB40) : Color(hex: 0xE9E9EC))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .box(fill: on ? Color(hex: 0xE07000) : Color(hex: 0x17171A),
                 border: on ? mix(0xFF8A00, 0.58, 0x26262B) : Color(hex: 0x3B3B41), radius: 3)
        }
        .buttonStyle(.plain)
    }
}

/// `.btn.vol-btn`: 88 pt minimum, 12 pt sides, tracked 0.16 em.
private struct VolumeButton: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("VOLUME", .cond(13, tracking: 2.08))
                .foregroundStyle(on ? Color(hex: 0xFFAB40) : Color(hex: 0xE9E9EC))
                .padding(.horizontal, 13)
                .frame(minWidth: 88, minHeight: 24, maxHeight: 24)
                .box(fill: on ? mix(0xFF8A00, 0.15, 0x151517) : Color(hex: 0x17171A),
                     border: on ? mix(0xFF8A00, 0.58, 0x26262B) : Color(hex: 0x3B3B41), radius: 3)
        }
        .buttonStyle(.plain)
    }
}

/// `.head .mini`: the 26 × 24 shortcuts key.
private struct ShortcutsKey: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("?", .cond(16, weight: .regular)).foregroundStyle(Color(hex: 0xCDCDD3))
                .frame(width: 26, height: 24)
                .box(fill: Color(hex: 0x151517), border: Color.white.opacity(0.13), radius: 3)
        }
        .buttonStyle(.plain)
    }
}

/// `.head-status`: a spinner, "ANALYSING 3 / 12", the track and a progress hairline.
private struct StatusPill: View {
    let status: ConsoleState.LibraryStatus

    private var count: String? {
        guard let current = status.current, let total = status.total, total > 0 else { return nil }
        return " \(current) / \(total)"
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().inset(by: 1).stroke(Palette.led.opacity(0.25), lineWidth: 2)
                Circle().inset(by: 1).trim(from: 0.625, to: 0.875).stroke(Palette.led, lineWidth: 2)
            }
            .frame(width: 9, height: 9)
            Label(status.label + (count ?? ""), .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk)
                .frame(height: 12)
            if let name = status.name {
                Text(name).font(Type.ui(14, weight: .medium)).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.tail).frame(height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: 330, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .bottomLeading) {
            if let current = status.current, let total = status.total, total > 0 {
                GeometryReader { geometry in
                    Palette.led.frame(width: (geometry.size.width - 2) * CGFloat(current) / CGFloat(total), height: 2)
                        .offset(x: 1, y: geometry.size.height - 3)
                }
            }
        }
        .box(fill: Color(hex: 0x101012), border: Color(hex: 0x2C2C30), radius: 2)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
