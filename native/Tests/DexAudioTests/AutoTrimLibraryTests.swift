import XCTest
import AVFoundation
@testable import DexAudio
import DexCore

/// AUTO trim's library side: loudness read at import and filled in for older
/// tracks, and a hand-set trim remembered per track.
@MainActor
final class AutoTrimLibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexAutoTrimTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stereo 997 Hz sine at `db` dBFS: it reads `db` LUFS.
    private func sine(_ db: Double, in root: URL, seconds: Int = 8) throws -> URL {
        let url = root.appendingPathComponent("Sine \(db).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        let amplitude = pow(10, db / 20)
        for second in 0..<seconds {
            for frame in 0..<48_000 {
                let value = Float(amplitude * sin(2 * .pi * 997 * (Double(second) + Double(frame) / 48_000)))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testImportMeasuresLoudnessAndStartsAtAuto() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorage(directory: root.appendingPathComponent("Library"))
        let imported = try await storage.importFile(try sine(-6, in: root))
        let loudness = try XCTUnwrap(imported.track.loudness)
        XCTAssertEqual(loudness.main, -6, accuracy: 0.1)
        XCTAssertEqual(imported.track.startingTrim, -4, accuracy: 0.1)
        let reopened = try await LibraryStorage(directory: root.appendingPathComponent("Library")).open()
        XCTAssertEqual(reopened.first?.loudness, loudness)
    }

    func testOlderTracksAreMeasuredAndAHandSetTrimIsRemembered() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        _ = try await LibraryStorage(directory: directory).importFile(try sine(-14, in: root))
        // A catalog saved before AUTO trim: the same track without loudness.
        let catalog = directory.appendingPathComponent("Library.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        document["tracks"] = (document["tracks"] as! [[String: Any]]).map { $0.filter { $0.key != "loudness" } }
        try JSONSerialization.data(withJSONObject: document).write(to: catalog)

        let library = NativeLibrary(directory: directory)
        await library.open()
        let id = try XCTUnwrap(library.tracks.first?.id)
        XCTAssertNil(library.tracks.first?.loudness)
        XCTAssertEqual(library.tracks.first?.startingTrim, 0)
        await library.readMissingLoudness()
        XCTAssertEqual(library.tracks.first?.loudness?.main ?? 0, -14, accuracy: 0.1)
        XCTAssertEqual(library.tracks.first?.startingTrim ?? 0, 4, accuracy: 0.1)

        library.setTrim(id, 2.5)
        XCTAssertEqual(library.tracks.first?.startingTrim, 2.5)
        await library.flush()
        let remembered = try await LibraryStorage(directory: directory).open().first?.trimDb
        XCTAssertEqual(remembered, 2.5)

        // Back at AUTO, the track forgets the hand-set trim.
        library.setTrim(id, library.tracks.first?.loudness?.autoTrim())
        XCTAssertNil(library.tracks.first?.trimDb)
        await library.flush()
        let forgotten = try await LibraryStorage(directory: directory).open().first
        XCTAssertNotNil(forgotten)
        XCTAssertNil(forgotten?.trimDb)
    }
}
