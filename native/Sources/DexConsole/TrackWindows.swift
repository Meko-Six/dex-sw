import SwiftUI
import UniformTypeIdentifiers

/// The two CDJ-style track windows under the lanes. Ports `Info` and
/// `TrackWindow` in `src/renderer/console/Band.tsx` and the `.zcard` rules.
struct TrackWindows: View {
    let state: ConsoleState
    let actions: ConsoleActions

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(state.decks.enumerated()), id: \.element.id) { index, deck in
                TrackWindow(deck: deck, isMaster: index == state.masterDeck, art: art(deck),
                            drop: state.drop?.deck == deck.id ? state.drop?.label : nil,
                            dragged: state.library.track(state.library.selected)?.name, actions: actions)
            }
        }
        // Library open: the windows ride up under the header, 4 pt lower in a taller band.
        .padding(.top, state.libraryOpen ? 6 : 2).padding(.horizontal, 8).padding(.bottom, 6)
        .frame(width: Stage.width, height: state.libraryOpen ? 148 : 144, alignment: .top)
        .background(Color(hex: 0x060607))
    }

    /// The cover while a library row is picked: load here, already here, or playing.
    private func art(_ deck: ConsoleState.Deck) -> ArtState {
        guard state.libraryOpen, let selected = state.library.selected else { return .idle }
        return selected == deck.trackID ? .loaded : deck.playing ? .blocked : .armed
    }
}

enum ArtState { case idle, armed, blocked, loaded }

private struct TrackWindow: View {
    let deck: ConsoleState.Deck
    let isMaster: Bool
    let art: ArtState
    /// What a file or library row held over this deck would bring.
    let drop: String?
    /// The library row picked, which is the one a drag carries.
    let dragged: String?
    let actions: ConsoleActions
    @Environment(\.consoleSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(deck: deck) { actions.library.setOpen(true) }
            HStack(spacing: 0) {
                Cover(deck: deck, state: art) { actions.tapArt(deck.id) }
                    .frame(width: 98, height: 98).padding(.leading, 8)
                VStack(spacing: 0) {
                    Live(deck: deck) { deck in
                        Readouts(deck: deck, isMaster: isMaster).frame(height: 50)
                        Overview(deck: deck, seek: actions.deck.seek).frame(height: 56)
                    }
                }
                .padding(.top, 2).padding(.bottom, 2).padding(.leading, 10).padding(.trailing, 8)
            }
            .frame(height: 110)
        }
        .frame(width: 574, height: 134, alignment: .top)
        .padding(1)
        .box(fill: Color(hex: 0x050506), border: Color(hex: 0x2A2A2E), radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay { if let drop { DropCover(deck: deck, label: drop).padding(1) } }
        .live(snapshot) { $0.onDrop(of: [.audio, .plainText], delegate: DeckDrop(deck: deck, row: dragged, actions: actions)) }
    }
}

/// `.ztitle`: deck letter, ♪, title and artist on the title-bar blue.
private struct TitleBar: View {
    let deck: ConsoleState.Deck
    /// An empty deck's name opens the library.
    let browse: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(deck.id, .cond(18)).foregroundStyle(Color.black)
                .frame(width: 23, height: 23).background(Palette.accent(deck.id))
            NoteIcon(height: 16).foregroundStyle(Color(hex: 0xDFE9F3))
            Text(deck.loading ? "Loading…" : deck.loaded ? deck.title : "No track loaded")
                .font(Face.ui(18, medium: true).font).foregroundStyle(deck.loaded ? Color(hex: 0xF2F5F8) : Color(hex: 0x74747B))
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                .onTapGesture { if !deck.loaded { browse() } }
            Text(deck.loaded ? deck.artist : "").font(Face.ui(14).font).foregroundStyle(Color(hex: 0x8EA4B8))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .frame(height: 23, alignment: .leading)
        .background(Color(hex: 0x17324A))
        .overlay(alignment: .bottom) { Color.black.frame(height: 1).offset(y: 1) }
        .frame(height: 24, alignment: .top)
    }
}

private extension ConsoleState.Deck {
    var hasCover: Bool { if case .cover? = art { true } else { false } }
}

/// `.zart`: the cover, which is also the load target.
private struct Cover: View {
    let deck: ConsoleState.Deck
    let state: ArtState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                switch deck.art {
                case .split(let first, let second)?:
                    LinearGradient(stops: [.init(color: Color(hex: first), location: 0), .init(color: Color(hex: first), location: 0.55),
                                           .init(color: Color(hex: second), location: 0.55), .init(color: Color(hex: second), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                case .cover(let cover)?:
                    Image(decorative: cover.image, scale: 1).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                case nil:
                    Color(hex: 0x151517)
                }
                if !deck.hasCover {
                    NoteIcon(height: 30).foregroundStyle(Color.white.opacity(0.28)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // letter-spacing and text-indent .22em centre the word on its letters.
                Label(state == .blocked ? "PLAYING" : state == .loaded ? "LOADED" : "LOAD", .cond(8.5, tracking: 1.87)).padding(.leading, 1.87)
                    .foregroundStyle(state == .armed ? Color.black : state == .blocked ? Color(hex: 0xFFB45E)
                                     : state == .loaded ? Color(hex: 0x74747B) : Color(hex: 0xE9E9EC))
                    .frame(maxWidth: .infinity).frame(height: 16.5)
                    .background(state == .armed ? Palette.accent(deck.id) : Color.black.opacity(0.7))
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            // `.zart.armed`: a 2 pt ring outside the cover.
            .overlay { if state == .armed { RoundedRectangle(cornerRadius: 4).inset(by: -1).stroke(Palette.accent(deck.id), lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(deck.loaded ? "Deck \(deck.id) cover" : "Open the library to load deck \(deck.id)")
    }
}

/// `.zreads`: five fixed columns keep each readout in the same place on both decks.
private struct Readouts: View {
    let deck: ConsoleState.Deck
    let isMaster: Bool

    private let heading = Face.ui(9, tracking: 0.55, medium: true)
    private let digits = Color(hex: 0xDCE1E5)

    var body: some View {
        let empty = !deck.loaded
        let length = deck.durationSec
        let left = empty ? (whole: "--:--", ms: "---") : remain(length - deck.position)
        let elapsed = empty ? "--:--" : clock(deck.position, padMinutes: true)
        let total = empty ? "--:--" : clock(length, padMinutes: true)
        let tempo = empty ? (sign: "+", digits: "0.00") : tempoParts(deck.rate)
        let dark = Color(hex: 0x4A4A50)
        let timeFace = Face.ui(17 * min(1, 5 / CGFloat(max(elapsed.count, total.count))), medium: true, tabular: true)
        let remainScale = min(1, 7.25 / (CGFloat(left.whole.count) + 2.25))
        ZStack(alignment: .topLeading) {
            readoutHeading("TIME", x: 0)
            readoutHeading("REMAIN", x: 57)
            readoutHeading("TEMPO", x: 231)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                // Pin the shared baseline 46 pt below the top of the readout.
                Color.clear.frame(width: 0, height: 46)
                    .alignmentGuide(.lastTextBaseline) { $0.height }
                VStack(alignment: .leading, spacing: 0) {
                    Label(elapsed, timeFace).foregroundStyle(empty ? dark : .white).frame(height: 17)
                    Label(total, timeFace).foregroundStyle(empty ? dark : Color(hex: 0x888888)).frame(height: 17)
                }
                .frame(width: 57, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Label(left.whole, .ui(40 * remainScale, tabular: true))
                    Label("." + left.ms, .ui(30 * remainScale, tabular: true))
                }
                .foregroundStyle(empty ? dark : digits)
                .frame(width: 174, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Label(tempo.sign + tempo.digits, .ui(30, tabular: true))
                    Label("%", .ui(12))
                }
                .foregroundStyle(empty ? dark : digits)
            }
            KeyStack(keyLock: deck.keyLock && !empty, camelot: empty ? "—" : deck.camelot ?? "—",
                     colour: empty ? nil : camelotColour(deck.camelot), empty: empty)
                .frame(width: 34).offset(x: 341, y: 3)
            BPMBox(deck: deck, role: empty ? .none : isMaster ? .master : deck.syncLocked ? .sync : .none)
                .frame(width: 71, height: 46).offset(x: 379, y: 2)
        }
        .frame(width: 450, height: 50, alignment: .topLeading)
    }

    private func readoutHeading(_ title: String, x: CGFloat) -> some View {
        Label(title, heading).foregroundStyle(Palette.text).frame(height: 10).offset(x: x, y: 1)
    }
}

/// `.zkey`: the KEY chip (hidden when off) over the Camelot key.
private struct KeyStack: View {
    let keyLock: Bool
    let camelot: String
    let colour: Color?
    /// `.zcard.empty .cam`: an outline, no key.
    var empty = false

    var body: some View {
        VStack(spacing: 3) {
            Label("KEY", .cond(15))
                .foregroundStyle(Palette.blue)
                .frame(maxWidth: .infinity).frame(height: 21)
                .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 0.625).stroke(Palette.blue, lineWidth: 1.25))
                .opacity(keyLock ? 1 : 0)
            Label(camelot, .cond(14, weight: .heavy)).foregroundStyle(empty ? Color(hex: 0x74747B) : Color(hex: 0x0B0913))
                .frame(maxWidth: .infinity).frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 2).fill(empty ? .clear : colour ?? Color(hex: 0x74747B)))
                .overlay { if empty { RoundedRectangle(cornerRadius: 2).inset(by: 1).stroke(Color(hex: 0x3A3A40), lineWidth: 2) } }
        }
    }
}

/// `.zbpm`: the played BPM, framed red for MASTER or blue for SYNC.
private struct BPMBox: View {
    enum Role { case master, sync, none }
    let deck: ConsoleState.Deck
    let role: Role

    var body: some View {
        let colour = !deck.loaded ? Color(hex: 0x3E3E44) : role == .master ? Color(hex: 0xFF4A3D) : role == .sync ? Color(hex: 0x8FCAFF) : Color(hex: 0xE4E4E8)
        let parts = !deck.loaded ? ("---", "-") : deck.grid.map { bpmParts($0.bpm * deck.rate) } ?? ("—", "")
        let whole = Face.ui(26, tracking: -0.26, tabular: true), tenth = Face.ui(16, tracking: -0.26, tabular: true)
        let textWidth = whole.width(of: parts.0) + (parts.1.isEmpty ? 0 : tenth.width(of: "." + parts.1))
        GeometryReader { geometry in
            let inner = geometry.size.width - 2
            // The grid's column is as wide as the BPM line (its min-content)
            // even when that overflows the box: the line then starts at its
            // padding, and the role strip centres in the wider column.
            let column = max(inner, textWidth + 16)
            let x = column - 8 - textWidth
            ZStack(alignment: .topLeading) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Label(parts.0, whole)
                    if !parts.1.isEmpty { Label("." + parts.1, tenth) }
                }
                .foregroundStyle(colour)
                .frame(height: 26).offset(x: x, y: 3.5)
                Label(role == .master ? "MASTER" : role == .sync ? "SYNC" : "", .cond(9, tracking: 1.44))
                    .padding(.leading, 1.44)
                    .foregroundStyle(role == .master ? Color.black : role == .sync ? Color.black : colour)
                    .frame(height: 11).padding(.top, 2)
                    .frame(width: column, height: 13)
                    .background(role == .master ? Palette.red : role == .sync ? Palette.blue : .clear)
                    .offset(y: 31)
            }
            .frame(width: inner, height: 44, alignment: .topLeading)
            .clipped()
            .offset(x: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(colour, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// `.zfull`: hot cue flags, the one-sided overview with the loop, the
/// progress bar and minute ticks, and a line from each flag to the bar.
/// Touch or drag along it to seek.
private struct Overview: View {
    let deck: ConsoleState.Deck
    let seek: (String, Double) -> Void
    @Environment(\.displayScale) private var scale
    @State private var lastSeek = -1.0

    var body: some View {
        let length = deck.durationSec
        // The demo works the played share out from whole seconds, as the mockup does.
        let played = length > 0 ? min(1, max(0, (deck.wave.map { if case .demo = $0 { floor(deck.position) } else { deck.position } } ?? deck.position) / length)) : 0
        let width: CGFloat = 450
        let at = { (seconds: Double) -> CGFloat in (seconds / length * 100 * 100).rounded() / 100 / 100 * width }
        let cues = length > 0 ? deck.hotCues.enumerated().compactMap { slot, seconds in seconds.map { (slot, $0) } } : []
        let cuePoint: Double? = deck.loaded && deck.cuePoint > 0.05 ? deck.cuePoint : nil
        ZStack(alignment: .topLeading) {
            switch deck.wave {
            case .demo(let seed)?:
                let demo = DemoWave.cached(count: 600, seed: seed + 3, oneSided: true)
                Canvas { context, size in demo.draw(in: context, rect: CGRect(origin: .zero, size: size)) }
                    .frame(width: width, height: 36).offset(y: 10)
            case .track(let data)?:
                TrackWave(data: data, start: 0, span: length, oneSided: true).equatable().frame(width: width, height: 36).offset(y: 10)
            case nil:
                EmptyView()
            }
            if let grid = deck.grid, let loop = deck.loop, length > 0 {
                let start = grid.time(atBeat: loop.startBeat)
                let box = snap(CGRect(x: at(start), y: 10, width: max(2, at(loop.lengthBeats * grid.period)), height: 36), scale)
                Color(.sRGB, red: 1, green: 211 / 255, blue: 40 / 255, opacity: 0.25)
                    .overlay(alignment: .leading) { Color(hex: 0xFFD328).frame(width: 1) }
                    .overlay(alignment: .trailing) { Color(hex: 0xFFD328).frame(width: 1) }
                    .frame(width: box.width, height: 36).offset(x: box.minX, y: 10)
            }
            if !deck.loaded {
                Label("TAP THE ART TO LOAD, OR DROP A FILE HERE", .cond(9, tracking: 1.62)).padding(.leading, 1.62)
                    .foregroundStyle(Color(hex: 0x74747B)).frame(width: width, height: 36).offset(y: 10)
            }
            // .zbar: a framed bar filled from the playhead to the end.
            Color(hex: 0x1A1A1D)
                .overlay(alignment: .trailing) {
                    if deck.loaded {
                        Color(hex: 0xE8E8EC).frame(width: snap(448 - (played * 100 * 100).rounded() / 100 / 100 * 448, scale))
                    }
                }
                .padding(1)
                .box(fill: .clear, border: Color(hex: 0x55555C), radius: 0)
                .frame(width: width, height: 5).offset(y: 46)
            if length > 0 {
                let step: Double = length > 240 ? 60 : 15
                ForEach(1..<(Int(length / step) + 1), id: \.self) { index in
                    Color(hex: 0xCFCFD4).frame(width: 1, height: 4).offset(x: snap(at(Double(index) * step), scale), y: 52)
                }
            }
            ForEach(cues, id: \.0) { slot, seconds in
                let colour = Color(hex: hotCueColours[slot])
                let x = snap(at(seconds), scale)
                colour.opacity(0.85).frame(width: 1, height: 31).offset(x: x, y: 15)
                Label(String(slot + 1), .ui(9, medium: true)).foregroundStyle(Color(hex: 0x0B0913))
                    .frame(width: 13, height: 11).background(colour).offset(x: x - 6, y: 4)
            }
            if let cuePoint {
                CueFlag().offset(x: snap(at(cuePoint) - 4, scale), y: 2)
                Palette.red.opacity(0.85).frame(width: 1, height: 37).offset(x: snap(at(cuePoint), scale), y: 9)
            }
            if length > 0 {
                Color.white.frame(width: 2, height: 47).offset(x: snap((played * 100 * 100).rounded() / 100 / 100 * width - 1, scale), y: 9)
            }
        }
        .frame(width: width, height: 56, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                // Seeks reschedule a playing deck, so a drag sends at most 25 a second.
                let time = ProcessInfo.processInfo.systemUptime
                guard deck.loaded, length > 0, time - lastSeek >= 0.04 else { return }
                lastSeek = time
                seek(deck.id, min(1, max(0, gesture.location.x / width)) * length)
            }
            .onEnded { gesture in
                lastSeek = -1
                guard deck.loaded, length > 0 else { return }
                seek(deck.id, min(1, max(0, gesture.location.x / width)) * length)
            })
    }
}

/// The memory CUE marker retains its triangle.
private struct CueFlag: View {
    var body: some View {
        Path { path in
            path.move(to: .zero); path.addLine(to: CGPoint(x: 8, y: 0)); path.addLine(to: CGPoint(x: 4, y: 5)); path.closeSubpath()
        }
        .fill(Palette.red).frame(width: 8, height: 5)
    }
}

/// `remain()` in format.ts: "01:12" and "418".
func remain(_ seconds: Double) -> (whole: String, ms: String) {
    let millis = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded(.down))
    let secs = millis / 1000
    return (String(format: "%02d:%02d", secs / 60, secs % 60), String(format: "%03d", millis % 1000))
}

/// `clock()` in format.ts: "5:11".
func clock(_ seconds: Double, padMinutes: Bool = false) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
    return String(format: padMinutes ? "%02d:%02d" : "%d:%02d", total / 60, total % 60)
}

/// `tempo()` in format.ts: "+" / "−" and "2.31".
func tempoParts(_ rate: Double) -> (sign: String, digits: String) {
    let percent = ((rate - 1) * 10000).rounded() / 100
    return (percent < 0 ? "−" : "+", String(format: "%.2f", abs(percent)))
}

/// `bpmParts()` in format.ts: "133.0" as ("133", "0").
func bpmParts(_ bpm: Double) -> (String, String) {
    let text = String(format: "%.1f", bpm)
    let parts = text.split(separator: ".")
    return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
}
