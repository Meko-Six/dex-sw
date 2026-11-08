import Foundation
import Combine
import DexCore

/// One coalescing writer, independent of the audio preparation lane. Dirty and
/// in-flight field patches preserve edits across failures and catalog refreshes.
@MainActor
public final class NativeLibrary: ObservableObject {
    @Published public private(set) var tracks: [LibraryTrack] = []
    @Published private var operationError: String?
    @Published private var saveError: String?
    @Published public private(set) var notice: String?
    private var recoveryNotice: String?
    public var error: String? { saveError ?? operationError }
    /// The last save failed; `retrySave()` tries again.
    public var saveFailed: Bool { saveError != nil }
    @Published public private(set) var saving = false
    @Published public private(set) var importing = false
    @Published public private(set) var pendingImports: [PendingImport] = []
    public struct PendingImport: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public fileprivate(set) var progress: ImportProgress
        fileprivate let source: URL
    }
    public enum ImportProgress: Sendable {
        case queued, opening, copying(Double), analysing(Double), saving

        public var fraction: Double {
            switch self {
            case .queued: 0
            case .opening: 0.03
            case .copying(let fraction): 0.05 + 0.14 * fraction
            case .analysing(let fraction): 0.20 + 0.70 * fraction
            case .saving: 0.95
            }
        }

        public var label: String {
            switch self {
            case .queued: "Queued"
            case .opening: "Opening"
            case .copying: "Copying"
            case .analysing: "Analysing"
            case .saving: "Saving"
            }
        }
    }
    /// FIND KEYS' place in its run, nil when it isn't running.
    @Published public private(set) var findingKeys: KeyProgress?
    public struct KeyProgress: Equatable, Sendable {
        public let current: Int, total: Int, title: String
    }
    /// The track RE-ANALYSE is working on.
    @Published public private(set) var analysing: String?
    @Published public private(set) var ready = false
    /// Saved beside the catalog in `playlists.json`, last writer wins.
    @Published public private(set) var playlists: [Playlist] = []
    private let storage: LibraryStorage
    private let playlistsURL: URL
    private var opening: Task<[LibraryTrack], Error>?
    private var writer: Task<Void, Never>?
    private var dirty: [UUID: LibraryMutation] = [:]
    private var inFlight: [UUID: LibraryMutation] = [:]
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var lastImportTask: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var tagTask: Task<Void, Never>?
    private var loudnessTask: Task<Void, Never>?
    private struct ImportFlight {
        let id: UUID
        let task: Task<PreparedLibraryTrack, Error>
        var waiters: Set<UUID>
    }
    private var flights: [URL: ImportFlight] = [:]

    public init(directory: URL? = nil) {
        let name = Bundle.main.bundleURL.pathExtension == "app" ? "DexNative" : "DexNativePreview"
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        storage = LibraryStorage(directory: root)
        playlistsURL = root.appendingPathComponent("playlists.json")
    }
    private func overlay(_ track: LibraryTrack) -> LibraryTrack {
        let saved = inFlight[track.id]?.applying(to: track) ?? track
        return dirty[track.id]?.applying(to: saved) ?? saved
    }
    public func open() async {
        do {
            if ready { tracks = try await storage.open().map(overlay) }
            else { try await ensureOpen() }
            operationError = nil
        } catch { operationError = error.localizedDescription }
    }
    private func ensureOpen() async throws {
        if ready { return }
        if opening == nil { opening = Task { try await storage.open() } }
        do {
            let loaded = try await opening!.value
            if !ready {
                tracks = loaded; ready = true
                loadPlaylists()
                if await storage.recoveredCatalog {
                    recoveryNotice = "Library restored from its previous save. Check your most recent edits."
                    notice = recoveryNotice
                }
            }
        } catch { opening = nil; throw error }
    }
    func prepare(url: URL) async throws -> PreparedLibraryTrack {
        try Task.checkCancellation()
        let key = url.standardizedFileURL
        if flights[key] == nil {
            let id = showImport(url)
            let task = Task { [weak self, storage] in
                guard let self else { throw CancellationError() }
                try await ensureOpen()
                return try await storage.importFile(url, id: id) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.updateImport(id, progress: progress) }
                }
            }
            flights[key] = ImportFlight(id: id, task: task, waiters: [])
        }
        let waiter = UUID()
        flights[key]!.waiters.insert(waiter)
        let flight = flights[key]!
        defer { releaseImport(key, flight: flight.id, waiter: waiter) }
        let prepared = try await withTaskCancellationHandler { try await flight.task.value } onCancel: {
            Task { @MainActor [weak self] in self?.releaseImport(key, flight: flight.id, waiter: waiter) }
        }
        try Task.checkCancellation()
        hideImport(flight.id)
        return merge(prepared)
    }
    private func showImport(_ url: URL) -> UUID {
        let source = url.standardizedFileURL
        if let row = pendingImports.first(where: { $0.source == source }) { return row.id }
        let row = pendingImport(source)
        pendingImports.append(row)
        return row.id
    }
    private func pendingImport(_ source: URL) -> PendingImport {
        PendingImport(id: UUID(), title: source.deletingPathExtension().lastPathComponent, progress: .queued, source: source)
    }
    private func hideImport(_ id: UUID) {
        if let index = pendingImports.firstIndex(where: { $0.id == id }) { pendingImports.remove(at: index) }
    }
    private func updateImport(_ id: UUID, progress: ImportProgress) {
        guard let index = pendingImports.firstIndex(where: { $0.id == id }),
              pendingImports[index].progress.fraction < progress.fraction else { return }
        pendingImports[index].progress = progress
    }
    private func releaseImport(_ key: URL, flight: UUID, waiter: UUID) {
        guard var current = flights[key], current.id == flight else { return }
        current.waiters.remove(waiter)
        if current.waiters.isEmpty {
            current.task.cancel(); flights[key] = nil
            hideImport(flight)
        } else { flights[key] = current }
    }
    var importWaiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    var importedBytes: Int64 { get async { await storage.copiedBytes } }
    func prepare(id: UUID) async throws -> PreparedLibraryTrack {
        try await ensureOpen()
        return merge(try await storage.prepare(id))
    }
    private func merge(_ prepared: PreparedLibraryTrack) -> PreparedLibraryTrack {
        var prepared = prepared
        prepared.track = overlay(prepared.track)
        if let index = tracks.firstIndex(where: { $0.id == prepared.track.id }) { tracks[index] = prepared.track }
        else { tracks.append(prepared.track) }
        notice = prepared.warning ?? recoveryNotice
        return prepared
    }
    public func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !Task.isCancelled else { return }
        if !importing { importing = true }
        var sources = Set(pendingImports.map(\.source))
        let queued = urls.map(\.standardizedFileURL).filter { sources.insert($0).inserted }.map(pendingImport)
        pendingImports += queued
        let pending = Set(queued.map(\.id))
        let batch = UUID()
        defer {
            pendingImports.removeAll { pending.contains($0.id) && flights[$0.source] == nil }
            importTasks[batch] = nil
            if importTasks.isEmpty { lastImportTask = nil; importing = false }
        }
        let task = Task { [weak self, previous = lastImportTask] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var failures: [String] = []
            for url in urls {
                do { try Task.checkCancellation(); _ = try await prepare(url: url) }
                catch is CancellationError { break }
                catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            operationError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
        importTasks[batch] = task
        lastImportTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    public func handleMemoryPressure() {
        for task in importTasks.values { task.cancel() }
        keyTask?.cancel(); tagTask?.cancel(); loudnessTask?.cancel()
    }
    /// Tracks the key analysis has not run on yet.
    public var tracksNeedingKeys: Int { tracks.filter { $0.key == nil }.count }
    /// FIND KEYS: reads the key of every track without one, one at a time.
    /// Unlike the Electron app's, it reads only the key, so grids and cues
    /// edited by hand stay as they are.
    public func findKeys() async {
        guard findingKeys == nil else { return }
        let pending = tracks.filter { $0.key == nil }.map(\.id)
        guard !pending.isEmpty else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for (index, id) in pending.enumerated() {
                // Re-read it: an earlier save or import may have changed it.
                guard !Task.isCancelled, let track = tracks.first(where: { $0.id == id }), track.key == nil else { continue }
                findingKeys = KeyProgress(current: index + 1, total: pending.count, title: track.label)
                do { setKey(id, try await storage.readKey(id)) }
                catch is CancellationError { break }
                catch { failures.append(track.label + ": " + error.localizedDescription) }
            }
            operationError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
        keyTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        keyTask = nil; findingKeys = nil
    }
    /// Reads the tags of tracks saved before MORE, one at a time and quietly:
    /// a file that can't be read now is tried again next launch.
    public func readMissingTags() async {
        do { try await ensureOpen() } catch { return }
        guard tagTask == nil else { return }
        let pending = tracks.filter { $0.details?.version != TrackDetails.currentVersion }.map(\.id)
        guard !pending.isEmpty else { return }
        let task = Task(priority: .utility) { [weak self] in
            for id in pending {
                guard !Task.isCancelled, let self, let reading = try? await storage.readTags(id) else { continue }
                fill(id, reading)
            }
        }
        tagTask = task
        await task.value
        tagTask = nil
    }
    /// Measures the loudness of tracks saved before AUTO trim, one at a time
    /// and quietly: a file that can't be read now is tried again next launch.
    public func readMissingLoudness() async {
        do { try await ensureOpen() } catch { return }
        guard loudnessTask == nil else { return }
        let pending = tracks.filter { $0.loudness == nil }.map(\.id)
        guard !pending.isEmpty else { return }
        let task = Task(priority: .utility) { [weak self] in
            for id in pending {
                guard !Task.isCancelled, let self, let loudness = try? await storage.readLoudness(id) else { continue }
                setLoudness(id, loudness)
            }
        }
        loudnessTask = task
        await task.value
        loudnessTask = nil
    }
    /// TRIM moved by hand: remembered for the track. Nil, or the AUTO value, plays it at AUTO again.
    public func setTrim(_ id: UUID, _ db: Double?) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let old = tracks[index]
        var updated = old
        let auto = old.loudness?.autoTrim()
        updated.trimDb = db.flatMap { abs($0 - (auto ?? 0)) < 0.05 ? nil : (abs($0) <= 12 && $0.isFinite ? $0 : nil) }
        commit(old, updated)
    }
    private func setLoudness(_ id: UUID, _ loudness: TrackLoudness) {
        guard let old = tracks.first(where: { $0.id == id }) else { return }
        var updated = old; updated.loudness = loudness
        commit(old, updated)
    }
    /// A track's saved cover, if it has one.
    public func coverURL(_ track: LibraryTrack) -> URL? {
        track.details?.hasCover == true ? storage.coverURL(track.id) : nil
    }
    private func fill(_ id: UUID, _ reading: TagReading) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let old = tracks[index]
        var updated = old
        updated.artist = old.artist ?? reading.artist
        updated.tagTitle = old.tagTitle ?? reading.title
        updated.details = reading.details
        commit(old, updated)
    }
    private func commit(_ old: LibraryTrack, _ updated: LibraryTrack) {
        let mutation = LibraryMutation(from: old, to: updated)
        guard !mutation.isEmpty, let index = tracks.firstIndex(where: { $0.id == old.id }) else { return }
        dirty[old.id] = dirty[old.id]?.merging(mutation) ?? mutation
        tracks[index] = updated
        startWriter()
    }
    /// RE-ANALYSE: the whole analysis again, as Electron's. The grid, its other
    /// readings and the key are replaced, hand-edited grids included; hot cues
    /// stay. Returns the track so decks holding it can follow.
    public func reanalyze(_ id: UUID) async -> LibraryTrack? {
        guard analysing == nil, let track = tracks.first(where: { $0.id == id }) else { return nil }
        analysing = track.label
        defer { analysing = nil }
        do {
            let result = try await storage.reanalyze(id)
            guard let old = tracks.first(where: { $0.id == id }) else { return nil }
            var updated = old
            updated.grid = result.overview.detection.grid
            updated.gridUncertain = result.overview.detection.uncertain
            updated.alternatives = result.overview.detection.alternatives
            updated.key = result.overview.key
            updated.loudness = result.overview.loudness ?? old.loudness
            updated.artist = old.artist ?? result.tags.artist
            updated.tagTitle = old.tagTitle ?? result.tags.title
            updated.details = result.tags.details
            commit(old, updated)
            operationError = nil
            return updated
        } catch is CancellationError {
            return nil
        } catch {
            operationError = track.label + ": " + error.localizedDescription
            return nil
        }
    }
    /// REMOVE: deletes the track's copy, cache and cover, and takes it out of
    /// every playlist. The original file wherever it was imported from stays.
    public func remove(_ id: UUID) async {
        await flush()
        dirty[id] = nil
        do {
            try await storage.remove(id)
            tracks.removeAll { $0.id == id }
            setPlaylists(Playlists.forget(playlists, track: id.uuidString))
            operationError = nil
        } catch { operationError = "The track could not be removed: " + error.localizedDescription }
    }
    /// Shows a reason an action was refused, like any library problem.
    public func report(_ message: String) { operationError = message }
    /// A load fills the names the track lacks from the file's tags, as
    /// `loadToDeck` does; names it already has stay.
    func fillNames(_ id: UUID, artist: String?, title: String?) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let old = tracks[index]
        guard (artist != nil && old.artist == nil) || (title != nil && old.tagTitle == nil) else { return }
        var updated = old; updated.artist = old.artist ?? artist; updated.tagTitle = old.tagTitle ?? title
        let mutation = LibraryMutation(from: old, to: updated)
        dirty[id] = dirty[id]?.merging(mutation) ?? mutation
        tracks[index] = updated
        startWriter()
    }
    private func setKey(_ id: UUID, _ key: TrackKey) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tracks[index]; updated.key = key
        let mutation = LibraryMutation(from: tracks[index], to: updated)
        guard !mutation.isEmpty else { return }
        dirty[id] = dirty[id]?.merging(mutation) ?? mutation
        tracks[index] = updated
        startWriter()
    }
    func edit(_ id: UUID, grid: BeatGrid?, uncertain: Bool, hotCues: [Double?]) {
        guard hotCues.count == 8, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let old = tracks[index]
        var updated = old; updated.grid = grid; updated.gridUncertain = uncertain; updated.hotCues = hotCues
        let mutation = LibraryMutation(from: old, to: updated)
        guard !mutation.isEmpty else { return }
        dirty[id] = dirty[id]?.merging(mutation) ?? mutation
        tracks[index] = updated
        startWriter()
    }
    private func startWriter() {
        guard writer == nil, !dirty.isEmpty else { return }
        saving = true
        writer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            await self?.drain()
        }
    }
    private func drain() async {
        while !dirty.isEmpty {
            inFlight = dirty; dirty.removeAll(keepingCapacity: true)
            do {
                try await storage.apply(Array(inFlight.values))
                inFlight.removeAll(keepingCapacity: true)
                saveError = nil
            } catch {
                for (id, older) in inFlight { dirty[id] = older.merging(dirty[id]) }
                inFlight.removeAll(keepingCapacity: true)
                saveError = "Library changes could not be saved: " + error.localizedDescription
                break
            }
        }
        writer = nil; saving = false
    }
    public func retrySave() { startWriter() }

    // MARK: Playlists

    private func loadPlaylists() {
        guard let data = try? Data(contentsOf: playlistsURL),
              let saved = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = Playlists.normalize(saved, known: Set(tracks.map(\.id.uuidString)))
    }

    private func setPlaylists(_ next: [Playlist]) {
        guard next != playlists else { return }
        playlists = next
        do {
            try FileManager.default.createDirectory(at: playlistsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: playlistsURL, options: .atomic)
        } catch { operationError = "Playlists could not be saved: " + error.localizedDescription }
    }

    /// Makes an empty playlist and returns its id.
    @discardableResult public func createPlaylist(named name: String = Playlists.defaultName) -> String {
        let id = "pl-" + UUID().uuidString
        setPlaylists(Playlists.create(playlists, id: id, name: name))
        return id
    }
    public func renamePlaylist(_ id: String, to name: String) { setPlaylists(Playlists.rename(playlists, id: id, to: name)) }
    public func deletePlaylist(_ id: String) { setPlaylists(Playlists.delete(playlists, id: id)) }
    public func addToPlaylist(_ id: String, tracks: [UUID]) { setPlaylists(Playlists.add(playlists, id: id, tracks: tracks.map(\.uuidString))) }
    public func removeFromPlaylist(_ id: String, track: UUID) { setPlaylists(Playlists.remove(playlists, id: id, track: track.uuidString)) }
    public func flush() async { startWriter(); await writer?.value }
    var persistenceCommits: Int { get async { await storage.commitCount } }
}
