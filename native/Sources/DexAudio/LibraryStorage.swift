import Foundation
import CryptoKit
import DexCore
import Darwin

private struct SourceIdentity: Codable, Equatable, Sendable {
    let location: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    static func read(_ url: URL) throws -> Self {
        var info = stat()
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Self(location: url.standardizedFileURL.path, device: UInt64(bitPattern: Int64(info.st_dev)), inode: info.st_ino,
                    size: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                    modifiedNanos: Int64(info.st_mtimespec.tv_nsec), changedSeconds: Int64(info.st_ctimespec.tv_sec),
                    changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
}

/// Which file sits at a path and whether it has been written since: enough to tell the
/// catalog this store last read or wrote from one another store has saved.
private struct FileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int, modifiedNanos: Int
    let changedSeconds: Int, changedNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
}

/// The catalog file this store holds in memory, kept open. Every save puts a new file in
/// the catalog's place, and while this one is open the system can't give its number to
/// another, so a file at the path with the same stamp is this very file, unchanged.
private final class HeldCatalogFile {
    let descriptor: Int32
    let stamp: FileStamp
    init(descriptor: Int32, stamp: FileStamp) { self.descriptor = descriptor; self.stamp = stamp }
    deinit { Darwin.close(descriptor) }
}

/// What the saved playlists turned out to be when the library opened.
enum SavedPlaylists: Sendable {
    /// The file read, or nothing has been saved yet.
    case loaded([Playlist])
    /// The file was missing or unreadable, and the save before it came back.
    case restored([Playlist])
    /// The file couldn't be read and there was no earlier save; it was kept under this name.
    case unreadable(kept: String)
    /// A newer version's file: never to be replaced.
    case newer
    /// The file couldn't be read or copied aside: never to be replaced.
    case stuck
}

actor LibraryStorage {
    private struct Alias: Codable { let identity: SourceIdentity; let fingerprint: String }
    private struct Catalog: Codable {
        var version = 1
        var tracks: [LibraryTrack] = []
        var sources: [Alias] = []
        private enum CodingKeys: String, CodingKey { case version, tracks, sources }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            tracks = try values.decode([LibraryTrack].self, forKey: .tracks)
            sources = try values.decodeIfPresent([Alias].self, forKey: .sources) ?? []
        }
    }
    let directory: URL
    private var catalog: Catalog?
    /// The file `catalog` came from or went to, nil when that isn't known for certain.
    private var held: HeldCatalogFile?
    private(set) var recoveredCatalog = false
    private(set) var commitCount = 0
    /// How many times a catalog file has been read and decoded whole.
    private(set) var decodeCount = 0
    private(set) var copiedBytes: Int64 = 0
    private let files = FileManager.default
    private let worker = LibraryAudioWorker()
    private var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private var cacheDirectory: URL { directory.appendingPathComponent("Analysis", isDirectory: true) }
    private var catalogURL: URL { directory.appendingPathComponent("Library.json") }
    private var backupURL: URL { directory.appendingPathComponent("Library.backup.json") }
    private var playlistsURL: URL { directory.appendingPathComponent("playlists.json") }
    private var playlistsBackupURL: URL { directory.appendingPathComponent("playlists.backup.json") }
    init(directory: URL) { self.directory = directory }

    /// Holds the library's OS lock, which other stores and other processes share.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try files.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".Library.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    /// Lock only short catalog transactions, never provider access or analysis.
    /// Under the same OS lock, read the catalog again before merging unless the file is
    /// still the one this store last read or wrote, including across processes.
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            // No pool around the body: `autoreleasepool`'s closure is transferred under
            // Swift 6, and a `body` closure can't be sent. The Foundation work a transaction
            // does is pooled where it happens: `decodeCatalog`, `commit`, and the recovery
            // write in `reloadCatalog`.
            if !catalogIsCurrent() { try reloadCatalog() }
            return try body()
        }
    }
    func open() throws -> [LibraryTrack] { try transaction { catalog!.tracks } }
    /// Whether the catalog on disk is the file this store holds in memory. Call under the lock.
    private func catalogIsCurrent() -> Bool {
        guard catalog != nil, let held else { return false }
        var info = stat()
        return stat(catalogURL.path, &info) == 0 && FileStamp(info) == held.stamp
    }
    /// Remembers the catalog file just written as the one in memory. Call under the lock,
    /// straight after the write, so no other store can have replaced it in between.
    private func holdWrittenCatalog() {
        held = nil
        let descriptor = Darwin.open(catalogURL.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); return }
        held = HeldCatalogFile(descriptor: descriptor, stamp: FileStamp(info))
    }
    /// Reads and decodes the catalog through one open file, and holds that file if it
    /// didn't change while it was being read.
    private func readCatalog() throws -> Catalog {
        held = nil
        let descriptor = Darwin.open(catalogURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var keep = false
        defer { if !keep { Darwin.close(descriptor) } }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var data = Data()
        data.reserveCapacity(Int(max(0, before.st_size)))
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            data.append(chunk, count: count)
        }
        let value = try decodeCatalog(data)
        var after = stat()
        if fstat(descriptor, &after) == 0, FileStamp(after) == FileStamp(before), Int64(data.count) == after.st_size {
            held = HeldCatalogFile(descriptor: descriptor, stamp: FileStamp(after))
            keep = true
        }
        return value
    }
    private func reloadCatalog() throws {
        held = nil
        if files.fileExists(atPath: catalogURL.path) {
            do { catalog = try readCatalog() }
            catch LibraryError.newerVersion { throw LibraryError.newerVersion }
            catch {
                guard let recovered = try? decodeCatalog(Data(contentsOf: backupURL)) else { throw LibraryError.damagedCatalog }
                try autoreleasepool {
                    try files.copyItem(at: catalogURL, to: directory.appendingPathComponent("Library.damaged-\(UUID().uuidString).json"))
                    try encode(recovered).write(to: catalogURL, options: .atomic)
                }
                catalog = recovered
                holdWrittenCatalog()
                recoveredCatalog = true
            }
        } else if files.fileExists(atPath: backupURL.path) {
            let recovered = try decodeCatalog(Data(contentsOf: backupURL))
            try autoreleasepool { try encode(recovered).write(to: catalogURL, options: .atomic) }
            catalog = recovered
            holdWrittenCatalog()
            recoveredCatalog = true
        } else { catalog = Catalog() }
    }
    private func decodeCatalog(_ data: Data) throws -> Catalog {
        decodeCount += 1
        return try autoreleasepool {
            struct Header: Decodable { let version: Int }
            guard try JSONDecoder().decode(Header.self, from: data).version == 1 else { throw LibraryError.newerVersion }
            let value = try JSONDecoder().decode(Catalog.self, from: data)
            guard Set(value.tracks.map(\.id)).count == value.tracks.count,
                  Set(value.tracks.map(\.fingerprint)).count == value.tracks.count,
                  value.tracks.allSatisfy(Self.valid) else { throw LibraryError.damagedCatalog }
            return value
        }
    }
    private static func valid(_ track: LibraryTrack) -> Bool {
        track.filename == URL(fileURLWithPath: track.filename).lastPathComponent &&
        !track.filename.isEmpty && track.filename != "." && track.filename != ".." &&
        track.duration.isFinite && track.duration > 0 && track.hotCues.count == 8 &&
        track.hotCues.allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= track.duration) } &&
        track.alternatives.allSatisfy { $0.bpm.isFinite && $0.bpm > 0 && $0.offsetMs.isFinite && $0.salience.isFinite } &&
        (track.key.map { $0.confidence.isFinite && (0...1).contains($0.confidence) } ?? true) &&
        (track.loudness.map { $0.integrated.isFinite && $0.main.isFinite && $0.peak.isFinite } ?? true) &&
        (track.trimDb.map { $0.isFinite && abs($0) <= 12 } ?? true)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func commit(_ next: Catalog) throws {
        let previous = catalog
        // If the save fails part-way, the next transaction reads the disk again.
        held = nil
        try autoreleasepool {
            let data = try encode(next)
            if let previous {
                // Never leave the first durable import with an empty recovery copy.
                let recovery = previous.tracks.isEmpty && !next.tracks.isEmpty ? next : previous
                try encode(recovery).write(to: backupURL, options: .atomic)
            }
            try data.write(to: catalogURL, options: .atomic)
        }
        catalog = next
        holdWrittenCatalog()
        commitCount += 1
    }
    private func cacheURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent(id.uuidString + ".waveform") }
    nonisolated func coverURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Analysis", isDirectory: true).appendingPathComponent(id.uuidString + ".cover.jpg")
    }
    private func saveCache(_ overview: WaveformOverview, id: UUID) async -> String? {
        await worker.saveCache(overview, to: cacheURL(id))
    }
    func prepare(_ id: UUID, progress: (@Sendable (NativeLibrary.ImportProgress) -> Void)? = nil) async throws -> PreparedLibraryTrack {
        let tracks = try open()
        try Task.checkCancellation()
        guard let track = tracks.first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        return try await prepare(track, progress: progress)
    }
    /// Prepares a track the caller has just read from the catalog, without reading it again first.
    private func prepare(_ track: LibraryTrack, progress: (@Sendable (NativeLibrary.ImportProgress) -> Void)?) async throws -> PreparedLibraryTrack {
        let id = track.id
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        let cached = try await worker.cached(cacheURL(id), track: track)
        if let cached {
            let current = try open().first(where: { $0.id == id }) ?? track
            return PreparedLibraryTrack(track: current, url: url, overview: cached)
        }
        progress?(.analysing(0))
        let scanned = try await worker.scan(url, analyzeRhythm: false) { progress?(.analysing($0)) }
        try Task.checkCancellation()
        progress?(.saving)
        let warning = await saveCache(scanned, id: id)
        let current = try open().first(where: { $0.id == id }) ?? track
        return PreparedLibraryTrack(track: current, url: url, overview: scanned, warning: warning)
    }
    func importFile(_ source: URL, id: UUID = UUID(), progress: (@Sendable (NativeLibrary.ImportProgress) -> Void)? = nil) async throws -> PreparedLibraryTrack {
        progress?(.opening)
        try Task.checkCancellation()
        let identity = try await worker.inspect(source)
        // The first look at the catalog: a library that can't be opened stops the import here.
        let existing: LibraryTrack? = try transaction {
            guard let alias = catalog!.sources.first(where: { $0.identity == identity }),
                  let track = catalog!.tracks.first(where: { $0.fingerprint == alias.fingerprint }),
                  let size = try? audioDirectory.appendingPathComponent(track.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == identity.size else { return nil }
            return track
        }
        if let existing { try Task.checkCancellation(); return try await prepare(existing, progress: progress) }
        let ext = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(12))
        let staging = audioDirectory.appendingPathComponent(".import-\(UUID().uuidString)" + suffix)
        defer { try? files.removeItem(at: staging) }
        progress?(.copying(0))
        let copied = try await worker.copy(source, to: staging) { progress?(.copying($0)) }
        copiedBytes += copied.identity.size
        try Task.checkCancellation()
        let duplicate = try open().first(where: { $0.fingerprint == copied.hash })
        let scanned: WaveformOverview
        if let duplicate {
            // Repair missing audio before cache preparation, under the catalog lock.
            let saved: LibraryTrack? = try transaction {
                let destination = audioDirectory.appendingPathComponent(duplicate.filename)
                if !files.fileExists(atPath: destination.path) { try files.moveItem(at: staging, to: destination) }
                var next = catalog!; remember(copied.identity, hash: copied.hash, in: &next); try commit(next)
                return next.tracks.first(where: { $0.id == duplicate.id })
            }
            try Task.checkCancellation()
            // Another store may have removed it since the copy was compared.
            guard let saved else { throw LibraryError.missingTrack }
            return try await prepare(saved, progress: progress)
        }
        progress?(.analysing(0))
        scanned = try await worker.scan(staging, analyzeKey: true) { progress?(.analysing($0)) }
        let tags = await worker.tags(staging, cover: coverURL(id))
        try Task.checkCancellation()
        let candidate = LibraryTrack(id: id, fingerprint: copied.hash, filename: id.uuidString + suffix,
                                     title: source.deletingPathExtension().lastPathComponent, duration: scanned.duration,
                                     grid: scanned.detection.grid, gridUncertain: scanned.detection.uncertain,
                                     alternatives: scanned.detection.alternatives, hotCues: Array(repeating: nil, count: 8), importedAt: Date(),
                                     key: scanned.key, artist: tags.artist, tagTitle: tags.title, details: tags.details,
                                     loudness: scanned.loudness)
        progress?(.saving)
        let committed: LibraryTrack = try transaction {
            var next = catalog!
            let selected = next.tracks.first(where: { $0.fingerprint == copied.hash }) ?? candidate
            let destination = audioDirectory.appendingPathComponent(selected.filename)
            let moved = !files.fileExists(atPath: destination.path)
            if moved { try files.moveItem(at: staging, to: destination) }
            if selected.id == id { next.tracks.append(candidate) }
            remember(copied.identity, hash: copied.hash, in: &next)
            do { try commit(next) }
            catch { if moved { try? files.removeItem(at: destination) }; throw error }
            return selected
        }
        if committed.id != id { try? files.removeItem(at: coverURL(id)) }
        let warning = await saveCache(scanned, id: committed.id)
        let current = try open().first(where: { $0.id == committed.id }) ?? committed
        return PreparedLibraryTrack(track: current, url: audioDirectory.appendingPathComponent(committed.filename),
                                    overview: scanned, warning: warning)
    }
    /// Reads a library track's key from its audio; the caller saves it.
    func readKey(_ id: UUID) async throws -> TrackKey {
        guard let track = try open().first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        return try await worker.readKey(url)
    }
    /// Measures a library track's loudness from its audio; the caller saves it.
    func readLoudness(_ id: UUID) async throws -> TrackLoudness {
        guard let track = try open().first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        return try await worker.readLoudness(url)
    }
    /// Reads a library track's tags and saves its cover; the caller saves the names.
    func readTags(_ id: UUID) async throws -> TagReading {
        guard let track = try open().first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        return await worker.tags(url, cover: coverURL(id))
    }
    /// Runs the whole analysis on a library track again and rebuilds its
    /// waveform cache; the caller saves the result.
    func reanalyze(_ id: UUID) async throws -> (overview: WaveformOverview, tags: TagReading) {
        guard let track = try open().first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        let scanned = try await worker.scan(url, analyzeKey: true)
        try Task.checkCancellation()
        _ = await saveCache(scanned, id: id)
        return (scanned, await worker.tags(url, cover: coverURL(id)))
    }
    /// Takes a track out of the catalog, then deletes its audio and caches. A
    /// deck holding it keeps playing from its open file.
    func remove(_ id: UUID) throws {
        let removed: LibraryTrack? = try transaction {
            var next = catalog!
            guard let index = next.tracks.firstIndex(where: { $0.id == id }) else { return nil }
            let track = next.tracks.remove(at: index)
            next.sources.removeAll { $0.fingerprint == track.fingerprint }
            try commit(next)
            return track
        }
        guard let removed else { return }
        try? files.removeItem(at: audioDirectory.appendingPathComponent(removed.filename))
        try? files.removeItem(at: cacheURL(id))
        try? files.removeItem(at: coverURL(id))
    }
    private func remember(_ identity: SourceIdentity, hash: String, in catalog: inout Catalog) {
        catalog.sources.removeAll { $0.identity.location == identity.location }
        catalog.sources.append(Alias(identity: identity, fingerprint: hash))
    }
    /// Compatibility helper for direct callers; compute a patch from this
    /// instance's last observed value before reloading the shared catalog.
    func update(_ track: LibraryTrack) throws {
        guard Self.valid(track) else { throw LibraryError.damagedCatalog }
        guard let old = catalog?.tracks.first(where: { $0.id == track.id }) else { throw LibraryError.missingTrack }
        try apply([LibraryMutation(from: old, to: track)])
    }
    func apply(_ changes: [LibraryMutation]) throws {
        try transaction {
            var next = catalog!
            for change in changes {
                guard let index = next.tracks.firstIndex(where: { $0.id == change.id }) else { throw LibraryError.missingTrack }
                let edited = change.applying(to: next.tracks[index])
                guard Self.valid(edited) else { throw LibraryError.damagedCatalog }
                next.tracks[index] = edited
            }
            try commit(next)
        }
    }

    // MARK: Playlists

    // Saved beside the catalog in `playlists.json`, last writer wins, with the save before it
    // kept as `playlists.backup.json`. Read and written under the catalog's lock, though not
    // with the catalog: a catalog that can't be read doesn't stop playlists being saved.
    private struct PlaylistFile: Codable {
        static let currentVersion = 1
        var version = PlaylistFile.currentVersion
        var playlists: [Playlist]
    }
    private enum PlaylistRead { case missing, lists([Playlist]), newer, unreadable }

    /// What a playlists file holds. Files from before the version was written are a bare list.
    private func readPlaylists(_ url: URL) -> PlaylistRead {
        guard files.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        struct Header: Decodable { let version: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data) {
            if header.version > PlaylistFile.currentVersion { return .newer }
            guard let file = try? JSONDecoder().decode(PlaylistFile.self, from: data) else { return .unreadable }
            return .lists(file.playlists)
        }
        guard let saved = try? JSONDecoder().decode([Playlist].self, from: data) else { return .unreadable }
        return .lists(saved)
    }

    /// Reads the saved playlists. A file that can't be read is copied aside here, before
    /// anything can be written in its place.
    func openPlaylists() throws -> SavedPlaylists {
        try locked {
            func restored() -> SavedPlaylists? {
                guard case .lists(let saved) = readPlaylists(playlistsBackupURL) else { return nil }
                return .restored(saved)
            }
            switch readPlaylists(playlistsURL) {
            case .lists(let saved): return .loaded(saved)
            case .missing: return restored() ?? .loaded([])
            case .newer: return .newer
            case .unreadable:
                let kept = directory.appendingPathComponent("playlists.damaged-\(UUID().uuidString).json")
                do { try files.copyItem(at: playlistsURL, to: kept) } catch { return .stuck }
                return restored() ?? .unreadable(kept: kept.lastPathComponent)
            }
        }
    }

    func savePlaylists(_ next: [Playlist]) throws {
        try locked {
            try autoreleasepool {
                let data = try JSONEncoder().encode(PlaylistFile(playlists: next))
                let onDisk = readPlaylists(playlistsURL)
                // A newer Dex may have saved since this one opened: its playlists stay.
                if case .newer = onDisk { throw LibraryError.newerVersion }
                // The save being replaced becomes the recovery copy, if it still reads.
                if case .lists = onDisk, let previous = try? Data(contentsOf: playlistsURL) {
                    try previous.write(to: playlistsBackupURL, options: .atomic)
                }
                try data.write(to: playlistsURL, options: .atomic)
            }
        }
    }
}

/// A file's names and details, its cover already saved.
struct TagReading: Sendable {
    let artist: String?
    let title: String?
    let details: TrackDetails
}

private actor LibraryAudioWorker {
    private let files = FileManager.default
    private func coordinated<T>(_ source: URL, body: (URL) throws -> T) throws -> T {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result { try body(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LibraryError.importFailed }
        return try result.get()
    }
    private struct Cache: Codable {
        var version = 2
        let duration: Double
        let peaks: [Float]
        let sampleRate: Double
        let frames: Int64
        let step: Int64
        let payload: Data
    }
    func cached(_ url: URL, track: LibraryTrack) throws -> WaveformOverview? {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= WaveformData.maximumBins * WaveformData.bytesPerBin + 128 * 1024 else { return nil }
            let scratch = try AudioMemoryBudget.shared.reserve(Int64(size) * 2 + 128 * 1024)
            defer { withExtendedLifetime(scratch) {} }
            guard let bytes = try? Data(contentsOf: url),
                  let cache = try? PropertyListDecoder().decode(Cache.self, from: bytes),
                  cache.version == 2, cache.duration == track.duration, cache.peaks.count == 2048,
                  cache.peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 4 }),
                  cache.sampleRate.isFinite, cache.sampleRate > 0,
                  abs(Double(cache.frames) / cache.sampleRate - track.duration) < 0.001 else { return nil }
            let waveform: TrackWaveform
            do { waveform = try TrackWaveform.decode(sampleRate: cache.sampleRate, frames: cache.frames, step: cache.step, payload: cache.payload) }
            catch is WaveformData.WaveformError { return nil }
            try Task.checkCancellation()
            return WaveformOverview(duration: cache.duration, peaks: cache.peaks, decodedFrames: 0,
                                    bufferCapacity: 0, detection: track.detection, waveform: waveform)
        }
    }
    func saveCache(_ overview: WaveformOverview, to url: URL) -> String? {
        do {
            try autoreleasepool {
                guard let data = overview.waveform?.data else { return }
                let scratch = try AudioMemoryBudget.shared.reserve(Int64(data.basePayload.count) * 2 + 128 * 1024)
                defer { withExtendedLifetime(scratch) {} }
                var directory = url.deletingLastPathComponent()
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try directory.setResourceValues(resources)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let cache = Cache(duration: overview.duration, peaks: overview.peaks, sampleRate: data.sampleRate,
                                  frames: data.sourceFrames, step: data.framesPerBin, payload: data.basePayload)
                try encoder.encode(cache).write(to: url, options: .atomic)
                try? files.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            }
            return nil
        } catch { return "Audio is available. Its waveform cache could not be saved and will be rebuilt next time." }
    }
    func inspect(_ source: URL) throws -> SourceIdentity {
        try Task.checkCancellation()
        return try coordinated(source) { try SourceIdentity.read($0) }
    }
    func scan(_ url: URL, analyzeRhythm: Bool = true, analyzeKey: Bool = false,
              progress: (@Sendable (Double) -> Void)? = nil) throws -> WaveformOverview {
        try autoreleasepool { try WaveformReader.read(url: url, analyzeRhythm: analyzeRhythm, analyzeKey: analyzeKey, progress: progress) }
    }
    func readKey(_ url: URL) throws -> TrackKey {
        try autoreleasepool { try WaveformReader.readKey(url: url) }
    }
    func readLoudness(_ url: URL) throws -> TrackLoudness {
        try autoreleasepool { try WaveformReader.readLoudness(url: url) }
    }
    func tags(_ url: URL, cover: URL) -> TagReading {
        autoreleasepool {
            let tags = Tags.read(url: url)
            var saved = false
            if let picture = tags.picture, let jpeg = TrackTags.rowCoverJPEG(picture.data) {
                try? files.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
                saved = (try? jpeg.write(to: cover, options: .atomic)) != nil
            }
            return TagReading(artist: tags.artist, title: tags.title,
                              details: TrackDetails(album: tags.album, genre: tags.genre, subgenre: tags.subgenre,
                                                    remixer: tags.remixer, release: tags.release, hasCover: saved))
        }
    }
    func copy(_ source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws -> (hash: String, identity: SourceIdentity) {
        try coordinated(source) { readable in
            let before = try SourceIdentity.read(readable)
            let input = try FileHandle(forReadingFrom: readable); defer { try? input.close() }
            guard files.createFile(atPath: destination.path, contents: nil) else { throw LibraryError.importFailed }
            let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
            var hash = SHA256()
            var written: Int64 = 0
            var reported = 0.0
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
                written += Int64(bytes.count)
                let fraction = min(1, Double(written) / Double(max(1, before.size)))
                if fraction >= reported + 0.05 || fraction == 1 && reported < 1 {
                    reported = fraction
                    progress(fraction)
                }
                return true
            }) {}
            try output.synchronize()
            guard try SourceIdentity.read(readable) == before else { throw LibraryError.sourceChanged }
            return (hash.finalize().map { String(format: "%02x", $0) }.joined(), before)
        }
    }
}
