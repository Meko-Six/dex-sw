import SwiftUI
import DexCore
import DexSlider

/// The chassis under the track windows, from the user's drawing
/// (`mockup/stage-two-decks FA.svg`) by way of the stage-two mockup
/// (`mockup/stage-two-decks.html`), which is the reference. The drawing's static
/// art is drawn as it is from two PDFs (`build-stage-art.mjs`); every control is
/// drawn on top at the drawing's coordinates, in the drawing's styles, and the
/// chips and the LEVEL and TEMPO faders work through DexSlider's bank.
struct Chassis: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let bank: SliderBank
    /// The decks whose platter is being scrubbed: it rises over the mixer until let go.
    @State private var lifted: Set<String> = []
    /// A finger holding CUE, by deck: where it is along CUE → PLAY, and whether it reached PLAY.
    @State private var slides: [String: CueSlide] = [:]

    /// DexSliderLab's tuning (the user's iPad tuning of 10 November), with the faders'
    /// travel set to the drawing's: LEVEL's 0 … 10 scale and TEMPO's ±16 % comb.
    static var tuning: SliderTuning {
        var tuning = SliderTuning()
        tuning.levelHeight = Layout.level.run + tuning.capHeight
        tuning.tempoHeight = 2 * Layout.tempo.half + tuning.capHeight
        tuning.tempoReadoutAbove = true
        return tuning
    }

    var body: some View {
        let folded = state.libraryOpen
        ZStack(alignment: .topLeading) {
            StageArt(file: .base)
            Group {
                StageArt(file: .platters)
                StageArt(file: .art)
                ForEach(state.decks, id: \.id) { deck in
                    Live(deck: deck) { PlatterMarks(deck: $0) }
                        .place(Layout.platterRect(deck.id))
                    PlatterTouch(deck: deck, scrub: actions.deck.scrub) { touching in
                        if touching { lifted.insert(deck.id) } else { lifted.remove(deck.id) }
                    }
                    .place(Layout.platterRect(deck.id))
                }
                StageMeters(fallback: state.meters)
                Canvas { context, _ in
                    var context = context
                    context.translateBy(x: -Layout.origin.x, y: -Layout.origin.y)
                    Draw.controls(context, state: state, bank: bank)
                }
                .allowsHitTesting(false)
                Controls(state: state, actions: actions, bank: bank)
            }
            .folded(folded)
            Group {
                Canvas { context, _ in
                    var context = context
                    context.translateBy(x: -Layout.origin.x, y: -Layout.origin.y)
                    Draw.transport(context, state: state, slides: slides)
                }
                .allowsHitTesting(false)
                Transport(state: state, actions: actions, slides: $slides)
            }
            .kept(folded)
            ForEach(state.decks.filter { lifted.contains($0.id) }, id: \.id) { deck in
                LiftedPlatter(deck: deck)
            }
            .folded(folded)
            ForEach(state.decks.filter(\.hotCuesOpen), id: \.id) { deck in
                HotCuePop(deck: deck, actions: actions.deck)
                    .offset(x: Layout.deckX(deck.id).platter - 150 - Layout.origin.x, y: 85)
                    .folded(folded)
            }
        }
        .frame(width: Stage.width, height: Layout.height, alignment: .topLeading)
        .clipped()
        .background(Color.black)
        .background { BankSync(state: state, actions: actions, bank: bank) }
    }
}

/// The chassis coordinates: the drawing's own, its 1194 × 834 canvas with the 10 pt
/// bezel. The chassis is the drawing's x 10 … 1184, y 348 … 824.
enum Layout {
    static let origin = CGPoint(x: 10, y: 348)
    static let height: CGFloat = 476
    /// A rect in the drawing's points, in the chassis.
    static func at(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x - origin.x, y: y - origin.y, width: w, height: h)
    }

    // The deck keys, 34 pt tall with 5 pt of touch above and below.
    static let key = (y: CGFloat(365.99), w: CGFloat(76.54), h: CGFloat(34.02), mtW: CGFloat(59.27))
    static func keys(_ deck: String) -> (mt: CGFloat, sync: CGFloat, master: CGFloat, hot: CGFloat) {
        deck == "B" ? (1106.73, 820.73, 906.73, 1008.73) : (28.73, 114.73, 200.73, 298.73)
    }
    static let channelCue = (a: CGFloat(332.73), b: CGFloat(784.5), y: CGFloat(686.99))
    static let lockLows = CGPoint(x: 558.73, y: 686.99)

    // The chips, 90 × 50, in a column each side of the meters.
    static let chip = CGSize(width: 90, height: 50)
    static func column(_ deck: String) -> CGFloat { deck == "B" ? 677 : 426 }
    enum Row: CGFloat { case trim = 358, hi = 425, mid = 486, low = 547, fx = 613, foot = 679 }
    static func chip(_ deck: String, _ row: Row) -> CGRect { at(column(deck), row.rawValue, chip.width, chip.height) }
    static let masterChip = CGRect(x: 551.64, y: 357.91, width: 90.71, height: 48.19)

    // The faders.
    static let level = (a: CGFloat(359.93), b: CGFloat(834.07), zero: CGFloat(627.55), run: CGFloat(174.55), foot: CGFloat(641))
    static func levelX(_ deck: String) -> CGFloat { deck == "B" ? level.b : level.a }
    static let tempo = (a: CGFloat(19.24), b: CGFloat(1114.76), y: CGFloat(435), w: CGFloat(60), h: CGFloat(206),
                        zero: CGFloat(537.5), half: CGFloat(85))
    static func tempoX(_ deck: String) -> CGFloat { deck == "B" ? tempo.b : tempo.a }
    static let crossfader = (x: CGFloat(480), w: CGFloat(234), cy: CGFloat(782), half: CGFloat(16.28))

    // The transport row and beat jump.
    static func transport(_ deck: String) -> (cue: CGFloat, play: CGFloat, loop: CGFloat) {
        deck == "B" ? (861, 935, 985) : (61, 135, 186)
    }
    static let transportY: CGFloat = 782
    static let loopY: CGFloat = 761
    static func jump(_ deck: String) -> CGFloat { deck == "B" ? 899 : 21 }
    static let jumpY: CGFloat = 682
    static let jumps = [1, 4, 16, 32]

    // The platters, under the mixer's faceplate (x 297 … 897) by 68 pt each.
    static let platter = (y: CGFloat(414), size: CGFloat(262))
    static func deckX(_ id: String) -> (platter: CGFloat, row: CGFloat) { id == "B" ? (960, 985) : (234, 186) }
    static func platterRect(_ id: String) -> CGRect {
        at(deckX(id).platter - platter.size / 2, platter.y, platter.size, platter.size)
    }
    static let tuckedRim: CGFloat = 68
    /// Where the filter's popover hangs from: the FX chip.
    static func filterButton(_ id: String) -> CGRect { chip(id, .fx) }
    /// How far the transport row rides up while the library is open, to sit under the track windows.
    static let keptLift: CGFloat = 394
}

extension View {
    /// `.lib-open .chassis > *`: hidden while the library is up.
    func folded(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }

    /// `.lib-open .chassis .keep`: CUE, PLAY, the loop and the crossfader ride
    /// up under the track windows while the library is up.
    func kept(_ raised: Bool) -> some View { offset(y: raised ? -Layout.keptLift : 0) }

    /// Absolute placement in the chassis, like `position: absolute` with `at()`.
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - The drawing's static art

/// One of the PDFs `mockup/build-stage-art.mjs` prints from the drawing, drawn at
/// the chassis's size. CoreGraphics draws PDFs as vectors, so it is sharp at any scale.
private struct StageArt: View {
    enum File: String, CaseIterable { case base = "chassis-base", platters = "chassis-platters", art = "chassis-art" }
    let file: File

    var body: some View {
        Canvas { context, size in
            guard let page = Self.pages[file] else { return }
            let box = page.getBoxRect(.mediaBox)
            context.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
                cg.translateBy(x: -box.minX, y: -box.minY)
                cg.drawPDFPage(page)
            }
        }
        .frame(width: Stage.width, height: Layout.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let pages: [File: CGPDFPage] = {
        var pages: [File: CGPDFPage] = [:]
        for file in File.allCases {
            if let url = Bundle.module.url(forResource: file.rawValue, withExtension: "pdf", subdirectory: "Art"),
               let page = CGPDFDocument(url as CFURL)?.page(at: 1) {
                pages[file] = page
            }
        }
        return pages
    }()
}

// MARK: - Drawing in the drawing's terms

/// The drawing's colours and type: its CSS classes, resolved.
private enum Ink {
    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color { Color(hex: value, opacity: opacity) }
    static let blue = hex(0x276FFF), orange = hex(0xE18400), green = hex(0x35D06B)

    /// A face as the drawing names it: Avenir Next DemiBold or Bold, or the Condensed DemiBold.
    struct Face {
        let name: String
        let size: CGFloat
        var spacing: CGFloat = 0
        static func demi(_ size: CGFloat) -> Face { Face(name: "AvenirNext-DemiBold", size: size) }
        static func bold(_ size: CGFloat, spacing: CGFloat = 0) -> Face { Face(name: "AvenirNext-Bold", size: size, spacing: spacing) }
        static func condDemi(_ size: CGFloat) -> Face { Face(name: "AvenirNextCondensed-DemiBold", size: size) }
    }
}

private extension GraphicsContext {
    /// An SVG rect: fill, then the stroke centred on its edge.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat = 0,
              fill: Color? = nil, stroke: Color? = nil, width: CGFloat = 1, opacity: Double = 1) {
        var context = self
        context.opacity = opacity
        let shape = rx > 0 ? Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: rx)
            : Path(CGRect(x: x, y: y, width: w, height: h))
        if let fill { context.fill(shape, with: .color(fill)) }
        if let stroke { context.stroke(shape, with: .color(stroke), lineWidth: width) }
    }

    /// The drawing's key gradients: radial, centred, reaching 0.71 of the box each way.
    func radial(_ rect: CGRect, rx: CGFloat, stops: [(Double, UInt32)]) {
        var context = self
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: rect.width, y: rect.height)
        let unit = Path(roundedRect: rect, cornerRadius: rx)
            .applying(CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(scaleX: 1 / rect.width, y: 1 / rect.height)))
        context.fill(unit, with: .radialGradient(Gradient(stops: stops.map { .init(color: Ink.hex($0.1), location: $0.0) }),
                                                 center: .zero, startRadius: 0, endRadius: 0.71))
    }

    /// SVG text: `x` is its middle (or its start), `y` its baseline.
    func text(_ string: String, _ face: Ink.Face, _ colour: Color, x: CGFloat, y: CGFloat, middle: Bool = true) {
        let resolved = resolve(Text(string).font(.custom(face.name, fixedSize: face.size))
            .tracking(face.spacing * face.size).foregroundStyle(colour))
        let size = resolved.measure(in: CGSize(width: 1000, height: 1000))
        let baseline = resolved.firstBaseline(in: size)
        draw(resolved, at: CGPoint(x: middle ? x - size.width / 2 : x, y: y - baseline), anchor: .topLeading)
    }
}

@MainActor private enum Draw {
    static let orangeStops: [(Double, UInt32)] = [(0, 0xCD9C04), (0.46, 0xD49210), (0.6, 0xDC8519), (0.74, 0xE87022), (0.88, 0xF05A27)]
    static let redStops: [(Double, UInt32)] = [(0, 0xFF7A5C), (0.32, 0xF8654A), (0.49, 0xF0553D), (0.67, 0xE64634), (0.81, 0xD93A2B), (0.95, 0xCC3024)]
    static let whiteStops: [(Double, UInt32)] = [(0, 0xFFFFFF), (0.46, 0xF3F3F3), (0.6, 0xE6E6E6), (0.74, 0xD2D2D2), (0.78, 0xD1D1D1)]
    static let autoStops: [(Double, UInt32)] = [(0, 0x8BE596), (0.32, 0x74DA82), (0.49, 0x62CF72), (0.67, 0x55C467), (0.81, 0x49BA60), (0.95, 0x3FAE56)]
    static let capStops: [(Double, UInt32)] = [
        (0.08, 0x323232), (0.15, 0x242424), (0.21, 0x3C3C3C), (0.28, 0x0A0A0A), (0.33, 0x0C0C0C), (0.35, 0x303030),
        (0.46, 0x303030), (0.48, 0xB0B0B0), (0.51, 0xB5B5B5), (0.53, 0x515151), (0.66, 0x616161), (0.68, 0x1C1C1C),
        (0.81, 0x1C1C1C), (0.88, 0x636363), (0.94, 0x606060), (0.97, 0x282828)
    ]

    // MARK: Keys

    enum KeyKind { case sync, master, mt, hot, cue, lows }

    /// A deck key in either look (`key()` in the mockup).
    static func key(_ c: GraphicsContext, _ kind: KeyKind, x: CGFloat, y: CGFloat, lit: Bool, lines: [String]) {
        let k = Layout.key, w = kind == .mt ? k.mtW : k.w, h = k.h, cx = x + w / 2
        let box = CGRect(x: x, y: y, width: w, height: h)
        if lit {
            switch kind {
            case .master, .cue: c.radial(box, rx: 5, stops: orangeStops)
            case .mt, .lows: c.radial(box, rx: 5, stops: redStops)
            default: c.radial(box, rx: 5, stops: whiteStops)
            }
            c.rect(x, y, w, h, rx: 5, stroke: .black, width: 1.25)
        } else {
            let line: UInt32 = switch kind {
            case .sync: 0xA5A6A5
            case .master, .cue: 0x995A00
            case .mt, .lows: 0xA03225
            case .hot: 0x1A4CAD
            }
            c.rect(x, y, w, h, rx: 5, fill: .black, stroke: Ink.hex(line), width: 1.25)
        }
        let inset: CGFloat = kind == .mt ? 1.14 : 1.47
        c.rect(x + inset, y + 1.28, w - 2 * inset, 0.85, fill: .white, opacity: lit ? 0.5 : 0.1)
        if lit && (kind == .master || kind == .cue) {
            var led = c
            led.opacity = 0.18
            led.fill(Path(ellipseIn: CGRect(x: x + 70.27 - 2, y: y + 4.01 - 2, width: 4, height: 4)), with: .color(Ink.orange))
        }
        let (face, colour): (Ink.Face, Color) = switch kind {
        case .sync: (.demi(15), lit ? .black : Ink.hex(0xA5A6A5))
        case .master, .cue: (.demi(15), lit ? .black : Ink.orange)
        case .mt: (.condDemi(13.74), lit ? .black : Ink.hex(0xE94F2D))
        case .lows: (.demi(13.74), lit ? .black : Ink.hex(0xEC4A37))
        case .hot: (.demi(15), Ink.blue)
        }
        if lines.count == 1 {
            c.text(lines[0], face, colour, x: cx, y: y + 22.32)
        } else {
            c.text(lines[0], face, colour, x: cx, y: y + 16.31)
            c.text(lines[1], face, colour, x: cx, y: y + 29)
        }
    }

    // MARK: Chips

    static func shell(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        c.rect(x, y, 90, 50, rx: 6, fill: .black, stroke: .black)
    }
    static func sheen(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        c.rect(x + 1.5, y + 1.5, 87, 1, fill: .white, opacity: 0.06)
    }
    static func words(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ title: String, _ value: String,
                      title titleColour: Color = Ink.hex(0xC6C7CC), value valueColour: Color = Ink.hex(0xEEF0F3)) {
        c.text(title, .demi(15), titleColour, x: x + 45, y: y + 20)
        c.text(value, .bold(19), valueColour, x: x + 45, y: y + 41)
    }

    /// EQ (grey) and PHONES (orange): filled from the foot.
    static func footChip(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ title: String, value: Double, readout: String, orange: Bool) {
        let fill = min(48.75, 50 * value)
        shell(c, x, y)
        if fill > 0 {
            c.rect(x + 1, y + 50 - fill, 88, fill, fill: orange ? Ink.orange : Ink.hex(0xF2F1F3), opacity: orange ? 0.4 : 0.3)
        }
        c.rect(x + 1.21, y + 1.25, 87.5, 47.5, rx: 5, stroke: orange ? Ink.orange : Ink.hex(0xF2F1F3), opacity: 0.85)
        sheen(c, x, y)
        words(c, x, y, title, readout)
    }

    /// FX (blue) and hand-set TRIM (green): a band from OFF or 0 at the centre ticks.
    static func centreChip(_ c: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ title: String, _ value: String,
                           fraction: Double, blue: Bool) {
        let tone = blue ? Ink.blue : Ink.green
        let band = abs(fraction) * 24, top = fraction >= 0 ? y + 25 - band : y + 25
        shell(c, x, y)
        c.rect(x + 1.25, y + 1.25, 87.5, 47.5, rx: 5, stroke: tone, width: 1.25, opacity: 0.85)
        sheen(c, x, y)
        c.rect(x + 3, y + 24, 9, 2, fill: tone)
        c.rect(x + 78, y + 24, 9, 2, fill: tone)
        if band > 0 { c.rect(x + 1, top, 88, band, fill: tone, opacity: blue ? 0.6 : 0.5) }
        words(c, x, y, title, value)
    }

    static func trimChip(_ c: GraphicsContext, deck: ConsoleState.Deck, value: Double) {
        let x = Layout.column(deck.id), y = Layout.Row.trim.rawValue
        if deck.trimIsAuto {
            let shape = Path(roundedRect: CGRect(x: x, y: y, width: 90, height: 50), cornerRadius: 6)
            c.fill(shape, with: .radialGradient(Gradient(stops: autoStops.map { .init(color: Ink.hex($0.1), location: $0.0) }),
                                                center: CGPoint(x: deck.id == "B" ? 722 : 471, y: 383),
                                                startRadius: 0, endRadius: 36.4))
            c.stroke(shape, with: .color(.black), lineWidth: 1)
            c.rect(x + 1.25, y + 1.25, 87.5, 47.5, rx: 5, stroke: Ink.green, width: 1.25, opacity: 0.85)
            sheen(c, x, y)
            words(c, x, y, "AUTO TRIM", SliderSpec.decibels(value), title: .black, value: .black)
        } else {
            centreChip(c, x, y, "TRIM", SliderSpec.decibels(value), fraction: value / 12, blue: false)
        }
    }

    /// CUE/MST: split in two, the orange the CUE share.
    static func cueMixChip(_ c: GraphicsContext, blend: Double) {
        let x = Layout.column("A"), y = Layout.Row.foot.rawValue
        let mst = Int((min(1, max(0, blend)) * 100).rounded()), cue = 100 - mst
        shell(c, x, y)
        let width = 88 * CGFloat(cue) / 100
        if width > 0 { c.rect(x + 1, y, width, 50, fill: Ink.orange, opacity: 0.4) }
        c.rect(x + 1.21, y + 1.25, 87.5, 47.5, rx: 5, stroke: Ink.orange, opacity: 0.85)
        sheen(c, x, y)
        c.text("CUE", .demi(15), Ink.hex(0xC6C7CC), x: x + 23.4, y: y + 20)
        c.text("MST", .demi(15), Ink.hex(0xC6C7CC), x: x + 68.9, y: y + 20)
        c.text("\(cue)", .bold(19), Ink.hex(0xEEF0F3), x: x + 23.4, y: y + 41)
        c.text("\(mst)", .bold(19), Ink.hex(0xEEF0F3), x: x + 68.9, y: y + 41)
    }

    static func masterChip(_ c: GraphicsContext, level: Double) {
        let r = Layout.masterChip, fill = r.height * min(1, max(0, level)), cx = r.midX
        c.rect(r.minX, r.minY, r.width, r.height, rx: 3, fill: .black, stroke: Ink.hex(0xD4E108))
        if fill > 0 { c.rect(r.minX, r.maxY - fill, 90.36, fill, fill: Ink.hex(0xD4E108), opacity: 0.3) }
        c.text("MASTER", .demi(14), Ink.hex(0xC6C7CC), x: cx, y: 372.36)
        c.text("LEVEL", .demi(14), Ink.hex(0xC6C7CC), x: cx, y: 386.36)
        c.text("\(Int((level * 100).rounded()))%", .bold(14), Ink.hex(0xF2F1F3), x: cx, y: 401.52)
    }

    // MARK: Faders

    /// LEVEL: the drawn cap on the 10 … 0 scale, the slot lit below it.
    static func levelFader(_ c: GraphicsContext, deck: String, level: Double) {
        let l = Layout.level, cx = Layout.levelX(deck), centre = l.zero - CGFloat(level) * l.run
        c.rect(cx - 2, centre - 2, 4, l.foot - centre + 2, fill: .white, opacity: 0.16)
        var cap = c
        cap.translateBy(x: cx - 30, y: centre - 16.28)
        cap.rect(0, 0, 60, 32.56, rx: 3.24, fill: Ink.hex(0x24242A), stroke: .black, width: 1.08)
        cap.rect(0.85, 0.99, 58.3, 30.58, rx: 2.32, fill: Ink.hex(0x24242A), stroke: Ink.hex(0xA0A0A5), width: 0.81, opacity: 0.7)
        cap.rect(0.5, 31.4, 59, 1.16, fill: Ink.hex(0x494949), opacity: 0.28)
        cap.rect(0, 15.5, 60, 1.57, fill: Ink.hex(0xF2F1F3))
        cap.rect(0, 16.88, 60, 1.16, fill: Ink.hex(0xECECF0), opacity: 0.55)
        var screws = cap
        screws.opacity = 0.7
        screws.fill(Path(ellipseIn: CGRect(x: 1.87 - 0.38, y: 1.35 - 0.44, width: 0.76, height: 0.88)), with: .color(Ink.hex(0xF2F1F3)))
        screws.fill(Path(ellipseIn: CGRect(x: 58.03 - 0.38, y: 1.29 - 0.44, width: 0.76, height: 0.88)), with: .color(Ink.hex(0xF2F1F3)))
    }

    /// TEMPO: the drawn cap, − (slower) at the top, ±16 % across the comb.
    static func tempoFader(_ c: GraphicsContext, deck: String, percent: Double) {
        let t = Layout.tempo, centre = t.zero + CGFloat(min(16, max(-16, percent)) / 16) * t.half
        var cap = c
        cap.translateBy(x: Layout.tempoX(deck) + 2.12, y: centre - 20.725)
        let body = Path(roundedRect: CGRect(x: 0, y: 0, width: 55.77, height: 41.45), cornerRadius: 3.91)
        cap.fill(body, with: .linearGradient(Gradient(stops: capStops.map { .init(color: Ink.hex($0.1), location: $0.0) }),
                                             startPoint: CGPoint(x: 0, y: 41.45), endPoint: .zero))
        cap.stroke(body, with: .color(.black), lineWidth: 0.54)
        var glint = Path()
        glint.move(to: CGPoint(x: 0.47, y: 10.66)); glint.addLine(to: CGPoint(x: 1.89, y: 10.66))
        glint.addCurve(to: CGPoint(x: 2.07, y: 10.54), control1: CGPoint(x: 1.99, y: 10.66), control2: CGPoint(x: 2.07, y: 10.61))
        glint.addLine(to: CGPoint(x: 2.07, y: 0.8))
        glint.addCurve(to: CGPoint(x: 0.29, y: 3.5), control1: CGPoint(x: 1.49, y: 0.93), control2: CGPoint(x: 0.33, y: 2.64))
        glint.addLine(to: CGPoint(x: 0.29, y: 10.54))
        glint.addCurve(to: CGPoint(x: 0.47, y: 10.66), control1: CGPoint(x: 0.29, y: 10.61), control2: CGPoint(x: 0.37, y: 10.66))
        glint.closeSubpath()
        var hi = cap
        hi.opacity = 0.4
        hi.fill(glint, with: .linearGradient(Gradient(stops: [.init(color: Ink.hex(0x999999, 0), location: 0), .init(color: Ink.hex(0xB5B5B5), location: 1)]),
                                             startPoint: CGPoint(x: 0, y: 10.66), endPoint: CGPoint(x: 0, y: 0.8)))
    }

    static func crossfader(_ c: GraphicsContext, position: Double) {
        let x = Layout.crossfader, cx = x.x + x.half + CGFloat(min(1, max(0, position))) * (x.w - 2 * x.half)
        var cap = c
        cap.translateBy(x: cx, y: x.cy)
        cap.rect(-16.28, -26.02, 32.56, 52.04, rx: 3.01, fill: Ink.hex(0x24242A), stroke: .black)
        cap.rect(-15.29, -25.28, 30.58, 50.56, rx: 2.16, fill: Ink.hex(0x24242A), stroke: Ink.hex(0xA0A0A5), width: 0.75, opacity: 0.7)
        cap.rect(-0.785, -26.02, 1.57, 52.04, fill: Ink.hex(0xF2F1F3))
        cap.rect(-1.76, -26.02, 1.16, 52.04, fill: Ink.hex(0xECECF0), opacity: 0.55)
        var screws = cap
        screws.opacity = 0.7
        for (sx, sy) in [(14.21, -24.95), (-14.27, -24.98)] as [(CGFloat, CGFloat)] {
            screws.fill(Path(ellipseIn: CGRect(x: sx - 0.44, y: sy - 0.44, width: 0.88, height: 0.88)), with: .color(Ink.hex(0xF2F1F3)))
        }
    }

    // MARK: Everything but the transport row

    static func controls(_ c: GraphicsContext, state: ConsoleState, bank: SliderBank) {
        let master = state.decks.indices.contains(state.masterDeck) ? state.decks[state.masterDeck].id : nil
        for deck in state.decks {
            let id = deck.id, keys = Layout.keys(id), y = Layout.key.y
            var dim = c
            dim.opacity = deck.loaded ? 1 : 0.35
            key(c, .mt, x: keys.mt, y: y, lit: deck.keyLock, lines: ["MASTER", "TEMPO"])
            key(c, .sync, x: keys.sync, y: y, lit: deck.syncLocked, lines: ["SYNC"])
            key(dim, .master, x: keys.master, y: y, lit: master == id && deck.loaded, lines: ["MASTER"])
            key(dim, .hot, x: keys.hot, y: y, lit: false, lines: ["HOT CUE"])
            key(c, .cue, x: id == "B" ? Layout.channelCue.b : Layout.channelCue.a, y: Layout.channelCue.y,
                lit: deck.headphoneCue, lines: ["CUE"])

            let x = Layout.column(id)
            trimChip(c, deck: deck, value: bank.value(SliderID(id, .trim)))
            for (role, row, title) in [(SliderRole.hi, Layout.Row.hi, "HI"), (.mid, .mid, "MID"), (.low, .low, "LOW")] {
                let sid = SliderID(id, role), value = bank.value(sid)
                footChip(c, x, row.rawValue, title, value: value, readout: SliderSpec.eq(deck: id).readout(value), orange: false)
            }
            let fx = SliderID(id, .fx), fxValue = bank.value(fx)
            let fxSpec = bank.controls[fx]?.spec ?? .fx(deck: id)
            centreChip(c, x, Layout.Row.fx.rawValue, fxSpec.title ?? "FILTER", fxSpec.readout(fxValue),
                       fraction: fxValue / 100, blue: true)
            levelFader(c, deck: id, level: bank.value(SliderID(id, .level)))
            tempoFader(c, deck: id, percent: bank.value(SliderID(id, .tempo)))
            beatJump(c, deck: deck)
        }
        masterChip(c, level: bank.value(SliderID("M", .master)))
        cueMixChip(c, blend: bank.value(SliderID("M", .cueMix)))
        let phones = bank.value(SliderID("M", .phones))
        footChip(c, Layout.column("B"), Layout.Row.foot.rawValue, "PHONES", value: phones,
                 readout: SliderSpec.phones().readout(phones), orange: true)
        key(c, .lows, x: Layout.lockLows.x, y: Layout.lockLows.y, lit: state.linkLows, lines: ["LOCK", "LOWS"])
    }

    static func beatJump(_ c: GraphicsContext, deck: ConsoleState.Deck) {
        var c = c
        c.opacity = deck.loaded && deck.grid != nil ? 1 : 0.35
        let x = Layout.jump(deck.id), y = Layout.jumpY, strip = x + 48
        c.rect(x, y, 44, 44, rx: 4, fill: Ink.hex(0x1A1A1E), stroke: .black)
        c.fill(triangle(tip: x + 16, base: x + 27), with: .color(Ink.hex(0xCDCED4)))
        c.rect(strip, y, 178, 44, rx: 4, fill: Ink.hex(0x08080A), stroke: .black)
        for (index, bars) in Layout.jumps.enumerated() {
            let cell = strip + 1 + CGFloat(index) * 44, on = bars == deck.jumpBars
            c.rect(cell, y, 43, 44, fill: Ink.hex(on ? 0x2A2A2F : 0x17171B))
            if on { c.rect(cell, y + 41, 43, 3, fill: Ink.blue) }
            c.text("\(bars)", .bold(17, spacing: 0.03), Ink.hex(on ? 0xF2F2F4 : 0x9A9BA1), x: cell + 21.5, y: 709.95)
        }
        for index in 1...3 { c.rect(strip + CGFloat(index) * 44, y, 1, 44, fill: .black) }
        c.rect(x + 230, y, 44, 44, rx: 4, fill: Ink.hex(0x1A1A1E), stroke: .black)
        c.fill(triangle(tip: x + 258, base: x + 247), with: .color(Ink.hex(0xCDCED4)))
    }

    /// The jump arrows: 13 pt tall, 11 pt deep, at the beat jump row.
    static func triangle(tip: CGFloat, base: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: base, y: 697.5)); path.addLine(to: CGPoint(x: base, y: 710.5))
        path.addLine(to: CGPoint(x: tip, y: 704)); path.closeSubpath()
        return path
    }

    // MARK: The transport row

    static func transport(_ c: GraphicsContext, state: ConsoleState, slides: [String: CueSlide]) {
        for deck in state.decks {
            let p = Layout.transport(deck.id), cy = Layout.transportY
            var c = c
            c.opacity = deck.loaded ? 1 : 0.35
            let slide = slides[deck.id], slideInk = slide?.latched == true ? Ink.green : Ink.orange
            if slide != nil {
                // Holding CUE: a track joins CUE to PLAY, under the keys.
                let track = Path(roundedRect: CGRect(x: p.cue - 39, y: cy - 39, width: p.play - p.cue + 78, height: 78), cornerRadius: 39)
                c.fill(track, with: .color(slideInk.opacity(0.12)))
                c.stroke(track, with: .color(slideInk.opacity(0.6)), lineWidth: 1.5)
            }
            ring(c, cx: p.cue, lit: deck.loaded ? Ink.orange : nil)
            c.text("CUE", .bold(16, spacing: 0.12), Ink.orange, x: p.cue - 18.25, y: 787.66, middle: false)
            ring(c, cx: p.play, lit: deck.playing ? Ink.green : nil)
            if deck.playing && !deck.previewing {
                c.fill(Path(roundedRect: CGRect(x: p.play - 6.5, y: cy - 7.58, width: 4.33, height: 15.17), cornerRadius: 1.08), with: .color(Ink.green))
                c.fill(Path(roundedRect: CGRect(x: p.play + 2.17, y: cy - 7.58, width: 4.33, height: 15.17), cornerRadius: 1.08), with: .color(Ink.green))
            } else {
                var play = Path()
                play.move(to: CGPoint(x: p.play - 4.33, y: cy - 7.04)); play.addLine(to: CGPoint(x: p.play - 4.33, y: cy + 7.04))
                play.addLine(to: CGPoint(x: p.play + 7.58, y: cy)); play.closeSubpath()
                c.fill(play, with: .color(Ink.green))
            }
            if let slide {
                // …and a puck follows the finger along it, green once it has reached PLAY.
                let x = min(p.play, max(p.cue, slide.x))
                let puck = Path(ellipseIn: CGRect(x: x - 33, y: cy - 33, width: 66, height: 66))
                c.fill(puck, with: .color(slideInk.opacity(0.3)))
                c.stroke(puck, with: .color(slideInk), lineWidth: 2)
            }
            loop(c, deck: deck)
        }
        crossfader(c, position: state.crossfader)
    }

    static func ring(_ c: GraphicsContext, cx: CGFloat, lit: Color?) {
        let circle = Path(ellipseIn: CGRect(x: cx - 33, y: Layout.transportY - 33, width: 66, height: 66))
        c.fill(circle, with: .color(.black))
        c.stroke(circle, with: .color(lit ?? Ink.hex(0x3A3A42)), lineWidth: lit == nil ? 1 : 2)
    }

    static func loop(_ c: GraphicsContext, deck: ConsoleState.Deck) {
        let x = Layout.transport(deck.id).loop, y = Layout.loopY, on = deck.loop != nil
        let beats = deck.loop?.lengthBeats ?? deck.loopBeats
        let off = Ink.hex(0x3A3A42), grey = Ink.hex(0xA0A0A5)
        var down = c, up = c
        down.opacity *= !deck.loaded || beats <= 1 ? 0.35 : 1
        up.opacity *= !deck.loaded || beats >= 64 ? 0.35 : 1
        down.rect(x, y, 54, 43, rx: 4, fill: .black, stroke: on ? Ink.blue : off)
        down.text("‹", .bold(22, spacing: 0.02), on ? Ink.blue : grey, x: x + 27, y: 787.59)
        c.rect(x + 60, y, 60, 43, rx: 4, fill: on ? Ink.blue : .black, stroke: on ? Ink.blue : off)
        c.text(beats == 0.5 ? "½" : String(Int(beats)), .bold(26, spacing: 0.02), on ? .black : grey, x: x + 90, y: 791.46)
        up.rect(x + 126, y, 54, 43, rx: 4, fill: .black, stroke: on ? Ink.blue : off)
        up.text("›", .bold(22, spacing: 0.02), on ? Ink.blue : grey, x: x + 153, y: 787.59)
    }
}

// MARK: - The platters

/// A platter being scrubbed, drawn again over everything with a soft shadow, so the
/// whole disc shows while the finger is on it (`#lift` in the mockup).
private struct LiftedPlatter: View {
    let deck: ConsoleState.Deck

    var body: some View {
        let rect = Layout.platterRect(deck.id)
        ZStack(alignment: .topLeading) {
            Circle().fill(Color.black.opacity(0.7))
                .frame(width: rect.width, height: rect.height)
                .blur(radius: 8)
                .offset(x: rect.minX, y: rect.minY + 6)
            StageArt(file: .platters)
                .mask(alignment: .topLeading) {
                    Circle().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
            Live(deck: deck) { PlatterMarks(deck: $0) }
                .place(rect)
        }
        .frame(width: Stage.width, height: Layout.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The platter display's marks: forty, nine degrees apart, three dashes each, with a
/// four-mark gap that goes round two beats a turn, as the drawing shows it at the top.
private struct PlatterMarks: View {
    let deck: ConsoleState.Deck

    var body: some View {
        let beat = 60 / (deck.grid?.bpm ?? 120)
        let angle = ((deck.position / beat * 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let first = Int(angle / 9) % 40
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            var marks = Path()
            for index in 0..<40 where (index - first + 40) % 40 >= 4 {
                let turn = Double(index) * 9 * .pi / 180, dx = sin(turn), dy = -cos(turn)
                for (from, to) in [(30.16, 33.28), (35.36, 38.48), (40.56, 44.72)] {
                    marks.move(to: CGPoint(x: centre.x + from * dx, y: centre.y + from * dy))
                    marks.addLine(to: CGPoint(x: centre.x + to * dx, y: centre.y + to * dy))
                }
            }
            context.stroke(marks, with: .color(Color(hex: 0xE4E8ED)), lineWidth: 2.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The platter's touch: dragging round the exposed disc scrubs, two beats a turn;
/// near the centre the angle means nothing.
private struct PlatterTouch: View {
    let deck: ConsoleState.Deck
    let scrub: (String, Scrub) -> Void
    /// Told when a finger lands on the disc and when it lifts.
    let lift: (Bool) -> Void
    @GestureState private var touching = false
    @State private var drag: Drag?

    private struct Drag {
        let start: CGPoint
        let position, period: Double
        var angle: Double?
        var beats = 0.0
    }

    var body: some View {
        Color.clear
            .contentShape(PlatterGrip(deck: deck.id))
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
            .onValueChange(of: touching) { lift($0) }
            .accessibilityHidden(true)
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

// MARK: - The meters

/// CH A · MASTER L R · CH B, lit on the drawing's twelve rungs: green to −15 dBFS, amber
/// to 0, red above, the 2 s hold in white, and the aim marks (−6 for a deck, −3 for
/// the master). CLIP lights while the master has reached 0 dBFS within its hold.
private struct StageMeters: View {
    let fallback: Meters
    static let columns: [(id: String, x: CGFloat, w: CGFloat)] = [("A", 548.46, 7.09), ("L", 586.46, 7.09), ("R", 600.46, 7.09), ("B", 637.75, 8.5)]
    /// The rungs from the foot: top and height in the drawing.
    static let rungs: [(y: CGFloat, h: CGFloat)] = [(639, 14), (624, 13), (608, 14), (592, 14), (577, 13), (561, 14),
                                                     (545, 14), (530, 13), (514, 14), (498, 14), (483, 13), (467, 14)]

    var body: some View {
        LiveMeters(fallback: fallback) { meters in
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var c = context
                    c.translateBy(x: -Layout.origin.x, y: -Layout.origin.y)
                    for column in Self.columns {
                        let lit = MeterLadder.rung(for: meters.level[column.id]), held = MeterLadder.rung(for: meters.hold[column.id])
                        for (index, rung) in Self.rungs.enumerated() {
                            let ink: Color = index <= lit ? Color(hex: index >= MeterLadder.red ? MeterLadder.rungs[index].ink
                                                                    : index >= MeterLadder.amber ? 0xC99A26 : 0x2B9E58)
                                : index == held ? Color(hex: 0xD8D8DD) : Color(hex: 0x121216)
                            c.fill(Path(CGRect(x: column.x, y: rung.y, width: column.w, height: rung.h)), with: .color(ink))
                        }
                        let aim: CGFloat = column.id == "A" || column.id == "B" ? 529 : 513
                        c.fill(Path(CGRect(x: column.x, y: aim, width: column.w, height: 1)), with: .color(Color(hex: 0x8E8E96, opacity: 0.7)))
                    }
                    if meters.masterClipping {
                        c.text("CLIP", Ink.Face(name: "AvenirNext-DemiBold", size: 9, spacing: 0.1), Color(hex: 0xFF6A52),
                               x: 586.16, y: 455.15, middle: false)
                    }
                }
                .allowsHitTesting(false)
                ForEach(Self.columns, id: \.id) { column in
                    let level = meters.level[column.id], clipped = meters.isClipping(column.id)
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(column.id == "A" || column.id == "B" ? "Deck \(column.id) level"
                                            : column.id == "L" ? "Master left" : "Master right")
                        .accessibilityValue((level <= MeterLevels.floor ? "Silent" : String(format: "%.0f dBFS", level))
                                            + (clipped ? ", clipping" : ""))
                        .place(Layout.at(column.x, 466, column.w, 188))
                }
            }
        }
    }
}

// MARK: - Touches

/// The touch areas over the drawing: keys as buttons, and the chips' and faders' frames,
/// which the slider bank routes touches to.
private struct Controls: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let bank: SliderBank

    var body: some View {
        let folded = state.libraryOpen
        ZStack(alignment: .topLeading) {
            ForEach(state.decks, id: \.id) { deck in
                let id = deck.id, keys = Layout.keys(id), k = Layout.key, empty = !deck.loaded
                let isMaster = state.decks.firstIndex(of: deck) == state.masterDeck
                tap("Deck \(id) master tempo", on: deck.keyLock, Layout.at(keys.mt, k.y - 5, k.mtW, k.h + 10)) {
                    actions.deck.toggleKeyLock(id)
                }
                tap("Deck \(id) sync", on: deck.syncLocked, Layout.at(keys.sync, k.y - 5, k.w, k.h + 10)) {
                    actions.deck.toggleSync(id)
                }
                tap("Deck \(id) master", on: isMaster && !empty, Layout.at(keys.master, k.y - 5, k.w, k.h + 10)) {
                    actions.deck.setMaster(id)
                }
                .disabled(empty)
                tap("Deck \(id) hot cues", on: deck.hotCuesOpen, Layout.at(keys.hot, k.y - 5, k.w, k.h + 10)) {
                    actions.deck.toggleHotCues(id)
                }
                .disabled(empty)
                tap("Deck \(id) headphone cue", on: deck.headphoneCue,
                    Layout.at(id == "B" ? Layout.channelCue.b : Layout.channelCue.a, Layout.channelCue.y - 5, k.w, k.h + 10)) {
                    actions.deck.toggleHeadphoneCue(id)
                }
                beatJump(deck)
                ForEach(Self.chips, id: \.0) { role, row in
                    SliderTarget(bank: bank, id: SliderID(id, role), folded: folded, deckName: id)
                        .place(Layout.chip(id, row))
                }
                SliderTarget(bank: bank, id: SliderID(id, .level), folded: folded, deckName: id)
                    .place(Layout.at(Layout.levelX(id) - 33, 441, 66, 205))
                SliderTarget(bank: bank, id: SliderID(id, .tempo), folded: folded, deckName: id)
                    .place(Layout.at(Layout.tempoX(id), 437, Layout.tempo.w, 204))
            }
            SliderTarget(bank: bank, id: SliderID("M", .master), folded: folded, deckName: nil)
                .place(Layout.at(Layout.masterChip.minX, Layout.masterChip.minY, Layout.masterChip.width, Layout.masterChip.height))
            SliderTarget(bank: bank, id: SliderID("M", .cueMix), folded: folded, deckName: nil)
                .place(Layout.chip("A", .foot))
            SliderTarget(bank: bank, id: SliderID("M", .phones), folded: folded, deckName: nil)
                .place(Layout.chip("B", .foot))
            tap("Lock lows", on: state.linkLows, Layout.at(Layout.lockLows.x, Layout.lockLows.y - 5, Layout.key.w, Layout.key.h + 10),
                action: actions.toggleLinkLows)
        }
    }

    static let chips: [(SliderRole, Layout.Row)] = [(.trim, .trim), (.hi, .hi), (.mid, .mid), (.low, .low), (.fx, .fx)]

    private func tap(_ label: String, on: Bool, _ rect: CGRect, action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(on ? "On" : "Off")
            .place(rect)
    }

    @ViewBuilder private func beatJump(_ deck: ConsoleState.Deck) -> some View {
        let x = Layout.jump(deck.id), y = Layout.jumpY, off = !deck.loaded || deck.grid == nil
        Group {
            tap("Deck \(deck.id) jump back", on: false, Layout.at(x, y, 44, 44)) { actions.deck.beatJump(deck.id, -1) }
            ForEach(Array(Layout.jumps.enumerated()), id: \.offset) { index, bars in
                tap("Deck \(deck.id) jump \(bars) bars", on: bars == deck.jumpBars, Layout.at(x + 49 + CGFloat(index) * 44, y, 43, 44)) {
                    actions.deck.setJumpBars(deck.id, bars)
                }
            }
            tap("Deck \(deck.id) jump forward", on: false, Layout.at(x + 230, y, 44, 44)) { actions.deck.beatJump(deck.id, 1) }
        }
        .disabled(off)
    }
}

/// A chip's or fader's place for the slider bank, which takes its touches. It draws
/// nothing (the canvas does) and holds no gesture; the stage routes by frame.
private struct SliderTarget: View {
    let bank: SliderBank
    let id: SliderID
    let folded: Bool
    let deckName: String?

    var body: some View {
        let spec = bank.controls[id]?.spec
        Color.clear
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(sliderStageSpace))
            } action: { frame in
                if !folded { bank.setFrame(frame, for: id) }
            }
            .onChange(of: folded) { _, folded in
                if folded { bank.removeFrame(id) }
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel((deckName.map { "Deck \($0) " } ?? "") + (spec?.title ?? id.role.title))
            .accessibilityValue(spec?.readout(bank.value(id)) ?? "")
            .accessibilityAdjustableAction { direction in
                guard let spec else { return }
                let step = spec.step.map { max($0, spec.span / 50) } ?? spec.span / 50
                let value = bank.value(id) + (direction == .increment ? step : -step) * (spec.invert ? -1 : 1)
                bank.setValue(value, for: id)
                bank.onChange?(id, bank.value(id))
            }
    }
}

/// CUE, PLAY, the loop and the crossfader: they stay while the library is open.
private struct Transport: View {
    let state: ConsoleState
    let actions: ConsoleActions
    @Binding var slides: [String: CueSlide]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.decks, id: \.id) { deck in
                TransportKeys(deck: deck, actions: actions.deck, slide: $slides[deck.id])
            }
            Crossfader(position: state.crossfader, set: actions.setCrossfader)
                .place(Layout.at(Layout.crossfader.x - 6, 750, Layout.crossfader.w + 12, 64))
        }
    }
}

/// A finger holding CUE: its x in the drawing, and whether it has reached PLAY.
struct CueSlide: Equatable {
    var x: CGFloat
    var latched = false
}

private struct TransportKeys: View {
    let deck: ConsoleState.Deck
    let actions: DeckActions
    @Binding var slide: CueSlide?

    var body: some View {
        let p = Layout.transport(deck.id), cy = Layout.transportY, empty = !deck.loaded
        let on = deck.loop != nil, beats = deck.loop?.lengthBeats ?? deck.loopBeats
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Circle())
                .press(enabled: !empty, down: {
                    slide = CueSlide(x: p.cue)
                    actions.cueDown(deck.id)
                }, moved: latchCue) { point in
                    if let point { latchCue(point) }
                    slide = nil
                    actions.cueUp(deck.id)
                }
                .accessibilityLabel("Deck \(deck.id) cue")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.cueDown(deck.id); actions.cueUp(deck.id) }
                .place(Layout.at(p.cue - 33, cy - 33, 66, 66))
            Color.clear.contentShape(Circle())
                // PLAY is play/pause, on the press itself, as on a deck: the drop lands
                // where the finger lands, not where it lifts. A second finger here while the
                // first holds CUE keeps the preview playing instead.
                .press(enabled: !empty, down: {
                    if !actions.continueCue(deck.id) { actions.togglePlay(deck.id) }
                }) { _ in }
                .accessibilityLabel("Deck \(deck.id) \(deck.playing && !deck.previewing ? "pause" : "play")")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.togglePlay(deck.id) }
                .place(Layout.at(p.play - 33, cy - 33, 66, 66))
            key("Deck \(deck.id) halve loop", Layout.at(p.loop, Layout.loopY - 0.5, 54, 44), disabled: empty || beats <= 1) {
                actions.stepLoop(deck.id, -1)
            }
            key("Deck \(deck.id) loop \(beats == 0.5 ? "half" : String(Int(beats))) beats", Layout.at(p.loop + 60, Layout.loopY - 0.5, 60, 44),
                disabled: empty) { actions.toggleLoop(deck.id) }
                .accessibilityValue(on ? "On" : "Off")
            key("Deck \(deck.id) double loop", Layout.at(p.loop + 126, Layout.loopY - 0.5, 54, 44), disabled: empty || beats >= 64) {
                actions.stepLoop(deck.id, 1)
            }
        }
    }

    private func key(_ label: String, _ rect: CGRect, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(label)
            .place(rect)
    }

    /// Sliding off CUE onto PLAY keeps the preview playing. PLAY's centre is 74 pt right
    /// of CUE's, the same size, so in CUE's units it spans 74 … 140 / 66.
    private func latchCue(_ point: CGPoint) {
        let cue = Layout.transport(deck.id).cue
        let left = (Layout.transport(deck.id).play - cue) / 66
        var next = slide ?? CueSlide(x: cue)
        next.x = cue - 33 + point.x * 66
        if point.x >= left, point.x <= left + 1, (0...1).contains(point.y) {
            _ = actions.continueCue(deck.id)
            next.latched = true
        }
        if next != slide { slide = next }
    }
}

/// The crossfader: the cap goes where the finger is, as on a mixer.
private struct Crossfader: View {
    let position: Double
    let set: (Double) -> Void

    var body: some View {
        let x = Layout.crossfader
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                // The view starts 6 pt left of the track.
                let along = gesture.location.x - 6 - x.half
                set(min(1, max(0, Double(along / (x.w - 2 * x.half)))))
            })
            .accessibilityElement()
            .accessibilityLabel("Crossfader")
            .accessibilityValue("\(Int((position * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                set(min(1, max(0, position + (direction == .increment ? 0.05 : -0.05))))
            }
    }
}

// MARK: - The bank and the console

/// Keeps the slider bank and the console in step: the console's values into the bank,
/// except where a finger holds the control, and the bank's changes out as actions. The
/// meters feed the panels' rungs.
private struct BankSync: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let bank: SliderBank

    var body: some View {
        LiveMeters(fallback: state.meters) { meters in
            Color.clear.onValueChange(of: meters) { meters in feed(meters) }
        }
        .onAppear { sync(); feed(state.meters) }
        .onValueChange(of: state) { _ in sync() }
        .onValueChange(of: effects) { _ in sync() }
    }

    /// Each deck's chosen effect, so taking FILTER back gives the filter its place again.
    private var effects: [String] {
        state.decks.map { bank.controls[SliderID($0.id, .fx)]?.spec.effect?.rawValue ?? "filter" }
    }

    private func feed(_ meters: Meters) {
        bank.meters = [
            .deckA: MeterValue(level: meters.level.a, hold: meters.hold.a),
            .deckB: MeterValue(level: meters.level.b, hold: meters.hold.b),
            .masterL: MeterValue(level: meters.level.l, hold: meters.hold.l),
            .masterR: MeterValue(level: meters.level.r, hold: meters.hold.r)
        ]
    }

    private func sync() {
        for deck in state.decks {
            let id = deck.id
            put(SliderID(id, .trim), .trim(deck: id, auto: deck.autoTrimDb ?? 0), deck.trimDb)
            put(SliderID(id, .hi), .eq(deck: id), deck.eq.high)
            put(SliderID(id, .mid), .eq(deck: id), deck.eq.mid)
            put(SliderID(id, .low), .eq(deck: id), deck.eq.low)
            let fx = SliderID(id, .fx), effect = bank.controls[fx]?.spec.effect ?? .filter
            // Only FILTER makes a sound yet; another effect's amount lives in the bank alone.
            put(fx, .fx(deck: id, effect: effect), effect == .filter ? deck.filter * 100 : nil)
            put(SliderID(id, .level), .level(deck: id), deck.level, fader: true)
            put(SliderID(id, .tempo), .tempo(bpm: deck.grid?.bpm ?? 120), (deck.rate - 1) * 100, fader: true)
        }
        // The engine's blend runs from the master (0) to the cue (1); the chip from CUE to MST.
        put(SliderID("M", .cueMix), .cueMix(), 1 - state.cueMix)
        put(SliderID("M", .phones), .phones(), state.phones)
        put(SliderID("M", .master), .master(), state.masterVolume)
        if state.decks.contains(where: { bank.controls[SliderID($0.id, .fx)]?.spec.effect != .filter }) {
            // Leaving FILTER for an effect with no sound yet: the filter goes back to off.
            for deck in state.decks where bank.controls[SliderID(deck.id, .fx)]?.spec.effect != .filter && deck.filter != 0 {
                actions.deck.setFilter(deck.id, 0)
            }
        }
        let actions = actions
        bank.onChange = { [weak bank] id, value in
            switch id.role {
            case .trim: actions.deck.setTrim(id.deck, value)
            case .hi: actions.deck.setFader(id.deck, "high", value)
            case .mid: actions.deck.setFader(id.deck, "mid", value)
            case .low: actions.deck.setFader(id.deck, "low", value)
            case .fx:
                if bank?.controls[id]?.spec.effect == .filter { actions.deck.setFilter(id.deck, value / 100) }
            case .level: actions.deck.setFader(id.deck, "level", value)
            case .tempo: actions.deck.setTempo(id.deck, 1 + value / 100)
            case .cueMix: actions.setCueMix(1 - value)
            case .phones: actions.setPhones(value)
            case .master: actions.setMasterVolume(value)
            }
        }
    }

    /// Adds the control, or brings its spec and (unless it's held) its value up to date.
    private func put(_ id: SliderID, _ spec: SliderSpec, _ value: Double?, fader: Bool = false) {
        guard let control = bank.controls[id] else {
            if fader { bank.addFader(id, spec: spec, value: value ?? 0) } else { bank.add(id, spec: spec, value: value ?? 0) }
            return
        }
        if control.spec != spec { bank.setSpec(spec, for: id) }
        if let value, !bank.isTouched(id), abs(control.value - spec.snap(spec.clamp(value))) > 1e-9 {
            bank.setValue(value, for: id)
        }
    }
}
