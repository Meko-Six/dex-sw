import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import DexAudio
import DexCore

/// What the library's MORE needs from the engine: tags and covers, re-analyse and remove.
@MainActor
final class MoreLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DexMoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// Eight seconds of clicks at 120 BPM.
    private func wav(seed: Int = 0) throws -> URL {
        let url = root.appendingPathComponent("Track \(seed).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for second in 0..<8 {
            for frame in 0..<44_100 {
                let time = Double(second) + Double(frame) / 44_100
                let phase = (time - 0.1 - Double(seed) * 0.01).truncatingRemainder(dividingBy: 0.5)
                buffer.floatChannelData![0][frame] = phase >= 0 && phase < 0.035 ? Float(sin(2 * .pi * 70 * phase) * exp(-phase * 100)) * 0.8 : 0
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func jpeg() throws -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Adds an ID3 chunk with a title, album, genre and cover, fixing the RIFF size.
    private func tagged(_ url: URL) throws {
        func safe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 127), UInt8(n >> 14 & 127), UInt8(n >> 7 & 127), UInt8(n & 127)] }
        func text(_ id: String, _ value: String) -> [UInt8] {
            let body = [3] + Array(value.utf8)
            return Array(id.utf8) + safe(body.count) + [0, 0] + body
        }
        let picture = [0] + Array("image/jpeg".utf8) + [0, 3, 0] + Array(try jpeg())
        let frames = text("TIT2", "Hidden Patterns (Original Mix)") + text("TPE1", "Rinkadink") + text("TALB", "Hidden Patterns")
            + text("TCON", "Psy-Trance") + Array("APIC".utf8) + safe(picture.count) + [0, 0] + picture
        var tag = Array("ID3".utf8) + [4, 0, 0] + safe(frames.count) + frames
        if tag.count % 2 == 1 { tag.append(0) }
        var data = try Data(contentsOf: url)
        withUnsafeBytes(of: UInt32(tag.count).littleEndian) { size in
            data.append(contentsOf: Array("ID3 ".utf8)); data.append(contentsOf: size)
        }
        data.append(contentsOf: tag)
        let riff = UInt32(data.count - 8).littleEndian
        withUnsafeBytes(of: riff) { data.replaceSubrange(4..<8, with: $0) }
        try data.write(to: url)
    }

    private func directory() -> URL { root.appendingPathComponent("Library") }

    func testImportReadsTheDetailsAndSavesTheCover() async throws {
        let source = try wav()
        try tagged(source)
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: source).track
        XCTAssertEqual(track.tagTitle, "Hidden Patterns (Original Mix)")
        XCTAssertEqual(track.details?.album, "Hidden Patterns")
        XCTAssertEqual(track.details?.genre, "Psy-Trance")
        XCTAssertEqual(track.details?.hasCover, true)
        let cover = try XCTUnwrap(library.coverURL(track))
        XCTAssertNotNil(CGImageSourceCreateWithURL(cover as CFURL, nil), "The cover must be a readable image")
    }

    func testDetailsFromBeforeTheAlbumAreReadAgain() async throws {
        let source = try wav()
        try tagged(source)
        let first = NativeLibrary(directory: directory())
        _ = try await first.prepare(url: source).track
        await first.flush()
        let catalog = directory().appendingPathComponent("Library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        var tracks = json["tracks"] as! [[String: Any]]
        tracks[0]["details"] = ["label": "Iboga Records", "hasCover": false]
        json["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: json).write(to: catalog)

        let older = NativeLibrary(directory: directory())
        await older.open()
        XCTAssertNil(older.tracks.first?.details?.album)
        await older.readMissingTags()
        XCTAssertEqual(older.tracks.first?.details?.album, "Hidden Patterns")
        XCTAssertEqual(older.tracks.first?.details?.version, TrackDetails.currentVersion)
    }

    func testOlderCatalogsLoadAndGetTheirTagsInTheBackground() async throws {
        let source = try wav()
        try tagged(source)
        let first = NativeLibrary(directory: directory())
        let imported = try await first.prepare(url: source).track
        await first.flush()
        // As an older version saved it: no details, no names.
        let catalog = directory().appendingPathComponent("Library.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        var tracks = json["tracks"] as! [[String: Any]]
        for key in ["details", "artist", "tagTitle"] { tracks[0].removeValue(forKey: key) }
        json["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: json).write(to: catalog)

        let older = NativeLibrary(directory: directory())
        await older.open()
        XCTAssertNil(older.tracks.first?.details)
        await older.readMissingTags()
        XCTAssertEqual(older.tracks.first?.details?.album, "Hidden Patterns")
        XCTAssertEqual(older.tracks.first?.artist, "Rinkadink")
        await older.flush()
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.tracks.first?.id, imported.id)
        XCTAssertEqual(reopened.tracks.first?.details?.genre, "Psy-Trance", "Filled tags must be saved")
    }

    func testReanalyseReplacesTheGridAndKeepsHotCues() async throws {
        let source = try wav()
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: source).track
        let detected = try XCTUnwrap(track.grid)
        var cues = track.hotCues; cues[2] = 3.5
        library.edit(track.id, grid: try BeatGrid(bpm: 77, offsetMs: 1, confidence: 1), uncertain: false, hotCues: cues)
        XCTAssertEqual(library.tracks[0].grid?.bpm, 77)

        let result = try await XCTUnwrapAsync(await library.reanalyze(track.id))
        XCTAssertEqual(result.grid?.bpm ?? 0, detected.bpm, accuracy: 0.01, "The analysis replaces a hand-edited grid")
        XCTAssertEqual(result.hotCues[2], 3.5, "Hot cues stay")
        XCTAssertNil(library.analysing)
        await library.flush()
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.tracks[0].grid?.bpm ?? 0, detected.bpm, accuracy: 0.01)
        XCTAssertEqual(reopened.tracks[0].hotCues[2], 3.5)
    }

    func testADeckHoldingTheTrackFollowsARe_analysis() async throws {
        let source = try wav()
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: source).track
        let mixer = NativeMixer(library: library); defer { mixer.shutdown() }
        try mixer.enableOfflineRendering()
        mixer.a.loadTrack(track.id)
        let deadline = ContinuousClock.now + .seconds(60)
        while mixer.a.loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(mixer.a.libraryTrackID, track.id)
        mixer.start()
        mixer.a.setGrid(bpm: 77)
        mixer.a.hotCue(1)
        XCTAssertEqual(mixer.a.grid?.bpm, 77)
        let result = try await XCTUnwrapAsync(await library.reanalyze(track.id))
        mixer.a.follow(reanalysed: result)
        mixer.b.follow(reanalysed: result)
        XCTAssertEqual(mixer.a.grid?.bpm ?? 0, track.grid?.bpm ?? -1, accuracy: 0.01)
        // The cue stays in its slot, on the new grid's nearest beat, and the library agrees.
        let cue = try XCTUnwrap(mixer.a.hotCues[1])
        XCTAssertEqual(cue, try XCTUnwrap(result.grid).cueTime(near: 0, duration: result.duration) ?? -1, accuracy: 0.001)
        XCTAssertEqual(library.tracks[0].hotCues[1], cue)
        XCTAssertNil(mixer.b.grid, "A deck not holding it is left alone")
    }

    func testRemoveDeletesTheCopyAndLeavesTheOriginalAndOtherTracks() async throws {
        let source = try wav(seed: 1), other = try wav(seed: 2)
        try tagged(source)
        let library = NativeLibrary(directory: directory())
        let gone = try await library.prepare(url: source)
        let kept = try await library.prepare(url: other)
        let cover = try XCTUnwrap(library.coverURL(gone.track))
        let list = library.createPlaylist(named: "Set")
        library.addToPlaylist(list, tracks: [gone.track.id, kept.track.id])
        // A pending edit on the removed track must not fail the save.
        library.edit(gone.track.id, grid: gone.track.grid, uncertain: false, hotCues: [1] + Array(repeating: nil, count: 7))

        await library.remove(gone.track.id)
        XCTAssertNil(library.error)
        XCTAssertEqual(library.tracks.map(\.id), [kept.track.id])
        XCTAssertEqual(library.playlists[0].trackIDs, [kept.track.id.uuidString])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.url.path), "The library's copy goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path), "So does its cover")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The original stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path))
        await library.flush()
        XCTAssertFalse(library.saveFailed)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.tracks.map(\.id), [kept.track.id])
        // Importing it again works: it was forgotten, not just hidden.
        let again = try await reopened.prepare(url: source)
        XCTAssertNotEqual(again.track.id, gone.track.id)
    }

    // MARK: Playlists on disk

    private var playlistsURL: URL { directory().appendingPathComponent("playlists.json") }
    private func siblings(_ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testAPlaylistsFileThatCannotBeReadIsKeptAndTheLastSaveRestored() async throws {
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: try wav())
        let list = library.createPlaylist(named: "Set")
        await library.flush()   // Two saves, not one: edits made together are written together.
        library.addToPlaylist(list, tracks: [track.track.id])   // The save before this one holds "Set", empty.
        await library.flush()
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: playlistsURL)

        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.playlists.map(\.name), ["Set"], "The previous save comes back")
        XCTAssertNotNil(reopened.notice)
        let kept = try siblings("playlists.damaged-")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: kept[0]), damaged, "What couldn't be read is kept as it was")
        // Changing playlists afterwards still leaves that copy alone.
        reopened.createPlaylist(named: "Later")
        await reopened.flush()
        XCTAssertEqual(try Data(contentsOf: kept[0]), damaged)
        let again = NativeLibrary(directory: directory())
        await again.open()
        XCTAssertEqual(again.playlists.map(\.name), ["Set", "Later"])
        XCTAssertNil(again.notice)
    }

    func testAPlaylistsFileThatCannotBeReadWithNoEarlierSaveStartsEmptyAndIsKept() async throws {
        let library = NativeLibrary(directory: directory())
        _ = try await library.prepare(url: try wav())
        let damaged = Data([0xff, 0x00, 0x7b])
        try damaged.write(to: playlistsURL)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.playlists, [])
        XCTAssertNotNil(reopened.notice)
        reopened.createPlaylist(named: "New")
        await reopened.flush()
        XCTAssertNil(reopened.error)
        let kept = try siblings("playlists.damaged-")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: kept[0]), damaged)
    }

    func testPlaylistsFromANewerVersionAreNeverWrittenOver() async throws {
        let library = NativeLibrary(directory: directory())
        _ = try await library.prepare(url: try wav())
        let newer = Data(#"{"version":2,"playlists":[],"folders":[{"name":"Friday"}]}"#.utf8)
        try newer.write(to: playlistsURL)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertNotNil(reopened.notice)
        reopened.createPlaylist(named: "Mine")
        XCTAssertEqual(reopened.playlists, [], "Nothing changes that couldn't be saved")
        XCTAssertNotNil(reopened.error)
        await reopened.flush()
        XCTAssertEqual(try Data(contentsOf: playlistsURL), newer)
    }

    func testAProblemRaisedAgainCountsAgainAndAStandingNoticeDoesNot() async throws {
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: try wav())
        library.report(.heldByDeck("A"))
        let first = library.errorRevision
        library.report(.heldByDeck("A"))
        XCTAssertEqual(library.errorRevision, first &+ 1, "The same cause raised again is a new problem")
        // A notice that stands is not raised again by each track prepared.
        try Data(#"{"version":2,"playlists":[]}"#.utf8).write(to: playlistsURL)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertNotNil(reopened.notice)
        let standing = reopened.noticeRevision
        _ = try await reopened.prepare(id: track.track.id)
        _ = try await reopened.prepare(id: track.track.id)
        XCTAssertEqual(reopened.noticeRevision, standing)
    }

    func testPlaylistsSavedBeforeTheVersionStillLoad() async throws {
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: try wav())
        let old = [Playlist(id: "pl-old", name: "Warm up", trackIDs: [track.track.id.uuidString])]
        try JSONEncoder().encode(old).write(to: playlistsURL)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.playlists, old)
        XCTAssertNil(reopened.notice)
    }

    func testNoPlaylistIsWrittenBeforeTheSavedOnesAreRead() async throws {
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: try wav())
        library.addToPlaylist(library.createPlaylist(named: "Set"), tracks: [track.track.id])
        await library.flush()
        let unopened = NativeLibrary(directory: directory())
        unopened.createPlaylist(named: "Too early")
        await unopened.open()
        XCTAssertEqual(unopened.playlists.map(\.name), ["Set"])
    }

    private func playlistsOnDisk(_ name: String) throws -> [Playlist] {
        struct File: Decodable { let version: Int; let playlists: [Playlist] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: directory().appendingPathComponent(name)))
        XCTAssertEqual(file.version, 1)
        return file.playlists
    }

    func testPlaylistEditsMadeTogetherAreWrittenOnceWithTheLatestList() async throws {
        let library = NativeLibrary(directory: directory())
        let track = try await library.prepare(url: try wav())
        library.createPlaylist(named: "Earlier")
        // The edit shows at once and returns before anything is written: the write is the storage's.
        XCTAssertEqual(library.playlists.map(\.name), ["Earlier"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: playlistsURL.path))
        await library.flush()
        XCTAssertEqual(try playlistsOnDisk("playlists.json"), library.playlists)
        let earlier = library.playlists

        let list = library.createPlaylist(named: "Set")
        let between = library.playlists
        library.addToPlaylist(list, tracks: [track.track.id])
        XCTAssertEqual(try playlistsOnDisk("playlists.json"), earlier, "Neither edit is written while the caller still runs")
        await library.flush()
        XCTAssertNil(library.error)
        XCTAssertEqual(library.playlists.last?.trackIDs, [track.track.id.uuidString])
        XCTAssertEqual(try playlistsOnDisk("playlists.json"), library.playlists, "The latest list is the one saved")
        let backup = try playlistsOnDisk("playlists.backup.json")
        XCTAssertTrue(backup == between || backup == earlier, "The recovery copy is the list before, or an older save")
        XCTAssertNotEqual(backup, library.playlists)
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        XCTAssertEqual(reopened.playlists, library.playlists)
        XCTAssertNil(reopened.notice)
    }

    func testAFailedPlaylistSaveIsReported() async throws {
        let library = NativeLibrary(directory: directory())
        _ = try await library.prepare(url: try wav())
        // A folder with something in it, where the file belongs, can't be replaced.
        try FileManager.default.createDirectory(at: playlistsURL, withIntermediateDirectories: false)
        try Data("in the way".utf8).write(to: playlistsURL.appendingPathComponent("obstruction"))
        let reopened = NativeLibrary(directory: directory())
        await reopened.open()
        reopened.createPlaylist(named: "Set")
        XCTAssertEqual(reopened.playlists.map(\.name), ["Set"])
        await reopened.flush()
        guard case .playlistSaveFailed = reopened.error else { return XCTFail("Expected a failed playlist save, got \(String(describing: reopened.error))") }
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?) async throws -> T {
        let result = await value()
        return try XCTUnwrap(result)
    }
}
