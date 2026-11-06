import AVFoundation
import DexEngineBenchKit
import Foundation

// swift run -c release --package-path native DexEngineBench <what>
//   cpu      two decks with key lock on, Bungee and Apple's, offline
//   speed    how soon a change of speed reaches the sound, offline
//   jump     how soon a pressed jump is heard, on the new engine, offline
//   live     Apple's time-pitch on the real output, muted
//   clips    --out <folder> --tempos 92,104 --seconds 24 <file>...   writes comparison clips
// Nothing here plays aloud.

pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

func runCPU(music: URL?) throws {
    print("| Stretcher | Block | CPU, one core = 100% | Block p50 µs | p99 µs | Worst µs | Block lasts µs | Blocks with a landing, mean / worst |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for block in [128, 256, 512, 1024] {
        print(Bench.engineCPU(blockFrames: block).row)
        print(try Bench.appleCPU(blockFrames: block).row)
    }
    if let music {
        let file = try AVAudioFile(forReading: music, commonFormat: .pcmFormatFloat32, interleaved: false)
        let start = AVAudioFramePosition(Double(file.length) * 0.3)
        file.framePosition = start
        let count = AVAudioFrameCount(min(file.length - start, AVAudioFramePosition(90 * file.processingFormat.sampleRate)))
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: pcm)
        let channels = pcm.floatChannelData!
        let left = Array(UnsafeBufferPointer(start: channels[0], count: Int(pcm.frameLength)))
        let right = file.processingFormat.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: Int(pcm.frameLength))) : left
        print("Real music: \(music.lastPathComponent), \(file.processingFormat.sampleRate) Hz")
        print(Bench.engineCPU(blockFrames: 256, trackA: [left, right], trackB: [left, right], rate: file.processingFormat.sampleRate).row)
        print(try Bench.appleCPU(blockFrames: 256, track: [left, right], rate: file.processingFormat.sampleRate).row)
    }
}

func runSpeed() throws {
    print("| Stretcher | Speed step | Takes hold after |")
    print("| --- | --- | --- |")
    for (from, to) in [(1.0, 1.08), (1.08, 1.0), (1.0, 0.92)] {
        let result = Bench.engineSpeedResponse(from: from, to: to)
        print("| \(Bench.engineName) | \(from) to \(to) | \(result.map { String(format: "%.1f ms", $0) } ?? "no reading") |")
        let apple = try Bench.appleSpeedResponse(from: from, to: to)
        print("| Apple time-pitch (offline) | \(from) to \(to) | \(apple.map { String(format: "%.1f ms", $0) } ?? "no reading") |")
    }
}

func runJump() {
    print("| Stretcher | Tempo | Press to attack | Attack level |")
    print("| --- | --- | --- | --- |")
    for tempo in [0.92, 1.0, 1.08] {
        print(Bench.engineJump(tempo: tempo).row)
    }
    let f = Bench.stretcherFacts()
    print("\(Bench.engineName): reads ahead \(f.inputLatencyFrames) frames, output behind \(f.outputLatencyFrames), primes \(f.primingOutputFrames), block \(f.blockFrames), step \(f.intervalFrames)")
}

func runLive() throws {
    print("Output: \(LiveApple.outputDescription)")
    print("| Tempo | Delay after the time-pitch, three runs, ms |")
    print("| --- | --- |")
    for tempo in [0.84, 0.92, 1.0, 1.08, 1.16] { print(try LiveApple.delay(tempo: tempo).row) }
    print("| Tempo | Press to attack, fastest | median | slowest, ms |")
    print("| --- | --- | --- | --- |")
    for tempo in [0.92, 1.0, 1.08] { print(try LiveApple.jump(tempo: tempo).row) }
}

func option(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func slug(_ url: URL) -> String {
    let base = url.deletingPathExtension().lastPathComponent
    let words = base.split(separator: "_").dropFirst().prefix(5)
    return (words.isEmpty ? base : words.joined(separator: "-")).lowercased()
}

func runClips() throws {
    let out = URL(fileURLWithPath: option("--out") ?? "clips")
    let tempos = (option("--tempos") ?? "84,92,96,100,104,108,116").split(separator: ",").compactMap { Double($0) }
    let seconds = Double(option("--seconds") ?? "24") ?? 24
    var skip = Set<Int>()
    for name in ["--out", "--tempos", "--seconds"] {
        if let i = CommandLine.arguments.firstIndex(of: name) { skip.insert(i); skip.insert(i + 1) }
    }
    let files = CommandLine.arguments.enumerated().dropFirst(2).filter { !skip.contains($0.offset) }.map { URL(fileURLWithPath: $0.element) }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var manifest: [[String: Any]] = []
    for url in files {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let start = duration * 0.35
        let name = slug(url)
        for percent in tempos {
            let tempo = percent / 100
            let bungee = try Clips.engine(url: url, startSeconds: start, seconds: seconds, tempo: tempo)
            let appleRaw = try Clips.apple(url: url, startSeconds: start, seconds: seconds, tempo: tempo)
            let lag = Clips.lag(of: appleRaw, on: bungee)
            let apple = Clips.trimmed(appleRaw, by: lag)
            // Matched in loudness to Apple's, then all pulled down together if any would clip.
            let target = Clips.rms(apple)
            let gains = [Float(target / Clips.rms(bungee)), 1]
            let versions = [("bungee", bungee), ("apple", apple)]
            var peak: Float = 0
            for (i, version) in versions.enumerated() { peak = max(peak, Clips.peak(version.1) * gains[i]) }
            let headroom = peak > 0.98 ? 0.98 / peak : 1
            let frames = Int(seconds * 48_000) - 480
            for (i, version) in versions.enumerated() {
                let path = "\(name)-\(Int(percent))-\(version.0).wav"
                try Clips.write(version.1, gain: gains[i] * headroom, frames: frames, to: out.appendingPathComponent(path))
            }
            let line = String(format: "%@ at %.0f%%: Apple trimmed by %.1f ms, level matched by Bungee %+.2f dB",
                              name, percent, Double(lag) / 48, 20 * log10(Double(gains[0])))
            print(line)
            manifest.append(["track": name, "tempo": Int(percent), "appleTrimMs": Double(lag) / 48,
                             "bungeeDb": 20 * log10(Double(gains[0]))])
        }
    }
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("clips.json"))
    try ListenPage.write(to: out, tracks: files.map(slug), tempos: tempos.map { Int($0) })
}

/// Reads the finished clips back: each set must line up, and none may be silent or clipped.
func checkClips() throws {
    let folder = URL(fileURLWithPath: option("--out") ?? "clips")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
    func read(_ url: URL) throws -> Clips.Rendered {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        let c = pcm.floatChannelData!, n = Int(pcm.frameLength)
        return Clips.Rendered(left: Array(UnsafeBufferPointer(start: c[0], count: n)), right: Array(UnsafeBufferPointer(start: c[1], count: n)))
    }
    var worst = 0.0
    var sizes = 0
    for apple in files.filter({ $0.lastPathComponent.hasSuffix("-apple.wav") }).sorted(by: { $0.path < $1.path }) {
        let base = apple.path.replacingOccurrences(of: "-apple.wav", with: "")
        let a = try read(apple)
        var row = apple.lastPathComponent.replacingOccurrences(of: "-apple.wav", with: "")
        row += String(format: ", Apple rms %.3f peak %.3f", Clips.rms(a), Clips.peak(a))
        sizes += a.left.count
        for name in ["bungee"] {
            let other = try read(URL(fileURLWithPath: base + "-\(name).wav"))
            let early = Clips.lag(of: other, on: a, maxSeconds: 0.25), late = Clips.lag(of: a, on: other, maxSeconds: 0.25)
            let offset = Double(early > late ? early : -late) / 48
            worst = max(worst, abs(offset))
            row += String(format: "; \(name) %+.1f ms rms %.3f peak %.3f", offset, Clips.rms(other), Clips.peak(other))
        }
        print(row)
    }
    print("worst offset between versions \(worst) ms, clips \(files.count)")
}

switch CommandLine.arguments.dropFirst().first {
case "checkclips": try checkClips()
case "cpu": try runCPU(music: option("--music").map { URL(fileURLWithPath: $0) })
case "speed": try runSpeed()
case "jump": runJump()
case "live": try runLive()
case "clips": try runClips()
case "memory":
    print("Memory for \(Bench.engineName), four voices and scratch: \(String(format: "%.1f", Double(Bench.engineFootprint()) / 1024 / 1024)) MiB")
default:
    print("usage: DexEngineBench cpu|speed|jump|live|clips")
    exit(2)
}
