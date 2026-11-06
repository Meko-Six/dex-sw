import AVFoundation
import CDexDSP
import DexCore

/// Immutable compact envelopes. A lease follows loaded data; rendering never
/// reserves memory or touches decoded audio. Base and pyramid total <5 MiB.
public final class TrackWaveform: Sendable, Identifiable {
    public let data: WaveformData
    public var id: UUID { data.id }
    private let reservation: AudioMemoryBudget.Lease
    init(data: WaveformData, reservation: AudioMemoryBudget.Lease) { self.data = data; self.reservation = reservation }
    static func decode(sampleRate: Double, frames: Int64, step: Int64, payload: Data) throws -> TrackWaveform {
        guard payload.count <= WaveformData.maximumBins * WaveformData.bytesPerBin else { throw WaveformData.WaveformError.invalidData }
        let lease = try AudioMemoryBudget.shared.reserve(Int64(max(1, payload.count)) * 2 + 1024)
        let data = try WaveformData(sampleRate: sampleRate, sourceFrames: frames, framesPerBin: step, payload: payload)
        return TrackWaveform(data: data, reservation: lease)
    }
}

final class WaveformEnvelopeBuilder {
    private let state: OpaquePointer
    private let rate: Double
    private let step: Int64
    private let reservation: AudioMemoryBudget.Lease
    private var payload = Data()
    private let scratch: UnsafeMutablePointer<DexWaveBin>
    private let scratchCount: Int
    init(format: AVAudioFormat, frames: Int64, chunkFrames: UInt32) throws {
        rate = format.sampleRate
        step = max(1, Int64(ceil(rate / 200)), (frames - 1) / Int64(WaveformData.maximumBins) + 1)
        let count = (frames - 1) / step + 1
        scratchCount = Int(Int64(chunkFrames) / step + 3)
        reservation = try AudioMemoryBudget.shared.reserve(count * Int64(WaveformData.bytesPerBin) * 2 + Int64(scratchCount * 20) + 1024)
        guard let state = dex_waveform_create(rate, format.channelCount, step) else { throw WaveformReader.ReadError.invalidBudget }
        self.state = state
        scratch = .allocate(capacity: scratchCount)
        payload.reserveCapacity(Int(count) * WaveformData.bytesPerBin)
    }
    deinit { dex_waveform_destroy(state); scratch.deallocate() }
    func consume(_ buffer: AVAudioPCMBuffer) throws {
        try Task.checkCancellation()
        guard let channels = buffer.floatChannelData else { throw WaveformReader.ReadError.unsupportedAudio }
        let count = dex_waveform_consume(state, channels[0], buffer.format.channelCount == 2 ? channels[1] : nil,
                                         buffer.frameLength, scratch, UInt32(scratchCount))
        for i in 0..<Int(count) { append(scratch[i]) }
    }
    private func append(_ bin: DexWaveBin) {
        WaveformData.append(WaveformBin(peak: bin.peak, rms: bin.rms, low: bin.low, mid: bin.mid, high: bin.high), to: &payload)
    }
    func finish(frames: Int64) throws -> TrackWaveform {
        if dex_waveform_finish(state, scratch) > 0 { append(scratch[0]) }
        let data = try WaveformData(sampleRate: rate, sourceFrames: frames, framesPerBin: step, payload: payload)
        return TrackWaveform(data: data, reservation: reservation)
    }
}
