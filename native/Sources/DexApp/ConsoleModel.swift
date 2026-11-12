import SwiftUI
import Combine
import DexAudio
import DexConsole
import DexCore
import UniformTypeIdentifiers

/// Bridges the engine and the console. It builds `ConsoleState` from the
/// mixer, decks and library, moves the playheads on the console clock, and
/// turns console actions into engine calls. Console-only settings live here:
/// the zoom, the open sheets and popovers, the library row picked, and the
/// fader positions behind the engine's dB.
@MainActor
final class ConsoleModel: ObservableObject {
    @Published private(set) var state = ConsoleState()
    let clock = ConsoleClock()
    let mixer: NativeMixer
    let library: NativeLibrary
    private(set) var actions = ConsoleActions()

    /// ADD FILES or ADD FOLDER is choosing what to import. `pick` outlives
    /// the picker, whose dismissal may clear `picking` before it reports.
    @Published var picking: Pick? { didSet { if let picking { pick = picking } } }
    private(set) var pick = Pick.files
    enum Pick { case files, folder }

    private struct Faders { var level = 1.0; var eq = ConsoleState.Bands() }
    private var faders = ["A": Faders(), "B": Faders()]
    private var spanSec = 12.0
    private var linkLows = false
    private var energyEnabled = false
    private var hotCuesOpen: Set<String> = []
    private var hotCuesDeleting: Set<String> = []
    private var volumeOpen = false
    private var libraryOpen = false
    private var more: ConsoleState.More?
    private var justMade: String?
    private var selected: String?
    private var sheet: ConsoleState.Sheet?
    private var help: ConsoleState.HelpTopic?
    private var mixPop: ConsoleState.MixPop?
    private var gridDeck: String?
    private var drop: ConsoleState.Drop?
    /// The alert the user put away, until another is raised, with the same words or not.
    private var dismissed: Problem?
    /// The alert the seven-second timer is running for.
    private var timed: Problem?
    private var alertTimer: Task<Void, Never>?
    /// The library's rows, kept so that only a change to the library remakes them.
    private var rows = LibraryRows()
    private var changes: Set<AnyCancellable> = []
    private var rebuildQueued = false
    private var ticker: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var active = true

    init(mixer: NativeMixer, library: NativeLibrary) {
        self.mixer = mixer; self.library = library
        for deck in decks { applyFaders(deck); deck.trimsOnLoad = true }
        Publishers.MergeMany(mixer.objectWillChange, mixer.a.objectWillChange, mixer.b.objectWillChange, library.objectWillChange)
            .sink { [weak self] _ in self?.queueRebuild() }
            .store(in: &changes)
        for deck in decks {
            deck.playhead.$seconds.combineLatest(deck.jog.$position)
                .sink { [weak self] seconds, jog in
                    guard let self else { return }
                    let position = jog ?? seconds
                    clock.deck(deck.label).position = position
                    clock.lane(deck.label).set(position, publish: !deck.playing)
                }
                .store(in: &changes)
            clock.lane(deck.label).heard = { [weak deck] ahead in
                guard let deck, deck.playing else { return nil }
                return deck.heardPosition(ahead: ahead)
            }
        }
        actions = makeActions()
        rebuild()
    }

    private var decks: [NativeDeck] { [mixer.a, mixer.b] }
    private func deck(_ id: String) -> NativeDeck { id == "B" ? mixer.b : mixer.a }

    /// The display clock only runs while the scene is active.
    func setActive(_ value: Bool) {
        active = value
        updateTicker()
        updateMeters()
    }

    // MARK: State

    /// `objectWillChange` fires before the change lands, so the rebuild waits a turn.
    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rebuildQueued = false
            rebuild()
        }
    }

    private func rebuild() {
        rows.follow(library.tracks) { library.coverURL($0) }
        var next = ConsoleState(decks: decks.map(deckState), masterDeck: mixer.a.isMaster ? 0 : mixer.b.isMaster ? 1 : -1,
                                splitCue: mixer.splitCue, energyEnabled: energyEnabled, volumeOpen: volumeOpen,
                                status: status, saveState: library.saveFailed ? .error : library.saving ? .saving : .saved)
        next.spanSec = spanSec
        next.crossfader = mixer.crossfader
        next.linkLows = linkLows
        next.masterVolume = Double(mixer.volume)
        next.cueMix = mixer.cueMix
        next.sheet = sheet
        next.help = help
        next.mixPop = mixPop
        next.gridDeck = gridDeck
        next.libraryOpen = libraryOpen
        next.more = more
        next.library = libraryState
        next.tap = ConsoleState.Tap(status: .error, error: "TAP needs audio input, which the native app does not read yet.")
        next.alert = alert
        next.drop = drop
        let shown = shownProblem
        if shown != timed { timed = shown; timeAlert(shown) }
        if next != state { state = next }
        updateTicker()
        updateMeters()
    }

    /// One raising of a problem: where it came from and which time this is, not just its words.
    private struct Problem: Equatable {
        let title: String, message: String
        let source: Int
        let revision: UInt64
    }

    /// The first problem the engine or library reports.
    private var problem: Problem? {
        let sources: [(String, String?, UInt64)] = [
            ("NO AUDIO", mixer.error, mixer.errorRevision),
            ("DECK A", mixer.a.error, mixer.a.errorRevision), ("DECK B", mixer.b.error, mixer.b.errorRevision),
            ("LIBRARY", library.error, library.errorRevision),
            ("AUDIO", mixer.notice, mixer.noticeRevision), ("LIBRARY", library.notice, library.noticeRevision)]
        for (index, source) in sources.enumerated() {
            if let message = source.1 { return Problem(title: source.0, message: message, source: index, revision: source.2) }
        }
        return nil
    }
    /// That problem, until put away.
    private var shownProblem: Problem? { problem.flatMap { $0 == dismissed ? nil : $0 } }
    private var alert: ConsoleState.Alert? { shownProblem.map { ConsoleState.Alert(title: $0.title, message: $0.message) } }

    private func dismissAlert() {
        dismissed = problem
        queueRebuild()
    }

    /// Alerts put themselves away after seven seconds, as in the Electron app. One raised again
    /// while it shows gets its seven seconds again.
    private func timeAlert(_ problem: Problem?) {
        alertTimer?.cancel()
        guard let problem else { return }
        alertTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let self, shownProblem == problem else { return }
            dismissAlert()
        }
    }

    private var libraryState: ConsoleState.Library {
        var state = ConsoleState.Library(tracks: rows.rows, playlists: library.playlists.map {
            ConsoleState.Library.Playlist(id: $0.id, name: $0.name, trackIDs: $0.trackIDs)
        }, selected: selected, busy: library.importing || library.findingKeys != nil || library.analysing != nil)
        state.pendingImports = library.pendingImports.map { pending in
            let id = pending.id.uuidString
            return ConsoleState.Library.PendingImport(id: id, title: pending.title, label: pending.progress.label,
                                                      fraction: pending.progress.fraction, art: placeholderArt(id))
        }
        state.justMade = justMade
        return state
    }

    private func deckState(_ deck: NativeDeck) -> ConsoleState.Deck {
        let id = deck.label, loaded = deck.duration > 0
        let grid = deck.grid.map { ConsoleState.Grid(bpm: $0.bpm, offsetMs: $0.offsetMs, confidence: $0.confidence) }
        let track = rows.track(deck.libraryTrackID)
        let names = trackNames(deck, track)
        let loop = deck.grid.flatMap { grid in
            deck.loopBounds.map { ConsoleState.Loop(startBeat: grid.beat(at: $0.lowerBound).rounded(), lengthBeats: deck.loopBeats) }
        }
        var state = ConsoleState.Deck(
            id: id, trackID: loaded ? deck.libraryTrackID?.uuidString ?? deck.name : nil, loading: deck.loading,
            playing: deck.playing, syncLocked: deck.syncLocked, grid: grid, durationSec: deck.duration,
            position: clock.deck(id).position ?? deck.playhead.seconds, cuePoint: deck.cuePoint, loop: loop,
            wave: deck.waveform.map { .track($0.data) }, title: names.title, artist: names.artist,
            art: loaded ? cover(deck) : nil, rate: deck.tempo, keyLock: deck.keyLock,
            camelot: loaded ? track?.key?.camelot : nil, hotCues: deck.hotCues)
        state.previewing = deck.previewing
        state.eq = faders[id]!.eq
        state.kills = ConsoleState.Kills(low: deck.kills.low, mid: deck.kills.mid, high: deck.kills.high)
        state.level = faders[id]!.level
        state.trimDb = Double(deck.trimDB)
        state.autoTrimDb = deck.autoTrimDB.map(Double.init)
        state.filter = deck.filter
        state.headphoneCue = deck.headphoneCue
        state.loopBeats = deck.loopBeats
        state.jumpBars = deck.jumpBars
        state.hotCuesOpen = hotCuesOpen.contains(id)
        state.hotCueDeleting = hotCuesDeleting.contains(id)
        return state
    }

    private var status: ConsoleState.LibraryStatus? {
        if library.importing { return ConsoleState.LibraryStatus(label: "IMPORTING") }
        if let keys = library.findingKeys {
            return ConsoleState.LibraryStatus(label: "FINDING KEYS", current: keys.current, total: keys.total, name: keys.title)
        }
        if let analysing = library.analysing { return ConsoleState.LibraryStatus(label: "ANALYSING", name: analysing) }
        if decks.contains(where: \.loading) { return ConsoleState.LibraryStatus(label: "ANALYSING") }
        return nil
    }

    /// Readouts at the Electron app's 30 Hz, the meter at half that. The zoom
    /// lanes follow the display instead, through `ConsoleClock.frame`.
    private func updateTicker() {
        let running = active && decks.contains(where: \.playing)
        clock.running = running
        if running, ticker == nil {
            ticker = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    mixer.a.refreshPosition(); mixer.b.refreshPosition()
                    tick += 1
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
        } else if !running, let ticker {
            ticker.cancel()
            self.ticker = nil
        }
    }

    /// The four meters, read every display frame (about 60 Hz) while anything shows, and ten
    /// times a second when all is quiet. The engine holds peaks until they're read, so a slow
    /// read misses nothing; nil hands the strip back to the silent state.
    private func updateMeters() {
        if active, meterTask == nil {
            meterTask = Task { [weak self] in
                var ballistics = MeterBallistics()
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let read = mixer.readMeters()
                    ballistics.update(MeterLevels(a: read.a, l: read.l, r: read.r, b: read.b), dt: now - last, now: now)
                    last = now
                    let quiet = ballistics.meters == .silent
                    let shown: Meters? = quiet ? nil : ballistics.meters
                    if clock.meter.meters != shown { clock.meter.meters = shown }
                    do { try await Task.sleep(for: .milliseconds(quiet ? 100 : 16)) } catch { return }
                }
            }
        } else if !active, let meterTask {
            meterTask.cancel()
            self.meterTask = nil
            clock.meter.meters = nil
        }
    }

    // MARK: Faders

    /// The engine takes dB; the console's positions follow the fader law.
    private func applyFaders(_ deck: NativeDeck) {
        let f = faders[deck.label]!
        deck.level = Float(FaderLaw.gain(f.level))
        deck.lowDB = Float(max(-96, FaderLaw.db(f.eq.low)))
        deck.midDB = Float(max(-96, FaderLaw.db(f.eq.mid)))
        deck.highDB = Float(max(-96, FaderLaw.db(f.eq.high)))
    }

    private func setFader(_ id: String, _ param: String, _ value: Double) {
        let value = min(1, max(0, value))
        var f = faders[id]!
        switch param {
        case "level": f.level = value
        case "high": f.eq.high = value
        case "mid": f.eq.mid = value
        case "low":
            if linkLows {
                let other = id == "A" ? "B" : "A"
                faders[other]!.eq.low = FaderLaw.linkedLow(faders[other]!.eq.low, delta: value - f.eq.low)
                applyFaders(deck(other))
            }
            f.eq.low = value
        default: return
        }
        faders[id] = f
        applyFaders(deck(id))
        queueRebuild()
    }

    private func setKill(_ id: String, _ band: String, _ on: Bool) {
        let deck = deck(id)
        switch band {
        case "low": deck.kills.low = on
        case "mid": deck.kills.mid = on
        case "high": deck.kills.high = on
        default: return
        }
    }

    // MARK: Actions

    private func makeActions() -> ConsoleActions {
        var actions = ConsoleActions()
        actions.setEnergy = { [weak self] in self?.energyEnabled = $0; self?.queueRebuild() }
        actions.toggleVolume = { [weak self] in self?.update {
            $0.volumeOpen.toggle()
            if $0.volumeOpen { $0.mixPop = nil }
        } }
        actions.setSheet = { [weak self] sheet in self?.update { $0.sheet = sheet } }
        actions.setHelp = { [weak self] topic in self?.update { $0.help = topic } }
        actions.setMixPop = { [weak self] pop in self?.setMixerPopover(pop) }
        actions.dismissAlert = { [weak self] in self?.dismissAlert() }
        actions.setMasterVolume = { [weak self] in self?.mixer.volume = Float(min(1, max(0, $0))) }
        actions.setCueMix = { [weak self] in self?.mixer.cueMix = min(1, max(0, $0)) }
        actions.closeGrid = { [weak self] in self?.update { $0.gridDeck = nil; $0.help = nil } }
        actions.gridWave = { [weak self] id, start, perColumn, columns in
            guard let url = self?.deck(id).fileURL else { return nil }
            let read = Task.detached(priority: .userInitiated) {
                try GridWaveReader.read(url: url, start: start, perColumn: perColumn, columns: columns)
            }
            return await withTaskCancellationHandler { try? await read.value } onCancel: { read.cancel() }
        }
        actions.setGrid = { [weak self] id, grid, _ in
            // Taking another reading leaves the readings list as the analysis made it.
            self?.deck(id).setGrid(bpm: grid.bpm, offsetMs: grid.offsetMs)
        }
        actions.setDrop = { [weak self] drop in self?.update { $0.drop = drop } }
        actions.dropFiles = { [weak self] id, urls in self?.dropFiles(id, urls) }
        actions.dropTrack = { [weak self] id, track in
            guard let self, let uuid = UUID(uuidString: track) else { return }
            deck(id).loadTrack(uuid)
        }
        actions.toggleSplitCue = { [weak self] in self?.mixer.splitCue.toggle() }
        actions.retrySave = { [weak self] in self?.library.retrySave() }
        actions.openGrid = { [weak self] id in
            guard let self, deck(id).duration > 0 else { return }
            update { $0.gridDeck = id; $0.libraryOpen = false }
        }
        actions.setSpan = { [weak self] in self?.spanSec = min(48, max(3, $0)); self?.queueRebuild() }
        actions.tapArt = { [weak self] in self?.tapArt($0) }
        actions.toggleLinkLows = { [weak self] in self?.linkLows.toggle(); self?.queueRebuild() }
        actions.openTrim = { [weak self] id in self?.setMixerPopover(.trim(id)) }
        actions.openBand = { [weak self] band in self?.setMixerPopover(.band(band)) }
        actions.library = libraryActions()
        actions.setCrossfader = { [weak self] in self?.mixer.crossfader = min(1, max(0, $0)) }

        var deckActions = DeckActions()
        deckActions.toggleSync = { [weak self] in self?.deck($0).toggleSync() }
        deckActions.setMaster = { [weak self] id in
            guard let self else { return }
            mixer.setMaster(self.deck(id))
        }
        deckActions.toggleKeyLock = { [weak self] in self?.deck($0).keyLock.toggle() }
        deckActions.toggleHotCues = { [weak self] id in
            self?.update { model in
                if model.hotCuesOpen.remove(id) == nil { model.hotCuesOpen.insert(id) } else { model.hotCuesDeleting.remove(id) }
            }
        }
        deckActions.setHotCueDelete = { [weak self] id, on in
            self?.update { if on { $0.hotCuesDeleting.insert(id) } else { $0.hotCuesDeleting.remove(id) } }
        }
        deckActions.hotCue = { [weak self] in self?.hotCue($0, $1) }
        deckActions.setTrim = { [weak self] in self?.setTrim($0, $1) }
        deckActions.cueDown = { [weak self] in self?.deck($0).cueDown() }
        deckActions.cueUp = { [weak self] in self?.deck($0).cueUp() }
        deckActions.continueCue = { [weak self] id in
            // PLAY during a preview keeps the running schedule.
            guard let deck = self?.deck(id), deck.previewing else { return false }
            deck.togglePlay()
            return true
        }
        deckActions.togglePlay = { [weak self] in self?.deck($0).togglePlay() }
        deckActions.beatJump = { [weak self] in self?.deck($0).jump(direction: $1) }
        deckActions.setJumpBars = { [weak self] in self?.deck($0).jumpBars = $1 }
        deckActions.stepLoop = { [weak self] id, direction in
            guard let deck = self?.deck(id) else { return }
            deck.setLoopBeats(direction < 0 ? max(1, deck.loopBeats / 2) : min(64, deck.loopBeats * 2))
        }
        deckActions.toggleLoop = { [weak self] in self?.deck($0).toggleLoop() }
        deckActions.toggleHeadphoneCue = { [weak self] in self?.deck($0).headphoneCue.toggle() }
        deckActions.setKill = { [weak self] in self?.setKill($0, $1, $2) }
        deckActions.setTempo = { [weak self] id, rate in
            guard let deck = self?.deck(id), !(deck.syncLocked && !deck.isMaster) else { return }
            deck.tempo = min(1.16, max(0.84, rate))
        }
        deckActions.setFader = { [weak self] in self?.setFader($0, $1, $2) }
        deckActions.setFilter = { [weak self] in self?.deck($0).filter = min(1, max(-1, $1)) }
        deckActions.scrub = { [weak self] id, scrub in
            guard let deck = self?.deck(id) else { return }
            switch scrub {
            case .begin: deck.beginJog()
            case .move(let seconds): deck.jog.move(displacement: seconds)
            case .end: deck.jog.release(velocity: 0)
            // An agreed improvement on Electron, whose scrub stops where the finger lifts.
            case .fling(let span): deck.jog.release(span: span)
            case .cancel: deck.cancelJog()
            }
        }
        deckActions.coasting = { [weak self] in self?.deck($0).jog.coasting ?? false }
        deckActions.seek = { [weak self] in self?.deck($0).seek(to: $1) }
        actions.deck = deckActions
        return actions
    }

    private func libraryActions() -> LibraryActions {
        var actions = LibraryActions()
        actions.setOpen = { [weak self] open in
            self?.update { $0.libraryOpen = open; if open { $0.gridDeck = nil } else { $0.more = nil } }
        }
        actions.setMore = { [weak self] more in self?.update { $0.more = more } }
        actions.reanalyze = { [weak self] id in self?.reanalyze(id) }
        actions.remove = { [weak self] id in self?.remove(id) }
        actions.newPlaylist = { [weak self] track in
            guard let self, let uuid = UUID(uuidString: track) else { return }
            let id = library.createPlaylist()
            library.addToPlaylist(id, tracks: [uuid])
            update { $0.more = nil; $0.justMade = id }
        }
        actions.select = { [weak self] id in self?.update { $0.selected = id } }
        actions.addFiles = { [weak self] in self?.picking = .files }
        actions.addFolder = { [weak self] in self?.picking = .folder }
        actions.findKeys = { [weak self] in
            guard let library = self?.library else { return }
            Task { await library.findKeys() }
        }
        actions.createPlaylist = { [weak self] in self?.library.createPlaylist() ?? "" }
        actions.addToPlaylist = { [weak self] playlist, track in
            guard let uuid = UUID(uuidString: track) else { return }
            self?.library.addToPlaylist(playlist, tracks: [uuid])
        }
        actions.removeFromPlaylist = { [weak self] playlist, track in
            guard let uuid = UUID(uuidString: track) else { return }
            self?.library.removeFromPlaylist(playlist, track: uuid)
        }
        actions.renamePlaylist = { [weak self] in self?.library.renamePlaylist($0, to: $1) }
        actions.deletePlaylist = { [weak self] in self?.library.deletePlaylist($0) }
        return actions
    }

    /// Decks holding the track take its new grid.
    private func reanalyze(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        Task { [weak self] in
            guard let self, let track = await library.reanalyze(uuid) else { return }
            for deck in decks { deck.follow(reanalysed: track) }
        }
    }

    /// A deck holding the track reopens its file by path after an audio route
    /// change, so the file can't go while it is loaded.
    private func remove(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        if let holder = decks.first(where: { $0.libraryTrackID == uuid }) {
            library.report("Deck \(holder.label) holds this track. Load another track there, then remove it.")
            return
        }
        if selected == id { selected = nil }
        Task { await library.remove(uuid) }
    }

    /// A change to the console's own settings, then one redraw.
    private func setMixerPopover(_ pop: ConsoleState.MixPop?) {
        update {
            $0.mixPop = pop
            if pop != nil { $0.volumeOpen = false }
        }
    }

    private func update(_ change: (ConsoleModel) -> Void) {
        change(self)
        queueRebuild()
    }

    /// The cover: with a library row picked, load it here and put the library
    /// away; otherwise open or close the library.
    private func tapArt(_ id: String) {
        let deck = deck(id)
        if libraryOpen, let selected, let track = UUID(uuidString: selected) {
            guard !deck.playing, deck.libraryTrackID != track else { return }
            deck.loadTrack(track)
            update { $0.libraryOpen = false }
        } else {
            update { $0.libraryOpen.toggle() }
        }
    }

    /// An empty pad captures the playhead, a set pad jumps; with DELETE armed
    /// a set pad is cleared, and DELETE disarms once nothing is left.
    private func hotCue(_ id: String, _ slot: Int) {
        let deck = deck(id)
        guard deck.hotCues.indices.contains(slot) else { return }
        if deck.hotCues[slot] != nil, hotCuesDeleting.contains(id) {
            deck.hotCue(slot, clear: true)
            if deck.hotCues.allSatisfy({ $0 == nil }) { update { $0.hotCuesDeleting.remove(id) } }
            return
        }
        guard deck.duration > 0 else { return }
        deck.hotCue(slot)
    }

    /// Dropped files are imported; the last one loads on the deck.
    private func dropFiles(_ id: String, _ urls: [URL]) {
        guard let last = urls.last else { return }
        let deck = deck(id)
        Task { [library] in
            if urls.count > 1 { await library.importFiles(Array(urls.dropLast())) }
            deck.load(last)
        }
    }

    /// ADD FOLDER: every audio file in the folder and the folders under it.
    func importFolder(_ folder: URL) {
        Task { [library] in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let files = await Task.detached(priority: .userInitiated) {
                let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey])
                return (contents?.allObjects as? [URL] ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .audio)) == true }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }.value
            await library.importFiles(files)
        }
    }

    /// TRIM: ±12 dB in 0.1 dB steps, snapping to AUTO (or 0 before the track is
    /// measured) within 0.25. The library remembers it for the track; AUTO forgets it.
    func setTrim(_ id: String, _ db: Double) {
        let deck = deck(id), auto = deck.autoTrimDB.map(Double.init) ?? 0
        let value = (min(12, max(-12, db)) * 10).rounded() / 10
        let snapped = abs(value - auto) < 0.25 ? auto : value
        deck.trimDB = Float(snapped)
        // Saved once the trim rests, not on every move of a drag.
        trimSaves[id]?.cancel()
        guard let track = deck.libraryTrackID else { return }
        // Decide nil against AUTO now, not when the save fires: the deck may hold
        // another track by then, and its AUTO would answer for this one.
        let forgetsAuto = deck.autoTrimDB == nil && snapped == 0
        trimSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            library.setTrim(track, forgetsAuto ? nil : snapped)
        }
    }
    private var trimSaves: [String: Task<Void, Never>] = [:]

    /// One wrapper per decoded cover, so the state compares it by identity.
    private var covers: [String: (image: CGImage, cover: ConsoleState.Cover)] = [:]

    /// The tags' cover, or the placeholder: two colours from the track id.
    private func cover(_ deck: NativeDeck) -> ConsoleState.Art {
        guard let image = deck.tags.cover else {
            covers[deck.label] = nil
            return placeholderArt(deck.libraryTrackID?.uuidString ?? deck.name)
        }
        if let held = covers[deck.label], held.image === image { return .cover(held.cover) }
        let cover = ConsoleState.Cover(image)
        covers[deck.label] = (image, cover)
        return .cover(cover)
    }
}

/// The library's tracks as the console's rows. Making a row costs a regular expression and a
/// date format, and the model rebuilds on every fader move, so a row is made once and kept
/// until its track changes.
struct LibraryRows {
    private(set) var rows: [ConsoleState.Library.Track] = []
    /// The tracks `rows` were made from, in the library's order.
    private var tracks: [LibraryTrack] = []
    /// Each track's row, and where the first track with that id sits in `tracks`.
    private var made: [UUID: (track: LibraryTrack, row: ConsoleState.Library.Track, index: Int)] = [:]
    /// The release date is written in the user's language, so a change of locale remakes every row.
    private var locale = Locale.current

    /// Takes the library as it now is. Nothing is done while it is as it was; otherwise only
    /// the tracks that changed get new rows, and rows of tracks that have gone are dropped.
    mutating func follow(_ next: [LibraryTrack], coverURL: (LibraryTrack) -> URL?) {
        let current = Locale.current
        if current != locale { locale = current; tracks = []; rows = []; made = [:] }
        guard next != tracks else { return }
        var kept: [UUID: (track: LibraryTrack, row: ConsoleState.Library.Track, index: Int)] = [:]
        kept.reserveCapacity(next.count)
        var remade: [ConsoleState.Library.Track] = []
        remade.reserveCapacity(next.count)
        for (index, track) in next.enumerated() {
            let row = if let held = made[track.id], held.track == track { held.row } else { Self.row(track, coverURL: coverURL(track)) }
            remade.append(row)
            if kept[track.id] == nil { kept[track.id] = (track, row, index) }
        }
        tracks = next; rows = remade; made = kept
    }

    /// The library's track with this id, without walking the library.
    func track(_ id: UUID?) -> LibraryTrack? {
        guard let id, let index = made[id]?.index else { return nil }
        return tracks[index]
    }

    static func row(_ track: LibraryTrack, coverURL: URL?) -> ConsoleState.Library.Track {
        let names = track.tagTitle.map { (artist: track.artist ?? "", title: $0) } ?? splitName(track.title)
        var row = ConsoleState.Library.Track(
            id: track.id.uuidString, name: displayName(track), key: track.key?.name, camelot: track.key?.camelot,
            keyChecked: track.key != nil, bpm: track.grid?.bpm ?? 0,
            durationSec: track.duration, confidence: track.grid?.confidence ?? 0, gridUncertain: track.gridUncertain,
            alternates: track.alternatives.map { ConsoleState.Library.Alternate(bpm: $0.bpm, offsetMs: $0.offsetMs, relation: $0.relation) },
            title: names.title, artist: names.artist)
        row.album = track.details?.album ?? ""
        row.genre = track.details?.genre ?? ""
        row.subgenre = track.details?.subgenre ?? ""
        row.remixer = track.details?.remixer ?? ""
        row.release = track.details?.release.map { Tags.releaseText($0) } ?? ""
        row.art = placeholderArt(track.id.uuidString)
        row.coverURL = coverURL
        return row
    }
}

/// "Artist — Title" from the tags, or the file name split the same way, as
/// `trackNames` in Band.tsx. The library's names win; a file loaded from
/// outside it has only the tags just read.
@MainActor func trackNames(_ deck: NativeDeck, _ track: LibraryTrack?) -> (artist: String, title: String) {
    if let title = track?.tagTitle { return (track?.artist ?? "", title) }
    if track == nil, let title = deck.tags.title { return (deck.tags.artist ?? "", title) }
    return splitName(track?.title ?? deck.name)
}

/// `placeholderArt` in Band.tsx: `hsl(hue 50% 32%)` over `hsl(hue + 150 55% 52%)`.
func placeholderArt(_ seed: String) -> ConsoleState.Art {
    var hash: UInt32 = 0
    for unit in seed.utf16 { hash = hash &* 31 &+ UInt32(unit) }
    let hue = Double(hash % 360)
    return .split(hsl(hue, 0.5, 0.32), hsl((hue + 150).truncatingRemainder(dividingBy: 360), 0.55, 0.52))
}

/// CSS Color 4's `hslToRgb`, rounded to 8-bit channels.
func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> UInt32 {
    func channel(_ n: Double) -> UInt32 {
        let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
        let a = saturation * min(lightness, 1 - lightness)
        let value = lightness - a * max(-1, min(k - 3, 9 - k, 1))
        return UInt32((value * 255).rounded())
    }
    return channel(0) << 16 | channel(8) << 8 | channel(4)
}

/// "Artist — Title" from a file name like "Artist - Title", as `displayName` in drop.ts.
func splitName(_ name: String) -> (artist: String, title: String) {
    guard let match = name.range(of: #"^(.+?)\s+[-–—]\s+(.+)$"#, options: .regularExpression) else { return ("", name) }
    let text = String(name[match])
    guard let dash = text.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) else { return ("", name) }
    return (String(text[..<dash.lowerBound]), String(text[dash.upperBound...]))
}

/// A library row's name: `displayName` in drop.ts.
func displayName(_ track: LibraryTrack) -> String {
    if let title = track.tagTitle { return track.artist.map { "\($0) — \(title)" } ?? title }
    return displayName(track.title)
}

func displayName(_ name: String) -> String {
    let parts = splitName(name)
    return parts.artist.isEmpty ? parts.title : "\(parts.artist) — \(parts.title)"
}
