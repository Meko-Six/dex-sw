import XCTest
import AVFoundation
@testable import DexAudio
import DexCore

/// Ratings and the set history, saved with the library and read back.
@MainActor
final class SetHistoryLibraryTests: XCTestCase {
    private func library() async throws -> (URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DexSetTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Tone.wav")
        try write(url)
        let directory = root.appendingPathComponent("Library")
        let track = try await LibraryStorage(directory: directory).importFile(url)
        return (directory, track.track.id)
    }

    /// Eight seconds of 440 Hz; the file closes on return.
    private func write(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for second in 0..<8 {
            for frame in 0..<48_000 {
                let value = Float(0.2 * sin(2 * .pi * 440 * (Double(second) + Double(frame) / 48_000)))
                buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
            }
            try file.write(from: buffer)
        }
    }

    func testRatingsAndSetsAreRemembered() async throws {
        let (directory, id) = try await library()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let library = NativeLibrary(directory: directory)
        await library.open()
        library.setRating(id, 4)
        library.recordPlay(id)
        XCTAssertEqual(library.sets.played, [id.uuidString])
        await library.flush()

        let again = NativeLibrary(directory: directory)
        await again.open()
        XCTAssertEqual(again.tracks.first?.rating, 4)
        XCTAssertEqual(again.sets.played, [id.uuidString])

        again.newSet()
        XCTAssertEqual(again.sets.played, [])
        let playlist = again.saveSetAsPlaylist(again.sets.sets[0].id, named: "Set Sat 14 Nov")
        XCTAssertEqual(again.playlists.first { $0.id == playlist }?.trackIDs, [id.uuidString])
        again.setRating(id, nil)
        XCTAssertNil(again.tracks.first?.rating)
        again.setRating(id, 9)
        XCTAssertNil(again.tracks.first?.rating, "only 1 to 5 stars")
    }
}
