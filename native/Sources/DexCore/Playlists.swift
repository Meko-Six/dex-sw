import Foundation

/// A named, ordered list of library track ids. Ports `src/shared/playlist.ts`.
public struct Playlist: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var trackIDs: [String]
    public init(id: String, name: String, trackIDs: [String] = []) { self.id = id; self.name = name; self.trackIDs = trackIDs }
}

/// The playlist edits: each returns the new list and leaves its input alone.
public enum Playlists {
    public static let defaultName = "New playlist"

    /// A name nobody else has: "New playlist", then "New playlist 2", and so on.
    public static func uniqueName(_ base: String, in playlists: [Playlist], except id: String? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let wanted = trimmed.isEmpty ? defaultName : trimmed
        let taken = Set(playlists.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(wanted.lowercased()) { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)".lowercased()) { n += 1 }
        return "\(wanted) \(n)"
    }

    public static func create(_ playlists: [Playlist], id: String, name: String = defaultName) -> [Playlist] {
        playlists + [Playlist(id: id, name: uniqueName(name, in: playlists))]
    }

    /// A blank name leaves the playlist as it was.
    public static func rename(_ playlists: [Playlist], id: String, to name: String) -> [Playlist] {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return playlists }
        return playlists.map { $0.id == id ? Playlist(id: id, name: uniqueName(name, in: playlists, except: id), trackIDs: $0.trackIDs) : $0 }
    }

    public static func delete(_ playlists: [Playlist], id: String) -> [Playlist] { playlists.filter { $0.id != id } }

    /// Appends the tracks the playlist does not hold yet, in the order given.
    public static func add(_ playlists: [Playlist], id: String, tracks: [String]) -> [Playlist] {
        playlists.map { playlist in
            guard playlist.id == id else { return playlist }
            var have = Set(playlist.trackIDs), copy = playlist
            for track in tracks where have.insert(track).inserted { copy.trackIDs.append(track) }
            return copy
        }
    }

    public static func remove(_ playlists: [Playlist], id: String, track: String) -> [Playlist] {
        playlists.map { $0.id == id ? Playlist(id: id, name: $0.name, trackIDs: $0.trackIDs.filter { $0 != track }) : $0 }
    }

    /// A track gone from the library leaves every playlist.
    public static func forget(_ playlists: [Playlist], track: String) -> [Playlist] {
        playlists.map { Playlist(id: $0.id, name: $0.name, trackIDs: $0.trackIDs.filter { $0 != track }) }
    }

    /// Saved playlists made safe: repeated playlists and tracks collapse,
    /// tracks the library no longer knows are dropped, blank names are named.
    public static func normalize(_ saved: [Playlist], known: Set<String>) -> [Playlist] {
        var seen = Set<String>(), out: [Playlist] = []
        for playlist in saved where !playlist.id.isEmpty && seen.insert(playlist.id).inserted {
            var tracks = Set<String>()
            let ids = playlist.trackIDs.filter { known.contains($0) && tracks.insert($0).inserted }
            let name = playlist.name.trimmingCharacters(in: .whitespaces)
            out.append(Playlist(id: playlist.id, name: name.isEmpty ? defaultName : name, trackIDs: ids))
        }
        return out
    }
}
