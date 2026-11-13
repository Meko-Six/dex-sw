import Foundation
import DexCore

/// What MORE shows from the file's tags beyond the names.
public struct TrackDetails: Codable, Equatable, Sendable {
    /// Which fields the read knew: an older reading is read again, for the album.
    public static let currentVersion = 2
    public var version: Int? = TrackDetails.currentVersion
    public var album: String?
    public var genre: String?
    public var subgenre: String?
    public var remixer: String?
    /// As the tag writes it; `Tags.releaseText` formats it.
    public var release: String?
    /// Its cover is saved beside the waveform cache: `NativeLibrary.coverURL`.
    public var hasCover: Bool
}

public struct LibraryTrack: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fingerprint: String
    public let filename: String
    public let title: String
    public let duration: Double
    public var grid: BeatGrid?
    public var gridUncertain: Bool
    public var alternatives: [DetectedGrid.Alternative]
    public var hotCues: [Double?]
    public let importedAt: Date
    /// Nil until the key analysis has run; `TrackKey.notFound` when it found none.
    public var key: TrackKey? = nil
    /// The tags' artist and title, read at import; older tracks get them on
    /// their first load. `title` stays the file name.
    public var artist: String? = nil
    public var tagTitle: String? = nil
    /// Nil until the tags have been read; older tracks fill in the background.
    public var details: TrackDetails? = nil
    /// How loud the track sounds, for AUTO trim. Nil until measured; older tracks fill in the background.
    public var loudness: TrackLoudness? = nil
    /// The trim the DJ chose for this track, in dB. Nil plays it at AUTO.
    public var trimDb: Double? = nil
    /// The trim a deck starts this track at: the DJ's own, else AUTO.
    public var startingTrim: Double { trimDb ?? loudness?.autoTrim() ?? 0 }
    /// "Artist — Title" from the tags, else the file name: `trackLabel` in library.ts.
    public var label: String { tagTitle.map { title in artist.map { "\($0) — \(title)" } ?? title } ?? title }
    var detection: DetectedGrid { DetectedGrid(grid: grid, uncertain: gridUncertain, alternatives: alternatives) }
}

struct PreparedLibraryTrack: Sendable {
    var track: LibraryTrack
    let url: URL
    let overview: WaveformOverview
    var warning: LibraryNotice? = nil
}

/// Field-level changes let writers merge independent cue/grid edits even when
/// another process has changed the catalog since this view was opened.
struct LibraryMutation: Sendable {
    struct Grid: Sendable { let value: BeatGrid?; let uncertain: Bool; let alternatives: [DetectedGrid.Alternative] }
    struct Cue: Sendable { let slot: Int; let value: Double? }
    struct Key: Sendable { let value: TrackKey? }
    struct Names: Sendable { let artist: String?; let title: String?; let details: TrackDetails? }
    struct Loudness: Sendable { let value: TrackLoudness? }
    struct Trim: Sendable { let value: Double? }
    let id: UUID
    var grid: Grid?
    var cues: [Cue]
    var key: Key?
    var names: Names?
    var loudness: Loudness?
    var trim: Trim?
    var isEmpty: Bool { grid == nil && cues.isEmpty && key == nil && names == nil && loudness == nil && trim == nil }
    init(from old: LibraryTrack, to new: LibraryTrack) {
        id = old.id
        grid = old.grid != new.grid || old.gridUncertain != new.gridUncertain || old.alternatives != new.alternatives
            ? Grid(value: new.grid, uncertain: new.gridUncertain, alternatives: new.alternatives) : nil
        cues = old.hotCues.indices.compactMap { old.hotCues[$0] != new.hotCues[$0] ? Cue(slot: $0, value: new.hotCues[$0]) : nil }
        key = old.key != new.key ? Key(value: new.key) : nil
        names = old.artist != new.artist || old.tagTitle != new.tagTitle || old.details != new.details
            ? Names(artist: new.artist, title: new.tagTitle, details: new.details) : nil
        loudness = old.loudness != new.loudness ? Loudness(value: new.loudness) : nil
        trim = old.trimDb != new.trimDb ? Trim(value: new.trimDb) : nil
    }
    func merging(_ newer: LibraryMutation?) -> LibraryMutation {
        guard let newer else { return self }
        var result = self
        if let grid = newer.grid { result.grid = grid }
        if let key = newer.key { result.key = key }
        if let names = newer.names { result.names = names }
        if let loudness = newer.loudness { result.loudness = loudness }
        if let trim = newer.trim { result.trim = trim }
        for cue in newer.cues { result.cues.removeAll { $0.slot == cue.slot }; result.cues.append(cue) }
        return result
    }
    func applying(to track: LibraryTrack) -> LibraryTrack {
        var result = track
        if let grid { result.grid = grid.value; result.gridUncertain = grid.uncertain; result.alternatives = grid.alternatives }
        if let key { result.key = key.value }
        if let names { result.artist = names.artist; result.tagTitle = names.title; result.details = names.details }
        if let loudness { result.loudness = loudness.value }
        if let trim { result.trimDb = trim.value }
        for cue in cues where result.hotCues.indices.contains(cue.slot) { result.hotCues[cue.slot] = cue.value }
        return result
    }
}

public enum LibraryError: Error, Equatable, Sendable {
    case damagedCatalog, newerVersion, missingAudio, missingTrack, importFailed, sourceChanged
}
