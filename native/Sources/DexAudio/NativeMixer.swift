import AVFoundation
import AudioToolbox
import CDexDSP
import CDexEngine
import Combine
import Darwin
import DexCore

/// The two decks, the crossfader, VOLUME and the output routing, over one engine: a single
/// real-time loop that owns everything audible. The AVAudioEngine graph is one source node
/// carrying that loop to the device, so a rebuild for a route change leaves every deck alone.
@MainActor
public final class NativeMixer: ObservableObject {
    public let a: NativeDeck
    public let b: NativeDeck
    @Published public var crossfader = 0.5 { didSet { updateCrossfader() } }
    /// Volume runs into the limiter, as Electron's router does: turning down gives the
    /// limiter headroom instead of just quietening what it has crushed.
    @Published public var volume: Float = 0.7 { didSet { dex_engine_set_volume(core.raw, volume) } }
    /// SPLIT CUE: the stereo master until a deck is on CUE, then mono master
    /// left and mono cue right. Off is 4-CH CUE, master on
    /// 1/2 and cue on 3/4, which needs a four-channel output; without one the
    /// mixer stays on split, as the Electron router does.
    @Published public var splitCue = true { didSet { applyRouting() } }
    /// The cue bus blend: 0 is the master alone, 1 the CUE'd decks alone.
    @Published public var cueMix = 0.85 { didSet { applyRouting() } }
    /// The output layout the engine feeds: 2, or 4 when the hardware has them.
    @Published public private(set) var outputChannels: AVAudioChannelCount = 2
    @Published public private(set) var error: String? { didSet { if error != nil { errorRevision &+= 1 } } }
    @Published public private(set) var notice: String? { didSet { if notice != nil { noticeRevision &+= 1 } } }
    /// Counts each time a problem or notice is raised, so one raised again with the same words
    /// is told from one still standing.
    public private(set) var errorRevision: UInt64 = 0
    public private(set) var noticeRevision: UInt64 = 0
    public enum AudioState: Equatable { case ready, interrupted, recovering, unavailable }
    @Published public private(set) var audioState = AudioState.ready
    private var engine = AVAudioEngine()
    private let core: EngineCore
    private var engineNode: AVAudioSourceNode
    /// For muted measurements on a real device: silence after the engine, so its whole
    /// output, limiter included, can be measured without a sound reaching the device.
    private let mutedAfterEngine: Bool
    private var muteNode: AVAudioMixerNode?
    private var outputSource: AVAudioNode { muteNode ?? engineNode }
    /// For offline tests: no audio is read while it's set, as if the disk had stalled.
    var loaderHeld = false
    /// With `loaderHeld`, reads one chunk for each deck, as a slow disk would.
    func pumpLoaderOnce() { core.pumpLoaderOnce() }
    /// The node carrying the engine's output, for a measurement's tap.
    public var engineOutputNode: AVAudioNode { engineNode }
    /// The engine's own counters, for measurements: nil before its first block.
    public struct EngineCounters: Sendable {
        public let outputGaps: UInt64, starved: [UInt64], waited: [UInt64], late: [UInt64]
        /// Seconds spent rendering so far, the longest block, and a block's length.
        public let renderSeconds: Double, worstBlockMs: Double, blockMs: Double
        /// How late the output runs after the engine's own clock: the limiter's look-ahead.
        public let delaySeconds: Double
    }
    public var engineCounters: EngineCounters? {
        guard let s = engineState else { return nil }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let tick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        return EngineCounters(outputGaps: s.outputGaps, starved: [s.deck.0.starvedBlocks, s.deck.1.starvedBlocks],
                              waited: [s.deck.0.waitedBlocks, s.deck.1.waitedBlocks], late: [s.deck.0.lateLandings, s.deck.1.lateLandings],
                              renderSeconds: Double(s.renderTicks) * tick, worstBlockMs: Double(s.worstRenderTicks) * tick * 1000,
                              blockMs: Double(s.blockFrames) / s.sampleRate * 1000, delaySeconds: Double(s.engineDelayFrames) / s.sampleRate)
    }
    /// The engine's newest block, for tests and measurements.
    var engineState: DexEngineState? {
        core.refresh()
        return core.hasState ? core.state : nil
    }
    /// Manual rendering's channel count, which stands in for the hardware.
    private var offlineChannels: AVAudioChannelCount?
    private let observations = AudioLifecycleObservers()
    private weak var library: NativeLibrary?
    private var enabled = true
    private var observing = false
    private var servicesMissing = false
    private var resumeIntent = [false, false]
    private var playbackObservers: Set<AnyCancellable> = []
    private var configurationQuietUntil = 0.0
    /// The engine reported a change while a start was under way; it's judged when that finishes.
    private var configurationPending = false
    /// The output the last start left the engine feeding.
    private var startedOutput: OutputLatency.Signature?
    private var pressureTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var startTicket: AudioControlTicket?
    private var lockTask: Task<Void, Never>?
    private var audiblePlaying = [false, false]
    private var decks: [NativeDeck] { [a, b] }
    /// The output's RMS over its latest block, dBFS (the Electron router's
    /// `readLevelDb`); −120 before any audio.
    public var meterDb: Double { core.meterDb }
    /// The centre strip's four meters, as peaks in dBFS since the last read: A and B each deck after
    /// TRIM, EQ and FILTER but before LEVEL and the crossfader, L and R the master after VOLUME and
    /// before the limiter. −∞ is silence. One reader: each read takes the peaks.
    public func readMeters() -> (a: Double, l: Double, r: Double, b: Double) {
        let reading = core.readMeters()
        func db(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -.infinity }
        return (db(reading.deck.0), db(reading.master.0), db(reading.master.1), db(reading.deck.1))
    }

    public convenience init(library: NativeLibrary? = nil) {
        self.init(library: library, mutedAfterEngine: false)
    }
    /// `mutedAfterEngine` is for muted measurements on a real device: silence after the
    /// engine, limiter and all.
    public init(library: NativeLibrary? = nil, mutedAfterEngine: Bool) {
        let core = EngineCore()
        self.core = core
        self.mutedAfterEngine = mutedAfterEngine
        engineNode = core.makeNode()
        a = NativeDeck(label: "A", core: core, index: 0)
        b = NativeDeck(label: "B", core: core, index: 1)
        self.library = library
        if let library { a.attachLibrary(library); b.attachLibrary(library) }
        a.partner = b; b.partner = a; a.isMaster = true
        configureGraph()
        for deck in decks {
            deck.$playing.dropFirst().sink { [weak self] playing in
                guard playing, let self else { return }
                runLock()
                guard audioState == .ready else { return }
                notice = nil
            }.store(in: &playbackObservers)
            deck.audioNow = { [weak self] in
                guard let self else { return 0 }
                return engine.isInManualRenderingMode ? Double(engine.manualRenderingSampleTime) / EngineCore.sampleRate
                    : AVAudioTime.seconds(forHostTime: mach_absolute_time())
            }
            deck.routingChanged = { [weak self] in self?.applyRouting() }
        }
    }
    private func configureGraph() {
        engine.attach(engineNode)
        if mutedAfterEngine {
            let mute = AVAudioMixerNode()
            engine.attach(mute)
            engine.connect(engineNode, to: mute, format: AVAudioFormat(standardFormatWithSampleRate: EngineCore.sampleRate, channels: 2)!)
            mute.outputVolume = 0
            muteNode = mute
        } else { muteNode = nil }
        connectOutput(channels: offlineChannels ?? CueRouting.channels(hardware: Int(engine.outputNode.outputFormat(forBus: 0).channelCount)))
        dex_engine_set_volume(core.raw, volume)
        updateCrossfader()
        applyRouting()
        dex_engine_snap_levels(core.raw)
    }
    private func connectOutput(channels: AVAudioChannelCount) {
        engine.connect(outputSource, to: engine.outputNode, format: CueRouting.format(channels: channels))
        outputChannels = channels
    }
    private func applyRouting() {
        // Offline renders take any layout: a two-channel 4-CH render is the
        // stereo master alone, which the transport tests read.
        let split = offlineChannels != nil ? splitCue : CueRouting.split(requested: splitCue, outputChannels: Int(outputChannels))
        if split != splitCue { splitCue = split; return }
        let mix = Float(min(1, max(0, cueMix.isFinite ? cueMix : 0.85))), cueA: Float = a.headphoneCue ? 1 : 0, cueB: Float = b.headphoneCue ? 1 : 0
        dex_engine_set_route(core.raw, Int32(split ? DEX_ROUTE_SPLIT : DEX_ROUTE_MULTICHANNEL), mix, cueA, cueB)
    }
    private func installObservers() {
        let observed = ControlHandle(object: engine)
        observations.install(engine: engine) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, enabled, engine === observed.object, !engine.isInManualRenderingMode else { return }
                receive(event)
            }
        }
        observing = true
    }
    /// A notification from the system. A change of configuration is held while a start is under
    /// way and judged once it has finished, never dropped; the start's own echoes are let go.
    private func receive(_ event: AudioLifecycleEvent) {
        guard case .configurationChanged = event else { handle(event); return }
        let running = engine.isRunning
        switch ConfigurationChange.decide(starting: startTask != nil,
                                          settling: ProcessInfo.processInfo.systemUptime < configurationQuietUntil, running: running,
                                          sameOutput: running && OutputLatency.signature(of: engine) == startedOutput) {
        case .wait: configurationPending = true
        case .ignore: break
        case .act: handle(event)
        }
    }
    /// After a start: a change reported during it is acted on if the engine has stopped again
    /// or is no longer feeding the output that start found.
    private func settleConfiguration() {
        guard configurationPending, startTask == nil else { return }
        configurationPending = false
        if !engine.isRunning || OutputLatency.signature(of: engine) != startedOutput { handle(.configurationChanged) }
    }
    public func setMaster(_ deck: NativeDeck) { deck.becomeMaster() }
    /// While anything plays, keep the decks' clocks on what the engine played, and the master
    /// rule current. The engine holds SYNC's lock itself. It doesn't depend on the display.
    private func runLock() {
        guard lockTask == nil, !engine.isInManualRenderingMode else { return }
        lockTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.holdSync()
                guard self.decks.contains(where: { $0.playing }) else { self.lockTask = nil; return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
    /// The deck left playing on its own leads, as on a CDJ, only when what's playing changes:
    /// MASTER pressed on a stopped deck stays there until then.
    private func holdSync() {
        let playing = decks.map { $0.playing && !$0.previewing }
        if playing != audiblePlaying {
            audiblePlaying = playing
            if playing.filter({ $0 }).count == 1, let alone = decks.first(where: { $0.playing && !$0.previewing }), !alone.isMaster {
                alone.becomeMaster()
            }
        }
        for deck in decks { deck.holdLock() }
    }
    /// Renders `channels` of output by hand. Offline defaults to the 4-CH
    /// layout, so a stereo render carries the master's own left and right.
    func enableOfflineRendering(channels: AVAudioChannelCount = 2, split: Bool = false) throws {
        core.goOffline()
        try engine.enableManualRenderingMode(.offline, format: CueRouting.format(channels: channels), maximumFrameCount: 1024)
        offlineChannels = channels
        connectOutput(channels: channels)
        splitCue = split
        applyRouting()
        dex_engine_snap_levels(core.raw)
    }
    func renderOffline(into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        a.serviceTransitions(); b.serviceTransitions()
        holdSync()
        if !loaderHeld { core.pumpLoader() }
        return try engine.renderOffline(buffer.frameCapacity, to: buffer)
    }
    public func start() {
        enabled = true
        guard audioState != .interrupted, !servicesMissing, startTask == nil else { return }
        if engine.isRunning && audioState == .ready { return }
        requestStart()
    }
    private func cancelStart() {
        startTicket?.cancel(); startTicket = nil
        startTask?.cancel(); startTask = nil
    }
    /// Offline tests own an engine on their rendering thread. Physical output
    /// uses an asynchronous control lane; no main-thread wait or semaphore.
    private func requestStart(resume: [Bool] = [false, false], notice: String? = nil) {
        guard enabled, !servicesMissing, audioState != .interrupted, startTask == nil else { return }
        configurationQuietUntil = ProcessInfo.processInfo.systemUptime + 0.25
        if !observing { installObservers() }
        if engine.isInManualRenderingMode {
            do {
                if !engine.isRunning { try engine.start() }
                finishStart(resume: resume, notice: notice)
            } catch { fail(error) }
            return
        }
        let engineDelay = core.engineDelaySeconds
        let engine = ControlHandle(object: engine), source = ControlHandle(object: outputSource), ticket = AudioControlTicket()
        startTicket = ticket
        audioState = .recovering
        for deck in decks { deck.audioAvailable = false }
        startTask = Task { [weak self] in
            do {
                let output = try await AudioControlExecutor.shared.run {
                    try Self.activateAndStart(engine.object, source: source.object, ticket: ticket)
                }
                guard let self, self.startTicket === ticket, !ticket.isCancelled else { return }
                self.startTask = nil; self.startTicket = nil
                self.outputChannels = output.channels; self.applyRouting()
                for deck in self.decks { deck.outputDelay = output.delay + engineDelay }
                self.startedOutput = output.signature
                self.finishStart(resume: resume, notice: notice)
                self.settleConfiguration()
            } catch {
                guard let self, self.startTicket === ticket, !ticket.isCancelled else { return }
                self.startTask = nil; self.startTicket = nil
                self.configurationPending = false
                self.fail(error)
            }
        }
    }
    /// Returns the output layout the engine was left feeding, and that output's delay.
    nonisolated private static func activateAndStart(_ engine: AVAudioEngine, source: AVAudioNode,
                                                     ticket: AudioControlTicket) throws -> (channels: AVAudioChannelCount, delay: Double, signature: OutputLatency.Signature?) {
        let connected = engine.outputNode.inputFormat(forBus: 0).channelCount
        guard !ticket.isCancelled else { return (connected, 0, nil) }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default || !session.categoryOptions.isEmpty {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        guard !ticket.isCancelled else { return (connected, 0, nil) }
        // The SDK documents activation as blocking. This executes on the serial
        // control worker, never the main actor or a high-QoS render thread.
        try session.setActive(true)
        // 4-CH CUE needs the interface's channels 3/4, which iOS only opens on request.
        if session.maximumOutputNumberOfChannels >= 4, session.outputNumberOfChannels < 4 {
            try? session.setPreferredOutputNumberOfChannels(4)
        }
        #endif
        guard !ticket.isCancelled else { return (connected, 0, nil) }
        // The output device can change while paused; follow its channel count.
        let wanted = CueRouting.channels(hardware: Int(engine.outputNode.outputFormat(forBus: 0).channelCount))
        if !engine.isRunning, wanted != connected {
            engine.connect(source, to: engine.outputNode, format: CueRouting.format(channels: wanted))
        }
        let channels = engine.outputNode.inputFormat(forBus: 0).channelCount
        if !engine.isRunning { try engine.start() }
        if ticket.isCancelled { engine.pause() }
        AudioDiagnostics.log.info("output: \(OutputLatency.describe(engine), privacy: .public)")
        return (channels, OutputLatency.seconds(for: engine), OutputLatency.signature(of: engine))
    }
    private func finishStart(resume: [Bool], notice: String?) {
        guard enabled, !servicesMissing, audioState != .interrupted else { return }
        audioState = .ready; error = nil
        configurationQuietUntil = ProcessInfo.processInfo.systemUptime + 0.25
        // A paused engine froze its filters mid-tail; nothing from before may ring on.
        dex_engine_clear_tails(core.raw)
        for deck in decks {
            if !deck.playing { deck.reanchor() }
            deck.audioAvailable = true
        }
        for (deck, wasPlaying) in zip(decks, resume) where wasPlaying { deck.togglePlay() }
        self.notice = notice
    }
    /// `then` runs on the main actor once the output has really stopped, if it has.
    private func controlEngine(_ operation: @escaping @Sendable (AVAudioEngine) -> Void,
                               then stopped: (@MainActor @Sendable () -> Void)? = nil) {
        let engine = engine, core = core
        if engine.isInManualRenderingMode {
            operation(engine)
            if !engine.isRunning { stopped?() }
        } else {
            let handle = ControlHandle(object: engine)
            AudioControlExecutor.shared.submit {
                operation(handle.object)
                withExtendedLifetime(core) {} // Its memory stays until the output has really stopped.
                if !handle.object.isRunning, let stopped { Task { @MainActor in stopped() } }
            }
        }
    }
    private func lastOutputTime() -> Double? {
        if engine.isInManualRenderingMode { return Double(engine.manualRenderingSampleTime) / EngineCore.sampleRate }
        guard let time = engine.outputNode.lastRenderTime, time.isHostTimeValid else { return nil }
        return AVAudioTime.seconds(forHostTime: time.hostTime)
    }
    @discardableResult
    private func suspend() -> [Bool] {
        cancelStart()
        let time = lastOutputTime()
        let result = decks.map { $0.suspendPlayback(at: time) }
        controlEngine { $0.pause() }
        return result
    }
    private func fail(_ failure: Error) {
        error = failure.localizedDescription; audioState = .unavailable
        for deck in decks { deck.audioAvailable = false }
    }
    /// Shared, testable policy for system notifications and scene transitions.
    func handle(_ event: AudioLifecycleEvent) {
        autoreleasepool { handleEvent(event) }
    }
    private func handleEvent(_ event: AudioLifecycleEvent) {
        guard enabled else { return }
        switch event {
        case .interruptionBegan:
            guard audioState != .interrupted, !servicesMissing else { return }
            resumeIntent = suspend(); audioState = .interrupted
            notice = "Playback interrupted."
        case .interruptionEnded(let shouldResume):
            guard audioState == .interrupted else { return }
            let resume = resumeIntent; resumeIntent = [false, false]
            audioState = .recovering
            requestStart(resume: shouldResume ? resume : [false, false],
                         notice: shouldResume && resume.contains(true) ? nil : "Audio is ready. Press PLAY to continue.")
        case .configurationChanged:
            guard audioState != .interrupted, !servicesMissing else { return }
            handle(.outputChanged)
        case .outputChanged:
            // Never start unexpectedly on speakers after headphones/USB vanish.
            let interrupted = audioState == .interrupted
            _ = suspend(); resumeIntent = [false, false]
            if servicesMissing { return }
            if interrupted { notice = "Audio output changed. Playback will remain paused."; return }
            audioState = .recovering
            requestStart(notice: "Audio output changed. Press PLAY to continue.")
        case .servicesLost:
            servicesMissing = true
            _ = suspend(); resumeIntent = [false, false]; audioState = .unavailable
            notice = "Audio services are restarting."
        case .servicesReset:
            servicesMissing = false
            _ = suspend(); resumeIntent = [false, false]; audioState = .recovering
            rebuildEngine()
        case .willSleep:
            _ = suspend(); resumeIntent = [false, false]; audioState = .unavailable
            notice = "Playback paused for sleep."
        case .foreground:
            AudioMemoryBudget.shared.setPressure(false)
            guard audioState != .interrupted, !servicesMissing, startTask == nil else { return }
            if !engine.isRunning {
                _ = suspend()
                requestStart(notice: "Audio is ready. Press PLAY to continue.")
            }
        case .memoryWarning:
            AudioMemoryBudget.shared.setPressure(true)
            library?.handleMemoryPressure()
            for deck in decks { deck.cancelOptionalWork() }
            let message = "Optional audio preparation paused to free memory. Playback continues."
            notice = message
            pressureTask?.cancel()
            pressureTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                AudioMemoryBudget.shared.setPressure(false)
                if self?.notice == message { self?.notice = nil }
            }
        }
    }
    private func rebuildEngine() {
        observations.clear(); observing = false
        let previous = engine
        if previous.isInManualRenderingMode {
            previous.stop()
            replaceEngine(offline: true)
            return
        }
        let ticket = AudioControlTicket(), retired = ControlHandle(object: previous); startTicket = ticket
        startTask = Task { [weak self] in
            _ = try? await AudioControlExecutor.shared.run { retired.object.stop() }
            guard let self, self.startTicket === ticket, !ticket.isCancelled else { return }
            self.startTask = nil; self.startTicket = nil
            self.replaceEngine(offline: false)
        }
    }
    /// A new graph around the same engine, whose decks keep everything they hold.
    private func replaceEngine(offline: Bool) {
        for deck in decks { deck.rebuildNodes() }
        engine = AVAudioEngine()
        engineNode = core.makeNode()
        let channels = offlineChannels, split = splitCue
        offlineChannels = nil
        configureGraph()
        do {
            if offline { try enableOfflineRendering(channels: channels ?? 2, split: split) }
            requestStart(notice: "Audio was restored. Press PLAY to continue.")
        } catch { fail(error) }
    }
    public func sceneBecameActive() { handle(.foreground) }
    /// How often the engine had to wait or fell short, in a line.
    public var engineReport: String {
        core.refresh()
        guard core.hasState else { return "engine: no audio yet" }
        let s = core.state
        func line(_ d: DexDeckState) -> String { "landings \(d.landings), late \(d.lateLandings), waited \(d.waitedBlocks) blocks, starved \(d.starvedBlocks), relocks \(d.relocks), chunks \(d.chunksResident)" }
        return "engine: A \(line(s.deck.0)); B \(line(s.deck.1)); output gaps \(s.outputGaps), block \(s.blockFrames)"
    }
    /// Writes what the engine has seen so far to the log.
    public func logDiagnostics() {
        AudioDiagnostics.log.info("\(self.engineReport, privacy: .public)")
    }
    public func shutdown() {
        enabled = false; cancelStart(); observing = false; observations.clear(); pressureTask?.cancel(); pressureTask = nil
        lockTask?.cancel(); lockTask = nil
        for deck in decks { deck.shutdown(); deck.audioAvailable = false }
        audioState = .unavailable
        let core = core
        controlEngine({ $0.stop() }, then: { core.close() })
    }
    private func updateCrossfader() {
        let (left, right) = MixMath.crossfade(crossfader)
        a.crossfadeGain = Float(left); b.crossfadeGain = Float(right)
    }
}
