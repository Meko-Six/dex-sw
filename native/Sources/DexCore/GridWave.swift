import Foundation

/// One column of the beat grid window's waveform: the signal's lowest and
/// highest sample, and its MID and HIGH envelopes.
public struct GridWaveColumn: Equatable, Sendable {
    public var low: Float, high: Float, mid: Float, top: Float
    public init(low: Float = 0, high: Float = 0, mid: Float = 0, top: Float = 0) {
        self.low = low; self.high = high; self.mid = mid; self.top = top
    }
    public static let empty = GridWaveColumn()
}

/// Builds the beat grid window's columns from a mono signal, as the mockup's
/// `readGridColumns` does: the bands split at the lane waveform's crossovers
/// (`DexWaveform.c`, 220 Hz and 3.5 kHz), each envelope rising at once and
/// falling over 4 ms, so every layer keeps the hit's exact start. Feed it from
/// `warmUp` seconds before the window so the filters have settled by its edge.
public struct GridWaveBuilder {
    /// Floats per column in `values`: lowest, highest, MID, HIGH.
    public static let stride = 4
    public static let warmUp = 0.06

    private struct Section {
        var b0, b1, b2, a1, a2: Double, z1 = 0.0, z2 = 0.0
        init(rate: Double, hz: Double, high: Bool) {
            let w = 2 * Double.pi * min(hz, rate * 0.45) / rate
            let c = cos(w), alpha = sin(w) / 2.0.squareRoot(), a0 = 1 + alpha
            b0 = (high ? 1 + c : 1 - c) / 2 / a0
            b1 = (high ? -(1 + c) : 1 - c) / a0
            b2 = b0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }
        mutating func tick(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var aboveLow, belowHigh, aboveHigh: Section
    private let fall: Double
    private var midEnvelope = 0.0, highEnvelope = 0.0
    public private(set) var values: [Float]

    public init(rate: Double, columns: Int) {
        aboveLow = Section(rate: rate, hz: 220, high: true)
        belowHigh = Section(rate: rate, hz: 3_500, high: false)
        aboveHigh = Section(rate: rate, hz: 3_500, high: true)
        fall = exp(-1 / (rate * 0.004))
        values = [Float](repeating: 0, count: max(0, columns) * Self.stride)
    }

    /// One sample, landing in `column`; one outside the window only moves the filters.
    public mutating func add(_ x: Double, column: Int) {
        midEnvelope = max(abs(belowHigh.tick(aboveLow.tick(x))), midEnvelope * fall)
        highEnvelope = max(abs(aboveHigh.tick(x)), highEnvelope * fall)
        let at = column * Self.stride
        guard column >= 0, at < values.count else { return }
        values[at] = min(values[at], Float(x))
        values[at + 1] = max(values[at + 1], Float(x))
        values[at + 2] = max(values[at + 2], Float(midEnvelope))
        values[at + 3] = max(values[at + 3], Float(highEnvelope))
    }

    public static func column(_ values: [Float], _ index: Int) -> GridWaveColumn {
        let at = index * stride
        guard index >= 0, at + 3 < values.count else { return .empty }
        return GridWaveColumn(low: values[at], high: values[at + 1], mid: values[at + 2], top: values[at + 3])
    }
}
