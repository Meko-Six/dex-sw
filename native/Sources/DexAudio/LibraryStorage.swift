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
    private(set) var recoveredCatalog = false
    private(set) var commitCount = 0
    private(set) var copiedBytes: Int64 = 0
    private let files = FileManager.default
    private let worker = LibraryAudioWorker()
    private var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private var cacheDirectory: URL { directory.appendingPathComponent("Analysis", isDirectory: true) }
    private var catalogURL: URL { directory.appendingPathComponent("Library.json") }
    private var backupURL: URL { directory.appendingPathComponent("Library.backup.json") }
    init(directory: URL) { self.directory = directory }

    /// Lock only short catalog transactions, never provider access or analysis.
    /// Reload under the same OS lock before merging, including across processes.
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try files.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".Library.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try autoreleasepool {
            try reloadCatalog()
            return try body()
        }
    }
    func open() throws -> [LibraryTrack] { try transaction { catalog!.tracks } }
    private func reloadCatalog() throws {
        if files.fileExists(atPath: catalogURL.path) {
            do { catalog = try decodeCatalog(catalogURL) }
            catch LibraryError.newerVersion { throw LibraryError.newerVersion }
            catch {
                guard let recovered = try? decodeCatalog(backupURL) else { throw LibraryError.damagedCatalog }
                try files.copyItem(at: catalogURL, to: directory.appendingPathComponent("Library.damaged-\(UUID().uuidString).json"))
                try encode(recovered).write(to: catalogURL, options: .atomic)
                catalog = recovered
                recoveredCatalog = true
            }
        } else if files.fileExists(atPath: backupURL.path) {
            let recovered = try decodeCatalog(backupURL)
            try encode(recovered).write(to: catalogURL, options: .atomic)
            catalog = recovered
            recoveredCatalog = true
        } else { catalog = Catalog() }
    }
    private func decodeCatalog(_ url: URL) throws -> Catalog {
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else { throw LibraryError.newerVersion }
        let value = try JSONDecoder().decode(Catalog.self, from: data)
        guard Set(value.tracks.map(\.id)).count == value.tracks.count,
              Set(value.tracks.map(\.fingerprint)).count == value.tracks.count,
              value.tracks.allSatisfy(Self.valid) else { throw LibraryError.damagedCatalog }
        return value
    }
    private static func valid(_ track: LibraryTrack) -> Bool {
        track.filename == URL(fileURLWithPath: track.filename).lastPathComponent &&
        !track.filename.isEmpty && track.filename != "." && track.filename != ".." &&
        track.duration.isFinite && track.duration > 0 && track.hotCues.count == 8 &&
        track.hotCues.allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= track.duration) } &&
        track.alternatives.allSatisfy { $0.bpm.isFinite && $0.bpm > 0 && $0.offsetMs.isFinite && $0.salience.isFinite } &&
        (track.key.map { $0.confidence.isFinite && (0...1).contains($0.confidence) } ?? true)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func commit(_ next: Catalog) throws {
        let data = try encode(next)
        if let previous = catalog {
            // Never leave the first durable import with an empty recovery copy.
            let recovery = previous.tracks.isEmpty && !next.tracks.isEmpty ? next : previous
            try encode(recovery).write(to: backupURL, options: .atomic)
        }
        try data.write(to: catalogURL, options: .atomic)
        catalog = next
        commitCount += 1
    }
    private func cacheURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent(id.uuidString + ".waveform") }
    nonisolated func coverURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Analysis", isDirectory: true).appendingPathComponent(id.uuidString + ".cover.jpg")
    }
    private func saveCache(_ overview: WaveformOverview, id: UUID) async -> String? {
        await worker.saveCache(overview, to: cacheURL(id))
    }
    func prepare(_ id: UUID) async throws -> PreparedLibraryTrack {
        let tracks = try open()
        try Task.checkCancellation()
        guard let track = tracks.first(where: { $0.id == id }) else { throw LibraryError.missingTrack }
        let url = audioDirectory.appendingPathComponent(track.filename)
        guard files.fileExists(atPath: url.path) else { throw LibraryError.missingAudio }
        let cached = try await worker.cached(cacheURL(id), track: track)
        if let cached {
            let current = try open().first(where: { $0.id == id }) ?? track
            return PreparedLibraryTrack(track: current, url: url, overview: cached)
        }
        let scanned = try await worker.scan(url, analyzeRhythm: false)
        try Task.checkCancellation()
        let warning = await saveCache(scanned, id: id)
        let current = try open().first(where: { $0.id == id }) ?? track
        return PreparedLibraryTrack(track: current, url: url, overview: scanned, warning: warning)
    }
    func importFile(_ source: URL) async throws -> PreparedLibraryTrack {
        _ = try open()
        try Task.checkCancellation()
        let identity = try await worker.inspect(source)
        let existing: LibraryTrack? = try transaction {
            guard let alias = catalog!.sources.first(where: { $0.identity == identity }),
                  let track = catalog!.tracks.first(where: { $0.fingerprint == alias.fingerprint }),
                  let size = try? audioDirectory.appendingPathComponent(track.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == identity.size else { return nil }
            return track
        }
        if let existing { return try await prepare(existing.id) }
        let ext = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(12))
        let staging = audioDirectory.appendingPathComponent(".import-\(UUID().uuidString)" + suffix)
        defer { try? files.removeItem(at: staging) }
        let copied = try await worker.copy(source, to: staging)
        copiedBytes += copied.identity.size
        try Task.checkCancellation()
        let duplicate = try open().first(where: { $0.fingerprint == copied.hash })
        let scanned: WaveformOverview
        if let duplicate {
            // Repair missing audio before cache preparation, under the catalog lock.
            try transaction {
                let destination = audioDirectory.appendingPathComponent(duplicate.filename)
                if !files.fileExists(atPath: destination.path) { try files.moveItem(at: staging, to: destination) }
                var next = catalog!; remember(copied.identity, hash: copied.hash, in: &next); try commit(next)
            }
            return try await prepare(duplicate.id)
        }
        scanned = try await worker.scan(staging, analyzeKey: true)
        let id = UUID()
        let tags = await worker.tags(staging, cover: coverURL(id))
        try Task.checkCancellation()
        let candidate = LibraryTrack(id: id, fingerprint: copied.hash, filename: id.uuidString + suffix,
                                     title: source.deletingPathExtension().lastPathComponent, duration: scanned.duration,
                                     grid: scanned.detection.grid, gridUncertain: scanned.detection.uncertain,
                                     alternatives: scanned.detection.alternatives, hotCues: Array(repeating: nil, count: 8), importedAt: Date(),
                                     key: scanned.key, artist: tags.artist, tagTitle: tags.title, details: tags.details)
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
    func scan(_ url: URL, analyzeRhythm: Bool = true, analyzeKey: Bool = false) throws -> WaveformOverview {
        try autoreleasepool { try WaveformReader.read(url: url, analyzeRhythm: analyzeRhythm, analyzeKey: analyzeKey) }
    }
    func readKey(_ url: URL) throws -> TrackKey {
        try autoreleasepool { try WaveformReader.readKey(url: url) }
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
    func copy(_ source: URL, to destination: URL) throws -> (hash: String, identity: SourceIdentity) {
        try coordinated(source) { readable in
            let before = try SourceIdentity.read(readable)
            let input = try FileHandle(forReadingFrom: readable); defer { try? input.close() }
            guard files.createFile(atPath: destination.path, contents: nil) else { throw LibraryError.importFailed }
            let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
            var hash = SHA256()
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
                return true
            }) {}
            try output.synchronize()
            guard try SourceIdentity.read(readable) == before else { throw LibraryError.sourceChanged }
            return (hash.finalize().map { String(format: "%02x", $0) }.joined(), before)
        }
    }
}
