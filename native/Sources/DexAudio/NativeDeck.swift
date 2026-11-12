import AVFoundation
import AudioToolbox
import CDexEngine
import Combine
import DexCore
import Darwin

/// One deck: the musical rules (cues, jumps, loops, SYNC, the jog's gesture) and its clock.
/// Every change of position ends in a landing the engine carries out in its own loop, on a
/// chosen output frame; the clock follows what the engine says it played.
/// Remaining feature-parity gates are tracked in native/README.md.
@MainActor
public final class NativeDeck: ObservableObject {
    @Published public private(set) var libraryTrackID: UUID?
    private var library: NativeLibrary?
    private var libraryChanges: AnyCancellable?
    @Published public private(set) var name = "Load track"
    /// The loaded file's tag names and cover, for the track window.
    @Published public private(set) var tags = TrackTags.none
    @Published public private(set) var duration = 0.0
    public let playhead = DeckPlayhead()
    public let jog = DeckJog()
    public private(set) var transportRevision: UInt64 = 0
    public private(set) var position: Double { get { playhead.seconds } set { playhead.set(newValue) } }
    @Published public private(set) var playing = false
    @Published public internal(set) var audioAvailable = true
    @Published public private(set) var loading = false
    @Published public private(set) var previewing = false { didSet { if previewing != oldValue { link.setPreview(previewing) } } }
    /// This deck's line to the engine.
    let link: EngineDeck
    /// When the end of the track will be heard, once the engine has played its last frame.
    private var endHeardAt: Double?
    /// When a start from stopped comes out, until it has.
    private var startDueAt: Double?
    /// The delay from the engine to what's heard: the device's, and the engine's limiter.
    public var outputLatency: Double { outputDelay }
    /// The engine's newest block for this deck, for tests.
    var engineDeckState: DexDeckState? {
        link.core.refresh()
        return link.core.hasState ? link.core.deckState(Int(link.index)) : nil
    }
    /// How many landings the engine has made on this deck, from its newest block.
    var engineLandings: UInt64? { engineDeckState?.landings }
    private let loops = DeckLoopController()
    public var loopActive: Bool { loops.current != nil }
    @Published public private(set) var grid: BeatGrid? { didSet { link.setGrid(grid); updateHotspots() } }
    @Published public private(set) var gridUncertain = false
    @Published public private(set) var gridAlternatives: [DetectedGrid.Alternative] = []
    @Published public private(set) var syncLocked = false { didSet { if syncLocked != oldValue { link.setSync(syncLocked) } } }
    @Published public internal(set) var isMaster = false { didSet { if isMaster != oldValue { sendMaster() } } }
    weak var partner: NativeDeck?
    var audioNow: () -> Double = { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    /// The engine's and the output device's delay. `clock` runs on the engine's time, which
    /// reaches the listener this much later; `position` is what they hear, so the waveform
    /// and anything captured from it land on the beat they heard. Both decks share it, so
    /// SYNC and scheduling stay on the engine's time.
    var outputDelay = 0.0
    private var clock = TransportClock()
    /// The speed really playing, from the engine, SYNC's correction included. `tempo` is what was asked for.
    private(set) var playRate = 1.0
    public static let loopSizes: [Double] = [0.5, 1, 2, 4, 8, 16, 32, 64]
    public var loopBeats: Double { loops.beats }
    public var loopBounds: ClosedRange<Double>? {
        guard let loopAudio else { return nil }
        return loopAudio.start...loopAudio.end
    }
    @Published public private(set) var hotCues: [Double?] = Array(repeating: nil, count: 8) { didSet { updateHotspots() } }
    @Published public private(set) var peaks: [Float] = []
    @Published public private(set) var waveform: TrackWaveform?
    @Published public private(set) var error: String?
    @Published public var tempo = 1.0 { didSet { updateTempo() } }
    @Published public var keyLock = true { didSet { updateTempo() } }
    @Published public var level: Float = 0.8 { didSet { updateGain() } }
    @Published public var trimDB: Float = 0 { didSet { updateBands() } }
    /// AUTO for the loaded track: the trim that brings it to the target loudness. Nil until measured.
    @Published public private(set) var autoTrimDB: Float?
    /// Whether a load sets the trim (the DJ's own for the track, else AUTO). The console turns it on;
    /// off, a load leaves the trim alone, so audio tests hear tracks at unity.
    public var trimsOnLoad = false
    @Published public var lowDB: Float = 0 { didSet { updateBands() } }
    @Published public var midDB: Float = 0 { didSet { updateBands() } }
    @Published public var highDB: Float = 0 { didSet { updateBands() } }
    /// A kill mutes its band whatever its fader says; so does a fader at −96 dB.
    @Published public var kills = EQKills() { didSet { updateBands() } }
    /// Headphone CUE: the deck reaches the cue bus after its tone section, before its fader.
    @Published public var headphoneCue = false { didSet { routingChanged?() } }
    var routingChanged: (() -> Void)?
    /// The one-knob sweep: −1 low-pass … 0 off … 1 high-pass.
    @Published public var filter = 0.0 { didSet { updateFilter() } }
    public let label: String
    private var hasStreamingVoice = false
    /// Rendering can only be assumed this far past its last confirmed block.
    private let renderedSlack = 0.05
    /// How long until the engine's next block: the soonest a change can come out.
    var replacementLookahead: Double {
        let now = audioNow()
        return link.core.soonest(after: now) - now
    }
    /// How long a press from stopped takes to come out, attack whole, for tests that count beats.
    var startDelay: Double { replacementLookahead + fadeDuration }
    /// How far into a beat that has already gone a quantized cue joins it, past any attack.
    /// A beat still to come is met whole, as soon as it can be.
    static let joinLead = 0.12
    private let fadeDuration = 0.01
    private var file: AVAudioFile?
    private var scopedURL: URL?
    private var loadGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var transportAt = 0.0
    @Published public private(set) var cuePoint = 0.0 { didSet { updateHotspots() } }
    private var cueHeld = false
    private var defaultCue = true
    private var loopAudio: LoopAudio? { loops.current?.audio }
    private struct LoopClockSegment {
        let time: Double
        let bounds: ClosedRange<Double>?
    }
    private var loopClock = [LoopClockSegment(time: 0, bounds: nil)]
    var crossfadeGain: Float = 0.707 { didSet { updateGain() } }

    init(label: String, core: EngineCore, index: Int32) {
        self.label = label
        let link = EngineDeck(core: core, index: index)
        self.link = link
        outputDelay = core.engineDelaySeconds
        loops.sampleRate = 48_000
        jog.engine = JogEngineControl(
            enter: { link.enterScrub(at: $0) }, speed: { link.scrubSpeed($0, damping: $1) },
            rendered: { link.renderedPosition }, leave: { link.leaveScrub() })
        updateBands(); updateFilter(); updateGain(); updateTempo()
        loops.changed = { [weak self] in self?.objectWillChange.send() }
        loops.failed = { [weak self] in self?.error = $0 }
        loops.committed = { [weak self] audio, shift in self?.commitLoop(audio, shift: shift) }
        jog.now = { [weak self] in self?.audioNow() ?? 0 }
        jog.located = { [weak self] target in
            guard let self else { return }
            position = target
            if let bounds = loopBounds, !bounds.contains(target) || target == bounds.upperBound { clearLoop() }
        }
        jog.finished = { [weak self] target in
            guard let self else { return }
            position = target
            clock.reset(at: audioNow(), position: target)
            scheduleLoopClock(at: audioNow(), bounds: loopBounds)
            if playing { schedule(from: target) } else { link.rest(at: target) }
        }
        jog.failed = { [weak self] message in self?.error = message }
    }
    /// What the tone section is set to: the LOW / MID / HIGH gains and the trim, as linear gains.
    var tone: (low: Float, mid: Float, high: Float, trim: Float) {
        (Isolator.gain(db: lowDB, killed: kills.low), Isolator.gain(db: midDB, killed: kills.mid),
         Isolator.gain(db: highDB, killed: kills.high), pow(10, trimDB / 20))
    }
    /// The sweep knob the engine is given: −1 low-pass … 0 off … 1 high-pass.
    var sweep: Float { let knob = Float(filter); return min(1, max(-1, knob.isFinite ? knob : 0)) }
    private func updateBands() {
        let tone = tone
        dex_engine_set_tone(link.engine, link.index, tone.low, tone.mid, tone.high, tone.trim)
    }
    private func updateFilter() { dex_engine_set_sweep(link.engine, link.index, sweep) }
    func sendMaster() {
        if isMaster { link.sent(dex_engine_set_master(link.engine, link.index)) }
        else if partner?.isMaster != true { link.sent(dex_engine_set_master(link.engine, -1)) }
    }
    /// What a DJ can reach at once, kept ready: the cues, the loop and every bar jump.
    private func updateHotspots() {
        var points = hotCues.compactMap { $0 }
        points.append(cuePoint)
        if let bounds = loopBounds { points += [bounds.lowerBound, bounds.upperBound] }
        link.setHotspots(points)
        if let grid {
            let bar = grid.beatSeconds * 4
            link.setReach(Self.jumpSizes.flatMap { [Double($0) * bar, -Double($0) * bar] })
        }
    }
    /// How many failed reads of the loaded track have been reported already.
    private var seenReadFailures: UInt64 = 0
    private func syncEngine() {
        link.sync(clock: &clock, following: playing && hasStreamingVoice && !jog.active)
        if let tempo = link.playedTempo { playRate = tempo }
        // The count starts again with each track, so this follows it down as well as up.
        let failures = link.readFailures
        if failures > seenReadFailures { error = PlaybackError.unreadable.localizedDescription }
        seenReadFailures = failures
        if link.dropped, link.confirmed { resendEngineState() }
    }
    /// After a command was dropped (the output stopped taking them, and the queue filled), the
    /// engine has caught up with the rest; this puts it back to what the deck says, all of it.
    private func resendEngineState() {
        link.dropped = false
        updateTempo(); updateGain(); updateBands(); updateFilter()
        link.setGrid(grid); updateHotspots(); sendMaster()
        link.setSync(syncLocked); link.setPreview(previewing)
        link.setLoop(loopBounds)
        if let position = jog.position {
            _ = link.enterScrub(at: position)
        } else {
            link.leaveScrub()
            if playing {
                hasStreamingVoice = true
                land(from: positionAt(audioNow()), quantizedCue: false, continuing: false, barShift: nil, loopShift: nil)
            } else {
                link.pause(); link.rest(at: position)
            }
        }
    }

    func attachLibrary(_ library: NativeLibrary) {
        self.library = library
        libraryChanges = library.$tracks.sink { [weak self] tracks in
            guard let self, let id = self.libraryTrackID,
                  let track = tracks.first(where: { $0.id == id }) else { return }
            self.receiveMetadata(track)
        }
    }

    private func receiveMetadata(_ track: LibraryTrack) {
        if grid != track.grid || gridUncertain != track.gridUncertain {
            cancelJog(resume: false)
            refreshPosition()
            clearLoop()
            grid = track.grid
            gridUncertain = track.gridUncertain
            gridAlternatives = track.alternatives
            updateCueGrid()
            followMasterTempo()
            if isMaster { partner?.followMasterTempo() }
            if playing { schedule(from: position, continuing: true) }
        }
        let cues = snappedHotCues(track.hotCues)
        if hotCues != cues { hotCues = cues }
    }
    private func snappedHotCues(_ cues: [Double?]) -> [Double?] {
        guard let grid else { return cues }
        return cues.map { $0.map { grid.cueTime(near: $0, duration: duration) ?? $0 } }
    }
    private func snappedCue(_ time: Double) -> Double {
        grid?.cueTime(near: time, duration: duration) ?? time
    }
    private func updateCueGrid() {
        let wasAtCue = abs(position - cuePoint) < 1e-7
        cuePoint = snappedCue(defaultCue ? 0 : cuePoint)
        if !playing && wasAtCue {
            position = cuePoint
            clock.reset(at: audioNow(), position: cuePoint)
            link.rest(at: cuePoint)
        }
        hotCues = snappedHotCues(hotCues)
    }
    private func saveMetadata() {
        guard let libraryTrackID else { return }
        library?.edit(libraryTrackID, grid: grid, uncertain: gridUncertain, hotCues: hotCues)
    }

    /// The open track's audio, for readers with their own handle.
    public var fileURL: URL? { file?.url }
    public func load(_ url: URL) { beginLoad(url: url, id: nil) }
    public func loadTrack(_ id: UUID) { beginLoad(url: nil, id: id) }

    private func beginLoad(url: URL?, id: UUID?) {
        guard audioAvailable else { error = "Audio is recovering. Load the deck again when audio is ready."; return }
        guard !playing else { error = "Pause this deck before loading a track."; return }
        cancelJog(resume: false)
        loadTask?.cancel()
        loadGeneration = UUID()
        let request = loadGeneration
        loading = true
        error = nil
        let library = self.library
        loadTask = Task { [weak self] in
            var scoped: URL?
            var committed = false
            defer { if !committed { scoped?.stopAccessingSecurityScopedResource() } }
            do {
                let source: URL
                let overview: WaveformOverview
                let metadata: LibraryTrack?
                if let library {
                    let prepared: PreparedLibraryTrack
                    if let id { prepared = try await library.prepare(id: id) }
                    else if let url { prepared = try await library.prepare(url: url) }
                    else { throw LibraryError.missingTrack }
                    source = prepared.url
                    overview = prepared.overview
                    metadata = prepared.track
                } else {
                    guard let url else { throw LibraryError.missingTrack }
                    if url.startAccessingSecurityScopedResource() { scoped = url }
                    let analysis = Task.detached(priority: .userInitiated) {
                        try await TrackPreparation.shared.read(url)
                    }
                    overview = try await withTaskCancellationHandler {
                        try await analysis.value
                    } onCancel: { analysis.cancel() }
                    source = url
                    metadata = nil
                }
                let tagSource = source
                let tags = await Task.detached(priority: .userInitiated) { TrackTags.read(url: tagSource) }.value
                try Task.checkCancellation()
                guard let self, self.loadGeneration == request else { return }
                guard !self.playing else {
                    self.loading = false
                    self.error = "Playback started; replacement was cancelled."
                    return
                }
                let next = try AVAudioFile(forReading: source)
                guard (1...2).contains(next.processingFormat.channelCount) else {
                    throw PlaybackError.unsupportedChannels
                }
                self.stopVoices()
                try self.link.load(url: source)
                self.loops.sampleRate = self.link.fileRate
                self.scopedURL?.stopAccessingSecurityScopedResource()
                self.scopedURL = scoped
                committed = true
                self.file = next
                self.libraryTrackID = metadata?.id
                self.name = metadata?.title ?? source.deletingPathExtension().lastPathComponent
                self.tags = tags
                self.duration = overview.duration
                self.peaks = overview.peaks
                self.waveform = overview.waveform
                self.clock.reset(at: self.audioNow())
                self.position = 0
                self.transportAt = 0
                self.cuePoint = 0
                self.defaultCue = true
                self.cueHeld = false
                self.previewing = false
                let detection = metadata?.detection ?? overview.detection
                self.grid = detection.grid
                self.gridUncertain = detection.uncertain
                self.gridAlternatives = detection.alternatives
                self.followMasterTempo()
                if self.isMaster { self.partner?.followMasterTempo() }
                self.hotCues = metadata?.hotCues ?? Array(repeating: nil, count: 8)
                // AUTO trim: the DJ's own trim for this track if they set one, else the measured one.
                let loudness = metadata?.loudness ?? overview.loudness
                self.autoTrimDB = loudness.map { Float($0.autoTrim()) }
                if self.trimsOnLoad { self.trimDB = Float(metadata?.trimDb ?? loudness?.autoTrim() ?? 0) }
                self.updateCueGrid()
                self.clearLoop()
                self.loading = false
                if let metadata, self.hotCues != metadata.hotCues { self.saveMetadata() }
                if let metadata { library?.fillNames(metadata.id, artist: tags.artist, title: tags.title) }
            } catch is CancellationError {
                if let self, self.loadGeneration == request { self.loading = false }
            } catch {
                if let self, self.loadGeneration == request {
                    self.loading = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// Capture the normal PLAY latch while the engine scrubs to the jog's gesture.
    /// This is reusable by a future platter gesture; display units stay in UI.
    public func beginJog(at anchor: Double? = nil) {
        guard audioAvailable, !loading, file != nil else { return }
        let target = anchor.flatMap { $0.isFinite ? $0 : nil } ?? jog.currentPosition ?? heardAt(audioNow() - outputDelay)
        transportRevision &+= 1
        jog.cancel()
        refreshPosition()
        previewing = false
        hasStreamingVoice = false; link.forgetLanding()
        position = min(duration, max(0, target))
        clock.reset(at: audioNow(), position: position)
        jog.begin(position: position, duration: duration)
    }
    /// A new transport intent owns the final position; a stale coast cannot
    /// later seek or resume over it. Lifecycle callers can suppress resumption.
    public func cancelJog(resume: Bool = true) {
        transportRevision &+= 1
        guard jog.active else { return }
        let target = jog.currentPosition ?? position
        jog.cancel()
        position = target
        clock.reset(at: audioNow(), position: target)
        scheduleLoopClock(at: audioNow(), bounds: loopBounds)
        if resume && playing { schedule(from: target) } else { link.rest(at: target) }
    }

    public func togglePlay() {
        guard audioAvailable else { return }
        cancelJog(resume: false)
        guard file != nil else { return }
        if previewing && playing {
            previewing = false // Latch the existing schedule; do not restart audio.
            return
        }
        if previewing { previewing = false; seek(to: cuePoint) }
        if playing {
            refreshPosition()
            stopVoices()
            playing = false
            clock.reset(at: audioNow(), position: position)
        } else {
            // The deck already playing leads: a start must never move what's being heard.
            if isMaster, let partner, partner.playing, !partner.previewing { partner.becomeMaster() }
            schedule(from: position >= duration ? 0 : position)
        }
    }

    public func seek(to seconds: Double) { locate(to: seconds) }

    private func locate(to seconds: Double, quantizedCue: Bool = false) {
        guard seconds.isFinite else { return }
        cancelJog(resume: false)
        let target = min(duration, max(0, seconds))
        if let bounds = loopBounds, !bounds.contains(target) || target == bounds.upperBound { clearLoop() }
        if previewing { previewing = false }
        if playing { schedule(from: target, quantizedCue: quantizedCue) }
        else { position = target; clock.reset(at: audioNow(), position: target); link.rest(at: target) }
    }

    public func cueDown() {
        guard audioAvailable, file != nil, !cueHeld else { return }
        cancelJog(resume: false)
        cueHeld = true
        if playing && !previewing {
            stopVoices()
            playing = false
            seek(to: cuePoint)
        } else {
            if let grid, grid.cueTime(near: position, duration: duration) == nil {
                cueHeld = false
                error = "The beat grid has no beat inside this track. Correct its BPM and offset."
                return
            }
            error = nil
            cuePoint = snappedCue(position)
            defaultCue = false
            seek(to: cuePoint)
            previewing = true
            schedule(from: cuePoint, quantizedCue: true)
        }
    }
    public func cueUp() {
        cueHeld = false
        guard previewing else { return }
        previewing = false
        stopVoices()
        playing = false
        seek(to: cuePoint)
    }
    public func cue() { cueDown(); cueUp() }

    /// RE-ANALYSE on the track this deck holds: its new grid, as Electron's
    /// `deck.setGrid`. Hot cues stay, snapped to it as on any grid change.
    public func follow(reanalysed track: LibraryTrack) {
        guard libraryTrackID == track.id, track.grid != nil else { return }
        cancelJog(resume: false)
        refreshPosition()
        clearLoop()
        grid = track.grid
        gridUncertain = track.gridUncertain
        gridAlternatives = track.alternatives
        updateCueGrid()
        saveMetadata()
        followMasterTempo()
        if isMaster { partner?.followMasterTempo() }
        if playing { schedule(from: position, continuing: true) }
    }

    public func setGrid(bpm: Double, offsetMs: Double = 0) {
        do {
            guard (40...300).contains(bpm) else { throw BeatGrid.GridError.invalidGrid }
            let next = try BeatGrid(bpm: bpm, offsetMs: offsetMs, confidence: 1)
            cancelJog(resume: false)
            refreshPosition()
            clearLoop()
            grid = next
            gridUncertain = false
            updateCueGrid()
            error = nil
            saveMetadata()
            followMasterTempo()
            if isMaster { partner?.followMasterTempo() }
            if playing { schedule(from: position, continuing: true) }
        } catch { self.error = "Enter a valid positive BPM and grid offset." }
    }
    public func hotCue(_ slot: Int, clear: Bool = false) {
        guard hotCues.indices.contains(slot), file != nil else { return }
        cancelJog()
        if clear { hotCues[slot] = nil }
        else {
            guard let grid else { error = "Set the track BPM before using hot cues."; return }
            guard let target = grid.cueTime(near: hotCues[slot] ?? position, duration: duration) else {
                error = "The beat grid has no beat inside this track. Correct its BPM and offset."; return
            }
            if hotCues[slot] != nil {
                if hotCues[slot] != target { hotCues[slot] = target; saveMetadata() }
                error = nil
                locate(to: target, quantizedCue: true)
                return
            }
            refreshPosition()
            hotCues[slot] = grid.cueTime(near: position, duration: duration)
        }
        error = nil
        saveMetadata()
    }

    public static let jumpSizes = [1, 4, 16, 32]
    @Published public var jumpBars = 1

    /// One press moves whole bars; preparation never removes the playing beat.
    public func jump(direction: Int) {
        guard audioAvailable, !loading, let grid, file != nil,
              Self.jumpSizes.contains(jumpBars), direction == -1 || direction == 1 else {
            if grid == nil { error = "Set the track BPM before using bar jumps." }
            return
        }
        cancelJog()
        refreshPosition()
        let when = audioNow() + (playing ? replacementLookahead : 0)
        var origin = playing ? positionAt(when) : position
        let region = loops.current?.region
        let bounds = region?.bounds(grid: grid)
        guard let plan = BarJump.plan(grid: grid, position: origin, duration: duration,
                                      playing: playing, bars: direction * jumpBars, loop: bounds) else {
            error = "The track has no playable bar for this jump."
            return
        }
        error = nil
        if let region {
            guard plan.bars != 0 else { return }
            var moved = region
            moved.startBeat += Double(plan.bars * 4)
            if prepareLoop(moved, shift: Double(plan.bars) * grid.beatSeconds * 4) { previewing = false }
        } else if playing {
            guard plan.bars != 0 else { return }
            previewing = false
            schedule(from: position, continuing: true, barShift: Double(plan.bars) * grid.beatSeconds * 4)
        } else {
            error = nil
            locate(to: plan.position)
        }
    }

    /// Select or resize. Growing keeps loop-in; shrinking keeps the part the
    /// playhead is in, so it plays on. An invalid expansion leaves the loop as it is.
    public func setLoopBeats(_ beats: Double) {
        cancelJog()
        guard Self.loopSizes.contains(beats), beats != loopBeats else { return }
        if loopActive {
            guard let current = loops.current?.region, let grid else { return }
            refreshPosition()
            let when = audioNow() + (playing ? replacementLookahead : 0)
            let origin = playing ? positionAt(when) : position
            let region = current.resized(to: beats, around: grid.beat(at: origin))
            guard prepareLoop(region) else { return }
        }
        loops.select(beats)
    }

    public func toggleLoop() {
        cancelJog()
        if loopActive {
            clearLoop()
            if playing { schedule(from: position, continuing: true) }
            return
        }
        guard file != nil, let grid else {
            error = "Set the track BPM before using a beat loop."
            return
        }
        refreshPosition()
        let region = LoopRegion(grid: grid, position: position, lengthBeats: loopBeats)
        _ = prepareLoop(region)
    }

    @discardableResult
    private func prepareLoop(_ region: LoopRegion, shift: Double = 0) -> Bool {
        guard audioAvailable, file != nil, let grid else { return false }
        error = nil
        return loops.request(region, shift: shift, grid: grid, duration: duration)
    }
    private func commitLoop(_ audio: LoopAudio, shift: Double) {
        // A moved loop goes with its jump, as one change. Otherwise the playhead just carries on into it.
        if !(playing && shift != 0) { link.setLoop(audio.start...audio.end) }
        updateHotspots()
        if playing { schedule(from: position, continuing: true, loopShift: shift) }
        else {
            if let previous = boundsAt(audioNow()) {
                if shift != 0 {
                    let origin = grid.flatMap { BarJump.plan(grid: $0, position: position, duration: duration, playing: false, bars: 0)?.position } ?? position
                    position = origin + shift
                } else if previous.contains(position) {
                    position = audio.folding(position)
                }
            }
            if position >= audio.end {
                position = audio.start + (position - audio.start).truncatingRemainder(dividingBy: audio.end - audio.start)
            }
            clock.reset(at: audioNow(), position: position)
            scheduleLoopClock(at: audioNow(), bounds: loopBounds)
            link.rest(at: position)
        }
    }
    private func clearLoop() {
        loops.clear()
        link.setLoop(nil)
        updateHotspots()
        if !playing { scheduleLoopClock(at: audioNow(), bounds: nil) }
    }

    private func boundsAt(_ time: Double) -> ClosedRange<Double>? {
        (loopClock.last(where: { $0.time <= time }) ?? loopClock[0]).bounds
    }
    private func scheduleLoopClock(at time: Double, bounds: ClosedRange<Double>?) {
        loopClock.removeAll { $0.time >= time }
        loopClock.append(LoopClockSegment(time: time, bounds: bounds))
        while loopClock.count > 2 && loopClock[1].time < time - 1 { loopClock.removeFirst() }
    }

    public func toggleSync() {
        cancelJog(resume: false)
        syncLocked.toggle()
        if syncLocked {
            // SYNC follows something: pressed on the master beside a deck to follow, the master moves there.
            if isMaster, let partner, partner.file != nil, partner.playing || !playing {
                isMaster = false; partner.isMaster = true
                partner.releaseLock()
            }
            // The engine's lock lands or steers this deck in the same block it hears about it.
            followMasterTempo()
        } else { releaseLock() }
    }
    /// The master is the truth: a synced deck takes its tempo and lands on its grid at once.
    func becomeMaster() {
        isMaster = true; partner?.isMaster = false
        releaseLock()
        partner?.followMasterTempo()
        partner?.holdLock()
    }
    /// The engine holds SYNC's lock in its own loop; here the deck only follows what it played.
    func holdLock() { serviceTransitions() }
    private func releaseLock() {
        let rate = min(1.16, max(0.84, tempo))
        guard rate != playRate else { return }
        playRate = rate
        if playing { clock.schedule(at: max(audioNow(), transportAt), rate: rate) }
    }
    func followMasterTempo() {
        guard syncLocked, !isMaster, let source = partner, source.isMaster,
              let grid, let masterGrid = source.grid else { return }
        tempo = MixMath.tempoRate(master: masterGrid.bpm * source.tempo, follower: grid.bpm)
    }
    private func positionAt(_ time: Double) -> Double {
        if let position = jog.position { return position }
        var value = clock.position(at: time)
        if let bounds = boundsAt(time), value >= bounds.upperBound {
            value = bounds.lowerBound + (value - bounds.lowerBound)
                .truncatingRemainder(dividingBy: bounds.upperBound - bounds.lowerBound)
        }
        return value
    }
    /// What the engine has confirmed for this time, for anything shown or captured.
    /// `positionAt` is the planned timeline, for working out what happens next.
    private func heardAt(_ time: Double) -> Double {
        syncEngine()
        let rendered = link.renderedUntil
        let confirmed = rendered > 0 ? min(time, rendered + renderedSlack) : time
        return positionAt(confirmed)
    }
    private func stopVoices() {
        hasStreamingVoice = false; endHeardAt = nil
        link.pause()
    }

    /// Brings the clock up to date with the engine, and notices the end of the track.
    func serviceTransitions() {
        jog.service()
        do {
            syncEngine()
            if playing, hasStreamingVoice, link.ended {
                // The last frame has been played; it's heard a device's delay later, and the
                // waveform reaches the end then, not before.
                hasStreamingVoice = false
                let now = audioNow(), reached = clock.position(at: now)
                let end = reached > duration && playRate > 0 ? now - (reached - duration) / playRate : now
                clock.schedule(at: end, rate: 0, position: duration)
                endHeardAt = end + outputDelay
            }
            if playing, let heard = endHeardAt, audioNow() >= heard {
                endHeardAt = nil; playing = false; position = duration
            }
        }
    }

    private func schedule(from seconds: Double, quantizedCue: Bool = false, continuing: Bool = false,
                          barShift: Double? = nil, loopShift: Double? = nil) {
        guard file != nil else { return }
        land(from: seconds, quantizedCue: quantizedCue, continuing: continuing, barShift: barShift, loopShift: loopShift)
    }

    /// Every change of position ends here, in one landing: a voice started on a chosen output
    /// frame and source frame. There's nothing to pre-roll or confirm, so the soonest it can
    /// come out is the next block, plus the fade when the attack has to be whole.
    private func land(from seconds: Double, quantizedCue: Bool, continuing: Bool,
                      barShift: Double?, loopShift: Double?) {
        serviceTransitions()
        partner?.syncEngine()
        let now = audioNow()
        // A start that hasn't come out yet isn't music playing: a press on top of it starts afresh.
        let starting = startDueAt.map { now < $0 } ?? false
        let replace = playing && hasStreamingVoice && !starting
        // The playhead just carries on, and the loop was set when it was committed or cleared.
        if replace, continuing, barShift == nil, (loopShift ?? 0) == 0 {
            scheduleLoopClock(at: now, bounds: loopBounds)
            return
        }
        // A press from stopped comes in whole too, with the fade over the audio before it.
        let wholeAttack = quantizedCue || !replace
        var outputTime = link.core.soonest(after: now) + (wholeAttack ? fadeDuration : 0)
        var cueSourceOffset = 0.0
        var timedToPartner = false
        if quantizedCue {
            let preparation = outputTime - now
            if replace, let grid, (40...300).contains(grid.bpm) {
                var timing = MixMath.hotCueTiming(position: positionAt(now), cue: seconds, rate: playRate, grid: grid, preparation: preparation)
                // A beat already gone is joined well past its attack, never a few milliseconds
                // into it: that would be a clipped click.
                if timing.sourceOffset > 0 {
                    timing = MixMath.hotCueTiming(position: positionAt(now), cue: seconds, rate: playRate, grid: grid, preparation: max(preparation, Self.joinLead))
                }
                outputTime = now + timing.delay
                cueSourceOffset = timing.sourceOffset
            } else if grid != nil, let source = partner, source.playing, !source.jog.active, !source.previewing,
                      let referenceGrid = source.grid, (40...300).contains(referenceGrid.bpm) {
                var timing = MixMath.cueLaunchTiming(position: source.positionAt(now), referenceRate: source.playRate,
                                                     referenceGrid: referenceGrid, cueRate: playRate, preparation: preparation)
                if timing.sourceOffset > 0 {
                    timing = MixMath.cueLaunchTiming(position: source.positionAt(now), referenceRate: source.playRate,
                                                     referenceGrid: referenceGrid, cueRate: playRate, preparation: max(preparation, Self.joinLead))
                }
                outputTime = now + timing.delay
                cueSourceOffset = timing.sourceOffset
                timedToPartner = true
            }
        }
        var requested = continuing ? positionAt(outputTime) : seconds + cueSourceOffset
        if let barShift, let grid {
            let origin = clock.position(at: outputTime)
            let wanted = (barShift / (grid.beatSeconds * 4)).rounded()
            if wanted.isFinite, abs(wanted) < Double(Int.max),
               let plan = BarJump.plan(grid: grid, position: origin, duration: duration, playing: true, bars: Int(wanted)) {
                requested = plan.position
            } else { requested = origin }
        } else if let loopShift, let loop = loopAudio, let previous = boundsAt(outputTime) {
            requested = previous.contains(requested) && loopShift == 0 ? loop.folding(requested) : requested + loopShift
        }
        var target = requested
        if let loop = loopAudio, target >= loop.end {
            target = loop.start + (target - loop.start).truncatingRemainder(dividingBy: loop.end - loop.start)
        }
        target = min(duration, max(0, target))
        var jump = DexJump()
        jump.position = target * link.fileRate
        jump.atFrame = link.core.frame(at: outputTime)
        jump.fadeEndsAtLanding = wholeAttack
        jump.alignToMaster = !quantizedCue && barShift == nil && loopShift == nil && syncLocked && !isMaster
        // A late start or plain seek waits and then starts where it was asked. Anything keeping
        // the beat count (a quantized cue, a bar jump, a loop, the other deck) slides on instead.
        let plainSeek = !quantizedCue && barShift == nil && loopShift == nil && !continuing
        jump.late = (plainSeek || !replace) && !timedToPartner && !jump.alignToMaster ? DEX_LATE_HOLD : DEX_LATE_SLIDE
        if loopShift != nil {
            jump.setLoop = true
            jump.loopActive = loopBounds != nil
            jump.loopIn = (loopBounds?.lowerBound ?? 0) * link.fileRate
            jump.loopOut = (loopBounds?.upperBound ?? 0) * link.fileRate
        }
        transportAt = outputTime
        position = replace ? min(duration, max(0, heardAt(now - outputDelay))) : target
        clock.schedule(at: outputTime, rate: playRate, position: target)
        scheduleLoopClock(at: outputTime, bounds: loopBounds)
        link.expectLanding(at: outputTime)
        endHeardAt = nil
        startDueAt = replace ? nil : outputTime
        hasStreamingVoice = true
        playing = true
        link.play(jump)
    }

    /// What will be heard this many seconds from now. It only reads, so a display
    /// can ask once a frame for the time of the frame it is drawing.
    public func heardPosition(ahead: Double) -> Double {
        min(duration, max(0, heardAt(audioNow() + ahead - outputDelay)))
    }

    public func refreshPosition() {
        serviceTransitions()
        guard playing else { return }
        position = min(duration, max(0, heardAt(audioNow() - outputDelay)))
    }

    func cancelOptionalWork(resumeJog: Bool = true) {
        cancelJog(resume: resumeJog)
        loadTask?.cancel(); loadGeneration = UUID(); loadTask = nil; loading = false
    }
    /// Freeze from the last rendered timestamp, not elapsed wall time while an
    /// output is stopped. Held previews return to their cue and never auto-resume.
    func suspendPlayback(at renderedTime: Double?) -> Bool {
        let jogPosition = jog.active ? (jog.renderedPosition ?? jog.position) : nil
        let resume = playing && !previewing
        if previewing { position = cuePoint }
        else if playing { position = min(duration, max(0, heardAt((renderedTime ?? audioNow()) - outputDelay))) }
        cancelOptionalWork(resumeJog: false)
        if let jogPosition { position = jogPosition }
        stopVoices()
        link.hardStop(at: position)
        playing = false; previewing = false; cueHeld = false; audioAvailable = false
        clock.reset(at: audioNow(), position: position)
        scheduleLoopClock(at: audioNow(), bounds: loopBounds)
        return resume
    }
    func reanchor() {
        clock.reset(at: audioNow(), position: position)
        scheduleLoopClock(at: audioNow(), bounds: loopBounds)
    }
    /// Everything the engine holds outlives a new graph; only a gesture in progress ends.
    func rebuildNodes() { jog.cancel() }
    func shutdown() {
        cancelJog(resume: false)
        clearLoop()
        previewing = false
        cueHeld = false
        loadGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        stopVoices()
        link.unload()
        playing = false
        file = nil
        waveform = nil; peaks = []
        libraryTrackID = nil
        autoTrimDB = nil
        tags = .none
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
    private func updateTempo() {
        cancelJog()
        let wanted = min(1.16, max(0.84, tempo))
        playRate = wanted
        link.setTempo(wanted)
        link.setKeyLock(keyLock)
        if playing { clock.schedule(at: max(audioNow(), transportAt), rate: playRate) }
        if isMaster { partner?.followMasterTempo() }
    }
    private func updateGain() { dex_engine_set_fader(link.engine, link.index, level, crossfadeGain) }
    enum PlaybackError: LocalizedError {
        case unsupportedChannels, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupportedChannels: "Only mono and stereo files are supported in this checkpoint."
            case .unreadable: "Part of this track's audio could not be read. Check the file or drive, then load the track again."
            }
        }
    }
}
