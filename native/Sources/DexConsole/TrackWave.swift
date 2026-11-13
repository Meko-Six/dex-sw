import SwiftUI
import CoreGraphics
import DexCore
import Foundation

/// Reports each zoom lane's draw for `DexWaveProfile`: the waveform's identity, the
/// track time it drew at the left edge, its span and columns, and the seconds taken.
public enum WaveProbe {
    public nonisolated(unsafe) static var drew: (@Sendable (UUID, Double, Double, Int, Double) -> Void)?
}

/// A decoded track's waveform as `waveform-gl.ts` draws it in three-band
/// mode: one device-pixel column at a time, the loudest LOW, MID and HIGH
/// envelopes under it, each scaled by its gain and a 0.8 gamma, overlapped
/// low first. Lanes mirror round the middle; the overview stands on the
/// bottom edge. Columns sit on a pixel grid fixed in track time
/// (`snapView`), so bars never flicker as the track scrolls; `moving` slides
/// that grid by the fraction of a column left over, so the scroll is even.
/// `tiled` draws from `WaveTiles`, so a frame only slides finished images instead of
/// asking the renderer for thousands of rectangles; snapshots draw directly.
/// Equatable, so a redraw around it (the overview's playhead) doesn't redo the columns.
struct TrackWave: View, Equatable {
    let data: WaveformData
    /// Track time at the left edge and across the view.
    let start, span: Double
    var oneSided = false
    var amp = 0.96
    var moving = false
    var tiled = false
    /// Device pixels per column once the stage's own scale is applied.
    var density = 1.0

    nonisolated static func == (a: TrackWave, b: TrackWave) -> Bool {
        a.data.id == b.data.id && a.start == b.start && a.span == b.span && a.oneSided == b.oneSided
            && a.amp == b.amp && a.moving == b.moving && a.tiled == b.tiled && a.density == b.density
    }

    /// Which column starts the view, how far left of the edge it sits (in columns, under
    /// one), and how many to draw: one extra when the last would otherwise leave a gap.
    static func columns(start: Double, perPixel: Double, width: Int, moving: Bool) -> (first: Double, slide: Double, count: Int) {
        let exact = start / perPixel, first = exact.rounded(.down)
        return moving ? (first, exact - first, width + 1) : (first, 0, width)
    }

    private static let colours = [Color(red: 46 / 255, green: 115 / 255, blue: 235 / 255),
                                  Color(red: 211 / 255, green: 145 / 255, blue: 49 / 255),
                                  Color(red: 1, green: 249 / 255, blue: 226 / 255)]
    nonisolated fileprivate static let rgb: [(CGFloat, CGFloat, CGFloat)] = [(46 / 255, 115 / 255, 235 / 255), (211 / 255, 145 / 255, 49 / 255), (1, 249 / 255, 226 / 255)]
    nonisolated fileprivate static let gains: [Float] = [1.6, 1.5, 1.5]

    var body: some View {
        Canvas { context, size in
            let scale = context.environment.displayScale
            let columns = Int((size.width * scale).rounded()), height = size.height * scale
            guard columns > 0, span > 0 else { return }
            let probe = oneSided ? nil : WaveProbe.drew, began = probe == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let perPixel = span / Double(columns)
            let (first, slide, count) = Self.columns(start: start, perPixel: perPixel, width: columns, moving: moving)
            if slide != 0 { context.translateBy(x: -slide / scale, y: 0) }
            if tiled {
                let shape = Shape(height: height, oneSided: oneSided, amp: amp)
                let width = Double(WaveTiles.columns)
                for index in Int((first / width).rounded(.down))...Int(((first + Double(count) - 1) / width).rounded(.down)) {
                    let left = Double(index) * width
                    guard (left + width) * perPixel > 0, left * perPixel < data.duration else { continue }
                    guard let tile = WaveTiles.shared.tile(data: data, index: index, perPixel: perPixel, shape: shape, density: density) else { continue }
                    context.draw(Image(decorative: tile, scale: density).interpolation(.low),
                                 in: CGRect(x: (left - first) / scale, y: 0, width: width / scale, height: Double(tile.height) / density / scale))
                }
            } else {
                let envelopes = Self.envelopes(data, first: first, perPixel: perPixel, columns: count)
                let shape = Shape(height: height, oneSided: oneSided, amp: amp)
                for band in 0..<3 {
                    var path = Path()
                    shape.bars(envelopes, band: band, count: count) { path.addRect($0) }
                    context.fill(path.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)), with: .color(Self.colours[band]))
                }
            }
            probe?(data.id, (first + slide) * perPixel, span, columns, ProcessInfo.processInfo.systemUptime - began)
        }
    }

    /// How a column's envelope stands in the view, in device pixels from the top.
    struct Shape: Hashable {
        let height: Double
        let oneSided: Bool
        let amp: Double

        func bars(_ envelopes: [Float], band: Int, count: Int, _ bar: (CGRect) -> Void) {
            // The shader's middle, floor(h / 2) + 0.5 up from the bottom.
            let mid = oneSided ? height : height - (height * 0.5).rounded(.down) - 0.5
            let reach = height * (oneSided ? 1 : 0.5) * amp
            for column in 0..<count {
                let value = envelopes[column * 3 + band]
                guard value > 0 else { continue }
                let size = Double(pow(min(1, value * TrackWave.gains[band]), 0.8)) * reach
                guard size > 0.01 else { continue }
                let top = mid - size, bottom = oneSided ? height : mid + size
                bar(CGRect(x: Double(column), y: top, width: 1, height: bottom - top))
            }
        }
    }

    /// LOW, MID, HIGH per column: the maximum over the bins a column covers,
    /// or, zoomed past the finest level, a blend of the two nearest bins.
    nonisolated static func envelopes(_ data: WaveformData, first: Double, perPixel: Double, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: columns * 3)
        let level = data.level(secondsPerPixel: perPixel), bin = level.secondsPerBin
        let start = first * perPixel, end = start + Double(columns) * perPixel
        guard end > 0, start < data.duration, level.count > 0 else { return result }
        if perPixel < bin {
            for column in 0..<columns {
                let time = start + (Double(column) + 0.5) * perPixel
                guard time >= 0, time < data.duration else { continue }
                let t = min(Double(level.count - 1), max(0, time / bin - 0.5))
                let index = Int(t), fraction = Float(t - Double(index))
                guard let a = level.sample(at: index) else { continue }
                let b = level.sample(at: min(index + 1, level.count - 1)) ?? a
                result[column * 3] = a.low + (b.low - a.low) * fraction
                result[column * 3 + 1] = a.mid + (b.mid - a.mid) * fraction
                result[column * 3 + 2] = a.high + (b.high - a.high) * fraction
            }
        } else {
            level.visit(start: max(0, start), end: min(data.duration, end)) { centre, value in
                // The bin's first sample decides its column, as in the shader.
                // Worked out from the track's start, so every tile places a bin alike.
                let column = Int(((centre - bin / 2) / perPixel).rounded(.down) - first)
                guard (0..<columns).contains(column) else { return }
                result[column * 3] = max(result[column * 3], value.low)
                result[column * 3 + 1] = max(result[column * 3 + 1], value.mid)
                result[column * 3 + 2] = max(result[column * 3 + 2], value.high)
            }
        }
        return result
    }
}

/// Finished stretches of waveform, fixed in track time, so scrolling only slides images.
/// A tile changes only with the data, zoom, shape or density, and the oldest go first
/// once past the limit, so memory stays bounded whatever the track's length.
final class WaveTiles: @unchecked Sendable {
    static let shared = WaveTiles(limit: 8 << 20)
    static let columns = 512

    private struct Key: Hashable {
        let data: UUID, index: Int, perPixel: Double, shape: TrackWave.Shape, density: Double
    }
    private let lock = NSLock()
    private let limit: Int
    private var tiles: [Key: (image: CGImage, used: UInt64)] = [:]
    private var bytes = 0, uses: UInt64 = 0
    private(set) var built = 0
    var residentBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }

    init(limit: Int) { self.limit = limit }

    func tile(data: WaveformData, index: Int, perPixel: Double, shape: TrackWave.Shape, density: Double) -> CGImage? {
        let key = Key(data: data.id, index: index, perPixel: perPixel, shape: shape, density: density)
        lock.lock(); defer { lock.unlock() }
        uses += 1
        if let found = tiles[key] {
            tiles[key]?.used = uses
            return found.image
        }
        guard let image = Self.draw(data: data, index: index, perPixel: perPixel, shape: shape, density: density) else { return nil }
        built += 1
        tiles[key] = (image, uses)
        bytes += image.bytesPerRow * image.height
        while bytes > limit, tiles.count > 1, let oldest = tiles.min(by: { $0.value.used < $1.value.used }) {
            bytes -= oldest.value.image.bytesPerRow * oldest.value.image.height
            tiles[oldest.key] = nil
        }
        return image
    }

    private static func draw(data: WaveformData, index: Int, perPixel: Double, shape: TrackWave.Shape, density: Double) -> CGImage? {
        let width = Int((Double(columns) * density).rounded(.up)), height = Int((shape.height * density).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A bin belongs to the column of its first sample but is found by its centre, so
        // the last column needs bins from just past the tile to meet the next one cleanly.
        let envelopes = TrackWave.envelopes(data, first: Double(index * columns), perPixel: perPixel, columns: columns + 2)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: density, y: -density)
        var rects: [CGRect] = []
        rects.reserveCapacity(columns)
        for band in 0..<3 {
            rects.removeAll(keepingCapacity: true)
            shape.bars(envelopes, band: band, count: columns) { rects.append($0) }
            let colour = TrackWave.rgb[band]
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(rects)
        }
        return context.makeImage()
    }
}
