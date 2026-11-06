import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import DexCore
@testable import DexAudio

/// The track window's names and cover come from the file's tags on load,
/// as `loadToDeck` reads them, and go when the deck takes another track.
final class TrackTagsTests: XCTestCase {
    private func wav(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let value = Float(sin(Double(i) * 2 * .pi * 220 / 44100)) * 0.2
            buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = value
        }
        try file.write(from: buffer)
    }

    /// A 600 x 400 PNG, larger than the thumbnail the deck keeps.
    private func png() throws -> Data {
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The WAV with an `id3 ` chunk carrying title, artist and an APIC frame.
    private func tagged(_ url: URL) throws {
        try wav(url)
        func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + be32(body.count) + [0, 0] + body }
        let frames = frame("TIT2", [3] + Array("Dark Rooms".utf8)) + frame("TPE1", [3] + Array("Jay Lumen".utf8))
            + frame("APIC", [0] + Array("image/png".utf8) + [0, 3, 0] + [UInt8](try png()))
        let size = frames.count
        var tag = Array("ID3".utf8) + [3, 0, 0] + [UInt8(size >> 21 & 127), UInt8(size >> 14 & 127), UInt8(size >> 7 & 127), UInt8(size & 127)] + frames
        if tag.count % 2 == 1 { tag.append(0) }
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes += Array("id3 ".utf8) + withUnsafeBytes(of: UInt32(tag.count).littleEndian, Array.init) + tag
        bytes.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(bytes.count - 8).littleEndian, Array.init))
        try Data(bytes).write(to: url)
    }

    @MainActor
    private func loaded(_ deck: NativeDeck) async throws {
        for _ in 0..<500 where deck.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(deck.loading); XCTAssertNil(deck.error)
    }

    @MainActor
    func testLoadReadsNamesAndCoverAndTheNextLoadClearsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let withTags = root.appendingPathComponent("Jay Lumen - Dark Rooms.wav"), plain = root.appendingPathComponent("Plain.wav")
        try tagged(withTags); try wav(plain)
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))
        let first = try await library.prepare(url: withTags), second = try await library.prepare(url: plain)
        let mixer = NativeMixer(library: library); defer { mixer.shutdown() }

        mixer.a.loadTrack(first.track.id); try await loaded(mixer.a)
        XCTAssertEqual(mixer.a.tags.title, "Dark Rooms")
        XCTAssertEqual(mixer.a.tags.artist, "Jay Lumen")
        let cover = try XCTUnwrap(mixer.a.tags.cover)
        XCTAssertEqual(max(cover.width, cover.height), TrackTags.coverPixels, "kept as a thumbnail, not the full picture")

        mixer.a.loadTrack(second.track.id); try await loaded(mixer.a)
        XCTAssertNil(mixer.a.tags.title)
        XCTAssertNil(mixer.a.tags.cover)
    }

    /// Import stores the tag names; a catalog from before them gets them on
    /// the track's first load, and names already there stay.
    @MainActor
    func testLibraryKeepsTagNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Jay Lumen - Dark Rooms.wav")
        try tagged(source)
        let directory = root.appendingPathComponent("Library")
        let imported = try await LibraryStorage(directory: directory).importFile(source)
        XCTAssertEqual(imported.track.artist, "Jay Lumen")
        XCTAssertEqual(imported.track.tagTitle, "Dark Rooms")
        XCTAssertEqual(imported.track.title, "Jay Lumen - Dark Rooms")
        XCTAssertEqual(imported.track.label, "Jay Lumen — Dark Rooms")

        // Saved before names: no artist, and a title someone already had.
        let catalog = directory.appendingPathComponent("Library.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        document["tracks"] = (document["tracks"] as! [[String: Any]]).map {
            var track = $0.filter { $0.key != "artist" }; track["tagTitle"] = "Kept"; return track
        }
        try JSONSerialization.data(withJSONObject: document).write(to: catalog)

        let library = NativeLibrary(directory: directory)
        await library.open()
        XCTAssertNil(library.tracks.first?.artist)
        let mixer = NativeMixer(library: library); defer { mixer.shutdown() }
        mixer.a.loadTrack(imported.track.id); try await loaded(mixer.a)
        XCTAssertEqual(library.tracks.first?.artist, "Jay Lumen")
        XCTAssertEqual(library.tracks.first?.tagTitle, "Kept")
        await library.flush()
        let reopened = try await LibraryStorage(directory: directory).open()
        let saved = try XCTUnwrap(reopened.first)
        XCTAssertEqual(saved.label, "Jay Lumen — Kept")
    }
}
