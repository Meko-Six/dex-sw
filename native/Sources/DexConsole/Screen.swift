import SwiftUI
import UniformTypeIdentifiers

/// The screen under the header: a GRID key per deck, the two zoom lanes
/// under one fixed playhead, and the zoom stack. Ports `Screen`, `Lane`,
/// `LaneLoop` and `LaneGrid` in `src/renderer/console/Band.tsx` and the
/// `.screen` rules in `console.css`. `stretch` is the elastic height.
struct Screen: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let stretch: CGFloat
    @Environment(\.consoleSnapshot) private var snapshot

    /// Inner box of `.screen-zoom` (1 pt border, 3 pt padding) and each lane.
    private var laneHeight: CGFloat { (156 + stretch - 2 - 6 - 4) / 2 }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                ForEach(state.decks, id: \.id) { deck in GridKey(deck: deck) { actions.openGrid(deck.id) } }
            }
            .padding(.vertical, 4)
            .frame(width: 44, height: 156 + stretch)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 4) {
                    ForEach(state.decks, id: \.id) { deck in
                        Lane(deck: deck, spanSec: state.laneSpan(of: deck), dropping: state.drop?.deck == deck.id && !deck.playing, actions: actions)
                            .frame(width: 1050, height: laneHeight)
                            .live(snapshot) { lane in
                                lane.onDrop(of: [.audio, .plainText], delegate: DeckDrop(
                                    deck: deck, row: state.library.track(state.library.selected)?.name, actions: actions))
                            }
                    }
                }
                .padding(4)
                // left 50% of the 1056 pt padding box, less translateX(-1px).
                Playhead(height: 154 + stretch).offset(x: 1 + 528 - 1, y: 1)
            }
            .frame(width: 1058, height: 156 + stretch, alignment: .topLeading)
            .box(fill: Color(hex: 0x030304), border: Color(hex: 0x26262A), radius: 3)
            ZoomStack(spanSec: state.spanSec, setSpan: actions.setSpan).frame(width: 44, height: 156 + stretch)
        }
        .padding(.top, 6).padding(.horizontal, 8)
        .frame(width: Stage.width, height: 162 + stretch, alignment: .top)
        .background(Color(hex: 0x060607))
    }
}

/// `.gridkey`: "GRID" over the deck letter.
private struct GridKey: View {
    let deck: ConsoleState.Deck
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                // text-indent .16em pushes the word right of centre.
                Label("GRID", .cond(12, tracking: 0.96)).padding(.leading, 1.92).frame(height: 12)
                DeckLetter(id: deck.id, size: 16, face: .cond(13, tracking: 0.26))
            }
            .foregroundStyle(Color(hex: 0xCDCDD3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .box(fill: Color(hex: 0x151517), border: Color.white.opacity(0.13), radius: 2)
        }
        .buttonStyle(.plain)
    }
}

/// `.letter`: the deck's letter on its accent colour.
struct DeckLetter: View {
    let id: String
    let size: CGFloat
    let face: Face

    var body: some View {
        Label(id, face)
            .foregroundStyle(id == "B" ? Color(hex: 0x1C1000) : Color.black)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 2).fill(Palette.accent(id)))
    }
}

/// `.zw-head`: the white playhead through both lanes. Its notch is a 10 pt
/// border triangle starting 4 pt left of the 2 pt line.
private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        Color.white.frame(width: 2, height: height)
            .overlay(alignment: .topLeading) {
                Path { path in
                    path.move(to: .zero); path.addLine(to: CGPoint(x: 10, y: 0)); path.addLine(to: CGPoint(x: 5, y: 5))
                    path.closeSubpath()
                }
                .fill(Color.white).frame(width: 10, height: 5).offset(x: -4)
            }
    }
}

/// `.zoom-stack`: zoom in, the zoom readout, zoom out.
private struct ZoomStack: View {
    let spanSec: Double
    let setSpan: (Double) -> Void

    var body: some View {
        let zoom = 48 / spanSec
        VStack(spacing: 4) {
            key("+") { setSpan(spanSec / 2) }
            Label("×" + (zoom >= 1 ? String(Int(zoom.rounded())) : String(format: "%.1f", zoom)), .cond(12, tracking: 0.96))
                .foregroundStyle(Color(hex: 0xB9B9BF))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .box(fill: Color(hex: 0x0A0A0B), border: Color(hex: 0x232327), radius: 2)
            key("−") { setSpan(spanSec * 2) }
        }
    }

    private func key(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(symbol, .cond(17)).foregroundStyle(Color(hex: 0xB9B9BF))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .box(fill: Color(hex: 0x151517), border: Color.white.opacity(0.13), radius: 2)
        }
        .buttonStyle(.plain)
    }
}

/// `.zw`: one zoom lane. The playhead sits mid-lane and the track scrolls
/// under it; drag to scrub, double-tap for the default zoom.
private struct Lane: View {
    let deck: ConsoleState.Deck
    let spanSec: Double
    /// A file or library row is held over this deck.
    let dropping: Bool
    let actions: ConsoleActions
    @Environment(\.displayScale) private var scale
    @GestureState private var touching = false
    @State private var scrubbing = false
    @State private var lastTap = -1.0

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: geometry.size.width - 2, height: geometry.size.height - 2)
            LaneFrame(deck: deck) { position, moving in
            let start = position - spanSec / 2
            ZStack(alignment: .topLeading) {
                if deck.loaded, let wave = deck.wave { LaneWave(wave: wave, start: start, span: spanSec, size: size, moving: moving) }
                if deck.loaded, let grid = deck.grid, let loop = deck.loop {
                    LaneLoop(grid: grid, loop: loop, start: start, span: spanSec, size: size, moving: moving)
                }
                if deck.loaded, let grid = deck.grid {
                    LaneGrid(grid: grid, start: start, span: spanSec, duration: deck.durationSec, size: size, moving: moving)
                }
                laneLabel.offset(x: 4, y: 3)
                if !deck.loaded && !deck.loading {
                    // `.zw-empty`: in the lane's first half, clear of the shared playhead.
                    Label("NO TRACK", .cond(10, tracking: 2.2)).padding(.leading, 2.2).foregroundStyle(Color(hex: 0x4A4A50))
                        .frame(width: size.width / 2, height: size.height)
                }
                if deck.loaded {
                    let cue = (deck.cuePoint - start) / spanSec * 100
                    if cue >= -2, cue <= 102 { CueMarker().offset(x: lanePlace(cue / 100 * size.width, scale, moving)) }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            }
            .offset(x: 1, y: 1)
        }
        .box(fill: Color(hex: 0x08090A), border: Color(hex: 0x1E1E22), radius: 2)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay {
            // `.zw.drop`: a 2 pt dashed outline inside the lane.
            if dropping {
                Rectangle().inset(by: 1).stroke(Palette.accent(deck.id), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { gesture in
                guard deck.loaded else { return }
                if !scrubbing {
                    guard abs(gesture.translation.width) >= 3 || actions.deck.coasting(deck.id) else { return }
                    scrubbing = true
                    actions.deck.scrub(deck.id, .begin)
                }
                actions.deck.scrub(deck.id, .move(-gesture.translation.width / 1050 * spanSec))
            }
            .onEnded { _ in
                if scrubbing {
                    scrubbing = false
                    actions.deck.scrub(deck.id, .fling(span: spanSec))
                    return
                }
                let time = ProcessInfo.processInfo.systemUptime
                if time - lastTap < 0.32 { actions.setSpan(12); lastTap = -1 } else { lastTap = time }
            })
        .onRelease(touching) {
            guard scrubbing else { return }
            scrubbing = false
            actions.deck.scrub(deck.id, .cancel)
        }
    }

    /// "DECK A · 133.0 BPM · PLAYING", the letter in the deck's colour.
    private var laneLabel: some View {
        let face = Face.cond(12, tracking: 0.96)
        let bpm = deck.grid.map { String(format: "%.1f", $0.bpm) } ?? "—"
        return HStack(spacing: 0) {
            Label("DECK ", face)
            Label(deck.id, face).foregroundStyle(Palette.accent(deck.id))
            Label(" · \(bpm) BPM · \(deck.stateWord)", face)
        }
        .foregroundStyle(Color(hex: 0xCFCFD4))
        .frame(height: 12)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.62)))
    }
}

/// A lane's position for what it draws, every display frame while the deck plays and
/// otherwise whenever something moves the deck. Only this redraws; the lane's gestures
/// and state sit outside it.
private struct LaneFrame<Content: View>: View {
    let deck: ConsoleState.Deck
    @ViewBuilder let content: (Double, Bool) -> Content
    @Environment(\.consoleClock) private var clock

    var body: some View {
        if let clock { Clocked(clock: clock.lane(deck.id), deck: deck, content: content) } else { content(deck.position, false) }
    }

    private struct Clocked: View {
        @ObservedObject var clock: LaneClock
        let deck: ConsoleState.Deck
        let content: (Double, Bool) -> Content

        var body: some View {
            if let moving = clock.moving { content(moving, true) } else { content(clock.position ?? deck.position, false) }
        }
    }
}

/// Where something on a lane goes. At rest it sits on a device pixel, as the mockup's
/// do; moving, everything shares the waveform's exact offset and so moves as one.
func lanePlace(_ x: CGFloat, _ scale: CGFloat, _ moving: Bool) -> CGFloat { moving ? x : snap(x, scale) }
func lanePlace(_ rect: CGRect, _ scale: CGFloat, _ moving: Bool) -> CGRect { moving ? rect : snap(rect, scale) }

/// The lane's waveform. The demo is `.zw-track`: twice the lane's width,
/// shifted left a quarter, standing still.
private struct LaneWave: View {
    let wave: ConsoleState.Wave
    let start, span: Double
    let size: CGSize
    let moving: Bool
    @Environment(\.consoleClock) private var clock
    @Environment(\.stageScale) private var stageScale

    var body: some View {
        switch wave {
        case .demo(let seed):
            let demo = DemoWave.cached(count: 1600, seed: seed, oneSided: false)
            Canvas { context, _ in
                demo.draw(in: context, rect: CGRect(x: -size.width / 2, y: 0, width: size.width * 2, height: size.height))
            }
            .frame(width: size.width, height: size.height)
        case .track(let data):
            TrackWave(data: data, start: start, span: span, moving: moving, tiled: clock != nil, density: stageScale).frame(width: size.width, height: size.height)
        }
    }
}

/// `.zw-loop`: the loop's audio, clipped to the window, with its length.
private struct LaneLoop: View {
    let grid: ConsoleState.Grid
    let loop: ConsoleState.Loop
    let start, span: Double
    let size: CGSize
    let moving: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        let loopStart = grid.time(atBeat: loop.startBeat), loopEnd = loopStart + loop.lengthBeats * grid.period
        let left = max(start, loopStart), right = min(start + span, loopEnd)
        if right > left {
            let box = lanePlace(CGRect(x: (left - start) / span * size.width, y: 0,
                                   width: (right - left) / span * size.width, height: size.height), scale, moving)
            let x = box.minX, width = box.width
            let edgeStart = loopStart >= start, edgeEnd = loopEnd <= start + span
            let gold = Color(hex: 0xFFD328)
            ZStack(alignment: .bottomLeading) {
                Color(.sRGB, red: 1, green: 211 / 255, blue: 40 / 255, opacity: 0.28)
                VStack(spacing: 0) { gold.frame(height: 1); Spacer(minLength: 0); gold.frame(height: 1) }
                HStack(spacing: 0) {
                    if edgeStart { gold.frame(width: 2) }
                    Spacer(minLength: 0)
                    if edgeEnd { gold.frame(width: 2) }
                }
                Label("LOOP · \(Int(loop.lengthBeats)) \(loop.lengthBeats == 1 ? "BEAT" : "BEATS")", .cond(12, tracking: 0.72))
                    .foregroundStyle(Color(hex: 0xFFE37C))
                    .frame(height: 12)
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.78)))
                    .fixedSize()
                    .offset(x: (edgeStart ? 2 : 0) + 4, y: -3)
            }
            .frame(width: width, height: size.height)
            .offset(x: x)
        }
    }
}

/// `.zw-grid`: a tick top and bottom on every beat, longer and red on bars.
private struct LaneGrid: View {
    let grid: ConsoleState.Grid
    let start, span, duration: Double
    let size: CGSize
    let moving: Bool

    var body: some View {
        Canvas { context, _ in
            let offset = grid.offsetMs / 1000, period = grid.period
            let first = Int(((max(0, start) - offset) / period).rounded(.up))
            let last = Int(((min(duration, start + span) - offset) / period).rounded(.down))
            guard first <= last else { return }
            for beat in first...last {
                // The CSS rounds `left` to 3 decimals of a percent.
                let exact = (offset + Double(beat) * period - start) / span * 100
                let percent = moving ? exact : (exact * 1000).rounded() / 1000
                let bar = ((beat % 4) + 4) % 4 == 0
                let width: CGFloat = bar ? 2 : 1, tick: CGFloat = bar ? 12 : 7
                let x = percent / 100 * size.width - width / 2
                let colour: Color = bar ? Palette.red : .white.opacity(0.8)
                let scale = context.environment.displayScale
                context.fill(Path(lanePlace(CGRect(x: x, y: 0, width: width, height: tick), scale, moving)), with: .color(colour))
                context.fill(Path(lanePlace(CGRect(x: x, y: size.height - tick, width: width, height: tick), scale, moving)), with: .color(colour))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// `.zw-cue`: the red CUE line with its label.
private struct CueMarker: View {
    var body: some View {
        Palette.red.frame(width: 2)
            .overlay(alignment: .topLeading) {
                // ui-monospace: SF Mono in Chromium on Apple platforms.
                Text("CUE").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Palette.red)
                    .fixedSize().frame(height: 12).offset(x: 3, y: 2)
            }
            .frame(maxHeight: .infinity)
    }
}
