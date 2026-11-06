import AVFoundation
import CoreAudio
import Darwin
import DexAudio

// Measures graph-to-ear delay acoustically: test clicks out, built-in mic in, both on host time.
// Audio stays in memory; nothing recorded is written to disk.
func seconds(_ host: UInt64) -> Double { AVAudioTime.seconds(forHostTime: host) }
func now() -> Double { seconds(mach_absolute_time()) }
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var a = addr(s, scope), v = UInt32(0), n = UInt32(4)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr ? v : 0
}
func rate(_ d: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal), v = Float64(0), n = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &n, &v); return v
}
func name(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal), r: Unmanaged<CFString>?, n = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &n, &r); return r?.takeRetainedValue() as String? ?? "?"
}
func streams(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
    var a = addr(kAudioDevicePropertyStreams, scope), size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, &ids); return ids
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal), size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids); return ids
}
/// Dex's own formula from `OutputLatency`: device plus first stream.
func reported(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Double {
    let first = streams(d, scope).first.map { u32($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? 0
    return Double(u32(d, kAudioDevicePropertyLatency, scope) + first) / rate(d)
}

final class Mic {
    let device: AudioObjectID, sampleRate: Double
    let capacity: Int
    let samples: UnsafeMutablePointer<Float>
    let anchorIndex = UnsafeMutablePointer<Int>.allocate(capacity: 400_000)
    let anchorHost = UnsafeMutablePointer<UInt64>.allocate(capacity: 400_000)
    var count = 0, anchors = 0
    var proc: AudioDeviceIOProcID?
    init(_ device: AudioObjectID) {
        self.device = device; sampleRate = rate(device); capacity = Int(sampleRate * 150)
        samples = .allocate(capacity: capacity)
    }
    func start() -> Bool {
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [self] _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = list.first, let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
            let channels = Int(buffer.mNumberChannels), frames = Int(buffer.mDataByteSize) / 4 / channels
            guard count + frames < capacity, anchors < 400_000 else { return }
            let p = data.assumingMemoryBound(to: Float.self)
            anchorIndex[anchors] = count; anchorHost[anchors] = inputTime.pointee.mHostTime; anchors += 1
            for i in 0..<frames { samples[count + i] = p[i * channels] }
            count += frames
        }
        return status == noErr && AudioDeviceStart(device, proc) == noErr
    }
    func stop() { AudioDeviceStop(device, proc); if let proc { AudioDeviceDestroyIOProcID(device, proc) } }
    /// Host seconds of a sample, from the callback stamp that holds it.
    func time(ofSample index: Int) -> Double {
        var lo = 0, hi = anchors - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if anchorIndex[mid] <= index { lo = mid } else { hi = mid - 1 } }
        return seconds(anchorHost[lo]) + Double(index - anchorIndex[lo]) / sampleRate
    }
    func index(ofTime t: Double) -> Int {
        var lo = 0, hi = anchors - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if seconds(anchorHost[mid]) <= t { lo = mid } else { hi = mid - 1 } }
        return max(0, min(count - 1, anchorIndex[lo] + Int((t - seconds(anchorHost[lo])) * sampleRate)))
    }
    /// Raw level over the last second, dBFS.
    func level() -> (rms: Double, peak: Double) {
        let n = min(count, Int(sampleRate)); guard n > 0 else { return (-200, -200) }
        var sum = 0.0, peak = 0.0
        for i in (count - n)..<count { let v = Double(samples[i]); sum += v * v; peak = max(peak, abs(v)) }
        return (10 * log10(max(1e-20, sum / Double(n))), 20 * log10(max(1e-10, peak)))
    }
    /// First strong arrival in a window, on a first-difference high-pass.
    func onset(from a: Double, to b: Double) -> (time: Double, snr: Double, peak: Float)? {
        let start = index(ofTime: a), end = index(ofTime: b); guard end > start + 8 else { return nil }
        var diff = [Float](repeating: 0, count: end - start), top: Float = 0, raw: Float = 0
        for i in (start + 1)..<end { let d = abs(samples[i] - samples[i - 1]); diff[i - start] = d; top = max(top, d); raw = max(raw, abs(samples[i])) }
        let median = diff.sorted()[diff.count / 2]
        let snr = Double(top) / Double(max(1e-9, median * 1.48))
        guard let first = diff.firstIndex(where: { $0 >= top * 0.25 }) else { return nil }
        return (time(ofSample: start + first), snr, raw)
    }
}

func clickTrack(duration: Double, clicks: [Double], gain: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000))!
    buffer.frameLength = buffer.frameCapacity
    for c in 0..<2 { buffer.floatChannelData![c].update(repeating: 0, count: Int(buffer.frameLength)) }
    for click in clicks {
        let at = Int((click * 48_000).rounded())
        for i in 0..<720 where at + i < Int(buffer.frameLength) {
            let t = Double(i) / 48_000
            let v = gain * Float(cos(2 * .pi * 3_000 * t) * exp(-t / 0.003))
            for c in 0..<2 { buffer.floatChannelData![c][at + i] = v }
        }
    }
    return buffer
}
func stats(_ title: String, _ values: [Double], reported: Double?, clicks: Int) {
    guard !values.isEmpty else { print("\(title): no clicks detected out of \(clicks)"); return }
    let s = values.sorted(), median = s[s.count / 2] * 1000
    var line = String(format: "\(title): %d/%d clicks, median %.1f ms, range %.1f to %.1f ms", values.count, clicks, median, s[0] * 1000, s[s.count - 1] * 1000)
    if let reported { line += String(format: ", reported %.1f ms, difference %+.1f ms", reported * 1000, median - reported * 1000) }
    print(line)
    print("  each: " + values.map { String(format: "%.1f", $0 * 1000) }.joined(separator: " "))
}
func detect(_ mic: Mic, centres: [Double], micDelay: Double) -> [Double] {
    var out = [Double]()
    for centre in centres {
        guard let hit = mic.onset(from: centre - 0.6, to: centre + 0.6) else { print("  click near \(centre): no data"); continue }
        if hit.snr < 12 { print(String(format: "  click rejected, snr %.1f", hit.snr)); continue }
        if hit.peak > 0.98 { print("  warning: mic clipped") }
        out.append(hit.time - micDelay - centre)
    }
    return out
}

/// Plain engine: graph time is known exactly, since the buffer starts at a scheduled host time.
func plain(_ title: String, device: AudioObjectID?, gain: Float, mic: Mic, micDelay: Double, expected: Double, reported r: Double) async throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    if let device { try engine.outputNode.auAudioUnit.setDeviceID(device) }
    engine.attach(player)
    let clicks = (0..<10).map { 0.5 + Double($0) * 1.5 }
    let buffer = clickTrack(duration: 16.5, clicks: clicks, gain: gain)
    engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
    engine.mainMixerNode.outputVolume = 1
    try engine.start()
    try await Task.sleep(for: .seconds(1.5))
    player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    let t0 = now() + 1.0
    player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: t0)))
    try await Task.sleep(for: .seconds(1.0 + 16.5))
    player.stop(); engine.stop()
    let graph = clicks.map { t0 + $0 }
    let offsets = detect(mic, centres: graph.map { $0 + expected }, micDelay: micDelay).map { $0 + expected }
    stats(title + " (scheduled to heard)", offsets, reported: r, clicks: clicks.count)
}

/// Dex's real graph on the default output: how far the waveform's position is from the sound.
@MainActor func dexEngine(mic: Mic, micDelay: Double, output: AudioObjectID) async throws {
    let clicks = (0..<18).map { 3.0 + Double($0) * 1.5 }
    let buffer = clickTrack(duration: 32, clicks: clicks, gain: 0.7)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dex-delay-clicks-\(UUID().uuidString).wav")
    do { let f = try AVAudioFile(forWriting: url, settings: buffer.format.settings); try f.write(from: buffer) }
    defer { try? FileManager.default.removeItem(at: url) }
    let mixer = NativeMixer()
    mixer.a.load(url)
    while mixer.a.loading { try await Task.sleep(for: .milliseconds(10)) }
    guard mixer.a.duration > 0, mixer.a.error == nil else { print("load failed: \(String(describing: mixer.a.error))"); return }
    mixer.crossfader = 0; mixer.a.level = 1; mixer.volume = 0.7
    mixer.start()
    for _ in 0..<400 where mixer.audioState != .ready { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .seconds(1.5))
    print("Dex engine: state \(mixer.audioState), notice \(String(describing: mixer.notice)), output latency \(String(format: "%.1f", mixer.a.outputLatency * 1000)) ms")
    mixer.a.togglePlay()
    guard mixer.a.playing else { print("deck did not start"); return }
    let began = now()
    var trace = [(t: Double, p: Double)]()
    while now() - began < 22 {
        trace.append((now(), mixer.a.heardPosition(ahead: 0)))
        try await Task.sleep(for: .milliseconds(4))
    }
    mixer.a.togglePlay(); mixer.shutdown(); try await Task.sleep(for: .seconds(0.5))
    let moved = trace.filter { $0.t > began + 1 }
    print(String(format: "position from %.3f to %.3f over %.3f s", moved.first?.p ?? -1, moved.last?.p ?? -1, (moved.last?.t ?? 0) - (moved.first?.t ?? 0)))
    // When the waveform's position reaches each click.
    var shown = [Double]()
    for click in clicks {
        guard let j = moved.firstIndex(where: { $0.p >= click }), j > 0 else { continue }
        let (a, b) = (moved[j - 1], moved[j]); guard b.p > a.p, b.t - a.t < 0.1 else { continue }
        let t = a.t + (click - a.p) / (b.p - a.p) * (b.t - a.t)
        if t < now() - 0.7 { shown.append(t) }
    }
    let errors = detect(mic, centres: shown, micDelay: micDelay)
    stats("Dex engine on \(name(output)) (sound after waveform: + waveform early, - waveform late)", errors, reported: nil, clicks: shown.count)
    if !errors.isEmpty {
        let median = errors.sorted()[errors.count / 2]
        print(String(format: "implied real delay through Dex's chain: %.1f ms (Dex uses %.1f ms)", (reported(output, kAudioObjectPropertyScopeOutput) + median) * 1000, reported(output, kAudioObjectPropertyScopeOutput) * 1000))
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0); print("mic permission…")
        guard await AVCaptureDevice.requestAccess(for: .audio) else { print("MIC DENIED"); exit(3) }
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal), output = AudioObjectID(0), n = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &output)
        let bluetooth = u32(output, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeBluetooth
        let builtin = devices().filter { u32($0, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeBuiltIn }
        guard let micDevice = builtin.first(where: { !streams($0, kAudioObjectPropertyScopeInput).isEmpty }),
              let speakers = builtin.first(where: { !streams($0, kAudioObjectPropertyScopeOutput).isEmpty }) else { print("no built-in devices"); exit(4) }
        print("output \(name(output)) rate \(rate(output)) bluetooth \(bluetooth); mic \(name(micDevice)) rate \(rate(micDevice)); speakers \(name(speakers))")
        guard bluetooth else { print("DEFAULT OUTPUT IS NOT BLUETOOTH, stopping"); exit(5) }
        let micDelay = reported(micDevice, kAudioObjectPropertyScopeInput)
        let bose = reported(output, kAudioObjectPropertyScopeOutput), internalDelay = reported(speakers, kAudioObjectPropertyScopeOutput)
        print(String(format: "reported: mic %.1f ms, Bose %.1f ms, built-in speakers %.1f ms", micDelay * 1000, bose * 1000, internalDelay * 1000))
        let mic = Mic(micDevice)
        guard mic.start() else { print("mic failed to start"); exit(6) }
        try await Task.sleep(for: .seconds(1.5))
        let quiet = mic.level()
        print(String(format: "room before clicks: rms %.1f dBFS, peak %.1f dBFS", quiet.rms, quiet.peak))
        if quiet.rms == -200 || mic.count == 0 { print("MIC SILENT, stopping"); exit(7) }
        try await plain("control, Mac speakers", device: speakers, gain: 0.25, mic: mic, micDelay: micDelay, expected: internalDelay, reported: internalDelay)
        try await plain("plain engine, Bose", device: nil, gain: 0.7, mic: mic, micDelay: micDelay, expected: bose, reported: bose)
        // Twice, since the Bluetooth link itself moves between runs.
        try await dexEngine(mic: mic, micDelay: micDelay, output: output)
        try await Task.sleep(for: .seconds(1))
        try await dexEngine(mic: mic, micDelay: micDelay, output: output)
        mic.stop()
        print("done, default output still \(name(output))")
        exit(0)
    }
}
