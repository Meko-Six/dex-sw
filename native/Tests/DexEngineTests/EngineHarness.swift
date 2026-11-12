import CDexEngine
import Foundation
import XCTest

/// A track made by a function, so a test knows exactly what is where.
final class SynthTrack {
    typealias Fill = (_ frame: Int64, _ count: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) -> Void
    let frames: Int64
    let rate: Double
    let fill: Fill
    private(set) var reads = 0
    /// Reads fail while it's set, as a file on a drive that has gone would.
    var failing = false

    init(frames: Int64, rate: Double, fill: @escaping Fill) {
        self.frames = frames
        self.rate = rate
        self.fill = fill
    }

    var source: DexTrackSource {
        var s = DexTrackSource()
        s.context = Unmanaged.passUnretained(self).toOpaque()
        s.read = { context, frame, count, left, right in
            let track = Unmanaged<SynthTrack>.fromOpaque(context!).takeUnretainedValue()
            track.reads += 1
            if track.failing { return -1 }
            track.fill(frame, Int(count), left!, right!)
            return Int32(count)
        }
        s.frames = frames
        s.sampleRate = rate
        return s
    }
}

/// Clicks at known source frames: a short decaying burst, the sharpest thing a stretcher will
/// be asked to hold together. `bed` adds a quiet steady tone underneath, as music always has.
struct Clicks {
    var first: Double
    var spacing: Double
    var hz = 3000.0
    var decaySeconds = 0.003
    var level = 0.8
    var bed = 0.0
    var bedHz = 110.0

    func frame(of index: Int) -> Double { first + Double(index) * spacing }

    func track(seconds: Double, rate: Double, channel: Int? = nil) -> SynthTrack {
        let frames = Int64(seconds * rate)
        let decayFrames = decaySeconds * rate
        let reach = Int(decayFrames * 12)
        let w = 2 * Double.pi * hz / rate
        let wBed = 2 * Double.pi * bedHz / rate
        let this = self
        return SynthTrack(frames: frames, rate: rate) { frame, count, left, right in
            for k in 0..<count {
                let f = frame + Int64(k)
                var value = this.bed > 0 ? this.bed * sin(wBed * Double(f)) : 0
                let index = Int(floor((Double(f) - this.first) / this.spacing))
                if index >= 0 {
                    let t = Double(f) - this.frame(of: index)
                    if t < Double(reach) { value += this.level * exp(-t / decayFrames) * sin(w * t) }
                }
                left[k] = Float(value)
                right[k] = Float(value)
            }
        }
    }
}

/// Runs the real callback offline and keeps what came out, per deck and per block.
final class Rig {
    let engine: OpaquePointer
    let rate: Double
    let blockFrames: Int
    var tapA: [[Float]] = [[], []], tapB: [[Float]] = [[], []], master: [[Float]] = [[], []]
    var states: [DexEngineState] = []
    var keepAudio = true
    var pumping = true
    var tracks: [SynthTrack] = []
    private var frame: UInt64 = 0
    /// Commands due at an output frame, sent just before the block containing it.
    private var buffers: [[Float]]

    init(rate: Double = 48_000, blockFrames: Int = 256,
         chunkFrames: UInt32 = 0, chunksPerDeck: UInt32 = 0, thread: Bool = false, maxFrames: UInt32 = 4096) {
        var config = DexEngineConfig()
        config.sampleRate = rate
        config.maxFrames = maxFrames
        config.chunkFrames = chunkFrames
        config.chunksPerDeck = chunksPerDeck
        config.loaderThread = thread
        config.hostTicksPerSecond = 1_000_000_000
        engine = dex_engine_create(&config)!
        self.rate = rate
        self.blockFrames = blockFrames
        buffers = Array(repeating: Array(repeating: 0, count: 8192), count: 6)
        dex_engine_set_fader(engine, 0, 1, 1)
        dex_engine_set_fader(engine, 1, 1, 1)
        dex_engine_set_volume(engine, 1)
        dex_engine_snap_levels(engine)
    }

    deinit { dex_engine_destroy(engine) }

    func load(_ track: SynthTrack, deck: Int32 = 0, at position: Double = 0) {
        tracks.append(track)
        var source = track.source
        XCTAssertNotEqual(dex_engine_load(engine, deck, &source, position), 0)
    }

    func hostTime(_ frame: UInt64) -> UInt64 { UInt64(Double(frame) / rate * 1e9) }
    var now: Int64 { Int64(frame) }

    func render(frames: Int, block: Int? = nil) {
        var left = frames
        let size = block ?? blockFrames
        while left > 0 {
            let n = min(left, size)
            if pumping { dex_engine_pump_loader(engine) }
            renderOne(n)
            left -= n
        }
    }

    func render(seconds: Double) { render(frames: Int(seconds * rate)) }

    /// Runs until `until` (an output frame), calling `body` each block.
    func run(to until: Int64, _ body: (Rig) -> Void = { _ in }) {
        while now < until {
            body(self)
            let n = min(blockFrames, Int(until - now))
            if pumping { dex_engine_pump_loader(engine) }
            renderOne(n)
        }
    }

    private func renderOne(_ n: Int) {
        let time = hostTime(frame)
        buffers.withUnsafeMutableBufferPointer { all in
            let pointers = (0..<6).map { i in all[i].withUnsafeMutableBufferPointer { $0.baseAddress! } }
            let outs: [UnsafeMutablePointer<Float>?] = [pointers[0], pointers[1]]
            let a: [UnsafeMutablePointer<Float>?] = [pointers[2], pointers[3]]
            let b: [UnsafeMutablePointer<Float>?] = [pointers[4], pointers[5]]
            outs.withUnsafeBufferPointer { o in
                a.withUnsafeBufferPointer { ta in
                    b.withUnsafeBufferPointer { tb in
                        dex_engine_render_tapped(engine, UInt32(n), time, o.baseAddress!, 2, ta.baseAddress!, tb.baseAddress!)
                    }
                }
            }
            if keepAudio {
                master[0].append(contentsOf: UnsafeBufferPointer(start: pointers[0], count: n))
                master[1].append(contentsOf: UnsafeBufferPointer(start: pointers[1], count: n))
                tapA[0].append(contentsOf: UnsafeBufferPointer(start: pointers[2], count: n))
                tapA[1].append(contentsOf: UnsafeBufferPointer(start: pointers[3], count: n))
                tapB[0].append(contentsOf: UnsafeBufferPointer(start: pointers[4], count: n))
                tapB[1].append(contentsOf: UnsafeBufferPointer(start: pointers[5], count: n))
            }
        }
        var state = DexEngineState()
        if dex_engine_read_state(engine, &state) { states.append(state) }
        frame += UInt64(n)
    }

    /// What the deck's clock said a given output frame was playing, from the block it fell in.
    func clock(deck: Int, at outputFrame: Int) -> (position: Double, speed: Double) {
        var low = 0, high = states.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if states[mid].outputFrame <= UInt64(outputFrame) { low = mid } else { high = mid - 1 }
        }
        let state = states[low]
        let d = deck == 0 ? state.deck.0 : state.deck.1
        return (d.position + d.speed * Double(outputFrame - Int(state.outputFrame)), d.speed)
    }

    func deckState(_ deck: Int) -> DexDeckState {
        let state = states[states.count - 1]
        return deck == 0 ? state.deck.0 : state.deck.1
    }

    func tap(_ deck: Int) -> [Float] { deck == 0 ? tapA[0] : tapB[0] }
}

/// Jump shorthand.
func jump(to position: Double, at frame: Int64 = -1, fadeEnds: Bool = true, late: DexLatePolicy = DEX_LATE_SLIDE,
          period: Double = 0, align: Bool = false) -> DexJump {
    var j = DexJump()
    j.position = position
    j.atFrame = frame
    j.fadeEndsAtLanding = fadeEnds
    j.late = late
    j.latePeriodFrames = period
    j.alignToMaster = align
    return j
}

// MARK: Finding clicks

enum Signal {
    /// A running 1 ms sum of magnitude: the shape of the attack, whatever the phase did.
    static func envelope(_ x: [Float], width: Int = 48) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        x.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                for i in 0..<input.count {
                    sum += abs(input[i])
                    if i >= width { sum -= abs(input[i - width]) }
                    output[i] = max(0, sum)
                }
            }
        }
        return out
    }

    /// The frame of the biggest envelope value in a window, refined by the peak's top half so a
    /// flat-topped peak doesn't read early. Nil if the window is below `floor`.
    static func peak(_ envelope: [Float], from: Int, to: Int, floor: Float = 0.01) -> Double? {
        let start = max(0, from), end = min(envelope.count, to)
        guard start < end else { return nil }
        var best = start
        var value: Float = 0
        envelope.withUnsafeBufferPointer { e in
            for i in start..<end where e[i] > value {
                value = e[i]
                best = i
            }
        }
        guard value > floor else { return nil }
        var low = best, high = best
        let half = value * 0.9
        while low > start, envelope[low - 1] >= half { low -= 1 }
        while high + 1 < end, envelope[high + 1] >= half { high += 1 }
        return Double(low + high) / 2
    }

    /// Where the detector says a click is, relative to where the click really starts.
    static func detectorOffset(_ clicks: Clicks, rate: Double, width: Int = 48) -> Double {
        let track = clicks.track(seconds: (clicks.first + clicks.spacing) / rate + 0.1, rate: rate)
        var l = [Float](repeating: 0, count: Int(track.frames)), r = l
        l.withUnsafeMutableBufferPointer { a in
            r.withUnsafeMutableBufferPointer { b in track.fill(0, a.count, a.baseAddress!, b.baseAddress!) }
        }
        let e = envelope(l, width: width)
        let at = Int(clicks.first)
        return peak(e, from: at, to: at + Int(clicks.spacing / 2))! - clicks.first
    }

    static func seconds(_ frames: Double, rate: Double) -> Double { frames / rate }
}

struct ErrorStats: CustomStringConvertible {
    var values: [Double] = []
    mutating func add(_ v: Double) { values.append(v) }
    var worst: Double { values.map(abs).max() ?? .infinity }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    var spread: Double { (values.max() ?? 0) - (values.min() ?? 0) }
    var description: String {
        String(format: "n=%d mean=%+.3f worst=%.3f spread=%.3f ms", values.count, mean, worst, spread)
    }
}
