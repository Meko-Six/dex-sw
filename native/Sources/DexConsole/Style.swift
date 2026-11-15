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
    /// The library's yellow-green outlined keys.
    static let outlineYellow = Color(hex: 0xDBE22D)
    static let removeRed = Color(hex: 0xFF5A4A)
    /// `--a` and `--blue`: deck A, selected rows, the sidebar, the jump length.
    static let blueHex: UInt32 = 0x276FFF
    static let blue = Color(hex: blueHex)
    /// Library text: the bright and the darker grey.
    static let rowText = Color(hex: 0xF2F4F3)
    static let rowDim = Color(hex: 0x74747B)
    static let playing = Color(hex: 0x80C342)
    /// A track's note once the current set has played it.
    static let played = Color.white.opacity(0.35)
    /// Lit stars.
    static let star = Color(hex: 0xDBE22D)
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
    /// `--font-avenir`: the wide cut used in the library.
    static func avenir(_ size: CGFloat, tracking: CGFloat = 0, weight: Weight = .medium, tabular: Bool = false) -> Face {
        Face(name: "AvenirNext-" + weight.rawValue, size: size, tracking: tracking, tabular: tabular)
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

/// The paths and view boxes from the SVGs in `icons/`.
enum ConsoleGlyph: Shape {
    case note, info, close
    /// Track details' rows and keys, from the user's drawing (`mockup/song.info.svg`).
    case artist, album, genre, bpm, key, length, rating, reanalyse, remove

    var size: CGSize {
        switch self {
        case .note: CGSize(width: 15.71, height: 25.89)
        case .info: CGSize(width: 14, height: 24.97)
        case .close: CGSize(width: 21, height: 24.97)
        case .artist: CGSize(width: 19.92, height: 19.92)
        case .album: CGSize(width: 17.12, height: 22.66)
        case .genre: CGSize(width: 20.76, height: 23.24)
        case .bpm: CGSize(width: 24, height: 20.17)
        case .key: CGSize(width: 24, height: 20.17)
        case .length: CGSize(width: 19.92, height: 19.92)
        case .rating: CGSize(width: 21.68, height: 20.72)
        case .reanalyse: CGSize(width: 24.61, height: 20.71)
        case .remove: CGSize(width: 20.06, height: 23.08)
        }
    }

    /// Where the view box starts: the re-analyse and remove icons keep the drawing's coordinates.
    private var origin: CGPoint {
        switch self {
        case .reanalyse: CGPoint(x: 42.74, y: 257.25)
        case .remove: CGPoint(x: 120.59, y: 255.15)
        default: .zero
        }
    }

    private static let notePath = svgPath("M15.71,5.85V1.01c0-.68-.54-1.12-1.21-.98l-6.61,1.43c-.82.19-1.27.62-1.27,1.35v14.34c.08.63-.22,1.04-.78,1.15l-2.05.42c-2.58.55-3.79,1.85-3.79,3.82s1.52,3.35,3.66,3.35c1.89,0,4.72-1.4,4.72-5.15v-11.79c0-.69.14-.82.75-.95l5.89-1.3C15.44,6.6,15.71,6.28,15.71,5.85Z")
    private static let infoPath = svgPath("M2.07,23.79h9.83c.8,0,1.44-.58,1.44-1.39,0-.77-.63-1.37-1.44-1.37h-3.25v-9.73c0-1.06-.53-1.75-1.54-1.75H2.4c-.78,0-1.41.6-1.41,1.36,0,.81.64,1.39,1.41,1.39h3.13v8.73h-3.46c-.8,0-1.41.6-1.41,1.37,0,.82.61,1.39,1.41,1.39ZM6.35,6.52c1.49,0,2.68-1.19,2.68-2.67s-1.18-2.68-2.68-2.68-2.66,1.18-2.66,2.68,1.19,2.67,2.66,2.67Z")
    private static let iconPaths: [ConsoleGlyph: Path] = [
        .artist: svgPath("M9.95,19.91c5.51,0,9.97-4.45,9.97-9.96S15.46,0,9.95,0,0,4.45,0,9.95,4.46,19.91,9.95,19.91ZM9.95,18.26c-4.58,0-8.29-3.72-8.29-8.31S5.37,1.65,9.95,1.65s8.31,3.72,8.31,8.3S14.54,18.26,9.95,18.26ZM16.64,16.39l-.03-.11c-.49-1.43-3.07-3.01-6.66-3.01s-6.15,1.58-6.64,3.01l-.03.11c1.76,1.74,4.78,2.75,6.68,2.75S14.86,18.14,16.64,16.39ZM9.95,11.62c1.88.02,3.36-1.58,3.36-3.68,0-1.98-1.48-3.61-3.36-3.61s-3.35,1.63-3.34,3.61C6.62,10.04,8.08,11.6,9.95,11.62Z"),
        .album: svgPath("M13.05,1.25H4.06c.04-.8.54-1.25,1.36-1.25h6.26C12.51,0,13.01.45,13.05,1.25ZM15.05,4.04c-.32-.05-.65-.07-1-.07H3.06c-.35,0-.68.02-1,.07.1-.93.73-1.46,1.77-1.46h9.45C14.31,2.58,14.94,3.11,15.05,4.04ZM17.12,8.57v11.06c0,2.01-1.03,3.03-3.07,3.03H3.06c-2.04,0-3.06-1.01-3.06-3.03v-11.06c0-2.02,1.02-3.02,3.06-3.02h10.99C16.09,5.55,17.12,6.56,17.12,8.57ZM12.74,10.33v-2.58c0-.36-.29-.59-.65-.52l-3.51.76c-.44.1-.68.33-.68.72v7.63c.04.34-.12.55-.41.61l-1.09.23c-1.38.29-2.02.98-2.02,2.03s.81,1.78,1.95,1.78c1,0,2.51-.74,2.51-2.74v-6.27c0-.37.07-.44.4-.51l3.13-.69C12.6,10.73,12.74,10.56,12.74,10.33Z"),
        .genre: svgPath("M1.24,22.01c1.62,1.62,3.53,1.64,5.13.03,1.18-1.17,2.42-3.96,3.33-5.04l2.08,2.08c.77.78,1.68.78,2.42.03l1.27-1.27c.74-.75.74-1.64-.04-2.41l-7.62-7.63c-.77-.78-1.67-.79-2.42-.03l-1.26,1.27c-.74.73-.75,1.64.02,2.42l2.08,2.07c-1.07.92-3.86,2.15-5.04,3.34C-.41,18.47-.4,20.38,1.24,22.01ZM5.48,9.9l.8-.77c.25-.26.52-.26.78,0l7.06,7.05c.24.24.24.52-.02.78l-.76.78c-.26.27-.55.27-.81.01l-2.33-2.34c-.36-.37-.82-.33-1.24.07-.77.75-2.09,3.96-3.65,5.51-.94.94-2.07.94-3.04-.02-.96-.97-.97-2.11-.03-3.05,1.56-1.54,4.78-2.88,5.52-3.65.39-.41.44-.89.08-1.24l-2.36-2.33C5.24,10.44,5.24,10.16,5.48,9.9ZM3.76,20.7c.66,0,1.2-.54,1.2-1.21s-.54-1.2-1.2-1.2-1.21.54-1.21,1.2S3.09,20.7,3.76,20.7ZM15.32,16.4l4.64-4.64c1.08-1.08,1.06-2.38-.04-3.49L12.25.59c-1.03-1.03-2.8-.62-3.16.97-.9,3.94-.94,4.41-2.45,6.51l1.13,1.11c1.71-2.24,1.83-3.32,2.77-6.81.13-.5.54-.63.87-.3l7.31,7.3c.45.45.45.99.03,1.42l-4.52,4.52L15.32,16.4ZM13.78,10.83c.51.51,3.37-1.07,4.35-2.3l-2.14-2.14c-.19,1.73-1.09,2.97-2.18,4.07C13.68,10.58,13.7,10.75,13.78,10.83Z"),
        .bpm: svgPath("M21.91,20.17H2.09c-1.15,0-2.09-.94-2.09-2.09V2.09C0,.94.94,0,2.09,0h19.82c1.15,0,2.09.94,2.09,2.09v15.99C24,19.23,23.06,20.17,21.91,20.17ZM4.92,2.79h-2.58v14.59h2.69c1.7,0,2.59-1.21,2.59-3.46v-1.19c0-1.54-.36-2.62-1.27-3.1v-.04c.76-.48,1.1-1.42,1.1-2.92v-.52C7.45,3.9,6.69,2.79,4.92,2.79ZM4.87,4.88c.61,0,.87.46.87,1.5v.81c0,1.17-.39,1.54-1.02,1.54h-.67v-3.85H4.87ZM4.81,10.81c.78,0,1.1.42,1.1,1.78v1.27c0,1.08-.31,1.43-.88,1.43h-.98v-4.48H4.81ZM11.16,2.79h-2.51v14.59h1.7v-5.48h.81c1.71,0,2.55-1.27,2.55-3.61v-1.89C13.71,4.07,12.87,2.79,11.16,2.79ZM11.16,4.88c.55,0,.84.33.84,1.37v2.19c0,1.04-.29,1.37-.84,1.37h-.81v-4.93H11.16ZM16.86,2.79h-2.37v14.59h1.49V7.07h.03l1.24,10.31h1.62l1.14-10.46h.04v10.46h1.61V2.79h-2.38l-1.14,10.36h-.03L16.86,2.79Z"),
        .key: svgPath("M21.91,0H2.09C.94,0,0,.94,0,2.09v15.99c0,1.15.94,2.09,2.09,2.09h19.82c1.15,0,2.09-.94,2.09-2.09V2.09C24,.94,23.06,0,21.91,0ZM9.39,13.45v3.67s-.8,0-.8,0v-3.49s-2.87.73-2.87.73v3.48s-.81,0-.81,0l.02-3.3-1.57.39v-2.17s1.56-.38,1.56-.38v-3.99s-1.56.36-1.56.36v-2.15s1.56-.37,1.56-.37v-3.68s.8.01.8.01v3.48s2.87-.74,2.87-.74V1.8s.8,0,.8,0v3.32s1.56-.38,1.56-.38v2.16s-1.55.39-1.55.39v3.98s1.55-.37,1.55-.37l.01,2.15L9.39,13.45ZM20.66,14.32c-.71.56-1.48,1.02-2.37,1.41-1.58.74-2.88,1.64-4.44,2.64V1.98s1.27,0,1.27,0v9.47c.93-.45,1.83-.78,2.9-.88,1.38-.12,2.82.33,3.43,1.36C21.97,12.81,21.41,13.68,20.66,14.32ZM18.7,12.92c-.09,1.22-2.14,2.66-3.56,3.6v-3.93c.35-.51,1.12-.95,1.86-.99C17.93,11.56,18.75,12.19,18.7,12.92ZM8.58,7.47v3.99s-2.86.72-2.86.72v-3.98S8.58,7.47,8.58,7.47Z"),
        .length: svgPath("M9.95,19.91c5.51,0,9.97-4.45,9.97-9.96S15.46,0,9.97,0c-.52,0-.77.31-.77.81v3.11c0,.43.29.77.71.77s.72-.34.72-.77V1.69c4.04.31,7.63,3.68,7.63,8.26s-3.72,8.31-8.31,8.31S1.66,14.54,1.66,9.97c0-2.09.76-3.96,1.99-5.39.29-.38.3-.87-.03-1.21-.33-.35-.87-.31-1.22.12C.91,5.23,0,7.49,0,9.95,0,15.46,4.46,19.91,9.95,19.91ZM9.95,11.53c.88,0,1.58-.7,1.58-1.58,0-.52-.25-.99-.67-1.28l-4.88-3.46c-.48-.34-.98.16-.66.65l3.25,4.87C8.89,11.2,9.38,11.53,9.95,11.53Z"),
        .rating: svgPath("M4.15,20.54c.42.31.91.2,1.52-.23l5.17-3.8,5.17,3.8c.6.43,1.1.54,1.52.23.4-.3.48-.81.23-1.51l-2.03-6.08,5.21-3.73c.61-.43.86-.89.69-1.37-.15-.48-.61-.71-1.36-.7l-6.4.04-1.94-6.1c-.23-.72-.58-1.09-1.09-1.09s-.85.37-1.09,1.09l-1.94,6.1-6.4-.04c-.75,0-1.2.22-1.36.7-.16.48.09.94.69,1.37l5.21,3.73-2.03,6.08C3.67,19.73,3.75,20.24,4.15,20.54ZM5.56,18.62s-.01-.04,0-.1l1.95-5.58c.13-.38.05-.68-.29-.92l-4.86-3.36s-.06-.04-.05-.07c.02-.04.04-.04.09-.04l5.91.11c.4.01.66-.15.78-.55l1.69-5.66c.02-.05.03-.07.06-.07s.04.02.06.07l1.69,5.66c.12.4.39.56.79.55l5.9-.11c.05,0,.07,0,.09.04,0,.03,0,.04-.05.07l-4.86,3.36c-.34.24-.42.54-.28.92l1.94,5.58c.01.06.02.07,0,.1-.02.02-.05,0-.09-.02l-4.7-3.59c-.31-.24-.66-.24-.98,0l-4.69,3.59S5.59,18.64,5.56,18.62Z"),
        .reanalyse: svgPath("M61.89,272.42c-.25,0-.62.08-.98.48-1.5,1.66-3.64,2.61-5.87,2.61-3.59,0-6.73-2.44-7.63-5.87h.89c.64,0,.9-.32,1-.51.17-.33.11-.74-.17-1.14l-2.18-3.11c-.23-.33-.54-.52-.88-.52s-.65.19-.88.51l-2.18,3.11c-.29.4-.35.83-.18,1.16.09.18.35.5,1,.5h1.06c.96,4.84,5.18,8.32,10.15,8.32,2.94,0,5.75-1.25,7.71-3.43.25-.29.37-.64.33-1-.03-.35-.22-.67-.5-.88C62.37,272.5,62.13,272.42,61.89,272.42ZM67.25,266.08c-.09-.18-.35-.5-.99-.5h-1.06c-.96-4.84-5.18-8.33-10.16-8.33-2.95,0-5.75,1.25-7.7,3.43-.26.29-.38.64-.35.99.04.35.22.67.51.9.22.15.46.23.7.23s.61-.09.97-.48c1.51-1.66,3.64-2.61,5.87-2.61,3.59,0,6.73,2.44,7.64,5.87h-.9c-.64,0-.9.31-.99.5-.18.33-.11.75.17,1.15l2.18,3.11c.23.33.54.51.88.51s.65-.18.88-.51l2.18-3.1C67.36,266.84,67.43,266.42,67.25,266.08Z"),
        .remove: svgPath("M133.69,274.89c-.4,0-.66-.25-.65-.61l.32-11.08c.01-.38.28-.61.65-.61s.65.24.64.61l-.32,11.08C134.32,274.66,134.06,274.89,133.69,274.89ZM130.62,274.89c-.4,0-.67-.24-.67-.61v-11.08c0-.36.27-.61.67-.61s.66.25.66.61v11.08C131.28,274.65,131.01,274.89,130.62,274.89ZM127.54,274.9c-.37,0-.64-.24-.65-.61l-.31-11.09c-.01-.36.25-.61.64-.61.38,0,.64.25.65.61l.31,11.08C128.19,274.65,127.93,274.9,127.54,274.9ZM135.16,259.89h-1.64v-2.21c0-.6-.42-.98-1.04-.98h-3.71c-.62,0-1.03.38-1.03.98v2.21h-1.66v-2.32c0-1.49.98-2.42,2.58-2.42h3.94c1.58,0,2.56.93,2.56,2.42V259.89ZM139.88,260.71h-18.53c-.43,0-.76-.35-.76-.77s.35-.78.76-.78h18.53c.4,0,.77.34.77.78S140.28,260.71,139.88,260.71ZM135.36,278.23h-9.5c-1.48,0-2.48-.96-2.55-2.45l-.72-15.25h1.66l.69,15.08c.03.63.47,1.06,1.09,1.06h9.19c.59,0,1.04-.45,1.07-1.06l.73-15.08h1.63l-.74,15.27C137.84,277.28,136.86,278.23,135.36,278.23Z"),
    ]
    private static let closePath = svgPath("M5.3,20.27l13.57-13.57c.3-.3.47-.68.47-1.11,0-.89-.71-1.58-1.59-1.58-.45,0-.81.15-1.11.48L3.05,18.02c-.3.32-.47.68-.47,1.13,0,.89.71,1.6,1.59,1.6.48,0,.85-.17,1.14-.48ZM16.6,20.27c.3.3.68.48,1.15.48.88,0,1.59-.71,1.59-1.6,0-.45-.18-.81-.47-1.13L5.28,4.49c-.3-.33-.66-.48-1.11-.48-.87,0-1.59.69-1.59,1.58,0,.43.17.81.47,1.11l13.55,13.57Z")

    private static func svgPath(_ source: String) -> Path {
        var path = Path(), command: Character = "M", values: [CGFloat] = []
        var point = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        func run() {
            defer {
                if !"cCsS".contains(command) { lastControl = nil }
                values.removeAll(keepingCapacity: true)
            }
            switch command {
            case "M", "m":
                guard values.count >= 2 else { return }
                point = command == "M" ? CGPoint(x: values[0], y: values[1])
                    : CGPoint(x: point.x + values[0], y: point.y + values[1])
                start = point
                path.move(to: point)
            case "H", "h":
                for x in values {
                    point.x = command == "H" ? x : point.x + x
                    path.addLine(to: point)
                }
            case "V", "v":
                for y in values {
                    point.y = command == "V" ? y : point.y + y
                    path.addLine(to: point)
                }
            case "L", "l":
                while values.count >= 2 {
                    point = command == "L" ? CGPoint(x: values[0], y: values[1])
                        : CGPoint(x: point.x + values[0], y: point.y + values[1])
                    path.addLine(to: point)
                    values.removeFirst(2)
                }
            case "c", "s", "C", "S":
                let smooth = command == "s" || command == "S"
                let origin = command == "C" || command == "S" ? CGPoint.zero : nil
                let count = smooth ? 4 : 6
                while values.count >= count {
                    let base = origin ?? point
                    let previous = lastControl ?? point
                    let first = smooth ? CGPoint(x: 2 * point.x - previous.x, y: 2 * point.y - previous.y)
                        : CGPoint(x: base.x + values[0], y: base.y + values[1])
                    let second = CGPoint(x: base.x + values[count - 4], y: base.y + values[count - 3])
                    let end = CGPoint(x: base.x + values[count - 2], y: base.y + values[count - 1])
                    path.addCurve(to: end, control1: first, control2: second)
                    lastControl = second
                    point = end
                    values.removeFirst(count)
                }
            case "Z": break
            default: assertionFailure("Unsupported icon path command: \(command)")
            }
        }
        var number = ""
        func flush() { if let value = Double(number) { values.append(CGFloat(value)) }; number = "" }
        for character in source {
            if character.isLetter {
                flush()
                run()
                command = character
                if character == "Z" { path.closeSubpath(); point = start }
            } else if character == "," || character.isWhitespace { flush() }
            else if character == "-" { flush(); number = "-" }
            else if character == ".", number.contains(".") { flush(); number = "." }
            else { number.append(character) }
        }
        flush()
        run()
        return path
    }

    func path(in rect: CGRect) -> Path {
        let path: Path
        switch self {
        case .note: path = Self.notePath
        case .info: path = Self.infoPath
        case .close: path = Self.closePath
        default: path = (Self.iconPaths[self] ?? Path()).offsetBy(dx: -origin.x, dy: -origin.y)
        }
        let scale = min(rect.width / size.width, rect.height / size.height)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - size.width * scale / 2, dy: rect.midY - size.height * scale / 2)
    }
}

/// The music note, `height` points tall in the current foreground colour.
struct NoteIcon: View {
    let height: CGFloat
    var body: some View {
        let note = ConsoleGlyph.note
        note.frame(width: height * note.size.width / note.size.height, height: height)
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
    /// Only SwiftUI's layout passes touch it, and they run on the main thread.
    final class LaidOut: @unchecked Sendable { var width: CGFloat? }

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
