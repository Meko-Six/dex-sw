import XCTest
import AVFoundation
@testable import DexAudio
import DexCore

/// The library's key analysis: read at import, and FIND KEYS for tracks
/// saved before it existed, without touching their grids or cues.
@MainActor
final class KeyLibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexKeyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An A minor triad (A3 C4 E4) with a few partials, stereo at 48 kHz.
    private func aMinor(in root: URL, seconds: Int = 8) throws -> URL {
        let url = root.appendingPathComponent("A minor.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for second in 0..<seconds {
            for frame in 0..<48_000 {
                let time = Double(second) + Double(frame) / 48_000
                var value = 0.0
                for midi in [57, 60, 64] {
                    for partial in 1...3 { value += 0.12 / pow(Double(partial), 1.6) * sin(2 * .pi * 440 * pow(2, Double(midi - 69) / 12) * Double(partial) * time) }
                }
                buffer.floatChannelData![0][frame] = Float(value)
                buffer.floatChannelData![1][frame] = Float(value * 0.8)
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testImportReadsTheKey() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorage(directory: root.appendingPathComponent("Library"))
        let imported = try await storage.importFile(try aMinor(in: root))
        XCTAssertEqual(imported.track.key?.camelot, "8A")
        XCTAssertEqual(imported.track.key?.name, "A minor")
        XCTAssertGreaterThan(imported.track.key?.confidence ?? 0, 0.3)
        let reopened = try await LibraryStorage(directory: root.appendingPathComponent("Library")).open()
        XCTAssertEqual(reopened.first?.key, imported.track.key)
    }

    func testFindKeysFillsOlderTracksAndKeepsHandEdits() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let imported = try await LibraryStorage(directory: directory).importFile(try aMinor(in: root))
        // A catalog saved before keys: the same track without its key field.
        let catalog = directory.appendingPathComponent("Library.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        document["tracks"] = (document["tracks"] as! [[String: Any]]).map { $0.filter { $0.key != "key" } }
        try JSONSerialization.data(withJSONObject: document).write(to: catalog)

        let library = NativeLibrary(directory: directory)
        await library.open()
        XCTAssertNil(library.tracks.first?.key)
        XCTAssertEqual(library.tracksNeedingKeys, 1)
        let grid = try BeatGrid(bpm: 128.5, offsetMs: -12, confidence: 1)
        var cues = [Double?](repeating: nil, count: 8); cues[2] = 3.5
        library.edit(imported.track.id, grid: grid, uncertain: false, hotCues: cues)

        await library.findKeys()
        XCTAssertNil(library.findingKeys)
        XCTAssertNil(library.error)
        XCTAssertEqual(library.tracks.first?.key?.camelot, "8A")
        XCTAssertEqual(library.tracksNeedingKeys, 0)
        await library.flush()

        let reopened = try await LibraryStorage(directory: directory).open()
        let saved = try XCTUnwrap(reopened.first)
        XCTAssertEqual(saved.key?.camelot, "8A")
        XCTAssertEqual(saved.grid, grid, "FIND KEYS must not re-read the grid")
        XCTAssertEqual(saved.hotCues, cues)
    }

    func testSilenceIsCheckedWithNoKey() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Silence.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for _ in 0..<3 { try file.write(from: buffer) }
        }
        XCTAssertEqual(try WaveformReader.readKey(url: url), .notFound)
    }
}
