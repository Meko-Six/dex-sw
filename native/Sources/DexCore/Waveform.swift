import Foundation

public struct WaveformBin: Sendable, Equatable {
    public let peak: Float
    public let rms: Float
    public let low: Float
    public let mid: Float
    public let high: Float
    public init(peak: Float, rms: Float, low: Float, mid: Float, high: Float) {
        self.peak = peak; self.rms = rms; self.low = low; self.mid = mid; self.high = high
    }
}

/// Five little-endian UInt16 fixed-point values per bin (0…4). Only envelopes survive decoding;
/// no audio PCM is retained. Coarser levels preserve energy and transient peaks.
public struct WaveformData: Sendable, Identifiable {
    public static let maximumBins = 262_144
    public static let bytesPerBin = 10
    public let id = UUID()
    public let sampleRate: Double
    public let sourceFrames: Int64
    public let framesPerBin: Int64
    public let levels: [WaveformLevel]
    public var duration: Double { Double(sourceFrames) / sampleRate }
    public var basePayload: Data { levels[0].payload }
    public var residentBytes: Int { levels.reduce(0) { $0 + $1.payload.count } }
    public init(sampleRate: Double, sourceFrames: Int64, framesPerBin: Int64, payload: Data) throws {
        guard sampleRate.isFinite, (1_000...768_000).contains(sampleRate), sourceFrames > 0, sourceFrames < Int64.max / 4,
              framesPerBin > 0, framesPerBin < Int64.max / 4 else { throw WaveformError.invalidData }
        let count64 = (sourceFrames - 1) / framesPerBin + 1
        guard count64 <= Self.maximumBins, payload.count == Int(count64) * Self.bytesPerBin else { throw WaveformError.invalidData }
        var current = WaveformLevel(framesPerBin: framesPerBin, sampleRate: sampleRate, payload: payload)
        guard current.isValid else { throw WaveformError.invalidData }
        var pyramid = [current]
        while current.count > 1 {
            var packed = Data(); packed.reserveCapacity((current.count + 1) / 2 * Self.bytesPerBin)
            current.payload.withUnsafeBytes { bytes in
                for first in stride(from: 0, to: current.count, by: 2) {
                    let a = WaveformLevel.bin(first, bytes: bytes)
                    let firstFrame = Int64(first) * current.framesPerBin
                    let na = Double(min(current.framesPerBin, sourceFrames - firstFrame))
                    let b = first + 1 < current.count ? WaveformLevel.bin(first + 1, bytes: bytes) : a
                    let nb = first + 1 < current.count ? Double(min(current.framesPerBin, sourceFrames - firstFrame - current.framesPerBin)) : 0
                    func energy(_ x: Float, _ y: Float) -> Float { Float(sqrt((Double(x * x) * na + Double(y * y) * nb) / (na + nb))) }
                    Self.append(WaveformBin(peak: max(a.peak, b.peak), rms: energy(a.rms, b.rms),
                                            low: energy(a.low, b.low), mid: energy(a.mid, b.mid), high: energy(a.high, b.high)), to: &packed)
                }
            }
            current = WaveformLevel(framesPerBin: current.framesPerBin * 2, sampleRate: sampleRate, payload: packed)
            pyramid.append(current)
        }
        self.sampleRate = sampleRate; self.sourceFrames = sourceFrames; self.framesPerBin = framesPerBin; levels = pyramid
    }
    public static func append(_ bin: WaveformBin, to data: inout Data) {
        for value in [bin.peak, bin.rms, bin.low, bin.mid, bin.high] {
            let bits = UInt16((min(4, max(0, value.isFinite ? value : 0)) * 16_383).rounded())
            data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
    }
    public func level(secondsPerPixel: Double) -> WaveformLevel {
        levels.last(where: { $0.secondsPerBin <= secondsPerPixel }) ?? levels[0]
    }
    public enum WaveformError: Error { case invalidData }
}

public struct WaveformLevel: Sendable {
    public let framesPerBin: Int64
    public let sampleRate: Double
    fileprivate let payload: Data
    public var secondsPerBin: Double { Double(framesPerBin) / sampleRate }
    public var count: Int { payload.count / WaveformData.bytesPerBin }
    fileprivate var isValid: Bool {
        payload.withUnsafeBytes { bytes in
            for i in 0..<(payload.count / 2) {
                let value = UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8
                if value > 65_532 { return false }
            }
            return true
        }
    }
    fileprivate static func bin(_ i: Int, bytes: UnsafeRawBufferPointer) -> WaveformBin {
        let offset = i * WaveformData.bytesPerBin
        func value(_ k: Int) -> Float { Float(UInt16(bytes[offset + k * 2]) | UInt16(bytes[offset + k * 2 + 1]) << 8) / 16_383 }
        return WaveformBin(peak: value(0), rms: value(1), low: value(2), mid: value(3), high: value(4))
    }
    public func sample(at index: Int) -> WaveformBin? {
        guard (0..<count).contains(index) else { return nil }
        return payload.withUnsafeBytes { Self.bin(index, bytes: $0) }
    }
    public func visit(start: Double, end: Double, _ body: (Double, WaveformBin) -> Void) {
        guard start.isFinite, end.isFinite, end > start else { return }
        let first = Int(max(0, min(Double(count), floor(start / secondsPerBin))))
        let last = Int(max(0, min(Double(count), ceil(end / secondsPerBin) + 1)))
        guard last > first else { return }
        payload.withUnsafeBytes { bytes in
            for i in first..<last { body((Double(i) + 0.5) * secondsPerBin, Self.bin(i, bytes: bytes)) }
        }
    }
}

public struct WaveformViewport: Sendable, Equatable {
    public let start: Double
    public let span: Double
    public init(position: Double, outputSpan: Double, rate: Double) {
        span = min(32, max(4, outputSpan.isFinite ? outputSpan : 8)) * min(1.16, max(0.84, rate.isFinite ? rate : 1))
        start = (position.isFinite ? position : 0) - span / 2
    }
    public func fraction(at sourceTime: Double) -> Double { (sourceTime - start) / span }
    public func sourceTime(at fraction: Double) -> Double { start + fraction * span }
}

public enum WaveformScale {
    public static func body(_ rms: Float) -> Double { 0.82 * pow(min(1, max(0, Double(rms))), 0.8) }
    public static func peak(_ value: Float) -> Double { 0.90 * pow(min(1, max(0, Double(value))), 0.8) }
    public static func band(_ value: Float, gain: Double) -> Double { 0.82 * pow(min(1, max(0, Double(value) * gain)), 0.8) }
}
