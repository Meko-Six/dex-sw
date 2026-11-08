import AppKit
import AVFoundation
import Darwin
import DexAudio
import DexConsole
import DexCore
import SwiftUI

/// Plays two synthetic tracks through the real console in a window, with no audio,
/// and measures how evenly the zoom lanes move. Run the release build:
///
///   swift run -c release --package-path native DexWaveProfile [--span 12] [--seconds 15]
///
/// `interval` is the time between a lane's draws. `step` is how far the waveform moved
/// between them, in device pixels, and `uneven` the share of steps over a third off the
/// usual one: what the eye reads as a jump.
///
/// `--audio 1` plays two real tracks through the deck engine instead, muted on the device,
/// with key lock on both, deck B synced to A from another tempo and the EQ moving, and the
/// lanes reading the decks' own `heardPosition(ahead:)`, as the app does.
var options = ["--span": "12", "--seconds": "15", "--ticker": "1", "--audio": "0", "--window": "1"]
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let key = arguments.next(), let value = arguments.next() { options[key] = value }
guard let span = Double(options["--span"]!), let seconds = Double(options["--seconds"]!) else { exit(2) }

func track(seed: UInt64) throws -> WaveformData {
    let rate = 48_000.0, framesPerBin: Int64 = 240, length = 300.0
    let count = (Int(length * rate) - 1) / Int(framesPerBin) + 1
    var payload = Data(capacity: count * WaveformData.bytesPerBin)
    var random = seed
    for index in 0..<count {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let noise = Float(random >> 40) / Float(1 << 24)
        let time = Double(index) * Double(framesPerBin) / rate
        let beat = (time / 0.48).truncatingRemainder(dividingBy: 1)
        let low = Float(exp(-beat * 6)) * 0.55, high = noise * 0.12 + Float(exp(-((beat - 0.5) * (beat - 0.5)) * 400)) * 0.3
        let mid = noise * 0.2 + 0.08
        WaveformData.append(WaveformBin(peak: max(low, mid, high), rms: low * 0.7, low: low, mid: mid, high: high), to: &payload)
    }
    return try WaveformData(sampleRate: rate, sourceFrames: Int64(length * rate), framesPerBin: framesPerBin, payload: payload)
}

final class Draws: @unchecked Sendable {
    struct Draw { let time, start, span, seconds: Double; let columns: Int }
    private let lock = NSLock()
    private var byLane: [UUID: [Draw]] = [:]
    func add(_ id: UUID, _ draw: Draw) { lock.lock(); byLane[id, default: []].append(draw); lock.unlock() }
    var lanes: [[Draw]] { lock.lock(); defer { lock.unlock() }; return Array(byLane.values) }
}
let draws = Draws()
WaveProbe.drew = { id, start, span, columns, cost in
    draws.add(id, .init(time: ProcessInfo.processInfo.systemUptime, start: start, span: span, seconds: cost, columns: columns))
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}
func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var state = ConsoleState.demos["home"]!
state.spanSec = span
let positions = [40.0, 90.0]
let withAudio = options["--audio"] == "1"
/// A beat, a hat and a pad, so every band has something in it.
func audioTrack(bpm: Double, seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexWaveProfile-\(Int(bpm))-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    pcm.frameLength = 48_000
    let beat = 60 / bpm
    var random: UInt64 = UInt64(bpm)
    for second in 0..<Int(seconds) {
        for i in 0..<48_000 {
            let t = Double(second) + Double(i) / 48_000
            let phase = t.truncatingRemainder(dividingBy: beat), half = (t + beat / 2).truncatingRemainder(dividingBy: beat)
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(Int64(bitPattern: random) >> 40) / Double(1 << 23)
            let kick = sin(2 * .pi * 55 * phase * (1 + exp(-phase * 30))) * exp(-phase * 9) * 0.5
            let hat = noise * exp(-half * 60) * 0.15
            let pad = sin(2 * .pi * 440 * t) * 0.05 + sin(2 * .pi * 660 * t) * 0.04
            pcm.floatChannelData![0][i] = Float(kick + hat + pad)
            pcm.floatChannelData![1][i] = Float(kick + hat * 0.8 + pad)
        }
        try file.write(from: pcm)
    }
    return url
}
@MainActor func startAudio() async throws -> NativeMixer {
    let mixer = NativeMixer(mutedAfterEngine: true) // Nothing reaches the device.
    mixer.volume = 1
    let urls = [try audioTrack(bpm: 120, seconds: 180), try audioTrack(bpm: 126, seconds: 200)]
    mixer.a.load(urls[0]); mixer.b.load(urls[1])
    for _ in 0..<6000 where mixer.a.loading || mixer.b.loading || mixer.a.waveform == nil || mixer.b.waveform == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    for url in urls { try? FileManager.default.removeItem(at: url) }
    guard mixer.a.waveform != nil, mixer.b.waveform != nil else { print("tracks didn't load: \(mixer.a.error ?? "") \(mixer.b.error ?? "")"); exit(3) }
    mixer.a.setGrid(bpm: 120); mixer.b.setGrid(bpm: 126)
    mixer.a.keyLock = true; mixer.b.keyLock = true
    mixer.a.level = 1; mixer.b.level = 1; mixer.crossfader = 0.5
    mixer.start()
    for _ in 0..<500 where mixer.audioState != .ready { try await Task.sleep(for: .milliseconds(10)) }
    mixer.a.seek(to: positions[0]); mixer.b.seek(to: positions[1])
    mixer.a.togglePlay()
    try await Task.sleep(for: .milliseconds(500))
    mixer.b.toggleSync(); mixer.b.togglePlay()
    print("audio: state \(mixer.audioState), muted")
    return mixer
}
// Started from a task while the run loop turns: an await at the top level would hold the main
// actor through app.run(), and nothing on it could run.
nonisolated(unsafe) var started: NativeMixer?
nonisolated(unsafe) var startDone = !withAudio
if withAudio { Task { @MainActor in started = try? await startAudio(); startDone = true } }
while !startDone { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
let mixer = started
if withAudio && mixer == nil { print("audio didn't start"); exit(3) }
let decks = mixer.map { [$0.a, $0.b] } ?? []
for index in state.decks.indices {
    if let deck = decks.dropFirst(index).first, let wave = deck.waveform {
        state.decks[index].wave = .track(wave.data)
        state.decks[index].durationSec = deck.duration
    } else {
        state.decks[index].wave = .track(try track(seed: UInt64(index + 1)))
        state.decks[index].durationSec = 300
    }
    state.decks[index].playing = true
    state.decks[index].position = positions[index]
}
let clock = ConsoleClock()
let origin = ProcessInfo.processInfo.systemUptime
nonisolated(unsafe) var frames: [Double] = []
@MainActor func position(_ deck: Int, at time: Double) -> Double {
    if !decks.isEmpty { return decks[deck].heardPosition(ahead: time - ProcessInfo.processInfo.systemUptime) }
    return positions[deck] + (time - origin)
}
let ids = state.decks.map(\.id)
for (index, id) in ids.enumerated() {
    clock.lane(id).heard = { ahead in
        if index == 0 { frames.append(ProcessInfo.processInfo.systemUptime) }
        return position(index, at: ProcessInfo.processInfo.systemUptime + ahead)
    }
}
clock.running = true
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: Stage.width, height: Stage.height), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Dex waveform profile"
window.level = .floating
// `--window 0` leaves the console out, so the process's CPU is the audio's alone.
if options["--window"] != "0" {
    window.contentView = NSHostingView(rootView: FittedConsole(state: state, clock: clock))
    window.orderFrontRegardless()
}

// The app's ticker: readouts about 30 times a second, the meter at half that.
_ = Task { @MainActor in
    var tick = 0
    while true {
        let now = ProcessInfo.processInfo.systemUptime
        if options["--ticker"] == "1" { for (index, id) in ids.enumerated() { clock.deck(id).position = position(index, at: now) } }
        tick += 1
        if options["--ticker"] == "1" {
            let swing = -12 - 6 * sin(now)
            let levels = MeterLevels(a: swing, l: swing + 6, r: swing + 5, b: swing - 3)
            clock.meter.meters = Meters(level: levels, hold: levels)
        }
        // The EQ keeps moving on both decks, as a DJ's hands would.
        for (index, deck) in decks.enumerated() {
            let swing = Float(sin(now * 1.3 + Double(index)))
            deck.lowDB = swing * 12; deck.midDB = -swing * 8; deck.highDB = Float(cos(now * 0.7)) * 10
        }
        try await Task.sleep(for: .milliseconds(33))
    }
}

let screen = window.screen ?? NSScreen.main
_ = Task { @MainActor in
    try await Task.sleep(for: .seconds(2)) // Let the first layout settle.
    let settled = ProcessInfo.processInfo.systemUptime, cpuBefore = cpuSeconds()
    try await Task.sleep(for: .seconds(seconds))
    let elapsed = ProcessInfo.processInfo.systemUptime - settled, cpu = cpuSeconds() - cpuBefore
    print(String(format: "span %.0f s, %.0f s, display %d Hz, backing %.0fx, process CPU %.0f%%",
                 span, elapsed, screen?.maximumFramesPerSecond ?? 0, window.backingScaleFactor, cpu / elapsed * 100))
    if let mixer {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        print(String(format: "audio: memory footprint %.0f MiB; both decks playing %@; %@", Double(info.phys_footprint) / 1_048_576,
                     mixer.a.playing && mixer.b.playing ? "yes" : "NO", mixer.engineReport))
    }
    let frameGaps = zip(frames, frames.dropFirst()).filter { $0.0 >= settled }.map { ($1 - $0) * 1000 }.sorted()
    print(String(format: "display link: %.1f/s; ms p50 %.1f p95 %.1f max %.1f", Double(frameGaps.count) / elapsed, percentile(frameGaps, 0.5), percentile(frameGaps, 0.95), frameGaps.last ?? 0))
    for lane in draws.lanes {
        let kept = lane.filter { $0.time >= settled }
        guard kept.count > 2 else { print("too few draws"); continue }
        let intervals = zip(kept, kept.dropFirst()).map { ($1.time - $0.time) * 1000 }.sorted()
        let costs = kept.map { $0.seconds * 1000 }.sorted()
        let perPixel = kept[0].span / Double(kept[0].columns)
        let steps = zip(kept, kept.dropFirst()).map { ($1.start - $0.start) / perPixel }.sorted()
        let usual = percentile(steps, 0.5)
        let uneven = Double(steps.filter { abs($0 - usual) > usual / 3 }.count) / Double(steps.count) * 100
        print(String(format: "lane: %.1f draws/s; interval ms p50 %.1f p95 %.1f p99 %.1f max %.1f; draw ms p50 %.2f p95 %.2f max %.2f; step px p50 %.2f p95 %.2f max %.2f, uneven %.1f%%; columns %d",
                     Double(kept.count) / elapsed, percentile(intervals, 0.5), percentile(intervals, 0.95), percentile(intervals, 0.99), intervals.last!,
                     percentile(costs, 0.5), percentile(costs, 0.95), costs.last!,
                     usual, percentile(steps, 0.95), steps.last!, uneven, kept[0].columns))
    }
    exit(0)
}
app.run()
