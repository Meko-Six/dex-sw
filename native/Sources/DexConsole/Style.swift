import CoreText
import SwiftUI

/// The console's colours and type, ported from `mockup/console.css`. CSS px
/// are stage points one for one; letter-spacing is tracking in points.
extension Color {
    /// An sRGB colour from 0xRRGGBB, as written in the stylesheet.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

enum Palette {
    static let stage = Color(hex: 0x0C0C0D)
    static let text = Color(hex: 0xF2F2F4)
    static let silk = Color(hex: 0x8F8F96)
    static let led = Color(hex: 0xFF8A00)
    static let green = Color(hex: 0x35D06B)
    static let red = Color(hex: 0xE8402F)
    /// The outlined keys: DONE and CLOSE in green, (i) and the library's in yellow-green.
    static let outlineGreen = Color(hex: 0x49BA60)
    static let outlineYellow = Color(hex: 0xDBE22D)
    static let removeRed = Color(hex: 0xFF5A4A)
    /// `--a` and `--blue`: deck A, selected rows, the sidebar, the jump length.
    static let blueHex: UInt32 = 0x276FFF
    static let blue = Color(hex: blueHex)
    /// Library text: the bright and the darker grey.
    static let rowText = Color(hex: 0xF2F4F3)
    static let rowDim = Color(hex: 0x8E9194)
    static let playing = Color(hex: 0x91CA53)
    /// `--a` / `--b`: each deck's colour.
    static func accent(_ deck: String) -> Color { deck == "B" ? Color(hex: 0xFF8A1F) : blue }
}

enum Type {
    /// `--font-ui`: Helvetica Neue.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("HelveticaNeue", fixedSize: size).weight(weight)
    }
}

/// A label face: PostScript name, size, CSS letter-spacing in points and
/// `font-variant-numeric: tabular-nums`.
struct Face: Hashable {
    let name: String
    let size: CGFloat
    var tracking: CGFloat = 0
    var tabular = false

    /// `--font-cond`, the label and readout face: Avenir Next Condensed, a
    /// system font on macOS and iPadOS. CSS weights 400/500/600/700/800 map to its cuts.
    enum Weight: String { case regular = "Regular", medium = "Medium", demi = "DemiBold", bold = "Bold", heavy = "Heavy" }
    /// `--font-avenir`: the wide cut, for the track details in MORE.
    static func avenir(_ size: CGFloat, weight: Weight = .medium) -> Face {
        Face(name: "AvenirNext-" + weight.rawValue, size: size)
    }
    static func cond(_ size: CGFloat, tracking: CGFloat = 0, weight: Weight = .bold, tabular: Bool = false) -> Face {
        Face(name: "AvenirNextCondensed-" + weight.rawValue, size: size, tracking: tracking, tabular: tabular)
    }
    /// `--font-ui`: Helvetica Neue, regular, medium or bold (CSS 400 / 500 / 600 and up).
    static func ui(_ size: CGFloat, tracking: CGFloat = 0, medium: Bool = false, bold: Bool = false, tabular: Bool = false) -> Face {
        Face(name: bold ? "HelveticaNeue-Bold" : medium ? "HelveticaNeue-Medium" : "HelveticaNeue", size: size, tracking: tracking, tabular: tabular)
    }
    var font: Font { tabular ? Font.custom(name, fixedSize: size).monospacedDigit() : .custom(name, fixedSize: size) }

    /// The width Chromium lays the text out at: CoreText's fractional advance,
    /// trailing letter-spacing included. SwiftUI rounds text sizes up to whole
    /// points, which drifts a row of labels by a point per item.
    func width(of text: String) -> CGFloat {
        var font = CTFontCreateWithName(name as CFString, size, nil)
        if tabular {
            let feature: [CFString: Any] = [kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                                            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
            font = CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
        }
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking
        ])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
    }
}

/// Text laid out at its exact CSS width (see `Face.width(of:)`).
struct Label: View {
    let text: String
    let face: Face

    init(_ text: String, _ face: Face) { self.text = text; self.face = face }

    var body: some View {
        Text(text).font(face.font).tracking(face.tracking).lineLimit(1).fixedSize()
            .frame(width: face.width(of: text))
    }
}

/// `icons/music.note.svg`, the app's music note, scaled to fit its frame.
struct NoteShape: Shape {
    static let size = CGSize(width: 15.01, height: 24.75)
    private static let path: Path = {
        // M, c and l, implicitly repeated: all the file uses.
        let d = "M9.06,19.71c-.01,1.12-.28,1.7-1,2.55-.28.33-.56.65-.91.92-1.18.91-2.49,1.42-4,1.27-.7-.07-1.38-.39-1.92-.81-1.15-.9-1.2-2.51-.44-3.8.27-.46.64-.83,1.03-1.21,1.16-1.16,3.06-1.84,4.66-1.5.41.09.77.23,1.18.37l.06-.91.06-8.37.05-5.64.05-1.99c.09-.19.41-.33.59-.29.8.19.59,1.02,1.03,2.01.32.7.76,1.29,1.27,1.85l1.56,1.73c2.06,2.27,3.04,5.14,1.89,8.1-.29.74-.65,1.42-1.3,1.89-.21.1-.65-.13-.66-.36.12-.47.33-.88.48-1.34.29-.87.44-1.75.32-2.67-.2-1.49-.94-2.87-2.11-3.81-.54-.43-1.14-.71-1.79-1.01l-.05,7.32-.06,5.72Z"
        var path = Path(), command: Character = "M", values: [CGFloat] = [], point = CGPoint.zero
        func run() {
            if command == "M", values.count >= 2 { point = CGPoint(x: values[0], y: values[1]); path.move(to: point); values.removeFirst(2) }
            while command == "l", values.count >= 2 {
                point = CGPoint(x: point.x + values[0], y: point.y + values[1]); path.addLine(to: point); values.removeFirst(2)
            }
            while command == "c", values.count >= 6 {
                let end = CGPoint(x: point.x + values[4], y: point.y + values[5])
                path.addCurve(to: end, control1: CGPoint(x: point.x + values[0], y: point.y + values[1]),
                              control2: CGPoint(x: point.x + values[2], y: point.y + values[3]))
                point = end; values.removeFirst(6)
            }
        }
        var number = ""
        func flush() { if let value = Double(number) { values.append(CGFloat(value)) }; number = "" }
        for character in d {
            if character.isLetter { flush(); run(); command = character; if character == "Z" { path.closeSubpath() } }
            else if character == "," { flush() }
            else if character == "-" { flush(); number = "-" }
            else if character == ".", number.contains(".") { flush(); number = "." }
            else { number.append(character) }
        }
        return path
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.size.width, rect.height / Self.size.height)
        return Self.path.applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - Self.size.width * scale / 2, dy: rect.midY - Self.size.height * scale / 2)
    }
}

/// The music note, `height` points tall in the current foreground colour.
struct NoteIcon: View {
    let height: CGFloat
    var body: some View {
        NoteShape().frame(width: height * NoteShape.size.width / NoteShape.size.height, height: height)
    }
}

/// `HOT_CUE_COLOURS` in `src/shared/hot-cue.ts`, by slot.
let hotCueColours: [UInt32] = [0x38A8FF, 0x35D06B, 0xFFB020, 0xFF5D8F, 0xB06CFF, 0x22D3EE, 0xFF8A1F, 0xD9E86A]

/// `CAMELOT_COLOURS` in `src/shared/camelot.ts`: minor (A) and major (B) per wheel number.
func camelotColour(_ code: String?) -> Color? {
    let table: [UInt32] = [0x56F1DA, 0x00E3C2, 0x7DF2AA, 0x3FE58A, 0xAEF589, 0x86EC4F, 0xE8EA8A, 0xDADF3F,
                           0xFDCF91, 0xFFB04E, 0xFDAFA0, 0xFF8B74, 0xFDA7C8, 0xFF7AAE, 0xF0A9EC, 0xE877E4,
                           0xD2B0FB, 0xB98CFF, 0xB5BBFD, 0x8F99FF, 0x9CCFFD, 0x6DB7FF, 0x84E6F6, 0x4AD6F0]
    guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), let ring = code.last,
          ring == "A" || ring == "B", let number = Int(code.dropLast()), (1...12).contains(number) else { return nil }
    return Color(hex: table[(number - 1) * 2 + (ring == "A" ? 0 : 1)])
}

/// Chromium paints CSS boxes snapped to whole device pixels: each edge rounds
/// to the nearest pixel. Overlays placed at fractional percentages must snap
/// the same way, or they anti-alias across two pixels where Chromium is crisp.
func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
func snap(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
    let x = snap(rect.minX, scale), y = snap(rect.minY, scale)
    return CGRect(x: x, y: y, width: snap(rect.maxX, scale) - x, height: snap(rect.maxY, scale) - y)
}

/// CSS `color-mix(in srgb, a p%, b)`.
func mix(_ a: UInt32, _ fraction: Double, _ b: UInt32) -> Color {
    func channel(_ shift: UInt32) -> Double {
        (Double(a >> shift & 0xFF) * fraction + Double(b >> shift & 0xFF) * (1 - fraction)) / 255
    }
    return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0))
}

extension View {
    /// A CSS box: fill, 1 pt inside border and corner radius.
    func box(fill: Color, border: Color, radius: CGFloat, width: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).inset(by: width / 2).stroke(border, lineWidth: width))
    }
}

extension Face {
    var ctFont: CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    /// The height SwiftUI gives one line of this face.
    var naturalLine: CGFloat {
        let font = ctFont
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }
}

/// Running text as CSS lays it out: words broken greedily at spaces (the
/// system's own wrapping keeps a lone last word off its line, Chromium does
/// not) on line boxes of `lineHeight` × the size, each line drawn whole so
/// it keeps its kerning.
struct Para: View {
    /// A stretch of text in one face and colour; nil keeps the foreground style.
    struct Run {
        let text: String
        let face: Face
        let colour: Color?
        init(_ text: String, _ face: Face, _ colour: Color? = nil) { self.text = text; self.face = face; self.colour = colour }
    }
    let runs: [Run]
    let lineHeight: CGFloat
    var centred = false
    /// The width the layout broke the lines at; the canvas is given it
    /// rounded to whole pixels, which would wrap a line that just fits.
    @State private var laidOut = LaidOut()
    final class LaidOut { var width: CGFloat? }

    init(_ runs: [Run], lineHeight: CGFloat, centred: Bool = false) { self.runs = runs; self.lineHeight = lineHeight; self.centred = centred }
    init(_ string: String, _ face: Face, lineHeight: CGFloat, centred: Bool = false) {
        self.init([Run(string, face)], lineHeight: lineHeight, centred: centred)
    }

    var body: some View {
        let breaker = LineBreaker(runs: runs)
        let pitch = (runs.first?.face.size ?? 16) * lineHeight
        ParaBox(breaker: breaker, lineHeight: pitch, laidOut: laidOut) {
            Canvas { context, size in
                let width = laidOut.width ?? size.width
                for (row, line) in breaker.lines(width: width).enumerated() {
                    var x = centred ? (width - breaker.width(line)) / 2 : 0
                    for segment in line {
                        let run = runs[segment.run]
                        var text = Text(segment.text).font(run.face.font).tracking(run.face.tracking)
                        if let colour = run.colour { text = text.foregroundColor(colour) }
                        let resolved = context.resolve(text)
                        let height = run.face.naturalLine
                        context.draw(resolved, at: CGPoint(x: x, y: CGFloat(row) * pitch + (pitch - height) / 2), anchor: .topLeading)
                        x += run.face.width(of: segment.text)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(runs.map(\.text).joined(separator: " "))
    }
}

/// Greedy CSS line breaking over runs of text, measured with CoreText.
struct LineBreaker {
    struct Segment { var text: String; let run: Int }
    let runs: [Para.Run]
    private let words: [(text: String, run: Int)]

    init(runs: [Para.Run]) {
        self.runs = runs
        words = runs.enumerated().flatMap { index, run in run.text.split(separator: " ").map { (String($0), index) } }
    }

    func width(_ line: [Segment]) -> CGFloat { line.reduce(0) { $0 + runs[$1.run].face.width(of: $1.text) } }

    /// A line's segments: words joined by spaces, a run per segment.
    private func segments(_ words: ArraySlice<(text: String, run: Int)>) -> [Segment] {
        var line: [Segment] = []
        for word in words {
            if let last = line.indices.last {
                line[last].text += " "
                if line[last].run == word.run { line[last].text += word.text; continue }
            }
            line.append(Segment(text: word.text, run: word.run))
        }
        return line
    }

    func lines(width: CGFloat) -> [[Segment]] {
        var lines: [[Segment]] = [], start = 0
        while start < words.count {
            var end = start + 1
            while end < words.count, self.width(segments(words[start...end])) <= width + 1.0 / 64 { end += 1 }
            lines.append(segments(words[start..<end]))
            start = end
        }
        return lines
    }

    /// One line's width, or nothing when there is no text.
    var natural: CGFloat { words.isEmpty ? 0 : width(segments(words[...])) }
}

/// Sizes a `Para`: one line as wide as its text, or the offered width with
/// as many line boxes as the breaks need.
private struct ParaBox: SwiftUI.Layout {
    let breaker: LineBreaker
    let lineHeight: CGFloat
    let laidOut: Para.LaidOut

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = breaker.natural, offered = proposal.width ?? full
        if full <= offered + 1.0 / 64 { return CGSize(width: full, height: lineHeight) }
        return CGSize(width: offered, height: CGFloat(breaker.lines(width: offered).count) * lineHeight)
    }

    /// The first line's baseline, for rows aligned on it.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let face = breaker.runs.first?.face else { return nil }
        return bounds.minY + (lineHeight - face.naturalLine) / 2 + CTFontGetAscent(face.ctFont)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        laidOut.width = bounds.width
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Words wrapped like a CSS line box: as wide as the line when it fits,
/// otherwise the whole offered width, broken greedily at spaces with a
/// fixed line height (SwiftUI's own wrapping cannot go below the font's).
struct WrappedLine: SwiftUI.Layout {
    let space: CGFloat
    let lineHeight: CGFloat
    var centred = false

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]], used: CGFloat = 0
        for index in subviews.indices {
            let word = subviews[index].sizeThatFits(.unspecified).width
            if !lines[lines.count - 1].isEmpty, used + space + word > width + 1.0 / 64 {
                lines.append([]); used = 0
            }
            used += (lines[lines.count - 1].isEmpty ? 0 : space) + word
            lines[lines.count - 1].append(index)
        }
        return lines
    }

    private func width(_ line: [Int], _ subviews: Subviews) -> CGFloat {
        line.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + space * CGFloat(max(0, line.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = width(Array(subviews.indices), subviews), offered = proposal.width ?? full
        if full <= offered + 1.0 / 64 { return CGSize(width: full, height: lineHeight) }
        return CGSize(width: offered, height: CGFloat(lines(subviews, width: offered).count) * lineHeight)
    }

    /// The first line's baseline, for rows aligned on it.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        let dimensions = first.dimensions(in: .unspecified)
        return bounds.minY + (lineHeight - dimensions.height) / 2 + dimensions[.firstTextBaseline]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (row, line) in lines(subviews, width: bounds.width).enumerated() {
            var x = bounds.minX + (centred ? (bounds.width - width(line, subviews)) / 2 : 0)
            for index in line {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(row) * lineHeight + (lineHeight - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + space
            }
        }
    }
}
