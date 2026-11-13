import XCTest
import AVFoundation
import Combine
@testable import DexAudio
import DexCore

final class LibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexLibraryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func audio(in root: URL, seconds: Int = 2) throws -> URL {
        let url = root.appendingPathComponent("Original track.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for second in 0..<seconds {
            for frame in 0..<44_100 {
                let time = Double(second) + Double(frame) / 44_100
                let phase = (time - 0.173).truncatingRemainder(dividingBy: 0.5)
                buffer.floatChannelData![0][frame] = time >= 0.173 && phase >= 0 && phase < 0.035
                    ? Float(sin(2 * .pi * 70 * phase) * exp(-phase * 100)) * 0.8 : 0
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testImportedAudioAndDetectedGridSurviveFreshStoreAndOriginalDeletion() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root, seconds: 24)
        let directory = root.appendingPathComponent("Library")
        let first = LibraryStorage(directory: directory)
        let imported = try await first.importFile(source)
        XCTAssertNotNil(imported.track.grid)
        XCTAssertEqual(imported.track.grid!.bpm, 120, accuracy: 0.5)
        XCTAssertEqual(imported.overview.peaks.count, 2048)
        XCTAssertNotEqual(imported.url, source)
        try FileManager.default.removeItem(at: source)
        let fresh = LibraryStorage(directory: directory)
        let restored = try await fresh.prepare(imported.track.id)
        XCTAssertEqual(restored.track, imported.track)
        XCTAssertEqual(restored.overview.peaks, imported.overview.peaks)
        XCTAssertEqual(restored.overview.waveform?.data.basePayload, imported.overview.waveform?.data.basePayload)
        XCTAssertNotNil(restored.overview.waveform)
        XCTAssertEqual(restored.overview.decodedFrames, 0, "A valid cache must avoid another decode/analysis")
        let file = try AVAudioFile(forReading: restored.url)
        XCTAssertEqual(file.length, 24 * 44_100)
    }

    func testManualEditsSurviveContainerRelocationAndCacheRebuild() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root)
        let original = root.appendingPathComponent("FirstContainer")
        let storage = LibraryStorage(directory: original)
        let imported = try await storage.importFile(source)
        var edited = imported.track
        edited.grid = try BeatGrid(bpm: 127.25, offsetMs: -42, confidence: 1)
        edited.gridUncertain = false
        edited.hotCues[0] = 0
        edited.hotCues[7] = 1.75
        try await storage.update(edited)
        let moved = root.appendingPathComponent("RestoredContainer")
        try FileManager.default.moveItem(at: original, to: moved)
        let cache = moved.appendingPathComponent("Analysis/\(edited.id.uuidString).waveform")
        try Data("damaged cache".utf8).write(to: cache)
        try FileManager.default.removeItem(at: source)
        let fresh = LibraryStorage(directory: moved)
        let restored = try await fresh.prepare(edited.id)
        XCTAssertEqual(restored.track, edited)
        XCTAssertGreaterThan(restored.overview.decodedFrames, 0)
        XCTAssertTrue(restored.url.path.hasPrefix(moved.path))
        let cached = try await fresh.prepare(edited.id)
        XCTAssertEqual(cached.overview.decodedFrames, 0)
        XCTAssertEqual(cached.track.grid, edited.grid)
    }

    func testLegacyPeakCacheUpgradesWithoutChangingSavedMetadata() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStorage(directory: directory)
        let imported = try await store.importFile(audio(in: root))
        var edited = imported.track
        edited.grid = try BeatGrid(bpm: 128, offsetMs: 17, confidence: 1)
        edited.hotCues[2] = 1.25
        try await store.update(edited)
        let base = directory.appendingPathComponent("Analysis/" + edited.id.uuidString)
        try FileManager.default.removeItem(at: base.appendingPathExtension("waveform"))
        let legacy = base.appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "duration": edited.duration, "peaks": imported.overview.peaks]).write(to: legacy)
        let restored = try await LibraryStorage(directory: directory).prepare(edited.id)
        XCTAssertEqual(restored.track, edited)
        XCTAssertGreaterThan(restored.overview.decodedFrames, 0)
        XCTAssertNotNil(restored.overview.waveform)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let cached = try await LibraryStorage(directory: directory).prepare(edited.id)
        XCTAssertEqual(cached.overview.decodedFrames, 0)
        XCTAssertEqual(cached.track, edited)
    }

    func testMetadataCommittedDuringCacheDecodeWinsOverEarlierSnapshot() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStorage(directory: directory)
        let imported = try await store.importFile(audio(in: root))
        let url = directory.appendingPathComponent("Analysis/" + imported.track.id.uuidString + ".waveform")
        // A valid, dense cache keeps the independent worker occupied while the
        // catalog actor accepts an edit. No timing hook in production code.
        var cache = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        cache["step"] = 1
        cache["payload"] = Data(repeating: 0, count: Int(imported.overview.waveform!.data.sourceFrames) * WaveformData.bytesPerBin)
        try PropertyListSerialization.data(fromPropertyList: cache, format: .binary, options: 0).write(to: url)
        let before = AudioMemoryBudget.shared.reservedBytes
        let preparing = Task { try await store.prepare(imported.track.id) }
        for _ in 0..<500 where AudioMemoryBudget.shared.reservedBytes == before { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThan(AudioMemoryBudget.shared.reservedBytes, before, "Cache decode must have started")
        var edited = imported.track
        edited.grid = try BeatGrid(bpm: 133, offsetMs: 42, confidence: 1)
        edited.hotCues[5] = 0.75
        try await store.update(edited)
        let result = try await preparing.value
        XCTAssertEqual(result.overview.decodedFrames, 0)
        XCTAssertEqual(result.track, edited, "Finishing cache work must not restore stale grid/cue metadata")
    }

    func testDuplicateByContentKeepsEditsAndRepairsMissingManagedAudio() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root)
        let directory = root.appendingPathComponent("Library")
        let storage = LibraryStorage(directory: directory)
        let imported = try await storage.importFile(source)
        var edited = imported.track
        edited.hotCues[3] = 1.25
        edited.grid = try BeatGrid(bpm: 99, offsetMs: 25, confidence: 1)
        try await storage.update(edited)
        let renamed = root.appendingPathComponent("Different name.wav")
        try FileManager.default.copyItem(at: source, to: renamed)
        let duplicate = try await storage.importFile(renamed)
        XCTAssertEqual(duplicate.track, edited)
        let all = try await storage.open()
        XCTAssertEqual(all.count, 1)
        try FileManager.default.removeItem(at: imported.url)
        do {
            _ = try await storage.prepare(edited.id)
            XCTFail("Missing audio must be reported without discarding metadata")
        } catch { XCTAssertEqual(error as? LibraryError, .missingAudio) }
        let repaired = try await storage.importFile(renamed)
        XCTAssertEqual(repaired.track, edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.url.path))
        let items = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Audio").path)
        XCTAssertEqual(items, [edited.filename])
    }

    func testDamagedCatalogRecoversPreviousAtomicSaveAndPreservesDamagedBytes() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root)
        let directory = root.appendingPathComponent("Library")
        let storage = LibraryStorage(directory: directory)
        let imported = try await storage.importFile(source)
        var edited = imported.track
        edited.hotCues[2] = 0.75
        try await storage.update(edited)
        // The previous catalog is deliberately one transaction behind.
        let badBytes = Data("interrupted/corrupt storage".utf8)
        try badBytes.write(to: directory.appendingPathComponent("Library.json"))
        let fresh = LibraryStorage(directory: directory)
        let recovered = try await fresh.open()
        XCTAssertEqual(recovered, [imported.track])
        let damaged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Library.damaged-") }
        XCTAssertNotNil(damaged)
        XCTAssertEqual(try Data(contentsOf: damaged!), badBytes)
        let playable = try await fresh.prepare(imported.track.id)
        XCTAssertEqual(playable.track, imported.track)
    }

    func testUnreadableOrFutureCatalogIsNeverOverwritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [Data("bad catalog".utf8), Data("{\"version\":99,\"tracks\":[]}".utf8)] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let catalog = directory.appendingPathComponent("Library.json")
            try bytes.write(to: catalog)
            let storage = LibraryStorage(directory: directory)
            do { _ = try await storage.open(); XCTFail("Must report catalog failure") }
            catch { XCTAssertTrue(error is LibraryError) }
            XCTAssertEqual(try Data(contentsOf: catalog), bytes)
        }
    }

    func testUnsupportedAndCancelledImportsLeaveNoPartialTrack() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let storage = LibraryStorage(directory: directory)
        let bad = root.appendingPathComponent("Bad.wav")
        try Data("not audio".utf8).write(to: bad)
        do { _ = try await storage.importFile(bad); XCTFail("Invalid audio must fail") } catch {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await storage.importFile(bad)
        }
        do { _ = try await task.value; XCTFail("Cancelled imports must not commit") } catch is CancellationError {}
        let remaining = try await storage.open()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Audio").path).isEmpty)
    }

    @MainActor
    func testImportRowsShowQueuedFilesAndProgressUntilReady() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root, seconds: 12)
        let bad = root.appendingPathComponent("Bad.wav")
        try Data("not audio".utf8).write(to: bad)
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))

        var queued: [NativeLibrary.PendingImport] = []
        var progress: [Double] = []
        let observation = library.$pendingImports.sink { rows in
            if queued.isEmpty { queued = rows }
            if let first = rows.first, first.id == queued.first?.id { progress.append(first.progress.fraction) }
        }
        defer { observation.cancel() }

        await library.importFiles([source, bad])

        XCTAssertEqual(queued.map(\.title), ["Original track", "Bad"])
        XCTAssertEqual(queued.map { $0.progress.fraction }, [0, 0])
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertTrue(progress.contains { $0 > 0.20 && $0 < 0.90 })
        XCTAssertEqual(library.tracks.map(\.id), queued.prefix(1).map(\.id))
        XCTAssertTrue(library.pendingImports.isEmpty)
        guard case .batchFailed(let failed) = library.error else { return XCTFail("Expected a failed batch, got \(String(describing: library.error))") }
        XCTAssertEqual(failed.map(\.name), ["Bad.wav"])
    }

    @MainActor
    func testDeckEditsShareAcrossDecksAndRestoreOnFreshLaunch() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root)
        let directory = root.appendingPathComponent("Library")
        let library = NativeLibrary(directory: directory)
        let mixer = NativeMixer(library: library)
        defer { mixer.shutdown() }
        mixer.a.load(source)
        try await loaded(mixer.a)
        let id = try XCTUnwrap(mixer.a.libraryTrackID)
        mixer.b.loadTrack(id)
        try await loaded(mixer.b)
        mixer.a.setGrid(bpm: 123.45, offsetMs: -17.5)
        mixer.a.seek(to: 0.5)
        mixer.a.hotCue(0)
        mixer.b.seek(to: 1.25)
        mixer.b.hotCue(7)
        mixer.a.hotCue(0, clear: true)
        mixer.a.seek(to: 0)
        mixer.a.hotCue(1)
        XCTAssertEqual(mixer.b.grid, mixer.a.grid)
        XCTAssertEqual(mixer.a.hotCues, mixer.b.hotCues)
        XCTAssertNil(mixer.b.hotCues[0])
        XCTAssertEqual(mixer.b.hotCues[1]!, 60 / 123.45 - 0.0175, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.hotCues[7]!, 180 / 123.45 - 0.0175, accuracy: 1e-9)
        await library.flush()
        XCTAssertFalse(library.saving)
        XCTAssertNil(library.error)
        mixer.shutdown()
        try FileManager.default.removeItem(at: source)
        let reopened = NativeLibrary(directory: directory)
        let next = NativeMixer(library: reopened)
        defer { next.shutdown() }
        next.a.loadTrack(id)
        try await loaded(next.a)
        XCTAssertEqual(next.a.name, "Original track")
        XCTAssertEqual(next.a.grid?.bpm, 123.45)
        XCTAssertEqual(next.a.grid?.offsetMs, -17.5)
        XCTAssertEqual(next.a.hotCues, mixer.b.hotCues)
        XCTAssertEqual(next.a.hotCues[1]!, 60 / 123.45 - 0.0175, accuracy: 1e-9)
        XCTAssertEqual(next.a.hotCues[7]!, 180 / 123.45 - 0.0175, accuracy: 1e-9)
        XCTAssertEqual(reopened.tracks.count, 1)
        try next.enableOfflineRendering()
        next.start()
        XCTAssertNil(next.error)
        next.a.togglePlay()
        let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
                                     frameCapacity: 1024)!
        var peak: Float = 0
        for _ in 0..<50 {
            if try next.renderOffline(into: output) == .success {
                for i in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][i])) }
            }
        }
        XCTAssertGreaterThan(peak, 0.01, "A restored library track must still produce audio without its original file")
        next.a.loadTrack(id)
        XCTAssertEqual(next.a.error, .playingBlocksLoad)
    }
    func testConcurrentImportsCommitOnlyOneIdentity() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root, seconds: 24)
        let directory = root.appendingPathComponent("Library")
        let storage = LibraryStorage(directory: directory)
        async let first = storage.importFile(source)
        async let second = storage.importFile(source)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.track.id, b.track.id)
        let all = try await storage.open()
        XCTAssertEqual(all.count, 1)
        let managedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Audio").path)
        XCTAssertEqual(managedFiles, [a.track.filename])
    }

    func testAnUnchangedCatalogIsNotDecodedAgain() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let first = try await LibraryStorage(directory: directory).importFile(audio(in: root))
        // A store that has never seen the catalog reads it once, then not again while it stays as it is.
        let store = LibraryStorage(directory: directory)
        _ = try await store.open()
        let opened = await store.decodeCount
        XCTAssertEqual(opened, 1)
        for _ in 0..<5 { _ = try await store.open() }
        _ = try await store.prepare(first.track.id)
        let source = root.appendingPathComponent("Second.wav")
        try FileManager.default.copyItem(at: try audio(in: root, seconds: 3), to: source)
        let second = try await store.importFile(source)
        XCTAssertNotEqual(second.track.id, first.track.id)
        var edited = second.track; edited.hotCues[4] = 1.5
        try await store.update(edited)
        let all = try await store.open()
        XCTAssertEqual(all.map(\.id), [first.track.id, second.track.id])
        let after = await store.decodeCount
        XCTAssertEqual(after, opened, "Opening, preparing, importing and editing must not read the whole catalog again")
        // What it holds is still what a store reading from scratch finds.
        let fresh = try await LibraryStorage(directory: directory).open()
        XCTAssertEqual(fresh, all)
        XCTAssertEqual(fresh.last?.hotCues[4], 1.5)
    }

    func testASecondStoreStillSeesEveryCommitOfTheFirst() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let a = LibraryStorage(directory: directory), b = LibraryStorage(directory: directory)
        let imported = try await a.importFile(audio(in: root))
        let seen = try await b.open()
        XCTAssertEqual(seen, [imported.track])
        let settled = await b.decodeCount
        // Every commit by the other store is read, once each, however alike the files are:
        // these differ by one digit, so size alone would not tell them apart.
        for round in 1...6 {
            var edited = imported.track; edited.hotCues[0] = Double(round % 2 == 0 ? 1 : 2)
            try await a.update(edited)
            let now = try await b.open()
            XCTAssertEqual(now.first?.hotCues[0], edited.hotCues[0], "Round \(round)")
            _ = try await b.open()
        }
        let after = await b.decodeCount
        XCTAssertEqual(after - settled, 6, "One read for each commit, none for the opens between")
        // And the other way: the first store, which wrote last, sees the second's commit.
        let current = try await b.open()
        var fromB = try XCTUnwrap(current.first); fromB.hotCues[7] = 0.5
        try await b.update(fromB)
        let back = try await a.open()
        XCTAssertEqual(back.first?.hotCues[7], 0.5)
        XCTAssertEqual(back.first?.hotCues[0], 1, "Merged with its own last edit, not written over it")
        // A catalog changed in place, as a restore from a backup tool might, is read again too.
        let catalog = directory.appendingPathComponent("Library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        json["tracks"] = [[String: Any]]()
        let handle = try FileHandle(forWritingTo: catalog)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: json))
        try handle.close()
        let emptied = try await a.open()
        XCTAssertTrue(emptied.isEmpty)
    }

    @MainActor
    func testSaveFailureRetainsEditsAndRetryPersistsThem() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audio(in: root)
        let directory = root.appendingPathComponent("Library")
        let library = NativeLibrary(directory: directory)
        let mixer = NativeMixer(library: library)
        defer { mixer.shutdown() }
        mixer.a.load(source)
        try await loaded(mixer.a)
        let id = try XCTUnwrap(mixer.a.libraryTrackID)
        let catalog = directory.appendingPathComponent("Library.json")
        try FileManager.default.removeItem(at: catalog)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        try Data("obstruct atomic rename".utf8).write(to: catalog.appendingPathComponent("obstruction"))
        mixer.a.setGrid(bpm: 131, offsetMs: 17)
        mixer.a.seek(to: 0.75)
        mixer.a.hotCue(2)
        await library.flush()
        XCTAssertNotNil(library.error)
        XCTAssertEqual(library.tracks.first!.hotCues[2]!, 0.017 + 120 / 131.0, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.grid?.bpm, 131)
        try FileManager.default.removeItem(at: catalog)
        library.retrySave()
        await library.flush()
        XCTAssertNil(library.error)
        XCTAssertFalse(library.saving)
        let fresh = LibraryStorage(directory: directory)
        let restored = try await fresh.prepare(id)
        XCTAssertEqual(restored.track.grid?.bpm, 131)
        XCTAssertEqual(restored.track.hotCues[2]!, 0.017 + 120 / 131.0, accuracy: 1e-9)
    }

    @MainActor
    private func loaded(_ deck: NativeDeck) async throws {
        for _ in 0..<500 where deck.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(deck.loading)
        XCTAssertNil(deck.error)
        if let error = deck.error { throw error }
    }
}
