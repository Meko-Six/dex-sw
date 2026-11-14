import SwiftUI
import DexCore

// The mixer parts the popovers (Pops.swift) still use, and the platter's grip and
// turn maths, kept from the chassis before the stage-two drawing.

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


/// Only the exposed arc can start a drag. Once captured, the drag keeps using
/// the full disc coordinates, while a second touch can still grab a fader.
struct PlatterGrip: Shape {
    let deck: String

    func path(in rect: CGRect) -> Path {
        guard rect.width > Layout.tuckedRim, rect.height > 0 else { return Path() }
        let cut = acos(1 - 2 * Layout.tuckedRim / rect.width)
        // Trace the exposed arc, then close it with the straight mixer edge.
        var grip = Path()
        grip.addRelativeArc(center: .zero, radius: 1, startAngle: .radians(cut), delta: .radians(2 * .pi - 2 * cut))
        grip.closeSubpath()
        return grip.applying(CGAffineTransform(a: (deck == "B" ? -1 : 1) * rect.width / 2, b: 0,
                                              c: 0, d: rect.height / 2, tx: rect.midX, ty: rect.midY))
    }
}

/// Beats turned between two angles, by the shorter way round (`shared/platter.ts`).
func platterBeatDelta(_ from: Double, _ to: Double) -> Double {
    var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    return delta * 2 / (2 * .pi)
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
    guard abs(knob) >= 0.04, frequency < 20_000 else { return "OFF" }
    let hz = frequency >= 1000 ? String(format: "%.1fk", frequency / 1000) : String(Int(frequency.rounded()))
    return (knob < 0 ? "LP " : "HP ") + hz
}

/// `.bandval` above a fader: the band's name only. The cap's place says where it is.

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

