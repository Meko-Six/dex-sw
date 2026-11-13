import AVFoundation
import CDexEngine
import DexCore
import Darwin

/// The engine the output callback renders, in a slot of plain memory, so the callback reads it
/// with one load and no Swift runtime. Only `EngineCore.close` changes it, once the output has stopped.
private struct EnginePointer: @unchecked Sendable {
    let slot: UnsafeMutablePointer<OpaquePointer>
    init(raw: OpaquePointer) { slot = .allocate(capacity: 1); slot.initialize(to: raw) }
    var raw: OpaquePointer {
        get { slot.pointee }
        nonmutating set { slot.pointee = newValue }
    }
    func free() { slot.deinitialize(count: 1); slot.deallocate() }
}

/// Owns the replacement engine, which outlives any graph: Apple's engine only carries its one
/// callback to the output device, so a rebuild for a route change leaves every deck's state alone.
final class EngineCore: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private let pointer: EnginePointer
    private var lease: AudioMemoryBudget.Lease?
    private(set) var state = DexEngineState()
    private(set) var hasState = false
    private(set) var offline = false
    private(set) var closed = false
    /// The newest MASTER sent. Until the engine confirms it, what it publishes as master is older.
    var masterCommand: UInt64 = 0
    var raw: OpaquePointer { pointer.raw }

    /// `chunksPerDeck` is the cache: 64 chunks of 65536 frames, about 87 s a deck. Tests that
    /// never play anything use one, so they hold almost no memory.
    init(chunksPerDeck: UInt32 = 64) {
        var config = DexEngineConfig()
        config.sampleRate = Self.sampleRate
        config.maxFrames = 4096
        config.chunksPerDeck = chunksPerDeck
        config.loaderThread = true
        lease = AudioMemoryBudget.shared.reserveFixed(Int64(dex_engine_required_bytes(&config)))
        pointer = EnginePointer(raw: dex_engine_create(&config))
    }
    deinit { dex_engine_destroy(pointer.raw); pointer.free() }

    /// Gives the audio memory back once the output has really stopped, for good. A stand-in
    /// with almost no memory takes its place, so a late command from a deck still lands somewhere.
    @MainActor func close() {
        guard !closed else { return }
        closed = true
        dex_engine_destroy(pointer.raw)
        var config = DexEngineConfig()
        config.sampleRate = Self.sampleRate
        config.maxFrames = 4096
        config.chunkFrames = 1024
        config.chunksPerDeck = 1
        config.loaderThread = false
        pointer.raw = dex_engine_create(&config)
        dex_engine_go_offline(pointer.raw)
        lease = nil
        hasState = false
    }

    /// A callback with nothing in it but the call: no Swift runtime work happens under it.
    func makeNode() -> AVAudioSourceNode {
        let engine = pointer
        return AVAudioSourceNode { _, time, frames, output in
            dex_engine_render_list(engine.raw, frames, time, output)
            return noErr
        }
    }
    var engineDelaySeconds: Double { Double(dex_engine_delay_frames(raw)) / Self.sampleRate }
    func goOffline() { offline = true; dex_engine_go_offline(raw) }
    func pumpLoader() { dex_engine_pump_loader(raw) }
    func pumpLoaderOnce() { _ = dex_engine_pump_loader_once(raw) }
    /// Reads the newest block. One reader, on the main actor.
    func refresh() {
        if dex_engine_read_state(raw, &state) { hasState = true }
    }
    func seconds(hostTime: UInt64) -> Double { AVAudioTime.seconds(forHostTime: hostTime) }
    var meterDb: Double {
        refresh()
        return hasState ? 20 * log10(max(1e-6, Double(state.masterRms))) : -120
    }
    /// The meters' newest values; takes the master peaks gathered since the last call.
    func readMeters() -> DexMeterReading {
        var reading = DexMeterReading()
        dex_engine_read_meters(raw, &reading)
        return reading
    }
    func deckState(_ index: Int) -> DexDeckState { index == 0 ? state.deck.0 : state.deck.1 }
    /// The soonest a landing can come out: the block after the newest one, never in the past.
    func soonest(after now: Double) -> Double {
        guard hasState else { return now }
        return max(now, seconds(hostTime: state.hostTime) + Double(state.blockFrames) / state.sampleRate)
    }
    /// The output frame heard at a time on the audio clock, or -1 (as soon as possible) before any block.
    func frame(at time: Double) -> Int64 {
        guard hasState else { return -1 }
        let frame = Double(state.outputFrame) + (time - seconds(hostTime: state.hostTime)) * state.sampleRate
        return Int64(max(0, frame.rounded()))
    }
}

/// A file for the engine's loader: opened for it alone, and only ever read on its thread.
private final class TrackReader {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let channels: Int
    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { throw NativeDeck.PlaybackError.unsupportedChannels }
        self.buffer = buffer
        channels = Int(file.processingFormat.channelCount)
    }
    var source: DexTrackSource {
        var source = DexTrackSource()
        source.context = Unmanaged.passRetained(self).toOpaque()
        source.frames = file.length
        source.sampleRate = file.processingFormat.sampleRate
        source.release = { Unmanaged<TrackReader>.fromOpaque($0!).release() }
        source.read = { context, frame, count, left, right in
            let reader = Unmanaged<TrackReader>.fromOpaque(context!).takeUnretainedValue()
            return autoreleasepool {
                reader.file.framePosition = frame
                reader.buffer.frameLength = 0
                let wanted = min(count, reader.buffer.frameCapacity)
                // A read that fails says so: the engine keeps nothing from it and tries again.
                guard (try? reader.file.read(into: reader.buffer, frameCount: wanted)) != nil,
                      let data = reader.buffer.floatChannelData else { return -1 }
                let frames = Int(reader.buffer.frameLength)
                left!.update(from: data[0], count: frames)
                right!.update(from: data[reader.channels > 1 ? 1 : 0], count: frames)
                return Int32(frames)
            }
        }
        return source
    }
}

/// One deck's line to the engine: thin commands, and what the published state means for the
/// deck's clock. Musical decisions stay in `NativeDeck`.
@MainActor
final class EngineDeck {
    let core: EngineCore
    let index: Int32
    private(set) var fileRate = 48_000.0
    private(set) var lastCommand: UInt64 = 0
    private var seenFrame: UInt64 = .max
    private var seenLandings: UInt64 = 0
    /// When the last landing asked for is due, until the sound has really reached it.
    private var plan: Double?
    /// The end of the newest block, so a display stops soon after the audio does.
    private(set) var renderedUntil = 0.0
    var engine: OpaquePointer { core.raw }

    init(core: EngineCore, index: Int32) { self.core = core; self.index = index }

    /// A command didn't fit in the engine's queue, so what it holds may differ from what the
    /// deck asked for until the deck sends it all again.
    var dropped = false
    func sent(_ sequence: UInt64) { if sequence != 0 { lastCommand = sequence } else { dropped = true } }

    // MARK: Commands

    func load(url: URL) throws {
        let reader = try TrackReader(url: url)
        let previousRate = fileRate
        fileRate = reader.file.processingFormat.sampleRate
        var source = reader.source
        let sequence = dex_engine_load(engine, index, &source, 0)
        guard sequence != 0 else {
            // The engine took nothing, so the deck keeps the track it had, and says so.
            source.release?(source.context)
            fileRate = previousRate
            throw NativeDeck.PlaybackError.engineBusy
        }
        sent(sequence)
        plan = nil
    }
    func unload() { sent(dex_engine_unload(engine, index)); plan = nil }
    func play(_ jump: DexJump) { var jump = jump; sent(dex_engine_play(engine, index, &jump)) }
    func land(_ jump: DexJump) { var jump = jump; sent(dex_engine_jump(engine, index, &jump)) }
    func pause() { sent(dex_engine_pause(engine, index, -1)); plan = nil }
    /// The deck is stopped; this is where the audio would start, so the loader can get it ready.
    func rest(at seconds: Double) {
        var jump = DexJump()
        jump.position = seconds * fileRate
        jump.atFrame = -1
        sent(dex_engine_jump(engine, index, &jump))
    }
    func enterScrub(at seconds: Double) -> Bool {
        let entered = dex_engine_scrub(engine, index, true)
        sent(entered)
        var jump = DexJump()
        jump.position = seconds * fileRate
        jump.atFrame = -1
        jump.late = DEX_LATE_HOLD
        let moved = dex_engine_jump(engine, index, &jump)
        sent(moved)
        plan = nil
        return entered != 0 && moved != 0
    }
    func scrubSpeed(_ sourceSecondsPerSecond: Double, damping: Double) -> Bool {
        let sequence = dex_engine_scrub_velocity(engine, index, sourceSecondsPerSecond, damping)
        sent(sequence)
        return sequence != 0
    }
    func leaveScrub() { sent(dex_engine_scrub(engine, index, false)) }
    func hardStop(at seconds: Double) { sent(dex_engine_park(engine, index, seconds * fileRate)); plan = nil }
    func setTempo(_ tempo: Double) { sent(dex_engine_set_tempo(engine, index, tempo)) }
    func setKeyLock(_ on: Bool) { sent(dex_engine_set_key_lock(engine, index, on)) }
    func setSync(_ on: Bool) { sent(dex_engine_set_sync(engine, index, on)) }
    func setPreview(_ on: Bool) { sent(dex_engine_set_preview(engine, index, on)) }
    func setLoop(_ bounds: ClosedRange<Double>?) {
        sent(dex_engine_set_loop(engine, index, bounds != nil, (bounds?.lowerBound ?? 0) * fileRate, (bounds?.upperBound ?? 0) * fileRate))
    }
    func setGrid(_ grid: BeatGrid?) {
        guard let grid else { sent(dex_engine_set_grid(engine, index, 0, 0)); return }
        sent(dex_engine_set_grid(engine, index, grid.time(atBeat: 0) * fileRate, grid.beatSeconds * fileRate))
    }
    func setHotspots(_ seconds: [Double]) {
        let frames = seconds.map { $0 * fileRate }
        frames.withUnsafeBufferPointer { dex_engine_set_hotspots(engine, index, $0.baseAddress, UInt32($0.count)) }
    }
    func setReach(_ seconds: [Double]) {
        let frames = seconds.map { $0 * fileRate }
        frames.withUnsafeBufferPointer { dex_engine_set_reach(engine, index, $0.baseAddress, UInt32($0.count)) }
    }
    /// The next jump is due then, on this clock: nothing re-anchors over it until the sound gets there.
    func expectLanding(at time: Double) { plan = time }
    func forgetLanding() { plan = nil }

    // MARK: Reading back

    /// The state confirmed everything this deck has sent, so it describes what the deck asked for.
    var confirmed: Bool { core.hasState && core.state.confirmedCommand >= lastCommand }
    var ended: Bool { confirmed && core.deckState(Int(index)).ended }
    /// Reads of the loaded track that have failed so far. That audio is missing, not silent.
    var readFailures: UInt64 { confirmed ? core.deckState(Int(index)).readFailures : 0 }
    var renderedPosition: Double? {
        core.refresh()
        guard core.hasState else { return nil }
        return core.deckState(Int(index)).positionEnd / fileRate
    }
    /// The speed really playing, as a tempo, while there's a block to say so.
    var playedTempo: Double? {
        guard core.hasState else { return nil }
        let deck = core.deckState(Int(index))
        return deck.playing && !deck.scrubbing ? deck.tempo * (1 + deck.steer) : nil
    }

    /// Brings the deck's clock up to date with the newest block: what was played, never a
    /// prediction, with any landing the engine has started marked on the output frame it's due.
    func sync(clock: inout TransportClock, following: Bool) {
        core.refresh()
        guard core.hasState, core.state.outputFrame != seenFrame else { return }
        let state = core.state, deck = core.deckState(Int(index))
        seenFrame = state.outputFrame
        let blockStart = core.seconds(hostTime: state.hostTime)
        renderedUntil = blockStart + Double(state.blockFrames) / state.sampleRate
        guard state.confirmedCommand >= lastCommand else { return }
        let landed = deck.landings != seenLandings
        seenLandings = deck.landings
        guard following else { plan = nil; return }
        let rate = deck.speed * state.sampleRate / fileRate
        if landed, deck.lastLandingFrame >= 0 {
            let due = blockStart + Double(deck.lastLandingFrame - Int64(state.outputFrame)) / state.sampleRate
            clock.schedule(at: due, rate: rate, position: deck.lastLandingPosition / fileRate)
            plan = due
            return
        }
        if let due = plan {
            if blockStart < due { return }
            // It's overdue because its audio isn't ready, and the outgoing audio is still playing.
            if deck.landingPending {
                clock.schedule(at: blockStart, rate: rate, position: deck.position / fileRate)
                return
            }
            plan = nil
        }
        clock.schedule(at: blockStart, rate: rate, position: deck.position / fileRate)
    }
}
