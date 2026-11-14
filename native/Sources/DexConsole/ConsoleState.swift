import Foundation
import CoreGraphics
import DexCore

/// Everything the console draws, as plain values. The app fills it from the
/// mixer; snapshots and previews use the demo states, which mirror the
/// Electron renderer's `?demo=mockup` screens so the two can be diffed.
public struct ConsoleState: Equatable, Sendable {
    public struct Grid: Equatable, Sendable {
        public var bpm: Double
        public var offsetMs: Double
        public var confidence: Double
        public init(bpm: Double, offsetMs: Double, confidence: Double = 1) {
            self.bpm = bpm; self.offsetMs = offsetMs; self.confidence = confidence
        }
        var period: Double { 60 / bpm }
        func time(atBeat beat: Double) -> Double { offsetMs / 1000 + beat * period }
    }
    public struct Loop: Equatable, Sendable {
        public var startBeat: Double
        public var lengthBeats: Double
        public init(startBeat: Double, lengthBeats: Double) { self.startBeat = startBeat; self.lengthBeats = lengthBeats }
    }
    /// Cover art: the track's own, or a two-colour placeholder.
    public enum Art: Equatable, Sendable {
        /// `linear-gradient(135deg, first 0 55%, second 55% 100%)`.
        case split(UInt32, UInt32)
        /// The picture from the file's tags, drawn `center / cover`.
        case cover(Cover)
    }
    /// A decoded cover, compared by identity so a state rebuild costs nothing.
    public final class Cover: Equatable, @unchecked Sendable {
        public let image: CGImage
        public init(_ image: CGImage) { self.image = image }
        public static func == (lhs: Cover, rhs: Cover) -> Bool { lhs === rhs }
    }
    /// The waveform a lane or overview draws.
    public enum Wave: Equatable, Sendable {
        /// The mockup's synthetic waveform (`waveSvg` in demo.tsx), by seed.
        case demo(seed: Int)
        /// A decoded track's level pyramid.
        case track(WaveformData)

        public static func == (lhs: Wave, rhs: Wave) -> Bool {
            switch (lhs, rhs) {
            case let (.demo(a), .demo(b)): a == b
            case let (.track(a), .track(b)): a.id == b.id
            default: false
            }
        }
    }
    /// The cut-only EQ's three bands, 0 (foot) … 1 (top, unity).
    public struct Bands: Equatable, Sendable {
        public var low, mid, high: Double
        public init(low: Double = 1, mid: Double = 1, high: Double = 1) { self.low = low; self.mid = mid; self.high = high }
    }
    public struct Kills: Equatable, Sendable {
        public var low, mid, high: Bool
        public init(low: Bool = false, mid: Bool = false, high: Bool = false) { self.low = low; self.mid = mid; self.high = high }
    }
    public struct Deck: Equatable, Sendable {
        public var id: String
        /// The library track loaded, if any.
        public var trackID: String?
        public var loading: Bool
        public var playing: Bool
        public var syncLocked: Bool
        public var grid: Grid?
        public var durationSec: Double
        public var position: Double
        public var cuePoint: Double
        public var loop: Loop?
        public var wave: Wave?
        public var title: String
        public var artist: String
        public var art: Art?
        /// The tempo fader's rate; the BPM box shows `grid.bpm * rate`.
        public var rate: Double
        public var keyLock: Bool
        public var camelot: String?
        /// Eight slots, seconds into the track.
        public var hotCues: [Double?]
        /// Previewing on CUE: PLAY shows ▶ even though the deck is sounding.
        public var previewing = false
        /// The track's stars, 1 … 5, and whether the current set has played it.
        public var rating: Int?
        public var played = false
        public var eq = Bands()
        public var kills = Kills()
        public var level = 1.0
        public var trimDb = 0.0
        /// AUTO: the trim that brings this track to the target loudness. Nil until measured.
        public var autoTrimDb: Double?
        /// The chip reads AUTO while the trim is the measured one (`.trimchip.auto`).
        public var trimIsAuto: Bool { autoTrimDb.map { $0 != 0 && abs(trimDb - $0) < 0.05 } ?? false }
        /// −1 (low-pass) … 0 (off) … 1 (high-pass).
        public var filter = 0.0
        /// The channel's headphone CUE.
        public var headphoneCue = false
        /// The loop size the stepper shows when no loop runs.
        public var loopBeats = 8.0
        public var jumpBars = 1
        public var hotCuesOpen = false
        /// DELETE is armed in the hot cue bank: set pads erase.
        public var hotCueDeleting = false
        public init(id: String, trackID: String? = nil, loading: Bool = false, playing: Bool = false,
                    syncLocked: Bool = false, grid: Grid? = nil, durationSec: Double = 0, position: Double = 0,
                    cuePoint: Double = 0, loop: Loop? = nil, wave: Wave? = nil, title: String = "", artist: String = "",
                    art: Art? = nil, rate: Double = 1, keyLock: Bool = false, camelot: String? = nil,
                    hotCues: [Double?] = Array(repeating: nil, count: 8)) {
            self.id = id; self.trackID = trackID; self.loading = loading; self.playing = playing
            self.syncLocked = syncLocked; self.grid = grid; self.durationSec = durationSec; self.position = position
            self.cuePoint = cuePoint; self.loop = loop; self.wave = wave; self.title = title; self.artist = artist
            self.art = art; self.rate = rate; self.keyLock = keyLock; self.camelot = camelot; self.hotCues = hotCues
        }
        public var loaded: Bool { trackID != nil }
        /// "loading", "empty", "playing" or "cued", as the lane label says it.
        var stateWord: String { loading ? "LOADING" : !loaded ? "EMPTY" : playing ? "PLAYING" : "CUED" }
    }
    /// What the library is working on, e.g. "ANALYSING 3 / 12 · Bicep — Glue".
    public struct LibraryStatus: Equatable, Sendable {
        public var label: String
        public var current: Int?
        public var total: Int?
        public var name: String?
        public init(label: String, current: Int? = nil, total: Int? = nil, name: String? = nil) {
            self.label = label; self.current = current; self.total = total; self.name = name
        }
    }
    public enum SaveState: Equatable, Sendable { case saved, saving, error }
    /// The track MORE is open on, and whether REMOVE waits for its second tap.
    public struct More: Equatable, Sendable {
        public var track: String
        public var confirming: Bool
        /// Re-analyse asked once; it replaces hand-edited grids.
        public var reanalysing: Bool
        public init(track: String, confirming: Bool = false, reanalysing: Bool = false) {
            self.track = track; self.confirming = confirming; self.reanalysing = reanalysing
        }
    }
    public enum Sheet: Equatable, Sendable { case tap, shortcuts }
    /// The instructions behind an (i) key.
    public enum HelpTopic: String, Equatable, Sendable { case grid, tap, trim, band, volume, library }
    /// The mixer's temporary controls, opened from the chassis.
    public enum MixPop: Equatable, Sendable { case trim(String), filter(String), master, band(String) }
    /// A failure, on one line under the header.
    public struct Alert: Equatable, Sendable {
        public var title: String
        public var message: String
        public var dismissable: Bool
        public init(title: String, message: String, dismissable: Bool = true) {
            self.title = title; self.message = message; self.dismissable = dismissable
        }
    }
    /// A file or library row held over a deck, and what it would bring.
    public struct Drop: Equatable, Sendable {
        public var deck: String
        public var label: String
        public init(deck: String, label: String) { self.deck = deck; self.label = label }
    }
    /// The crate: tracks, playlists and the row picked for loading.
    public struct Library: Equatable, Sendable {
        public struct Alternate: Equatable, Sendable, Hashable {
            public var bpm: Double
            public var offsetMs: Double
            /// Its tempo over the current one, e.g. "2/3".
            public var relation: String
            public init(bpm: Double, offsetMs: Double, relation: String) { self.bpm = bpm; self.offsetMs = offsetMs; self.relation = relation }
        }
        public struct Track: Equatable, Sendable, Identifiable {
            public var id: String
            /// "Artist — Title".
            public var name: String
            /// "F minor", from the key analysis.
            public var key: String?
            public var camelot: String?
            /// The key analysis has run on it, whether or not it found one.
            public var keyChecked: Bool
            public var bpm: Double
            public var durationSec: Double
            /// The grid's confidence, 0 … 1.
            public var confidence: Double
            public var gridUncertain: Bool
            public var alternates: [Alternate]
            public var missing: Bool
            /// The title alone, as a row shows it.
            public var title: String
            /// What MORE shows beyond the row. Empty when the tags don't say.
            public var artist = ""
            public var album = ""
            public var genre = ""
            public var subgenre = ""
            public var remixer = ""
            /// "Dec 09, 2019".
            public var release = ""
            /// The placeholder, while `coverURL` is nil.
            public var art: Art?
            /// The cover saved from the tags, read when its row appears.
            public var coverURL: URL?
            /// The DJ's stars, 1 … 5.
            public var rating: Int?
            public init(id: String, name: String, key: String? = nil, camelot: String? = nil, keyChecked: Bool = false,
                        bpm: Double, durationSec: Double, confidence: Double, gridUncertain: Bool = false,
                        alternates: [Alternate] = [], missing: Bool = false, title: String? = nil, artist: String? = nil) {
                self.id = id; self.name = name; self.key = key; self.camelot = camelot; self.keyChecked = keyChecked
                self.bpm = bpm; self.durationSec = durationSec; self.confidence = confidence
                self.gridUncertain = gridUncertain; self.alternates = alternates; self.missing = missing
                let parts = name.components(separatedBy: " — ")
                self.title = title ?? parts.last ?? name
                self.artist = artist ?? (parts.count > 1 ? parts[0] : "")
            }
        }
        public struct Playlist: Equatable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var trackIDs: [String]
            public init(id: String, name: String, trackIDs: [String] = []) { self.id = id; self.name = name; self.trackIDs = trackIDs }
        }
        /// A set: what the crowd heard, in order. The last of `sets` is the current one.
        public struct SetEntry: Equatable, Sendable, Identifiable {
            public struct Play: Equatable, Sendable {
                public var trackID: String
                /// The clock time it joined the set: "22:04".
                public var time: String
                public init(trackID: String, time: String) { self.trackID = trackID; self.time = time }
            }
            public var id: String
            /// "Fri 13 Nov" for the sidebar, and "Fri 13 Nov · 22:04" for the heading.
            public var day: String
            public var started: String
            public var plays: [Play]
            public init(id: String, day: String, started: String, plays: [Play] = []) {
                self.id = id; self.day = day; self.started = started; self.plays = plays
            }
        }
        public struct PendingImport: Equatable, Sendable, Identifiable {
            public let id: String
            public let title: String
            public let label: String
            public let fraction: Double
            public let art: Art?
            public init(id: String, title: String, label: String, fraction: Double, art: Art? = nil) {
                self.id = id; self.title = title; self.label = label; self.fraction = fraction; self.art = art
            }
        }
        public var tracks: [Track]
        public var playlists: [Playlist]
        public var pendingImports: [PendingImport] = []
        /// Every set, the current one last; its tracks are the played ones.
        public var sets: [SetEntry] = [SetEntry(id: "set-now", day: "", started: "")]
        public var currentSet: SetEntry? { sets.last }
        public var played: Set<String> { Set(currentSet?.plays.map(\.trackID) ?? []) }
        /// The row picked for loading: tap a deck's art to load it.
        public var selected: String?
        /// Something is importing or analysing.
        public var busy: Bool
        /// What the engine can do to a track: analyse its key (FIND KEYS),
        /// analyse it again (↻) and take it out of the library (✕).
        public var findsKeys: Bool
        public var reanalyzes: Bool
        public var removes: Bool
        /// A playlist just made from MORE, for the library to open and name.
        public var justMade: String?
        public init(tracks: [Track] = [], playlists: [Playlist] = [], selected: String? = nil, busy: Bool = false,
                    findsKeys: Bool = true, reanalyzes: Bool = true, removes: Bool = true) {
            self.tracks = tracks; self.playlists = playlists; self.selected = selected; self.busy = busy
            self.findsKeys = findsKeys; self.reanalyzes = reanalyzes; self.removes = removes
        }
        public func track(_ id: String?) -> Track? { id.flatMap { id in tracks.first { $0.id == id } } }
    }
    /// TAP: the tempo of an audio input.
    public struct Tap: Equatable, Sendable {
        public enum Status: Equatable, Sendable { case idle, starting, listening, error }
        public struct Device: Equatable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var loopback: Bool
            public init(id: String, label: String, loopback: Bool = false) { self.id = id; self.label = label; self.loopback = loopback }
        }
        public var status: Status
        public var devices: [Device]
        /// The input listened to.
        public var deviceID: String?
        public var levelDb: Double
        public var bpm: Double?
        public var confidence: Double
        public var error: String?
        /// Analysis windows read so far.
        public var windows: Int
        public init(status: Status = .idle, devices: [Device] = [], deviceID: String? = nil, levelDb: Double = -120,
                    bpm: Double? = nil, confidence: Double = 0, error: String? = nil, windows: Int = 0) {
            self.status = status; self.devices = devices; self.deviceID = deviceID; self.levelDb = levelDb
            self.bpm = bpm; self.confidence = confidence; self.error = error; self.windows = windows
        }
        var listening: Bool { status == .listening || status == .starting }
    }

    public var decks: [Deck]
    public var masterDeck: Int
    public var sampleRate: Double
    public var splitCue: Bool
    public var energyEnabled: Bool
    public var volumeOpen: Bool
    public var sheet: Sheet?
    public var status: LibraryStatus?
    public var saveState: SaveState
    /// Seconds across a zoom lane.
    public var spanSec: Double = 12
    public var crossfader = 0.5
    public var linkLows = false
    /// The centre strip's meters when no clock drives them: snapshots and previews.
    public var meters = Meters.silent
    /// Master output, 0 … 1 (unity).
    public var masterVolume = 1.0
    /// The headphones' blend as the engine takes it: master (0) to the cued decks (1).
    public var cueMix = 0.5
    /// PHONES: the headphones' level, 0 … 1.
    public var phones = 1.0
    public var help: HelpTopic?
    public var mixPop: MixPop?
    /// The deck whose beat grid sheet is up.
    public var gridDeck: String?
    /// The library is up: the lanes fold away and the crate fills the chassis.
    public var libraryOpen = false
    /// MORE, over the library.
    public var more: More?
    public var library = Library()
    public var tap = Tap()
    public var alert: Alert?
    public var drop: Drop?

    public init(decks: [Deck] = [Deck(id: "A"), Deck(id: "B")], masterDeck: Int = 0, sampleRate: Double = 48_000,
                splitCue: Bool = true, energyEnabled: Bool = false, volumeOpen: Bool = false, sheet: Sheet? = nil,
                status: LibraryStatus? = nil, saveState: SaveState = .saved) {
        self.decks = decks; self.masterDeck = masterDeck; self.sampleRate = sampleRate; self.splitCue = splitCue
        self.energyEnabled = energyEnabled; self.volumeOpen = volumeOpen; self.sheet = sheet
        self.status = status; self.saveState = saveState
    }
}

extension ConsoleState.Deck {
    /// A copy with some fields changed, for building demo states.
    func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}

/// What the console's controls ask for. Defaults do nothing, for snapshots.
public struct ConsoleActions {
    public var setEnergy: (Bool) -> Void = { _ in }
    public var toggleVolume: () -> Void = {}
    public var toggleSplitCue: () -> Void = {}
    public var setSheet: (ConsoleState.Sheet?) -> Void = { _ in }
    public var retrySave: () -> Void = {}
    public var openGrid: (String) -> Void = { _ in }
    public var setSpan: (Double) -> Void = { _ in }
    /// The cover: open the library, or load the selected track on this deck.
    public var tapArt: (String) -> Void = { _ in }
    public var deck = DeckActions()
    public var toggleLinkLows: () -> Void = {}
    public var openTrim: (String) -> Void = { _ in }
    public var openBand: (String) -> Void = { _ in }
    public var setCrossfader: (Double) -> Void = { _ in }
    public var setMixPop: (ConsoleState.MixPop?) -> Void = { _ in }
    public var setHelp: (ConsoleState.HelpTopic?) -> Void = { _ in }
    public var dismissAlert: () -> Void = {}
    public var setMasterVolume: (Double) -> Void = { _ in }
    public var setCueMix: (Double) -> Void = { _ in }
    public var setPhones: (Double) -> Void = { _ in }
    public var closeGrid: () -> Void = {}
    /// Deck, the new grid, and the other readings when they change with it.
    public var setGrid: (String, ConsoleState.Grid, [ConsoleState.Library.Alternate]?) -> Void = { _, _, _ in }
    /// Deck, start, seconds per column and columns: the lowest and highest
    /// sample per column, in pairs, read from the audio.
    public var gridWave: @MainActor (String, Double, Double, Int) async -> [Float]? = { _, _, _, _ in nil }
    public var library = LibraryActions()
    public var tap = TapActions()
    /// A file or library row held over a deck, or nil when it leaves.
    public var setDrop: (ConsoleState.Drop?) -> Void = { _ in }
    /// Audio files dropped on a deck: imported, the last one loaded there.
    public var dropFiles: (String, [URL]) -> Void = { _, _ in }
    /// A library row dropped on a deck.
    public var dropTrack: (String, String) -> Void = { _, _ in }
    public init() {}
}

/// The crate's controls. Ids are the library's track and playlist ids.
public struct LibraryActions {
    public var setOpen: (Bool) -> Void = { _ in }
    public var select: (String?) -> Void = { _ in }
    public var addFiles: () -> Void = {}
    public var addFolder: () -> Void = {}
    public var findKeys: () -> Void = {}
    public var reanalyze: (String) -> Void = { _ in }
    /// MORE on a row: its details, playlists, re-analyse and remove; nil closes it.
    public var setMore: (ConsoleState.More?) -> Void = { _ in }
    /// Makes a playlist from MORE with this track in it, and opens it.
    public var newPlaylist: (String) -> Void = { _ in }
    public var remove: (String) -> Void = { _ in }
    /// Makes an empty playlist and returns its id.
    public var createPlaylist: () -> String = { "" }
    public var addToPlaylist: (_ playlist: String, _ track: String) -> Void = { _, _ in }
    public var removeFromPlaylist: (_ playlist: String, _ track: String) -> Void = { _, _ in }
    public var renamePlaylist: (_ playlist: String, _ name: String) -> Void = { _, _ in }
    public var deletePlaylist: (String) -> Void = { _ in }
    /// Stars for a track, 1 … 5; nil clears them.
    public var rate: (_ track: String, _ stars: Int?) -> Void = { _, _ in }
    /// NEW SET: the played marks clear and a new set starts.
    public var newSet: () -> Void = {}
    /// SAVE AS PLAYLIST: a playlist of the set's tracks; returns its id.
    public var saveSet: (String) -> String? = { _ in nil }
    public init() {}
}

/// TAP's controls.
public struct TapActions {
    public var refresh: () -> Void = {}
    /// Listen to the input with this id.
    public var listen: (String?) -> Void = { _ in }
    public var stop: () -> Void = {}
    /// Set this deck's tempo to the tapped BPM.
    public var match: (String) -> Void = { _ in }
    public init() {}
}

/// A scrub of the lane or platter, in source seconds from where it began.
/// `end` stops where the pointer lifts; `fling` carries on with the pointer's speed,
/// from a lane showing this many source seconds.
public enum Scrub: Equatable, Sendable { case begin, move(Double), end, fling(span: Double), cancel }

/// A deck's controls, by deck id ("A" / "B").
public struct DeckActions {
    public var toggleSync: (String) -> Void = { _ in }
    public var setMaster: (String) -> Void = { _ in }
    public var toggleKeyLock: (String) -> Void = { _ in }
    public var toggleHotCues: (String) -> Void = { _ in }
    public var cueDown: (String) -> Void = { _ in }
    public var cueUp: (String) -> Void = { _ in }
    /// Keep a CUE preview playing (sliding onto PLAY, or PLAY pressed while
    /// CUE is held); false when there was no preview to keep.
    public var continueCue: (String) -> Bool = { _ in false }
    public var togglePlay: (String) -> Void = { _ in }
    public var beatJump: (String, Int) -> Void = { _, _ in }
    public var setJumpBars: (String, Int) -> Void = { _, _ in }
    public var stepLoop: (String, Int) -> Void = { _, _ in }
    public var toggleLoop: (String) -> Void = { _ in }
    public var toggleHeadphoneCue: (String) -> Void = { _ in }
    /// Deck, band ("high", "mid", "low"), on.
    public var setKill: (String, String, Bool) -> Void = { _, _, _ in }
    /// The tempo fader's rate.
    public var setTempo: (String, Double) -> Void = { _, _ in }
    /// Deck, fader ("level", "high", "mid", "low"), position 0 … 1.
    public var setFader: (String, String, Double) -> Void = { _, _, _ in }
    /// −1 (low-pass) … 0 … 1 (high-pass).
    public var setFilter: (String, Double) -> Void = { _, _ in }
    public var scrub: (String, Scrub) -> Void = { _, _ in }
    /// A released scrub is still carrying on, so a touch should catch it.
    public var coasting: (String) -> Bool = { _ in false }
    /// Seconds into the track.
    public var seek: (String, Double) -> Void = { _, _ in }
    /// TRIM, dB.
    public var setTrim: (String, Double) -> Void = { _, _ in }
    public var setHotCueDelete: (String, Bool) -> Void = { _, _ in }
    /// A hot cue pad: an empty one captures, a set one jumps, or erases while DELETE is armed.
    public var hotCue: (String, Int) -> Void = { _, _ in }
    public init() {}
}

extension ConsoleState {
    /// The seconds of track a deck's lane shows. The master is the truth: a deck locked to it
    /// is scaled so its beats match the master's across the whole width and scroll with them.
    func laneSpan(of deck: Deck) -> Double {
        guard deck.syncLocked, decks.indices.contains(masterDeck), decks[masterDeck].id != deck.id,
              decks[masterDeck].loaded, let own = deck.grid, let truth = decks[masterDeck].grid,
              abs(truth.bpm * decks[masterDeck].rate / own.bpm - deck.rate) < 0.005 else { return spanSec }
        return spanSec * truth.bpm / own.bpm
    }

    /// `?demo=mockup`: the SNAPSHOT in demo.tsx. A plays an 8-beat loop as
    /// master; B is cued and synced.
    public static let demoHome: ConsoleState = {
        var state = ConsoleState(decks: [
            Deck(id: "A", trackID: "demo-0", playing: true, grid: Grid(bpm: 133, offsetMs: 489.9, confidence: 0.95),
                 durationSec: 384, position: 384 - 72.418, loop: Loop(startBeat: 688, lengthBeats: 8), wave: .demo(seed: 7),
                 title: "Everlight (Extended Mix)", artist: "Tiesto, Mathame", art: .split(0x2B4F7A, 0xD0703A),
                 keyLock: true, camelot: "8A", hotCues: [32.0, 104.7, 312.67, 261.5, nil, nil, nil, nil])
                .with { $0.headphoneCue = true; $0.trimDb = -1.4; $0.autoTrimDb = -1.4 },
            Deck(id: "B", trackID: "demo-1", syncLocked: true, grid: Grid(bpm: 130, offsetMs: 247.3, confidence: 0.88),
                 durationSec: 418, position: 0.91, cuePoint: 0.9, wave: .demo(seed: 21),
                 title: "Ocean", artist: "Patrick Topping", art: .split(0x0F5E63, 0x9AD3C4),
                 rate: 1.0231, camelot: "4A", hotCues: [31.0, nil, 135.0, nil, nil, nil, nil, nil])
                .with { $0.eq = Bands(low: 0.06, mid: 0.6, high: 0.8); $0.loopBeats = 16; $0.trimDb = 1.2; $0.autoTrimDb = 1.2 }
        ])
        state.masterVolume = 0.816
        // The mockup's still meters (`METER.still`): A playing alone near the top, B cued and silent,
        // the master A through VOLUME.
        state.meters = Meters(level: MeterLevels(a: -2.0, l: -3.8, r: -4.3, b: MeterLevels.floor),
                              hold: MeterLevels(a: -1.0, l: -2.8, r: -3.2, b: MeterLevels.floor))
        state.library = demoLibrary
        return state
    }()

    /// The demo crate: `LIBRARY` and the two playlists in demo.tsx.
    static let demoLibrary: Library = {
        let rows: [(String, Double, String, Double, String, String)] = [
            ("Tiesto, Mathame — Everlight (Extended Mix)", 133.0, "6:24", 95, "A minor", "8A"),
            ("Patrick Topping — Ocean", 130.0, "6:58", 88, "F minor", "4A"),
            ("Oneeva — Platform 9 (NCS Release)", 126.0, "4:12", 91, "D major", "10B"),
            ("Curtis Mayfield — Move On Up", 130.0, "2:00", 84, "G major", "9B"),
            ("Arkins, JERIDE, B.A.S.E — Banger Rangers", 132.0, "2:00", 97, "C minor", "5A"),
            ("Fred again.. — Delilah (pull me out of this)", 124.0, "4:09", 93, "B♭ minor", "3A"),
            ("Bicep — Glue", 129.9, "4:29", 96, "F minor", "4A"),
            ("Peggy Gou — It Goes Like (Nanana)", 130.0, "3:35", 90, "A♭ major", "4B"),
            ("Chris Lake — Turn Off The Lights", 126.0, "3:22", 92, "E minor", "9A"),
            ("Overmono — So U Kno", 134.0, "4:04", 87, "D minor", "7A"),
            ("Mochakk — Jealous", 128.0, "3:12", 94, "E♭ minor", "2A"),
            ("Disclosure — Latch", 122.0, "4:15", 89, "C# minor", "12A")
        ]
        let tracks = rows.enumerated().map { index, row in
            let seconds = row.2.split(separator: ":").reduce(0.0) { $0 * 60 + Double($1)! }
            var track = Library.Track(id: "demo-\(index)", name: row.0, key: row.4, camelot: row.5, keyChecked: true,
                                      bpm: row.1, durationSec: seconds, confidence: row.3 / 100)
            // `ROW_ART` and `DEMO_TAGS` in the mockup.
            let art: [UInt32] = [0xF47131, 0xF3362F, 0x40BD5C, 0x393F40, 0x00BCF2, 0xDCE12D]
            track.art = .split(art[index % art.count], art[index % art.count])
            let tags = demoTags[index]
            track.album = tags.0; track.genre = tags.1; track.subgenre = tags.2; track.remixer = tags.3; track.release = tags.4
            return track
        }
        return Library(tracks: tracks, playlists: [
            Library.Playlist(id: "warm", name: "Warm up", trackIDs: ["demo-5", "demo-2", "demo-6", "demo-3"]),
            Library.Playlist(id: "peak", name: "Peak time")
        ])
    }()

    /// Album, genre, subgenre, remixer and release, as `DEMO_TAGS` in the mockup,
    /// the date as the diff's Chromium formats it.
    private static let demoTags: [(String, String, String, String, String)] = [
        ("Demo Album", "Melodic House", "Progressive", "", "14/03/2024"),
        ("Demo Album", "Tech House", "Latin", "", "02/06/2023"),
        ("Sample Sessions", "Trance", "Uplifting", "", "19/01/2022"),
        ("Sample Sessions", "Soul", "", "", "01/09/1970"),
        ("Test Pressing", "Hard Dance", "", "Demo Remixer", "07/10/2024"),
        ("Test Pressing", "House", "Melodic", "", "25/02/2022"),
        ("Demo Album", "Electronica", "Breaks", "", "09/12/2019"),
        ("Sample Sessions", "House", "", "", "11/08/2023"),
        ("Test Pressing", "House", "Tech", "", "30/05/2023"),
        ("Demo Album", "Techno", "Peak Time", "", "16/04/2021"),
        ("", "", "", "", "21/07/2023"),
        ("Sample Sessions", "UK Garage", "", "Demo Remixer", "08/10/2012")
    ]

    /// `?demo=mockup&screen=analysing`.
    public static let demoAnalysing: ConsoleState = demoHome.with {
        $0.status = LibraryStatus(label: "ANALYSING", current: 3, total: 12, name: "Bicep — Glue")
    }

    /// First run: both decks empty, the mixer as the mockup leaves it.
    static let demoFirstRun: ConsoleState = demoHome.with { state in
        state.decks = state.decks.map { loaded in
            Deck(id: loaded.id, keyLock: loaded.keyLock).with {
                $0.eq = loaded.eq; $0.level = loaded.level; $0.filter = loaded.filter
                $0.headphoneCue = loaded.headphoneCue; $0.loopBeats = loaded.loopBeats
            }
        }
        state.library = Library()
        state.meters = .silent
    }

    /// Deck A's track with the tempos the analysis turned down, its grid open.
    static func demoGrid(unsure: Bool) -> ConsoleState {
        demoHome.with { state in
            state.library.tracks[0].gridUncertain = unsure
            state.library.tracks[0].alternates = [
                Library.Alternate(bpm: 88.667, offsetMs: 120.4, relation: "2/3"),
                Library.Alternate(bpm: 177.333, offsetMs: 489.9, relation: "4/3"),
                Library.Alternate(bpm: 99.75, offsetMs: 312.8, relation: "3/4")
            ]
            state.gridDeck = "A"
        }
    }

    /// The TAP sheet as the mockup draws it: listening to a loopback device.
    static let demoTap: ConsoleState = demoHome.with {
        $0.sheet = .tap
        $0.tap = Tap(status: .listening, devices: [Tap.Device(id: "blackhole", label: "BlackHole 2ch", loopback: true)],
                     deviceID: "blackhole", levelDb: -14, bpm: 128, confidence: 0.86, windows: 5)
    }

    /// The library with the tracks from `first` on saved before key analysis.
    static func demoKeyless(from first: Int) -> ConsoleState {
        demoHome.with { state in
            state.libraryOpen = true
            for index in first..<state.library.tracks.count {
                state.library.tracks[index].key = nil
                state.library.tracks[index].camelot = nil
                state.library.tracks[index].keyChecked = false
            }
        }
    }

    /// Deck B on its first load: dark like an empty deck, the mixer as it was.
    static let demoLoading: ConsoleState = demoHome.with { state in
        let loaded = state.decks[1]
        state.decks[1] = Deck(id: "B", loading: true).with {
            $0.eq = loaded.eq; $0.level = loaded.level; $0.filter = loaded.filter; $0.loopBeats = loaded.loopBeats
        }
        state.status = LibraryStatus(label: "ANALYSING")
        state.meters.level.b = MeterLevels.floor; state.meters.hold.b = MeterLevels.floor
    }

    /// Screens the mockup's picker added after the Electron freeze. Their
    /// reference is the mockup, not `?demo=mockup`.
    static let demosAfterFreeze: [String: ConsoleState] = [
        "importing": demoHome.with { $0.status = LibraryStatus(label: "IMPORTING") },
        "importprogress": demoHome.with {
            $0.status = LibraryStatus(label: "IMPORTING")
            $0.libraryOpen = true
            $0.library.busy = true
            $0.library.pendingImports = [
                Library.PendingImport(id: "import-1", title: "Night Drive", label: "Analysing", fraction: 0.62, art: .split(0x20242C, 0x20242C)),
                Library.PendingImport(id: "import-2", title: "After Hours", label: "Queued", fraction: 0, art: .split(0x262A37, 0x262A37))
            ]
        },
        "loading": demoLoading,
        "saving": demoHome.with { $0.saveState = .saving },
        "notsaved": demoHome.with { $0.saveState = .error },
        "keysmissing": demoKeyless(from: 8),
        "findingkeys": demoKeyless(from: 10).with {
            $0.library.busy = true
            $0.status = LibraryStatus(label: "FINDING KEYS", current: 3, total: 4, name: "Mochakk — Jealous")
        },
        "filemissing": demoHome.with { $0.libraryOpen = true; $0.library.tracks[6].missing = true },
        "dropaudio": demoHome.with { $0.drop = Drop(deck: "B", label: "Audio file · analysed, then loaded") },
        "dropfiles": demoHome.with { $0.drop = Drop(deck: "B", label: "3 files · analysed, the last one loaded") },
        "droplibrary": demoHome.with { $0.drop = Drop(deck: "B", label: "Bicep — Glue · from the library") },
        "tapidle": demoTap.with { $0.tap = Tap(status: .idle, devices: demoTap.tap.devices) },
        "tapnoinputs": demoHome.with { $0.sheet = .tap; $0.tap = Tap(status: .idle) },
        "bothdecks": demoHome.with { $0.libraryOpen = true; $0.decks[1].trackID = "demo-0" },
        "trackmore": demoHome.with { $0.libraryOpen = true; $0.more = More(track: "demo-6") },
        "trackremove": demoHome.with { $0.libraryOpen = true; $0.more = More(track: "demo-6", confirming: true) },
        "trackagain": demoHome.with { $0.libraryOpen = true; $0.more = More(track: "demo-6", reanalysing: true) }
    ]

    /// The demo screens by their `screen=` name ("home" for none), plus the
    /// mockup diff's screens reached by a tap: library, volume, trim,
    /// band-low, hotcue, grid and the help sheets.
    public static let demos: [String: ConsoleState] = [
        "home": demoHome,
        "analysing": demoAnalysing,
        "library": demoHome.with { $0.libraryOpen = true; $0.library.selected = "demo-3" },
        "volume": demoHome.with { $0.volumeOpen = true },
        "volumehelp": demoHome.with { $0.volumeOpen = true; $0.help = .volume },
        "trim": demoHome.with { $0.mixPop = .trim("A") },
        "filter": demoHome.with { $0.mixPop = .filter("A") },
        "master-level": demoHome.with { $0.mixPop = .master },
        "band-low": demoHome.with { $0.mixPop = .band("low") },
        "hotcue": demoHome.with { $0.decks[0].hotCuesOpen = true },
        "grid": demoHome.with { $0.gridDeck = "A" },
        "gridunsure": demoGrid(unsure: true),
        "gridalts": demoGrid(unsure: false),
        "gridhelp": demoGrid(unsure: false).with { $0.help = .grid },
        "gridunsure-library": demoGrid(unsure: true).with { $0.gridDeck = nil; $0.libraryOpen = true },
        "firstrun": demoFirstRun,
        "firstrun-library": demoFirstRun.with { $0.libraryOpen = true },
        "error": demoHome.with {
            $0.alert = Alert(title: "CAN'T LOAD", message: "\"Bicep — Glue\" isn't on disk any more. Add the file again to play it.")
        },
        "drop": demoHome.with { $0.drop = Drop(deck: "B", label: "Bicep — Glue.flac · analysed, then loaded") },
        "dropblocked": demoHome.with { $0.drop = Drop(deck: "A", label: "") },
        "shortcuts": demoHome.with { $0.sheet = .shortcuts },
        "tap": demoTap,
        "taphelp": demoTap.with { $0.help = .tap },
        "playlistmenu": demoHome.with { $0.libraryOpen = true },
        "rename": demoHome.with { $0.libraryOpen = true },
        "delete": demoHome.with { $0.libraryOpen = true }
    ].merging(demosAfterFreeze) { first, _ in first }

    /// Where the library starts in the mockup's playlist screens.
    public static let demoLibraryStarts: [String: LibraryView] = [
        "playlistmenu": LibraryView(view: "warm", listMenu: "warm"),
        "rename": LibraryView(view: "warm", renaming: "warm"),
        "delete": LibraryView(view: "warm", listMenu: "warm", confirmDelete: true),
        "gridunsure-library": LibraryView(scrolledToEnd: true)
    ]

    /// A copy with some fields changed.
    func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}
