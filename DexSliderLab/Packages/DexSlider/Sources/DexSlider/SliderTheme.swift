import SwiftUI

/// Colours sampled from the sketch, and Dex's condensed face.
public enum SliderTheme {
    public static let sketchBackground = Color(hex: 0x383838)
    public static let dexBackground = Color(hex: 0x0C0C0D)
    static let backdrop = Color(hex: 0x262628)
    static let chip = Color(hex: 0x151517)
    static let chipFill = Color(hex: 0xC8C8CE)
    static let outline = Color(hex: 0x55555B)
    static let text = Color(hex: 0xF2F2F4)
    static let dim = Color(hex: 0x8F8F96)
    static let track = Color(hex: 0x9C9C9C)
    static let fill = Color(hex: 0xF1F1F3)
    /// TRIM's AUTO mark: Dex's LED orange.
    static let mark = Color(hex: 0xFF8A00)
    static let green = Color(hex: 0x66CE77)
    static let yellow = Color(hex: 0xF8D04A)
    static let red = Color(hex: 0xDE5C3C)

    static func colour(_ tone: MeterTone) -> Color {
        switch tone {
        case .green: green
        case .yellow: yellow
        case .red: red
        }
    }

    /// Avenir Next Condensed, as the console uses, with even-width digits.
    public static func cond(_ size: CGFloat, _ weight: String = "Bold") -> Font {
        Font.custom("AvenirNextCondensed-" + weight, fixedSize: size).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
