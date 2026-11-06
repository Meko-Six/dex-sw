import AVFoundation
import Accelerate
import DexCore

/// Fixed PCM/FFT scratch. Retain only onset and 0.5 ms band features, capped at
/// twenty minutes (~29 MiB at 48 kHz); waveform scanning can continue beyond it.
final class RhythmReader {
    static let maximumSeconds = 20 * 60.0
    private let rate = 22050.0
    private let converter: AVAudioConverter
    private let converted: AVAudioPCMBuffer
    private let hop: Int
    private let lowCoefficient: Double
    private let highCoefficient: Double
    private var l1 = 0.0, l2 = 0.0, h1 = 0.0, h2 = 0.0
    private var sumLow = 0.0, sumMid = 0.0, sumHigh = 0.0, energy = 0.0
    private var framed = 0, samples = 0
    private var previous = 0.0, nextResample = 0.0
    private var features: RhythmFeatures
    private var ring = [Double](repeating: 0, count: 256)
    private var resampledCount = 0
    private var real = [Double](repeating: 0, count: 256)
    private var imaginary = [Double](repeating: 0, count: 256)
    private var outReal = [Double](repeating: 0, count: 256)
    private var outImaginary = [Double](repeating: 0, count: 256)
    private var previousMagnitudes = [Float](repeating: 0, count: 128)
    private let window: [Double] = (0..<256).map { (i: Int) -> Double in 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 255) }
    private let fft: vDSP_DFT_SetupD
    init?(format: AVAudioFormat) {
        let analysisFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        guard format.sampleRate >= 8000, format.sampleRate <= 384_000,
              let converter = AVAudioConverter(from: format, to: analysisFormat),
              let converted = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: 32_768),
              let fft = vDSP_DFT_zop_CreateSetupD(nil, 256, .FORWARD) else { return nil }
        self.fft = fft
        self.converter = converter
        self.converted = converted
        converter.primeMethod = .none
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        hop = 11
        features = RhythmFeatures(frameSeconds: 11.0 / 22050)
        lowCoefficient = exp(-2 * .pi * 120 / 22050)
        highCoefficient = exp(-2 * .pi * 2000 / 22050)
    }
    deinit { vDSP_DFT_DestroySetupD(fft) }
    func consume(_ input: AVAudioPCMBuffer) throws {
        guard Double(samples) < Self.maximumSeconds * rate else { return }
        var supplied = false
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? WaveformReader.ReadError.unsupportedAudio as NSError }
            if converted.frameLength > 0, let channels = converted.floatChannelData {
                consumeMono(UnsafePointer(channels), frames: Int(converted.frameLength))
            }
            if status != .haveData || converted.frameLength == 0 { break }
        }
    }
    private func consumeMono(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        for frame in 0..<frames {
            guard Double(samples) < Self.maximumSeconds * rate else { return }
            var value = Double(channels[0][frame])
            if !value.isFinite { value = 0 }
            value = min(16, max(-16, value))
            energy += value * value
            l1 = (1 - lowCoefficient) * value + lowCoefficient * l1
            l2 = (1 - lowCoefficient) * l1 + lowCoefficient * l2
            h1 = (1 - highCoefficient) * value + highCoefficient * h1
            let y = value - h1
            h2 = (1 - highCoefficient) * y + highCoefficient * h2
            let high = y - h2, mid = value - l2 - high
            sumLow += l2 * l2; sumHigh += high * high; sumMid += mid * mid
            framed += 1
            if framed == hop {
                features.low.append(Float(sumLow)); features.mid.append(Float(sumMid)); features.high.append(Float(sumHigh))
                framed = 0; sumLow = 0; sumMid = 0; sumHigh = 0
            }
            while nextResample <= Double(samples) {
                let fraction = samples == 0 ? 1 : nextResample - Double(samples - 1)
                feed(previous + (value - previous) * fraction)
                nextResample += rate / 11025
            }
            previous = value
            samples += 1
        }
    }
    private func feed(_ sample: Double) {
        ring[resampledCount & 255] = sample
        resampledCount += 1
        guard resampledCount >= 256, (resampledCount - 256) % 128 == 0 else { return }
        for i in 0..<256 { real[i] = ring[(resampledCount + i) & 255] * window[i] }
        real.withUnsafeBufferPointer { re in
            imaginary.withUnsafeBufferPointer { im in
                outReal.withUnsafeMutableBufferPointer { outRe in
                    outImaginary.withUnsafeMutableBufferPointer { outIm in
                        vDSP_DFT_ExecuteD(fft, re.baseAddress!, im.baseAddress!, outRe.baseAddress!, outIm.baseAddress!)
                    }
                }
            }
        }
        var flux = 0.0, lowFlux = 0.0
        for bin in 1..<128 {
            let magnitude = Float(log1p(60 * hypot(outReal[bin], outImaginary[bin])))
            let delta = magnitude - previousMagnitudes[bin]
            if delta > 0 { flux += Double(delta); if (1...4).contains(bin) { lowFlux += Double(delta) } }
            previousMagnitudes[bin] = magnitude
        }
        features.flux.append(Float(flux)); features.lowFlux.append(Float(lowFlux))
    }
    func detect() throws -> DetectedGrid {
        // Flush the converter's small filter tail without retaining the file PCM.
        while Double(samples) < Self.maximumSeconds * rate {
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if status == .error { throw error ?? WaveformReader.ReadError.unsupportedAudio as NSError }
            if converted.frameLength > 0, let channels = converted.floatChannelData {
                consumeMono(UnsafePointer(channels), frames: Int(converted.frameLength))
            }
            if status == .endOfStream || converted.frameLength == 0 { break }
        }
        features.duration = Double(samples) / rate
        features.rms = sqrt(energy / Double(max(1, samples)))
        return try BeatDetector.detect(features)
    }
}
