import SwiftUI
import DexCore

/// The chassis under the header band: deck A's bay, the mixer, deck B's bay.
/// Every control sits at the mockup's drawing coordinates, as in
/// `src/renderer/console/Chassis.tsx` and `layout.ts`.
struct Chassis: View {
    let state: ConsoleState
    let actions: ConsoleActions

    var body: some View {
        let folded = state.libraryOpen
        ZStack(alignment: .topLeading) {
            Color(hex: 0x161618)
            Group {
                Seam().place(Layout.at(367, 48, 1, 475))
                Seam().place(Layout.at(827, 48, 1, 475))
            }
            .folded(folded)
            ForEach(state.decks, id: \.id) { deck in
                Bay(deck: deck, isMaster: state.decks.firstIndex(of: deck) == state.masterDeck, folded: folded, actions: actions.deck)
            }
            Mixer(state: state, actions: actions)
            Group {
                switch state.mixPop {
                case .trim(let id)?:
                    if let deck = state.decks.first(where: { $0.id == id }) {
                        TrimPop(deck: deck, actions: actions).offset(x: Layout.at(id == "A" ? 372 : 522, 110, 0, 0).minX, y: 110 - Layout.lift)
                    }
                case .band(let band)?:
                    BandPop(band: band, state: state, actions: actions).offset(x: 352 - 10, y: 62 - Layout.lift)
                case nil:
                    EmptyView()
                }
                ForEach(state.decks.filter(\.hotCuesOpen), id: \.id) { deck in
                    HotCuePop(deck: deck, actions: actions.deck).offset(x: Layout.deckX(deck.id).platter - 150 - 10, y: 132 - Layout.lift)
                }
            }
            .folded(folded)
        }
        .frame(width: Stage.width, height: 475, alignment: .topLeading)
        .clipped()
        .padding(.top, 1)
        .background(Color.black)
    }
}

/// The chassis coordinates: x across the 1194 pt drawing (its 10 pt bezel
/// included), y down from the chassis line raised by LIFT.
enum Layout {
    static let lift: CGFloat = 48
    static func at(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x - 10, y: y - lift, width: w, height: h)
    }
    /// SYNC · MASTER · KEY · HOT CUE run the full width of the deck, centred on
    /// the TRIM row and 40 pt tall on purpose, The tempo fader starts 23 pt under them,
    /// a finger's room, and its foot lines up with the mixer faders' foot (150 + 228),
    /// with its readout and then TEMPO below it.
    static let deckKey = (y: CGFloat(64), w: CGFloat(78), h: CGFloat(40), gap: CGFloat(6))
    static let tempoColumn = (y: CGFloat(127), h: CGFloat(251 + 34))
    static let platter = (y: CGFloat(114), size: CGFloat(262))
    static let rowY: CGFloat = 446
    static let key: CGFloat = 66
    static let jump = (y: CGFloat(384), h: CGFloat(44), key: CGFloat(44), gap: CGFloat(6), width: CGFloat(274))
    static func deckX(_ id: String) -> (keys: CGFloat, jump: CGFloat, tempo: CGFloat, platter: CGFloat, row: CGFloat) {
        id == "B" ? (842, 842, 1148, 979, 832) : (22, 78, 46, 215, 22)
    }
    /// One of the deck's four keys, by its place in the row.
    static func deckKeyRect(_ id: String, _ index: Int) -> CGRect {
        at(deckX(id).keys + CGFloat(index) * (deckKey.w + deckKey.gap), deckKey.y, deckKey.w, deckKey.h)
    }
    enum Column: String, CaseIterable { case level, high, mid, low }
    /// Deck B's columns mirror deck A's across the centre.
    static func column(_ deck: String, _ column: Column) -> (x: CGFloat, w: CGFloat) {
        let (x, w): (CGFloat, CGFloat) = switch column {
        case .level: (372, 44)
        case .high: (422, 44)
        case .mid: (472, 44)
        case .low: (522, 52)
        }
        return (deck == "A" ? x : 1194 - x - w, w)
    }
    static let row = (top: (CGFloat(62), CGFloat(44)), val: (CGFloat(110), CGFloat(36)), fader: (CGFloat(150), CGFloat(228)),
                      kill: (CGFloat(384), CGFloat(44)), xf: (CGFloat(455), CGFloat(48)))
}

extension View {
    /// `.lib-open .chassis > *`: hidden while the library is up.
    func folded(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }

    /// `.lib-open .chassis .keep`: CUE, PLAY, the loop and the crossfader ride
    /// up under the track windows while the library is up.
    func kept(_ raised: Bool) -> some View { offset(y: raised ? -392 : 0) }

    /// Absolute placement in the chassis, like `position: absolute` with `at()`.
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

/// The thin panel seams framing the mixer.
private struct Seam: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.055), location: 0.1),
                               .init(color: .white.opacity(0.055), location: 0.9), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A hardware key's colours: black face when off; LED-tinted face, border
/// and legend when on (`.chan-btn.on`, `.linkbtn.on`).
struct KeyColours {
    let face: Color, border: Color, legend: Color
    static func lit(_ hex: UInt32) -> KeyColours {
        KeyColours(face: mix(hex, 0.15, 0x151517), border: mix(hex, 0.60, 0x26262B), legend: mix(hex, 0.76, 0xFFFFFF))
    }
    /// A solid key with a black legend: active headphone CUE.
    static func solid(_ hex: UInt32) -> KeyColours { KeyColours(face: Color(hex: hex), border: .black, legend: .black) }
    static let off = KeyColours(face: Color(hex: 0x151517), border: .white.opacity(0.13), legend: Color(hex: 0xCDCDD3))
}

// MARK: - Deck bay

private struct Bay: View {
    let deck: ConsoleState.Deck
    let isMaster: Bool
    let folded: Bool
    let actions: DeckActions
    /// PLAY's press kept a CUE preview, so its release must not pause it.
    @State private var continuedOnPress = false

    var body: some View {
        let x = Layout.deckX(deck.id)
        let empty = !deck.loaded
        ZStack(alignment: .topLeading) {
            Group {
            DeckKey(label: "SYNC", colour: .sync, on: deck.syncLocked) { actions.toggleSync(deck.id) }
                .place(Layout.deckKeyRect(deck.id, 0))
            DeckKey(label: "MASTER", colour: .master, on: isMaster && !empty) { actions.setMaster(deck.id) }
                .disabled(empty).place(Layout.deckKeyRect(deck.id, 1))
            DeckKey(label: "KEY", colour: .blue, on: deck.keyLock) { actions.toggleKeyLock(deck.id) }
                .place(Layout.deckKeyRect(deck.id, 2))
            DeckKey(label: "HOT CUE", colour: .blue, on: deck.hotCuesOpen) { actions.toggleHotCues(deck.id) }
                .disabled(empty).place(Layout.deckKeyRect(deck.id, 3))
            TempoColumn(deck: deck.id, rate: deck.rate) { actions.setTempo(deck.id, $0) }
                .place(Layout.at(x.tempo - 24, Layout.tempoColumn.y, 48, Layout.tempoColumn.h))
            Live(deck: deck) { deck in Platter(deck: deck, scrub: actions.scrub) }
                .place(Layout.at(x.platter - Layout.platter.size / 2, Layout.platter.y, Layout.platter.size, Layout.platter.size))
            BeatJump(deck: deck, actions: actions)
            }
            .folded(folded)
            Group {
            BigKey(kind: .cue, lit: true)
                .press(enabled: !empty, down: { actions.cueDown(deck.id) }, moved: latchCue) { point in
                    if let point { latchCue(point) }
                    actions.cueUp(deck.id)
                }
                .opacity(empty ? 0.35 : 1)
                .accessibilityLabel("Deck \(deck.id) cue")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.cueDown(deck.id); actions.cueUp(deck.id) }
                .place(Layout.at(x.row, Layout.rowY, Layout.key, Layout.key))
            BigKey(kind: deck.playing && !deck.previewing ? .pause : .play, lit: deck.playing)
                .press(enabled: !empty, down: {
                    // A second finger can keep the preview while the first holds CUE.
                    continuedOnPress = actions.continueCue(deck.id)
                }) { point in
                    defer { continuedOnPress = false }
                    guard let point, !continuedOnPress, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
                    actions.togglePlay(deck.id)
                }
                .opacity(empty ? 0.35 : 1)
                .accessibilityLabel("Deck \(deck.id) \(deck.playing && !deck.previewing ? "pause" : "play")")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.togglePlay(deck.id) }
                .place(Layout.at(x.row + Layout.key + 8, Layout.rowY, Layout.key, Layout.key))
            LoopStepper(deck: deck, actions: actions)
                .place(Layout.at(x.row + 2 * Layout.key + 26, Layout.rowY + 7, 340 - 2 * Layout.key - 26, 52))
            }
            .kept(folded)
        }
    }

    /// Sliding off CUE onto PLAY keeps the preview playing. PLAY sits 8 pt
    /// right of CUE, the same size, so in CUE's units it spans 74 … 140 / 66.
    private func latchCue(_ point: CGPoint) {
        let left = (Layout.key + 8) / Layout.key
        if point.x >= left, point.x <= left + 1, (0...1).contains(point.y) { _ = actions.continueCue(deck.id) }
    }
}

/// A `.pill`'s colours: its outline and legend when off, and when on its
/// elliptical gradient. Stops are (distance, colour), with distance in units of
/// the key's half-size, sampled from the design, so the outer colour only
/// reaches the corners.
struct DeckKeyColour {
    let ink: UInt32
    let stops: [(CGFloat, UInt32)]

    static let sync = DeckKeyColour(ink: 0xF2F4F3, stops: [
        (0, 0xFFFFFF), (0.45, 0xFBFBFB), (0.65, 0xF3F3F3), (0.85, 0xE6E6E6), (0.95, 0xDDDDDD), (1.05, 0xD2D2D2), (1.10, 0xD1D1D1)
    ])
    static let master = DeckKeyColour(ink: 0xE18400, stops: [
        (0, 0xCD9C04), (0.45, 0xCF9808), (0.65, 0xD49210), (0.85, 0xDC8519), (0.95, 0xE27B1F), (1.05, 0xE87022), (1.15, 0xEE6126), (1.25, 0xF05A27)
    ])
    static let blue = DeckKeyColour(ink: Palette.blueHex, stops: [
        (0, 0x02ADEE), (0.45, 0x02AAEF), (0.65, 0x05A4F1), (0.85, 0x0D9AF4), (0.95, 0x1491F6), (1.05, 0x1A89F9), (1.15, 0x1F7FFC), (1.25, 0x2573FE), (1.35, 0x276FFF)
    ])

    /// CSS `radial-gradient(ellipse closest-side, …)`: EllipticalGradient's unit
    /// square puts the box's edge at a radius of 0.5.
    var gradient: EllipticalGradient {
        let end = stops.last!.0
        return EllipticalGradient(stops: stops.map { Gradient.Stop(color: Color(hex: $0.1), location: $0.0 / end) },
                                  center: .center, startRadiusFraction: 0, endRadiusFraction: end / 2)
    }
}

/// `.pill`: the deck's keys. Off, a dark face with outline and legend in the
/// key's colour; on, the gradient with a black outline and legend.
private struct DeckKey: View {
    let label: String
    let colour: DeckKeyColour
    let on: Bool
    let action: () -> Void
    @Environment(\.displayScale) private var scale
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        // 1.5 pt, down to whole device pixels as Chromium draws a CSS border.
        let line = floor(1.5 * scale) / scale
        Button(action: action) {
            Label(label, .cond(18, tracking: 0.36)).foregroundStyle(on ? Color.black : Color(hex: colour.ink))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    // Inset to the outline's centre, so none shows past its rounded corners.
                    let shape = RoundedRectangle(cornerRadius: 4).inset(by: line / 2)
                    if on { shape.fill(colour.gradient) } else { shape.fill(Color(hex: 0x151517)) }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).inset(by: line / 2).stroke(on ? Color.black : Color(hex: colour.ink), lineWidth: line))
        }
        .buttonStyle(Press())
        .opacity(enabled ? 1 : 0.35)
    }

    /// `.plain` dims a disabled key by its own amount; `.pill:disabled` is 35%.
    /// The touch area reaches 2 pt past the drawn key, for 44 pt of height.
    private struct Press: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.7 : 1).contentShape(Rectangle().inset(by: -2))
        }
    }
}

/// `.col`: the tempo fader over its readout over TEMPO.
private struct TempoColumn: View {
    let deck: String
    let rate: Double
    let set: (Double) -> Void

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                // The 34 pt cap is travel the drag cannot use.
                TempoFader(position: MixerMath.tempoToFader(rate))
                    .relativeDrag("\(deck)-tempo", travel: geometry.size.height - 2 - 34, value: MixerMath.tempoToFader(rate),
                                  reset: 0.5) { set(MixerMath.faderToTempo($0)) }
            }
            Label(MixerMath.tempoText(rate), .cond(12, tracking: 0.72)).foregroundStyle(Color(hex: 0xB6B6BB)).frame(height: 12)
            Label("TEMPO", .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(height: 12)
        }
    }
}

/// `.fader-v`: black track, guide lines every 24 pt, centre mark, black cap
/// with a white index line. `position` 0 is the foot.
private struct TempoFader: View {
    let position: Double
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let inner = CGSize(width: geometry.size.width - 2, height: geometry.size.height - 2)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // ::before / ::after: 1 pt lines every 24 pt, 3 pt in from each side.
                    var y: CGFloat = 12
                    while y < size.height - 12 {
                        for x in [3, size.width - 8] {
                            context.fill(Path(CGRect(x: x, y: y, width: 5, height: 1)), with: .color(.white.opacity(0.15)))
                        }
                        y += 24
                    }
                }
                RoundedRectangle(cornerRadius: 1).fill(Color.black)
                    .frame(width: 6, height: inner.height - 20).offset(x: inner.width / 2 - 3, y: 10)
                Color.white.opacity(0.18).frame(width: inner.width - 10, height: 1).offset(x: 5, y: snap(inner.height / 2, scale))
                Cap(width: 48, height: 34, line: Color(hex: 0xE9E9EE), vertical: false)
                    .offset(x: -1, y: snap(inner.height - CGFloat(position) * inner.height - 17, scale))
            }
            .frame(width: inner.width, height: inner.height, alignment: .topLeading)
            .offset(x: 1, y: 1)
        }
        .box(fill: Color(hex: 0x131315), border: Color(hex: 0x26262A), radius: 3)
    }
}

/// A fader cap: black with a 2 pt index line, horizontal or vertical.
struct Cap: View {
    let width, height: CGFloat
    let line: Color
    var vertical: Bool
    var border = Color(hex: 0x3E3E45)

    var body: some View {
        ZStack {
            if vertical { line.frame(width: 2, height: height - 12) } else { line.frame(width: width - 12, height: 2) }
        }
        .frame(width: width, height: height)
        .box(fill: Color(hex: 0x232327), border: border, radius: 2)
    }
}

/// `.platter` and `.platter-display`: the record, rings and the centre
/// screen whose two-mark gap follows the track position. Dragging round it
/// scrubs, two beats a turn; near the centre the angle means nothing.
private struct Platter: View {
    let deck: ConsoleState.Deck
    let scrub: (String, Scrub) -> Void
    @GestureState private var touching = false
    @State private var drag: Drag?

    private struct Drag {
        let start: CGPoint
        let position, period: Double
        var angle: Double?
        var beats = 0.0
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x111113))
            // Inset shadows from the edge: a 1 pt highlight over a 9 pt dark band, then a faint 1 pt ring.
            Circle().inset(by: 4.5).stroke(Color(hex: 0x0B0B0D), lineWidth: 9)
            Circle().inset(by: 9.5).stroke(Color.white.opacity(0.07), lineWidth: 1)
            Circle().inset(by: 0.5).stroke(Color.white.opacity(0.12), lineWidth: 1)
            // ::before: fine grooves, 1 pt every 4 pt, inside 23 pt.
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                var radius: CGFloat = 0.5
                while radius < size.width / 2 {
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(.white.opacity(0.035)), lineWidth: 1)
                    radius += 4
                }
            }
            .frame(width: 216, height: 216)
            PlatterDisplay(deck: deck)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged(turn)
            .onEnded { _ in
                if drag != nil { scrub(deck.id, .end) }
                drag = nil
            })
        .onRelease(touching) {
            if drag != nil { scrub(deck.id, .cancel) }
            drag = nil
        }
    }

    private func turn(_ gesture: DragGesture.Value) {
        let size = Layout.platter.size, centre = CGPoint(x: size / 2, y: size / 2)
        func angle(_ point: CGPoint) -> Double? {
            let dx = point.x - centre.x, dy = point.y - centre.y
            return hypot(dx, dy) < size * 0.08 ? nil : atan2(dy, dx)
        }
        guard deck.loaded, deck.durationSec > 0 else { return }
        guard var d = drag, d.start == gesture.startLocation else {
            drag = Drag(start: gesture.startLocation, position: deck.position, period: 60 / (deck.grid?.bpm ?? 120),
                        angle: angle(gesture.startLocation))
            scrub(deck.id, .begin)
            return
        }
        let next = angle(gesture.location)
        if let from = d.angle, let next { d.beats += platterBeatDelta(from, next) }
        d.angle = next
        let target = min(deck.durationSec, max(0, d.position + d.beats * d.period))
        d.beats = (target - d.position) / d.period
        drag = d
        scrub(deck.id, .move(target - d.position))
    }
}

/// Beats turned between two angles, by the shorter way round (`shared/platter.ts`).
func platterBeatDelta(_ from: Double, _ to: Double) -> Double {
    var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    return delta * 2 / (2 * .pi)
}

private struct PlatterDisplay: View {
    let deck: ConsoleState.Deck

    var body: some View {
        let beat = 60 / (deck.grid?.bpm ?? 120)
        let angle = ((deck.position / beat * 360 / 2).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let gap = (angle / 9).rounded(.down) * 9
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            context.stroke(Path(ellipseIn: CGRect(x: 2, y: 2, width: 96, height: 96)), with: .color(Color(hex: 0x191C21)), lineWidth: 1)
            for index in 0..<40 where !Self.inGap(tick: index, gap: gap) {
                var marks = Path()
                for (from, to) in [(7.0, 11.0), (13.0, 16.0), (18.0, 21.0)] {
                    marks.move(to: CGPoint(x: 50, y: from)); marks.addLine(to: CGPoint(x: 50, y: to))
                }
                let turn = CGAffineTransform(translationX: 50, y: 50).rotated(by: Double(index) * 9 * .pi / 180).translatedBy(x: -50, y: -50)
                context.stroke(marks.applying(turn), with: .color(Color(hex: 0xE4E8ED)), lineWidth: 2.4)
            }
            context.stroke(Path(ellipseIn: CGRect(x: 26, y: 26, width: 48, height: 48)), with: .color(Palette.accent(deck.id)), lineWidth: 1.8)
            // The SVG circle's dashes start at 3 o'clock and run clockwise; the
            // ring is turned −45°. Four 25-unit dashes, 4.845 gaps, radius 19.
            var dashes = Path()
            for dash in 0..<4 {
                let start: Double = -45 + Double(dash) * 90, sweep: Double = 25.0 / 19.0 * 180.0 / Double.pi
                for step in 0...32 {
                    let angle = (start + sweep * Double(step) / 32) * .pi / 180
                    let point = CGPoint(x: 50 + 19 * cos(angle), y: 50 + 19 * sin(angle))
                    if step == 0 { dashes.move(to: point) } else { dashes.addLine(to: point) }
                }
            }
            context.stroke(dashes, with: .color(Color(hex: 0x9DA4AD)), style: StrokeStyle(lineWidth: 1.8, lineCap: .butt))
            context.fill(Path(ellipseIn: CGRect(x: 35, y: 35, width: 30, height: 30)), with: .color(Color(hex: 0x0B0C0F)))
            context.stroke(Path(ellipseIn: CGRect(x: 35, y: 35, width: 30, height: 30)), with: .color(Color(hex: 0x16191D)), lineWidth: 1)
        }
        .frame(width: 104, height: 104)
        .background(Circle().fill(Color(hex: 0x07080A)))
        .overlay(Circle().inset(by: -0.5).stroke(Color(hex: 0x22252A), lineWidth: 1))
        .shadow(color: .black, radius: 3, y: 2)
    }

    /// The gap wedge masks the two tick positions starting at `gap` degrees.
    static func inGap(tick: Int, gap: Double) -> Bool {
        let first = Int(gap / 9) % 40
        return tick == first || tick == (first + 1) % 40
    }
}

/// `.jstep` ◀ · `.jlen` 1 4 16 32 · `.jstep` ▶.
private struct BeatJump: View {
    let deck: ConsoleState.Deck
    let actions: DeckActions

    var body: some View {
        let j = Layout.jump, left = Layout.deckX(deck.id).jump
        let right = left + j.width
        let off = !deck.loaded || deck.grid == nil
        ZStack(alignment: .topLeading) {
            JumpStep(forward: false) { actions.beatJump(deck.id, -1) }.place(Layout.at(left, j.y, j.key, j.h))
            HStack(spacing: 0) {
                ForEach(Array([1, 4, 16, 32].enumerated()), id: \.offset) { index, length in
                    Button { actions.setJumpBars(deck.id, length) } label: {
                        Label(String(length), .cond(18, tracking: 0.36))
                            .foregroundStyle(length == deck.jumpBars ? Palette.text : Color(hex: 0xA0A0A6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(length == deck.jumpBars ? Color(hex: 0x26262A) : Color(hex: 0x121214))
                            .overlay(alignment: .bottom) { if length == deck.jumpBars { Palette.blue.frame(height: 2) } }
                            .overlay(alignment: .leading) { if index > 0 { Color(hex: 0x2E2E32).frame(width: 1) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(1)
            .box(fill: .clear, border: Color(hex: 0x2E2E32), radius: 3)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .place(Layout.at(left + j.key + j.gap, j.y, j.width - 2 * (j.key + j.gap), j.h))
            JumpStep(forward: true) { actions.beatJump(deck.id, 1) }.place(Layout.at(right - j.key, j.y, j.key, j.h))
        }
        .disabled(off)
        .opacity(off ? 0.35 : 1)
    }
}

private struct JumpStep: View {
    let forward: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Triangle(pointsRight: forward).fill(Color(hex: 0xCDCDD3))
                .frame(width: 26, height: 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .box(fill: Color(hex: 0x151517), border: .white.opacity(0.12), radius: 3)
        }
        .buttonStyle(.plain)
    }
}

/// The 24-unit icon triangles: ▶ `M7 5.5v13L18 12z`, ◀ `M17 5.5v13L6 12z`.
private struct Triangle: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: 7 * s, y: 5.5 * s)); path.addLine(to: CGPoint(x: 7 * s, y: 18.5 * s)); path.addLine(to: CGPoint(x: 18 * s, y: 12 * s))
        } else {
            path.move(to: CGPoint(x: 17 * s, y: 5.5 * s)); path.addLine(to: CGPoint(x: 17 * s, y: 18.5 * s)); path.addLine(to: CGPoint(x: 6 * s, y: 12 * s))
        }
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// `.big.lg`: the round CUE and PLAY keys.
/// The keys' faces; the bay gives them their presses.
private struct BigKey: View {
    enum Kind { case cue, play, pause }
    let kind: Kind
    let lit: Bool

    var body: some View {
        let colour: Color = kind == .cue ? Color(hex: 0xFFAB40) : lit ? Palette.green : Color(hex: 0xEAEAEE)
        let ring: Color = kind == .cue ? Palette.led : lit ? Palette.green : Color(hex: 0x3A3A40)
        ZStack {
            Circle().fill(Color(hex: 0x151517))
            Circle().inset(by: 1).stroke(ring, lineWidth: 2)
            switch kind {
            case .cue: Label("CUE", .cond(19, tracking: 2.66)).padding(.leading, 2.66).foregroundStyle(colour)
            case .play: Triangle(pointsRight: true).fill(colour).frame(width: 26, height: 26)
            case .pause: PauseIcon().fill(colour).frame(width: 26, height: 26)
            }
        }
    }
}

private struct PauseIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 6 * s, y: 5 * s, width: 4 * s, height: 14 * s), cornerSize: CGSize(width: s, height: s))
        path.addRoundedRect(in: CGRect(x: 14 * s, y: 5 * s, width: 4 * s, height: 14 * s), cornerSize: CGSize(width: s, height: s))
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// `.loopbar`: ‹ halves, the size starts or leaves the loop, › doubles.
private struct LoopStepper: View {
    let deck: ConsoleState.Deck
    let actions: DeckActions

    var body: some View {
        let on = deck.loop != nil
        let beats = deck.loop?.lengthBeats ?? deck.loopBeats
        let colours: KeyColours = on ? .lit(0xFF8A00) : KeyColours(face: Color(hex: 0x151517), border: .white.opacity(0.12), legend: Color(hex: 0xCDCDD3))
        HStack(spacing: 4) {
            step("‹", colours: colours, disabled: !deck.loaded || beats <= 1) { actions.stepLoop(deck.id, -1) }
            Button { actions.toggleLoop(deck.id) } label: {
                Label(beats == 0.5 ? "½" : String(Int(beats)), .cond(32, tracking: 0.64)).foregroundStyle(colours.legend)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .box(fill: colours.face, border: colours.border, radius: 3)
            }
            .buttonStyle(.plain).disabled(!deck.loaded)
            step("›", colours: colours, disabled: !deck.loaded || beats >= 64) { actions.stepLoop(deck.id, 1) }
        }
    }

    private func step(_ glyph: String, colours: KeyColours, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(glyph, .cond(22)).foregroundStyle(colours.legend)
                .frame(width: 44).frame(maxHeight: .infinity)
                .box(fill: colours.face, border: colours.border, radius: 3)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

// MARK: - Mixer

private struct Mixer: View {
    let state: ConsoleState
    let actions: ConsoleActions

    var body: some View {
        let a = state.decks[0], b = state.decks[1]
        let sum = MixerMath.lowSumDb(a, b, crossfader: state.crossfader)
        let sumBar = sum == -.infinity ? 0 : max(0, min(100, (sum + 24) / 30 * 100))
        ZStack(alignment: .topLeading) {
            Group {
            Channel(deck: a, link: state.linkLows, actions: actions)
            BandValue(name: "LOW Σ", value: MixerMath.formatDb(sum),
                      colour: sum >= 3 ? Color(hex: 0xFF6A52) : sum > 1 ? Color(hex: 0xFFC531) : Color(hex: 0xB6B6BB))
                .place(Layout.at(574, Layout.row.val.0, 46, Layout.row.val.1))
            LiveMeter(fallback: state.meterDb) { db in Meter(fill: max(0, min(100, (db + 48) / 48 * 100)), marker: nil) }
                .place(Layout.at(578, Layout.row.fader.0, 7, Layout.row.fader.1))
            Meter(fill: sumBar, marker: 80).place(Layout.at(589, Layout.row.fader.0, 27, Layout.row.fader.1))
            DotKey(lines: ["LINK", "LOWS"], indent: 1.68, colours: state.linkLows ? .lit(0xFF8A00) : .off,
                   dot: state.linkLows ? Palette.led : Color(hex: 0x43434A), action: actions.toggleLinkLows)
                .place(Layout.at(575, Layout.row.kill.0, 44, Layout.row.kill.1))
            Channel(deck: b, link: state.linkLows, actions: actions)
            }
            .folded(state.libraryOpen)
            Group {
            Label("A", .cond(13, tracking: 1.3)).foregroundStyle(Palette.silk).place(Layout.at(452, Layout.row.xf.0 + 12, 14, 24))
            HorizontalFader(position: state.crossfader, thumbWidth: 58, label: nil)
                .relativeDrag("xfade", horizontal: true, travel: 250 - 58, value: state.crossfader, reset: 0.5, set: actions.setCrossfader)
                .place(Layout.at(472, Layout.row.xf.0, 250, Layout.row.xf.1))
            Label("B", .cond(13, tracking: 1.3)).foregroundStyle(Palette.silk).place(Layout.at(728, Layout.row.xf.0 + 12, 14, 24))
            }
            .kept(state.libraryOpen)
        }
    }
}

private struct Channel: View {
    let deck: ConsoleState.Deck
    let link: Bool
    let actions: ConsoleActions
    @EnvironmentObject private var touches: ControlTouches

    var body: some View {
        let id = deck.id
        let level = Layout.column(id, .level)
        ZStack(alignment: .topLeading) {
            Button { actions.openTrim(id) } label: {
                VStack(spacing: 4) {
                    Label("TRIM", .cond(12, tracking: 0.96)).padding(.leading, 2.4).foregroundStyle(Palette.silk).frame(height: 12)
                    Label(MixerMath.formatTrim(deck.trimDb), .cond(14, tracking: 0.56)).foregroundStyle(Color(hex: 0xCDCDD3)).frame(height: 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .box(fill: Color(hex: 0x151517), border: .white.opacity(0.13), radius: 3)
            }
            .buttonStyle(.plain)
            .place(Layout.at(id == "A" ? 372 : 762, Layout.row.top.0, 60, Layout.row.top.1))
            HorizontalFader(position: (deck.filter + 1) / 2, thumbWidth: 40, label: filterLabel(deck.filter))
                .relativeDrag("\(id)-filter", horizontal: true, travel: 134 - 40, value: (deck.filter + 1) / 2, reset: 0.5) {
                    actions.deck.setFilter(id, $0 * 2 - 1)
                }
                .place(Layout.at(id == "A" ? 440 : 620, Layout.row.top.0, 134, Layout.row.top.1))
            ForEach(Layout.Column.allCases, id: \.self) { column in
                let (x, w) = Layout.column(id, column)
                let position = column == .level ? deck.level : band(column)
                let killed = column != .level && kill(column)
                let db = MixerMath.faderDb(position)
                let key = "\(id)-\(column.rawValue)", speed = touches.speeds[key]
                let name = column == .level ? "LEVEL" : column == .high ? "HI" : column == .mid ? "MID" : "LOW"
                BandValue(name: speed.map { $0 < 1 ? ($0 > 0.2 ? "FINE ¼" : "FINE ⅒") : name } ?? name,
                          value: killed ? "KILL" : MixerMath.formatDb(db),
                          colour: killed ? Color(hex: 0xFF6A52) : db < -0.05 ? Color(hex: 0xFFB45E) : Color(hex: 0xB6B6BB),
                          live: speed != nil, fine: (speed ?? 1) < 1)
                    .onTapGesture { if column != .level { actions.openBand(column.rawValue) } }
                    .place(Layout.at(x - 3, Layout.row.val.0, w + 6, Layout.row.val.1))
                ChannelFader(position: position, accentLine: column == .level || column == .low ? Palette.accent(id) : nil,
                             killed: killed, linked: column == .low && link, dragging: speed != nil)
                    .relativeDrag(key, travel: Layout.row.fader.1 - 2 - 24, value: position, reset: 1) {
                        actions.deck.setFader(id, column.rawValue, $0)
                    }
                    .place(Layout.at(x, Layout.row.fader.0, w, Layout.row.fader.1))
            }
            ForEach([Layout.Column.high, .mid, .low], id: \.self) { column in
                let (x, w) = Layout.column(id, column)
                KillPad(deck: id, band: column.rawValue, on: kill(column), set: actions.deck.setKill)
                    .place(Layout.at(x, Layout.row.kill.0, w, Layout.row.kill.1))
            }
            Button { actions.deck.toggleHeadphoneCue(id) } label: {
                let colours: KeyColours = deck.headphoneCue ? .solid(0xE18400) : .off
                Label("CUE", .cond(13, tracking: 2.08)).foregroundStyle(colours.legend)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .box(fill: colours.face, border: colours.border, radius: 2)
            }
            .buttonStyle(.plain)
            .place(Layout.at(level.x, Layout.row.kill.0, level.w, Layout.row.kill.1))
        }
    }

    private func band(_ column: Layout.Column) -> Double {
        column == .high ? deck.eq.high : column == .mid ? deck.eq.mid : deck.eq.low
    }
    private func kill(_ column: Layout.Column) -> Bool {
        column == .high ? deck.kills.high : column == .mid ? deck.kills.mid : column == .low ? deck.kills.low : false
    }
}

/// A kill mutes on touch-down: a tap latches, a hold of 300 ms or more is
/// momentary, and touching a latched kill releases it.
struct KillPad: View {
    let deck: String
    let band: String
    let on: Bool
    let set: (String, String, Bool) -> Void
    @EnvironmentObject private var touches: ControlTouches
    @State private var touch: (wasOn: Bool, at: Double)?

    var body: some View {
        let key = "\(deck)-\(band)", held = touches.held.contains(key)
        let colours = on ? KeyColours(face: mix(0xE8402F, 0.18, 0x151517), border: mix(0xE8402F, 0.62, 0x26262B), legend: Color(hex: 0xFF8A7A))
            : KeyColours(face: Color(hex: 0x151517), border: .white.opacity(0.13), legend: Palette.silk)
        DotFace(lines: [band == "high" ? "HI" : band.uppercased(), "KILL"], indent: 1.44,
                colours: held ? KeyColours(face: colours.face, border: Color(hex: 0xFFD0C8), legend: colours.legend) : colours,
                dot: on ? Palette.red : Color(hex: 0x43434A))
            .press(down: {
                touch = (on, ProcessInfo.processInfo.systemUptime)
                touches.hold(key, true)
                set(deck, band, true)
            }) { _ in
                guard let touch else { return }
                self.touch = nil
                touches.hold(key, false)
                let held = ProcessInfo.processInfo.systemUptime - touch.at >= 0.3
                set(deck, band, touch.wasOn ? false : !held)
            }
            .accessibilityLabel("Deck \(deck) \(band) kill")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { set(deck, band, !on) }
    }
}

/// FILTER's label: "FILTER", or "LP 1.2k" / "HP 340" once it bites. The
/// corner frequency is `filterSetting()` in curves.ts: low-pass from 20 kHz
/// down to 120 Hz, high-pass from 20 Hz up to 9 kHz, both exponential.
func filterLabel(_ knob: Double) -> String {
    let frequency = FilterSetting(knob: knob).frequency
    guard abs(knob) >= 0.04, frequency < 20_000 else { return "FILTER" }
    let hz = frequency >= 1000 ? String(format: "%.1fk", frequency / 1000) : String(Int(frequency.rounded()))
    return (knob < 0 ? "LP " : "HP ") + hz
}

/// `.bandval`: the band's name over its dB, above each fader.
private struct BandValue: View {
    let name: String
    let value: String
    let colour: Color
    /// `.live` while its fader is dragged; `.fine` once the drag slows.
    var live = false
    var fine = false

    var body: some View {
        VStack(spacing: 5) {
            // text-indent .2em pushes the name right of centre.
            Label(name, .cond(12, tracking: 0.96)).padding(.leading, 2.4).foregroundStyle(fine ? Color(hex: 0xFFAB40) : Palette.silk).frame(height: 12)
            Label(value, .cond(13, tracking: 0.52)).foregroundStyle(colour).frame(height: 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .box(fill: live ? Color(hex: 0x0A0A0B) : .clear, border: live ? Color(hex: 0x303036) : .clear, radius: 2)
        .contentShape(Rectangle())
    }
}

/// `.cf`: a cut-only channel fader with its six law ticks and black cap.
private struct ChannelFader: View {
    let position: Double
    let accentLine: Color?
    let killed: Bool
    let linked: Bool
    var dragging = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let inner = CGSize(width: geometry.size.width - 2, height: geometry.size.height - 2)
            ZStack(alignment: .topLeading) {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.2, 0], id: \.self) { mark in
                    // top: (inner − cap/2 − p·(inner − cap)).toFixed(1)
                    let top = ((inner.height - 12 - mark * (inner.height - 24)) * 10).rounded() / 10
                    Color.white.opacity(mark == 1 ? 0.34 : 0.13).frame(width: inner.width - 8, height: 1).offset(x: 4, y: snap(top, scale))
                }
                RoundedRectangle(cornerRadius: 1).fill(Color.black)
                    .frame(width: 6, height: inner.height - 24).offset(x: inner.width / 2 - 3, y: 12)
                Cap(width: inner.width - 2, height: 24,
                    line: killed ? Color(hex: 0xFF6A52) : accentLine ?? Color(hex: 0xE9E9EE), vertical: false,
                    border: killed ? Color(.sRGB, red: 232 / 255, green: 64 / 255, blue: 47 / 255, opacity: 0.55) : Color(hex: 0x3E3E45))
                    .offset(x: 1, y: snap(inner.height - 12 - CGFloat(position) * (inner.height - 24) - 12, scale))
            }
            .frame(width: inner.width, height: inner.height, alignment: .topLeading)
            .offset(x: 1, y: 1)
        }
        .box(fill: Color(hex: 0x131315),
             border: dragging ? Color(hex: 0x4D4D54)
                 : killed ? Color(.sRGB, red: 232 / 255, green: 64 / 255, blue: 47 / 255, opacity: 0.45)
                 : linked ? mix(0xFF8A00, 0.60, 0x26262B) : Color(hex: 0x26262A), radius: 3)
    }
}

/// `.fx`: a horizontal relative slider (FILTER, crossfader, TRIM and the
/// band sheet's faders) with its centre mark.
struct HorizontalFader: View {
    let position: Double
    let thumbWidth: CGFloat
    let label: String?
    /// The box's border while dragged; none otherwise.
    var border: Color?
    var line = Color(hex: 0xE9E9EE)
    var capBorder: Color?
    var centreMark = true
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.black).frame(width: size.width - 16, height: 8).offset(x: 8, y: size.height / 2 - 4)
                if centreMark {
                    Color.white.opacity(0.18).frame(width: 1, height: size.height - 16).offset(x: snap(size.width / 2, scale), y: 8)
                }
                if let label { Label(label, .cond(12, tracking: 0.96)).foregroundStyle(Palette.silk).frame(height: 12).offset(x: 4, y: -2) }
                Cap(width: thumbWidth, height: size.height - 10, line: line, vertical: true, border: capBorder ?? Color(hex: 0x3E3E45))
                    .offset(x: snap(thumbWidth / 2 + CGFloat(position) * (size.width - thumbWidth) - thumbWidth / 2, scale), y: 5)
            }
        }
        .overlay { if let border { RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(border, lineWidth: 1) } }
    }
}

/// `.kill-pad` / `.linkbtn`: a lamp dot over a two-line legend.
private struct DotKey: View {
    let lines: [String]
    let indent: CGFloat
    let colours: KeyColours
    let dot: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) { DotFace(lines: lines, indent: indent, colours: colours, dot: dot) }
            .buttonStyle(.plain)
    }
}

private struct DotFace: View {
    let lines: [String]
    let indent: CGFloat
    let colours: KeyColours
    let dot: Color

    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(dot).overlay(Circle().inset(by: 0.5).stroke(Color.black.opacity(0.7), lineWidth: 1)).frame(width: 5, height: 5)
            VStack(spacing: 0) {
                ForEach(lines, id: \.self) { line in
                    // line-height 1.15: 13.8 pt per line.
                    Label(line, .cond(12, tracking: 0.96)).padding(.leading, indent).frame(height: 13.8)
                }
            }
            .foregroundStyle(colours.legend)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .box(fill: colours.face, border: colours.border, radius: 3)
    }
}

/// `.meter-v`: a segmented green-to-red bar (4 pt lit, 2 pt dark) filled to
/// `fill` percent, with an optional white marker at `marker` percent.
private struct Meter: View {
    let fill: Double
    let marker: Double?

    var body: some View {
        GeometryReader { geometry in
            let inner = CGSize(width: geometry.size.width - 2, height: geometry.size.height - 2)
            // The bar box is 72% of the meter from the top (an over-constrained
            // CSS rule), clipped from its top to `fill`.
            let bar = inner.height * 0.72
            let clip = bar * (1 - fill / 100)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var y = size.height
                    var stripes = Path()
                    while y > 0 {
                        stripes.addRect(CGRect(x: 0, y: max(0, y - 4), width: size.width, height: min(4, y)))
                        y -= 6
                    }
                    var visible = context
                    visible.clip(to: Path(CGRect(x: 0, y: clip, width: size.width, height: size.height - clip)))
                    visible.clip(to: stripes)
                    visible.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                        Gradient(stops: [.init(color: Color(hex: 0x25A859), location: 0), .init(color: Color(hex: 0x25A859), location: 0.64),
                                         .init(color: Color(hex: 0xD8A029), location: 0.78), .init(color: Color(hex: 0xD9662A), location: 0.9),
                                         .init(color: Color(hex: 0xD03A2C), location: 1)]),
                        startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero))
                }
                .frame(width: inner.width, height: bar)
            }
            .frame(width: inner.width, height: inner.height, alignment: .topLeading)
            .clipped()
            .offset(x: 1, y: 1)
            if let marker {
                Color.white.opacity(0.7).frame(width: geometry.size.width, height: 1)
                    .offset(y: inner.height * (1 - marker / 100))
            }
        }
        .box(fill: Color(hex: 0x0A0A0B), border: Color(hex: 0x26262A), radius: 1)
    }
}
