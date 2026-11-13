import Foundation

public struct BeatGrid: Codable, Equatable, Sendable {
    public let bpm: Double
    public let offsetMs: Double
    public let confidence: Double

    public init(bpm: Double, offsetMs: Double = 0, confidence: Double = 0) throws {
        guard bpm.isFinite, bpm > 0, offsetMs.isFinite,
              confidence.isFinite, (0...1).contains(confidence) else {
            throw GridError.invalidGrid
        }
        self.bpm = bpm
        self.offsetMs = offsetMs
        self.confidence = confidence
    }
    private enum CodingKeys: String, CodingKey { case bpm, offsetMs, confidence }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bpm: values.decode(Double.self, forKey: .bpm),
                      offsetMs: values.decode(Double.self, forKey: .offsetMs),
                      confidence: values.decode(Double.self, forKey: .confidence))
    }
    public enum GridError: Error { case invalidGrid }
    public var beatSeconds: Double { 60 / bpm }
    public func time(atBeat beat: Double) -> Double { offsetMs / 1000 + beat * beatSeconds }
    public func beat(at time: Double) -> Double { (time - offsetMs / 1000) / beatSeconds }
    public func phase(at time: Double) -> Double {
        let value = beat(at: time)
        return value - floor(value)
    }
    /// Nearest complete beat inside playable audio. Clamping a quantized time
    /// to zero/end would create an off-grid cue when the first beat is offset.
    public func cueTime(near time: Double, duration: Double) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        let first = ceil(beat(at: 0))
        let last = floor(beat(at: max(0, duration - 1e-9)))
        guard first.isFinite, last.isFinite, first <= last else { return nil }
        let selected = min(last, max(first, floor(beat(at: time) + 0.5)))
        let result = self.time(atBeat: selected)
        return result.isFinite && result >= 0 && result < duration ? result : nil
    }
    public func quantize(_ time: Double, beats: Double = 1) -> Double {
        // JavaScript Math.round semantics, including negative half-beats.
        self.time(atBeat: floor(beat(at: time) / beats + 0.5) * beats)
    }
}

/// A deck's position over output time: what the engine has played, plus what the deck has
/// asked for that the engine hasn't played yet. Each segment carries the loop in force from
/// it on, so a position and its loop never disagree. Changing rate never rewrites elapsed audio,
/// and about a second of history is kept, for a listener that hears it a device's delay later.
public struct DeckTimeline: Sendable {
    private struct Segment: Sendable {
        var time: Double
        var position: Double
        var rate: Double
        var loop: ClosedRange<Double>?
    }
    private var segments = [Segment(time: 0, position: 0, rate: 0, loop: nil)]
    /// When the newest landing asked for is due, until the engine has played up to it. Blocks
    /// from before then describe the audio being replaced, so they don't re-anchor over it.
    public private(set) var pendingLanding: Double?
    /// When the newest landing asked for is due, kept after it is heard: a change of rate made
    /// before then takes effect with it, never ahead of it.
    private var lastLanding = -Double.infinity
    /// When a start from stopped comes out, while it hasn't yet: nothing is heard before then.
    /// The engine's time once it has started the landing, which a wait for audio can delay.
    public private(set) var pendingStart: Double?
    /// The deck has asked the engine for sound and not taken it back: its one request the engine
    /// can't report until it confirms it. After a jog the engine plays again on its own while the
    /// deck still means its next press as a fresh start, so this is kept here, not read back.
    public private(set) var soundRequested = false
    public init() {}

    private func segment(at time: Double) -> Segment { segments.last(where: { $0.time <= time }) ?? segments[0] }
    /// Where the source is at a time, without folding into a loop.
    public func unfoldedPosition(at time: Double) -> Double {
        let segment = segment(at: time)
        return segment.position + (time - segment.time) * segment.rate
    }
    /// Where the source is at a time, folded into the loop in force then.
    public func position(at time: Double) -> Double {
        let value = unfoldedPosition(at: time)
        guard let loop = loop(at: time), value >= loop.upperBound, loop.upperBound > loop.lowerBound else { return value }
        return loop.lowerBound + (value - loop.lowerBound).truncatingRemainder(dividingBy: loop.upperBound - loop.lowerBound)
    }
    public func loop(at time: Double) -> ClosedRange<Double>? { segment(at: time).loop }

    /// From `time` on, play at `rate` from `position` (or carry on from where it is), inside
    /// `loop` (or the loop in force then). Anything planned from then on is replaced.
    public mutating func schedule(at time: Double, rate: Double, position: Double? = nil,
                                  loop: ClosedRange<Double>?? = .none) {
        let next = Segment(time: time, position: position ?? unfoldedPosition(at: time), rate: rate,
                           loop: loop ?? self.loop(at: time))
        segments.removeAll { $0.time >= time }
        segments.append(next)
        while segments.count > 2 && segments[1].time < time - 1 { segments.removeFirst() }
    }
    /// Stopped at `position` from `time`, inside `loop` (or the loop in force then). Forgets history.
    public mutating func reset(at time: Double, position: Double = 0, loop: ClosedRange<Double>?? = .none) {
        segments = [Segment(time: time, position: position, rate: 0, loop: loop ?? self.loop(at: time))]
        pendingLanding = nil
        pendingStart = nil
        soundRequested = false
    }
    /// The loop changes at `time`; the playhead carries on as it was.
    public mutating func changeLoop(_ loop: ClosedRange<Double>?, at time: Double) {
        schedule(at: time, rate: segment(at: time).rate, loop: .some(loop))
    }
    /// The speed changes now, or with the landing still to come if there is one.
    public mutating func changeRate(_ rate: Double, from now: Double) {
        let time = max(now, lastLanding)
        schedule(at: time, rate: rate)
    }
    /// The deck has asked the engine to land here, on this output time: a start from stopped,
    /// or a change to music already playing.
    public mutating func land(at time: Double, position: Double, rate: Double, loop: ClosedRange<Double>?, start: Bool = false) {
        schedule(at: time, rate: rate, position: position, loop: .some(loop))
        pendingLanding = time
        lastLanding = time
        pendingStart = start ? time : nil
        soundRequested = true
    }
    /// Sound is asked for again as it was, as when a dropped command is sent again.
    public mutating func requestSound() { soundRequested = true }
    /// The deck takes its request back: paused, or the engine has played the last frame.
    public mutating func releaseSound() { soundRequested = false }
    /// Nothing asked for is still to come: the next block is the truth, whatever it says.
    public mutating func forgetLanding() { pendingLanding = nil; pendingStart = nil }
    /// Whether a start asked for is still to come out at this time.
    public func starting(at time: Double) -> Bool { pendingStart.map { time < $0 } ?? false }

    /// One block the engine has played, that confirms everything the deck has sent: the
    /// timeline follows it, never a prediction. A landing the engine has started is marked on
    /// the output time it's due; until a pending one is reached, the audio it replaces doesn't
    /// re-anchor over it, unless it is overdue and still waiting for its audio.
    public mutating func follow(blockStart: Double, position: Double, rate: Double, loop: ClosedRange<Double>?,
                                landing: (due: Double, position: Double)?, landingWaiting: Bool) {
        if let landing {
            schedule(at: landing.due, rate: rate, position: landing.position)
            pendingLanding = landing.due
            if pendingStart != nil { pendingStart = landing.due }
            return
        }
        if let due = pendingLanding {
            if blockStart < due { return }
            if !landingWaiting { pendingLanding = nil; pendingStart = nil }
        }
        schedule(at: blockStart, rate: rate, position: position, loop: .some(loop))
    }
}

public struct HotCueTiming: Sendable, Equatable {
    /// Output seconds from the input press to the audible handover.
    public let delay: Double
    /// Source seconds already elapsed since the intended saved-cue beat.
    public let sourceOffset: Double
}

public enum MixMath {
    /// The crossfader's gains for A and B. Each deck stays full until the centre and fades only
    /// across the far half, on a quarter cosine, as a club mixer's cut curve does: centred, both
    /// decks are fully open and LEVEL alone sets the mix (agreed 8 November 2026).
    public static func crossfade(_ position: Double) -> (Double, Double) {
        let x = min(1, max(0, position))
        func side(_ past: Double) -> Double { past <= 0 ? 1 : past >= 1 ? 0 : cos(past * .pi / 2) }
        return (side(2 * x - 1), side(1 - 2 * x))
    }
    public static func wrapPhase(_ error: Double) -> Double {
        var value = error.truncatingRemainder(dividingBy: 1)
        if value > 0.5 { value -= 1 }
        if value <= -0.5 { value += 1 }
        return value
    }
    /// Main-CUE audition uses the other deck's beat at the input timestamp.
    /// A human press up to 150 ms late (30% of a fast output beat) still joins
    /// that beat. Preparation advances the incoming source rather than replaying
    /// its missed attack or postponing an otherwise well-timed launch.
    public static func cueLaunchTiming(position: Double, referenceRate: Double, referenceGrid: BeatGrid,
                                       cueRate: Double, preparation: Double = 0.12) -> HotCueTiming {
        guard position.isFinite, referenceRate.isFinite, referenceRate > 0,
              cueRate.isFinite, cueRate > 0 else { return HotCueTiming(delay: 0, sourceOffset: 0) }
        let lead = max(0, preparation.isFinite ? preparation : 0.12)
        let beatDuration = referenceGrid.beatSeconds / referenceRate
        let next = nextBeatDelay(position: position, rate: referenceRate, grid: referenceGrid)
        let previous = next - beatDuration
        let tolerance = min(0.150, beatDuration * 0.30)
        let boundary = previous >= -tolerance - 1e-9 ? previous : next
        let delay = max(lead, boundary)
        return HotCueTiming(delay: delay, sourceOffset: max(0, delay - boundary) * cueRate)
    }

    /// A near-boundary press belongs to that bar, including slightly late
    /// presses. Already-heard audio cannot be replayed in the past: late entry
    /// picks up the saved cue at the corresponding elapsed source position.
    public static func hotCueTiming(position: Double, cue: Double, rate: Double, grid: BeatGrid,
                                    preparation: Double = 0.12) -> HotCueTiming {
        guard rate.isFinite, rate > 0, position.isFinite, cue.isFinite else {
            return HotCueTiming(delay: 0, sourceOffset: 0)
        }
        let lead = max(0, preparation.isFinite ? preparation : 0.12)
        let beatDuration = grid.beatSeconds / rate
        let tolerance = min(0.100, beatDuration * 0.20)
        let next = hotCueDelay(position: position, cue: cue, rate: rate, grid: grid)
        let previous = next - 4 * beatDuration
        let boundary = previous >= -tolerance - 1e-9 ? previous : next
        let delay = max(lead, boundary)
        return HotCueTiming(delay: delay, sourceOffset: max(0, delay - boundary) * rate)
    }
    /// Preserve the 1-2-3-4 count when recalling a saved beat. A cue on beat
    /// one enters on the next beat one; cues on beats 2/3/4 keep their place too.
    public static func hotCueDelay(position: Double, cue: Double, rate: Double, grid: BeatGrid) -> Double {
        let current = grid.beat(at: position)
        let target = grid.beat(at: cue).rounded()
        guard current.isFinite, target.isFinite, rate.isFinite, rate > 0 else { return 0 }
        var beats = (target - current).truncatingRemainder(dividingBy: 4)
        if beats < 0 { beats += 4 }
        if beats < 1e-9 || beats > 4 - 1e-9 { beats = 0 }
        return beats * grid.beatSeconds / rate
    }
    /// Output seconds until the next master beat, sampled at the earliest
    /// schedulable output time. Independent of the preview deck's own BPM/rate.
    public static func nextBeatDelay(position: Double, rate: Double, grid: BeatGrid) -> Double {
        let phase = grid.phase(at: position)
        guard phase.isFinite, rate.isFinite, rate > 0 else { return 0 }
        if phase < 1e-9 || phase > 1 - 1e-9 { return 0 }
        return (1 - phase) * grid.beatSeconds / rate
    }

}

public struct LoopRegion: Equatable, Sendable {
    public var startBeat: Double
    public var lengthBeats: Double
    public init(grid: BeatGrid, position: Double, lengthBeats: Double) {
        startBeat = ceil(grid.beat(at: position))
        self.lengthBeats = lengthBeats.isFinite ? max(0.5, floor(lengthBeats * 2 + 0.5) / 2) : 1
    }
    public func bounds(grid: BeatGrid) -> ClosedRange<Double> {
        grid.time(atBeat: startBeat)...grid.time(atBeat: startBeat + lengthBeats)
    }
    /// Shrinking keeps the window of the new length that holds `beat`, so the
    /// playhead carries on: halving a 4-beat loop on beat 3 keeps beats 3–4.
    /// Growing, or a loop the playhead has not reached yet, keeps loop-in.
    public func resized(to beats: Double, around beat: Double) -> LoopRegion {
        var region = self
        region.lengthBeats = beats
        let offset = beat - startBeat
        guard beats > 0, beats < lengthBeats, offset.isFinite, offset >= 0 else { return region }
        let folded = offset.truncatingRemainder(dividingBy: lengthBeats)
        let last = floor(lengthBeats / beats + 1e-9) - 1
        region.startBeat += min(last, floor(folded / beats + 1e-9)) * beats
        return region
    }
}
