import AVFoundation
import CDexEngine
import Foundation

// Gate 2 of docs/ENGINE-REBUILD-SPEC.md: measures Bungee against Apple's
// time-pitch, and renders comparison clips to files. Nothing here ever plays aloud: engines are
// offline, or live with the output volume at zero and a tap reading the signal before it.

public enum BenchSignal {
    /// A busy stand-in for music, so the same material can run on any device: kick, bass, chords,
    /// hats and a noise bed, deterministic. Spectral stretchers work hardest on dense material.
    public static func music(seconds: Double, rate: Double = 48_000) -> [[Float]] {
        let frames = Int(seconds * rate)
        var left = [Float](repeating: 0, count: frames), right = left
        let beat = rate * 60 / 140
        var seed: UInt32 = 12345
        func noise() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        let chords: [[Double]] = [[110, 220, 277.2, 329.6], [98, 196, 246.9, 293.7], [130.8, 261.6, 329.6, 392], [87.3, 174.6, 220, 261.6]]
        for i in 0..<frames {
            let t = Double(i)
            let beatPos = t.truncatingRemainder(dividingBy: beat)
            let bar = Int(t / (beat * 16)) % chords.count
            // Kick with a falling pitch.
            let kickT = beatPos / rate
            var value = 0.7 * sin(2 * .pi * (50 * kickT + 12 * (1 - exp(-kickT * 28)))) * exp(-kickT * 11)
            // Rolling offbeat bass.
            let bassT = (beatPos - beat / 2) / rate
            if bassT > 0 { value += 0.3 * sin(2 * .pi * chords[bar][0] * 0.5 * t / rate) * exp(-bassT * 8) }
            // Chords: a stack of harmonics.
            var chord = 0.0
            for note in chords[bar] {
                for harmonic in 1...5 { chord += sin(2 * .pi * note * Double(harmonic) * t / rate) / Double(harmonic * harmonic) }
            }
            value += 0.06 * chord
            // Hats on the offbeat, and a little air everywhere.
            let hatT = ((t + beat / 2).truncatingRemainder(dividingBy: beat)) / rate
            let hat = noise() * Float(0.2 * exp(-hatT * 60) + 0.01)
            left[i] = Float(value) + hat
            right[i] = Float(value) - hat * 0.5
        }
        return [left, right]
    }

    /// A repeating frequency sweep: the frequency says where in the track the sound comes from,
    /// and a stretcher keeps frequency, so it shows when a change of speed really takes hold.
    public static func sweeps(seconds: Double, rate: Double = 48_000, period: Double = 2, low: Double = 500, high: Double = 4500) -> [[Float]] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames)
        var phase = 0.0
        for i in 0..<frames {
            let t = (Double(i) / rate).truncatingRemainder(dividingBy: period)
            let hz = low + (high - low) * t / period
            phase += 2 * .pi * hz / rate
            if phase > 2 * .pi { phase -= 2 * .pi }
            out[i] = Float(0.5 * sin(phase))
        }
        return [out, out]
    }

    public static func clicks(seconds: Double, every: Double, rate: Double = 48_000) -> [[Float]] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames)
        var at = every * rate
        while Int(at) + 1000 < frames {
            for k in 0..<720 {
                out[Int(at) + k] = Float(0.8 * sin(2 * .pi * 3000 * Double(k) / rate) * exp(-Double(k) / (0.003 * rate)))
            }
            at += every * rate
        }
        return [out, out]
    }
}

/// A track held in memory, for the engine's loader to read as if it were a file.
final class MemoryTrack {
    let samples: [[Float]]
    let rate: Double
    init(samples: [[Float]], rate: Double) { self.samples = samples; self.rate = rate }
    var source: DexTrackSource {
        var s = DexTrackSource()
        s.context = Unmanaged.passUnretained(self).toOpaque()
        s.frames = Int64(samples[0].count)
        s.sampleRate = rate
        s.read = { context, frame, count, left, right in
            let track = Unmanaged<MemoryTrack>.fromOpaque(context!).takeUnretainedValue()
            let start = Int(frame), n = min(Int(count), track.samples[0].count - start)
            guard n > 0 else { return 0 }
            track.samples[0].withUnsafeBufferPointer { left!.update(from: $0.baseAddress! + start, count: n) }
            track.samples[1].withUnsafeBufferPointer { right!.update(from: $0.baseAddress! + start, count: n) }
            return Int32(n)
        }
        return s
    }
}

/// A real file, decoded on the loader's thread.
final class FileTrack {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 17)!
    }
    var source: DexTrackSource {
        var s = DexTrackSource()
        s.context = Unmanaged.passUnretained(self).toOpaque()
        s.frames = file.length
        s.sampleRate = file.processingFormat.sampleRate
        s.read = { context, frame, count, left, right in
            let track = Unmanaged<FileTrack>.fromOpaque(context!).takeUnretainedValue()
            track.file.framePosition = frame
            track.buffer.frameLength = 0
            guard (try? track.file.read(into: track.buffer, frameCount: min(count, track.buffer.frameCapacity))) != nil else { return -1 }
            let n = Int(track.buffer.frameLength)
            let channels = track.buffer.floatChannelData!
            left!.update(from: channels[0], count: n)
            right!.update(from: channels[track.file.processingFormat.channelCount > 1 ? 1 : 0], count: n)
            return Int32(n)
        }
        return s
    }
}

private func makeEngine(rate: Double = 48_000, maxFrames: UInt32 = 4096) -> OpaquePointer {
    var config = DexEngineConfig()
    config.sampleRate = rate
    config.maxFrames = maxFrames
    config.hostTicksPerSecond = 1e9
    return dex_engine_create(&config)!
}

private func timeNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
private func threadTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

public struct CPUResult: Sendable {
    public var name: String
    public var blockFrames: Int
    public var percentOfOneCore: Double   // thread CPU over audio time
    public var p50, p99, worst: Double    // microseconds per block, wall clock
    public var deadline: Double           // microseconds a block has
    public var landingMean: Double        // microseconds, blocks with a landing in them
    public var landingWorst: Double
    public var landings: Int
    public var row: String {
        String(format: "| %@ | %d | %.1f%% | %.0f | %.0f | %.0f | %.0f | %@ |",
               name, blockFrames, percentOfOneCore, p50, p99, worst, deadline,
               landings > 0 ? String(format: "%.0f / %.0f µs over %d", landingMean, landingWorst, landings) : "n/a")
    }
}

private func summarise(name: String, blockFrames: Int, seconds: Double, rate: Double, cpu: UInt64, times: [UInt64], landingTimes: [UInt64]) -> CPUResult {
    let sorted = times.sorted()
    func microseconds(_ t: UInt64) -> Double { Double(t) / 1000 }
    let landingSum = landingTimes.reduce(0, +)
    return CPUResult(name: name, blockFrames: blockFrames,
                     percentOfOneCore: Double(cpu) / 1e9 / seconds * 100,
                     p50: microseconds(sorted[sorted.count / 2]), p99: microseconds(sorted[sorted.count * 99 / 100]), worst: microseconds(sorted.last!),
                     deadline: Double(blockFrames) / rate * 1e6,
                     landingMean: landingTimes.isEmpty ? 0 : microseconds(landingSum / UInt64(landingTimes.count)),
                     landingWorst: microseconds(landingTimes.max() ?? 0), landings: landingTimes.count)
}

public enum Bench {
    public static let engineName = "Bungee Basic"
    public static let music: [[Float]] = BenchSignal.music(seconds: 90)

    /// Two decks with key lock on, both playing and both jumping every few seconds. Decoding is
    /// outside the timing: in the app that's on the loader's thread.
    public static func engineCPU(blockFrames: Int, seconds: Double = 40, trackA: [[Float]]? = nil, trackB: [[Float]]? = nil, rate sourceRate: Double = 48_000) -> CPUResult {
        let rate = 48_000.0
        let engine = makeEngine()
        defer { dex_engine_destroy(engine) }
        let a = MemoryTrack(samples: trackA ?? music, rate: sourceRate), b = MemoryTrack(samples: trackB ?? music, rate: sourceRate)
        var sa = a.source, sb = b.source
        dex_engine_load(engine, 0, &sa, sourceRate)
        dex_engine_load(engine, 1, &sb, sourceRate * 5)
        dex_engine_set_tempo(engine, 0, 1.06)
        dex_engine_set_tempo(engine, 1, 0.97)
        dex_engine_set_fader(engine, 0, 0.7, 1)
        dex_engine_set_fader(engine, 1, 0.7, 1)
        dex_engine_play(engine, 0, nil)
        dex_engine_play(engine, 1, nil)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4096), right = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { left.deallocate(); right.deallocate() }
        let outs: [UnsafeMutablePointer<Float>?] = [left, right]
        let total = Int(seconds * rate / Double(blockFrames))
        var times = [UInt64](repeating: 0, count: total)
        var landingTimes: [UInt64] = []
        var cpu: UInt64 = 0
        var state = DexEngineState()
        var lastLandings: UInt64 = 0
        var host: UInt64 = 0
        var nextJump = 2.0, deck: Int32 = 0
        outs.withUnsafeBufferPointer { list in
            for i in 0..<total {
                let now = Double(i * blockFrames) / rate
                if now >= nextJump {
                    nextJump += 1.5
                    var j = DexJump()
                    j.position = Double.random(in: 10...70) * sourceRate
                    j.atFrame = -1
                    j.fadeEndsAtLanding = true
                    dex_engine_jump(engine, deck, &j)
                    deck = 1 - deck
                }
                dex_engine_pump_loader(engine)
                let c0 = threadTime(), t0 = timeNow()
                dex_engine_render(engine, UInt32(blockFrames), host, list.baseAddress!, 2)
                let t1 = timeNow(), c1 = threadTime()
                times[i] = t1 - t0
                cpu += c1 - c0
                host += UInt64(Double(blockFrames) / rate * 1e9)
                if dex_engine_read_state(engine, &state) {
                    let landings = state.deck.0.landings + state.deck.1.landings
                    if landings != lastLandings {
                        if lastLandings > 0 { landingTimes.append(t1 - t0) }
                        lastLandings = landings
                    }
                }
            }
        }
        return summarise(name: Bench.engineName, blockFrames: blockFrames, seconds: seconds, rate: rate, cpu: cpu, times: times, landingTimes: landingTimes)
    }

    /// The same load through Apple's time-pitch: two players, two time-pitches and a mixer, in
    /// the same offline rendering mode the current engine's tests use.
    public static func appleCPU(blockFrames: Int, seconds: Double = 40, track: [[Float]]? = nil, rate sourceRate: Double = 48_000) throws -> CPUResult {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
        let samples = track ?? music
        let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples[0].count))!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<2 { samples[c].withUnsafeBufferPointer { pcm.floatChannelData![c].update(from: $0.baseAddress!, count: $0.count) } }
        let engine = AVAudioEngine()
        var players: [AVAudioPlayerNode] = []
        for tempo in [1.06, 0.97] {
            let player = AVAudioPlayerNode(), stretch = AVAudioUnitTimePitch()
            engine.attach(player)
            engine.attach(stretch)
            engine.connect(player, to: stretch, format: sourceFormat)
            // The time-pitch can't change rate, so a file at another rate meets the mix after it.
            engine.connect(stretch, to: engine.mainMixerNode, format: sourceFormat)
            stretch.rate = Float(tempo)
            players.append(player)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        for player in players {
            player.scheduleBuffer(pcm, at: nil, options: .loops)
            player.play()
        }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let total = Int(seconds * rate / Double(blockFrames))
        var times = [UInt64](repeating: 0, count: total)
        var cpu: UInt64 = 0
        for i in 0..<total {
            let c0 = threadTime(), t0 = timeNow()
            _ = try engine.renderOffline(AVAudioFrameCount(blockFrames), to: output)
            let t1 = timeNow(), c1 = threadTime()
            times[i] = t1 - t0
            cpu += c1 - c0
        }
        engine.stop()
        return summarise(name: "Apple time-pitch", blockFrames: blockFrames, seconds: seconds, rate: rate, cpu: cpu, times: times, landingTimes: [])
    }

    // MARK: Response to a change of speed

    /// Where the sound is coming from, from the frequency of the sweep in a short window.
    private static func trackedPositions(_ x: [Float], rate: Double, from: Int, to: Int, step: Int, period: Double, low: Double, high: Double) -> [(frame: Int, seconds: Double)] {
        var out: [(Int, Double)] = []
        let half = Int(0.004 * rate)
        var i = from
        while i + half < to {
            var first = -1.0, last = -1.0, crossings = 0
            for k in (i - half + 1)..<(i + half) where x[k - 1] <= 0 && x[k] > 0 {
                let exact = Double(k - 1) + Double(-x[k - 1] / (x[k] - x[k - 1]))
                if first < 0 { first = exact }
                last = exact
                crossings += 1
            }
            if crossings >= 4 {
                let hz = Double(crossings - 1) / ((last - first) / rate)
                let position = (hz - low) / (high - low) * period
                if position > 0.05 * period, position < 0.95 * period { out.append((i, position)) }
            }
            i += step
        }
        return out
    }

    /// Fits a straight line through the tracked position over a run of output, unwrapping the
    /// sweep's repeats using the speed we know we asked for. Returns where it's aimed.
    private static func line(_ points: [(frame: Int, seconds: Double)], rate: Double, speed: Double, period: Double) -> (slope: Double, intercept: Double)? {
        guard let first = points.first else { return nil }
        var xs: [Double] = [], ys: [Double] = []
        var previous = first.seconds
        var wraps = 0.0
        var previousFrame = first.frame
        for p in points {
            let elapsed = Double(p.frame - previousFrame) / rate * speed
            let predicted = previous + elapsed
            wraps = ((predicted - p.seconds) / period).rounded()
            let unwrapped = p.seconds + wraps * period
            if abs(unwrapped - predicted) < 0.05 { xs.append(Double(p.frame) / rate); ys.append(unwrapped) ; previous = unwrapped; previousFrame = p.frame }
        }
        guard xs.count > 20 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0, denominator = 0.0
        for k in xs.indices { numerator += (xs[k] - mx) * (ys[k] - my); denominator += (xs[k] - mx) * (xs[k] - mx) }
        let slope = numerator / denominator
        return (slope, my - slope * mx)
    }

    /// When a speed change takes hold in the sound: where the line before meets the line after.
    private static func response(_ x: [Float], rate: Double, stepFrame: Int, speedBefore: Double, speedAfter: Double) -> Double? {
        let period = 2.0, low = 500.0, high = 4500.0
        let before = trackedPositions(x, rate: rate, from: stepFrame - Int(1.5 * rate), to: stepFrame - Int(0.05 * rate), step: 24, period: period, low: low, high: high)
        let after = trackedPositions(x, rate: rate, from: stepFrame + Int(0.5 * rate), to: stepFrame + Int(2.0 * rate), step: 24, period: period, low: low, high: high)
        guard let a = line(before, rate: rate, speed: speedBefore, period: period), let b = line(after, rate: rate, speed: speedAfter, period: period) else { return nil }
        // The two are on different unwraps of the sweep, by whole periods.
        var best = Double.infinity
        for wraps in -4...4 {
            let meeting = (b.intercept + Double(wraps) * period - a.intercept) / (a.slope - b.slope)
            let delay = meeting - Double(stepFrame) / rate
            if abs(delay) < abs(best) { best = delay }
        }
        return best * 1000
    }

    public static func engineSpeedResponse(from: Double = 1.0, to: Double = 1.08, blockFrames: Int = 256) -> Double? {
        let rate = 48_000.0
        let engine = makeEngine()
        defer { dex_engine_destroy(engine) }
        let track = MemoryTrack(samples: BenchSignal.sweeps(seconds: 30), rate: rate)
        var source = track.source
        dex_engine_load(engine, 0, &source, 0)
        dex_engine_set_tempo(engine, 0, from)
        dex_engine_play(engine, 0, nil)
        var tap = [Float](repeating: 0, count: 4096), other = tap, l = tap, r = tap
        var result: [Float] = []
        var frame = 0
        let stepFrame = Int(4 * rate)
        var host: UInt64 = 0
        while frame < stepFrame + Int(2.2 * rate) {
            if frame == stepFrame { dex_engine_set_tempo(engine, 0, to) }
            dex_engine_pump_loader(engine)
            tap.withUnsafeMutableBufferPointer { t in other.withUnsafeMutableBufferPointer { o in l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                let tapList: [UnsafeMutablePointer<Float>?] = [t.baseAddress, o.baseAddress]
                let outList: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                outList.withUnsafeBufferPointer { ol in tapList.withUnsafeBufferPointer { tl in
                    dex_engine_render_tapped(engine, UInt32(blockFrames), host, ol.baseAddress!, 2, tl.baseAddress!, nil)
                } }
            } } } }
            result.append(contentsOf: tap[0..<blockFrames])
            frame += blockFrames
            host += 1
        }
        return response(result, rate: rate, stepFrame: stepFrame, speedBefore: from, speedAfter: to)
    }

    /// Apple's time-pitch, offline. It rounds speed to steps of 1/512, which the slopes pick up.
    public static func appleSpeedResponse(from: Double = 1.0, to: Double = 1.08, blockFrames: Int = 256) throws -> Double? {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let sweep = BenchSignal.sweeps(seconds: 30)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sweep[0].count))!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<2 { sweep[c].withUnsafeBufferPointer { pcm.floatChannelData![c].update(from: $0.baseAddress!, count: $0.count) } }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode(), stretch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        stretch.rate = Float(from)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(pcm, at: nil)
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var result: [Float] = []
        var frame = 0
        let stepFrame = Int(4 * rate)
        while frame < stepFrame + Int(2.2 * rate) {
            if frame == stepFrame { stretch.rate = Float(to) }
            _ = try engine.renderOffline(AVAudioFrameCount(blockFrames), to: output)
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: blockFrames))
            frame += blockFrames
        }
        engine.stop()
        return response(result, rate: rate, stepFrame: stepFrame, speedBefore: from, speedAfter: to)
    }

    // MARK: A jump, on the engine

    public struct JumpResult: Sendable {
        public var name: String
        public var tempo: Double
        public var keyPressToAttackMs: Double   // pressed with no lead, to the attack coming out
        public var attackLevel: Double          // the attack against the same click played through
        public var row: String { String(format: "| %@ | %.2f | %.1f ms | %.0f%% |", name, tempo, keyPressToAttackMs, attackLevel * 100) }
    }

    private static func envelope(_ x: [Float], width: Int = 48) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        for i in x.indices {
            sum += abs(x[i])
            if i >= width { sum -= abs(x[i - width]) }
            out[i] = sum
        }
        return out
    }

    /// Pressed with no warning, as a hot cue hit by hand: from the block after the press to the
    /// attack leaving the deck. The measure of "first correct audio".
    public static func engineJump(tempo: Double, blockFrames: Int = 256) -> JumpResult {
        let rate = 48_000.0
        let engine = makeEngine()
        defer { dex_engine_destroy(engine) }
        let clicks = BenchSignal.clicks(seconds: 60, every: 0.5)
        let track = MemoryTrack(samples: clicks, rate: rate)
        var source = track.source
        dex_engine_load(engine, 0, &source, 0)
        dex_engine_set_tempo(engine, 0, tempo)
        dex_engine_play(engine, 0, nil)
        var tap = [Float](repeating: 0, count: 4096), other = tap, l = tap, r = tap
        var result: [Float] = []
        var host: UInt64 = 0
        func render(_ frames: Int) {
            var left = frames
            while left > 0 {
                dex_engine_pump_loader(engine)
                tap.withUnsafeMutableBufferPointer { t in other.withUnsafeMutableBufferPointer { o in l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    let tapList: [UnsafeMutablePointer<Float>?] = [t.baseAddress, o.baseAddress]
                    let outList: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                    outList.withUnsafeBufferPointer { ol in tapList.withUnsafeBufferPointer { tl in
                        dex_engine_render_tapped(engine, UInt32(blockFrames), host, ol.baseAddress!, 2, tl.baseAddress!, nil)
                    } }
                } } } }
                result.append(contentsOf: tap[0..<blockFrames])
                left -= blockFrames
                host += 1
            }
        }
        render(Int(0.73 * rate))
        // Well between clicks, then hit a click.
        var delays: [Double] = [], levels: [Double] = []
        for press in 0..<12 {
            let target = (20.0 + Double(press) * 2) * rate
            var j = DexJump()
            j.position = target
            j.atFrame = -1
            j.fadeEndsAtLanding = true
            dex_engine_jump(engine, 0, &j)
            let pressed = result.count
            render(Int(1.03 * rate))
            let e = envelope(result)
            var best = pressed, value: Float = 0
            for i in pressed..<(pressed + Int(0.15 * rate)) where e[i] > value { value = e[i]; best = i }
            delays.append(Double(best - 40 - pressed) / 48)
            // The next click along, played through normally, is the reference.
            let next = best + Int(0.5 / tempo * rate)
            var reference: Float = 0
            for i in (next - 2400)..<(next + 2400) where e[i] > reference { reference = e[i] }
            levels.append(Double(value / reference))
        }
        delays.sort()
        levels.sort()
        return JumpResult(name: Bench.engineName, tempo: tempo, keyPressToAttackMs: delays[delays.count / 2], attackLevel: levels[levels.count / 2])
    }

    public static func stretcherFacts(rate: Double = 48_000) -> DexStretcherFacts {
        let engine = makeEngine(rate: rate)
        defer { dex_engine_destroy(engine) }
        var facts = DexStretcherFacts()
        dex_engine_stretcher_facts(engine, &facts)
        return facts
    }

    public static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// What four voices and the engine's scratch cost, chunk pool excluded (it's budgeted). Run
    /// each in a fresh process, and render a little, or freed memory and untouched pages hide it.
    public static func engineFootprint() -> Int64 {
        var config = DexEngineConfig()
        config.sampleRate = 48_000
        config.maxFrames = 4096
        config.chunkFrames = 4096
        config.chunksPerDeck = 2
        config.hostTicksPerSecond = 1e9
        let before = footprintBytes()
        let engine = dex_engine_create(&config)!
        defer { dex_engine_destroy(engine) }
        let silence = MemoryTrack(samples: [[Float](repeating: 0, count: 4096), [Float](repeating: 0, count: 4096)], rate: 48_000)
        var source = silence.source
        for deck in Int32(0)...1 {
            dex_engine_load(engine, deck, &source, 0)
            dex_engine_play(engine, deck, nil)
            dex_engine_pump_loader(engine)
        }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4096), right = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { left.deallocate(); right.deallocate() }
        let outs: [UnsafeMutablePointer<Float>?] = [left, right]
        outs.withUnsafeBufferPointer { dex_engine_render(engine, 4096, 0, $0.baseAddress!, 2) }
        return footprintBytes() - before
    }
}
