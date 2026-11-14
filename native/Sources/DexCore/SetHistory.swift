import Foundation

/// One set: what the crowd heard, in order, from NEW SET to the next.
public struct DJSet: Codable, Equatable, Sendable, Identifiable {
    public struct Play: Codable, Equatable, Sendable {
        /// The library track's id, as playlists keep it.
        public let track: String
        public let at: Date
        public init(track: String, at: Date) { self.track = track; self.at = at }
    }
    public let id: String
    public let startedAt: Date
    public var plays: [Play]
    public init(id: String = "set-" + UUID().uuidString, startedAt: Date, plays: [Play] = []) {
        self.id = id; self.startedAt = startedAt; self.plays = plays
    }
}

/// Every set, the current one last. A track is played when the current set holds it:
/// its music note turns orange in the library until NEW SET.
public struct SetHistory: Codable, Equatable, Sendable {
    /// Past sets, oldest first, then the current one.
    public private(set) var sets: [DJSet]
    public static let version = 1
    public var version: Int = SetHistory.version

    public init(sets: [DJSet] = [], now: Date = Date()) {
        self.sets = sets.isEmpty ? [DJSet(startedAt: now)] : sets
    }

    public var current: DJSet { sets[sets.count - 1] }
    /// The tracks the current set has played.
    public var played: Set<String> { Set(current.plays.map(\.track)) }

    /// The crowd heard `track`: it goes on the end of the current set.
    public mutating func record(_ track: String, at time: Date) {
        sets[sets.count - 1].plays.append(DJSet.Play(track: track, at: time))
    }

    /// NEW SET: the current set is kept with the others and an empty one starts. An empty
    /// current set is simply restarted, so pressing it twice makes no empty sets.
    public mutating func newSet(at time: Date) {
        if current.plays.isEmpty { sets[sets.count - 1] = DJSet(startedAt: time) }
        else { sets.append(DJSet(startedAt: time)) }
    }

    /// A deleted track leaves every set.
    public mutating func forget(_ track: String) {
        for index in sets.indices { sets[index].plays.removeAll { $0.track == track } }
    }

    /// A set's tracks in the order played, each once, for saving as a playlist.
    public func tracks(of id: String) -> [String] {
        guard let set = sets.first(where: { $0.id == id }) else { return [] }
        var seen = Set<String>()
        return set.plays.map(\.track).filter { seen.insert($0).inserted }
    }

    /// Drops tracks the library no longer has, and keeps at least the current set.
    public static func normalize(_ saved: SetHistory, known: Set<String>, now: Date = Date()) -> SetHistory {
        var result = SetHistory(sets: saved.sets, now: now)
        for index in result.sets.indices { result.sets[index].plays.removeAll { !known.contains($0.track) } }
        return result
    }
}

/// When a deck's track counts as played: the crowd has heard it for 30 seconds in all,
/// on this load. Heard means playing to the master (not a CUE preview) with the channel's
/// LEVEL and its side of the crossfader together at −12 dB or louder.
public struct PlayCounter: Sendable {
    public static let seconds = 30.0
    public static let audibleGain = 0.25

    private struct Load { var track: UUID; var heard = 0.0; var counted = false }
    private var loads: [String: Load] = [:]

    public init() {}

    /// Whether a channel is reaching the crowd.
    public static func heard(playing: Bool, previewing: Bool, level: Double, crossfadeSide: Double) -> Bool {
        playing && !previewing && level * crossfadeSide >= audibleGain
    }

    /// Advances one deck by `dt` seconds. Returns the track once, the moment it has been
    /// heard long enough; a new track on the deck starts its count again.
    public mutating func advance(deck: String, track: UUID?, heard: Bool, dt: Double) -> UUID? {
        guard let track else { loads[deck] = nil; return nil }
        var load = loads[deck].flatMap { $0.track == track ? $0 : nil } ?? Load(track: track)
        defer { loads[deck] = load }
        guard heard, !load.counted, dt > 0, dt < 5 else { return nil }
        load.heard += dt
        guard load.heard >= Self.seconds else { return nil }
        load.counted = true
        return track
    }
}
