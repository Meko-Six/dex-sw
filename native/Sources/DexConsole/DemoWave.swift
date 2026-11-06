import SwiftUI

/// The mockup's synthetic stroke waveform (`waveSvg` in
/// `src/renderer/console/demo.tsx`), ported value for value so demo
/// snapshots can be diffed against the renderer: the same seeded generator,
/// the same 1-decimal path coordinates, in a `count` × 100 box.
struct DemoWave {
    struct Column { let x: Double; let all, mids, highs: (top: Double, bottom: Double) }
    let count: Int
    let columns: [Column]

    @MainActor private static var cache: [String: DemoWave] = [:]
    /// Each demo wave is built once; views redraw from the same columns.
    @MainActor static func cached(count: Int, seed: Int, oneSided: Bool) -> DemoWave {
        let key = "\(count)-\(seed)-\(oneSided)"
        if let wave = cache[key] { return wave }
        let wave = DemoWave(count: count, seed: seed, oneSided: oneSided)
        cache[key] = wave
        return wave
    }

    init(count: Int, seed: Int, oneSided: Bool) {
        var state = seed
        func random() -> Double {
            state = (state * 9301 + 49297) % 233280
            return Double(state) / 233280
        }
        // JS toFixed(1).
        func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let seedValue = Double(seed)
        var columns: [Column] = []
        columns.reserveCapacity(count)
        for i in 0..<count {
            let index = Double(i)
            let phrase = 0.5 + 0.5 * sin(index * 0.011 + seedValue * 0.13)
            let beat = 0.42 + 0.58 * abs(sin(index * 0.083 + seedValue * 0.37))
            let grain = 0.62 + 0.38 * random()
            let hit = random() > 0.985 ? 0.5 : 0
            let height = max(2, min(96, 6 + 78 * phrase * beat * grain + hit * 26))
            let bias = 0.46 + (random() - 0.5) * 0.16
            func segment(_ h: Double) -> (top: Double, bottom: Double) {
                oneSided ? (round1(100 - h), 100) : (round1(50 - h * bias), round1(50 + h * (1 - bias)))
            }
            columns.append(Column(
                x: index + 0.5,
                all: segment(height),
                mids: segment(height * (0.28 + 0.25 * abs(sin(index * 0.043 + seedValue)))),
                highs: segment(height * (0.12 + 0.65 * pow(abs(sin(index * 0.083 + seedValue * 0.37)), 18)))))
        }
        self.count = count
        self.columns = columns
    }

    /// Strokes the three bands, 1 pt wide whatever the scale (the SVG's
    /// non-scaling stroke), into `rect`: blue body, orange mids, cream highs.
    /// Chromium anti-aliases these hairlines a little differently, so demo
    /// lanes keep a residual in the native diff; real waveforms draw elsewhere.
    func draw(in context: GraphicsContext, rect: CGRect) {
        let sx = rect.width / Double(count), sy = rect.height / 100
        for (band, colour) in [(\Column.all, Color(hex: 0x2E73EB)), (\Column.mids, Color(hex: 0xD39131)), (\Column.highs, Color(hex: 0xFFF9E2))] {
            var path = Path()
            for column in columns {
                let span = column[keyPath: band]
                let x = rect.minX + column.x * sx
                path.move(to: CGPoint(x: x, y: rect.minY + span.top * sy))
                path.addLine(to: CGPoint(x: x, y: rect.minY + span.bottom * sy))
            }
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1, lineCap: .butt))
        }
    }
}
