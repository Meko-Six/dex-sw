import XCTest
import AVFoundation
import DexCore
@testable import DexAudio

final class QuantizedCueTests: XCTestCase {
    private func audio(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("Cue grid.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.2 }
        try file.write(from: buffer)
        return url
    }
    @MainActor
    private func loaded(_ deck: NativeDeck) async throws {
        for _ in 0..<500 where deck.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(deck.loading); XCTAssertNil(deck.error)
    }
    @MainActor
    func testInitialCueHotCuesAndGridCorrectionsStayQuantizedAndPersistTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let library = NativeLibrary(directory: directory)
        let imported = try await library.prepare(url: audio(root))
        let grid = try BeatGrid(bpm: 120, offsetMs: 123, confidence: 1)
        var oldCues = [Double?](repeating: nil, count: 8); oldCues[0] = 0; oldCues[7] = 3
        library.edit(imported.track.id, grid: grid, uncertain: false, hotCues: oldCues)
        await library.flush()
        let mixer = NativeMixer(library: library); defer { mixer.shutdown() }
        mixer.a.loadTrack(imported.track.id); try await loaded(mixer.a)
        mixer.b.loadTrack(imported.track.id); try await loaded(mixer.b)
        XCTAssertEqual(mixer.a.cuePoint, 0.123, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.position, mixer.a.cuePoint)
        XCTAssertEqual(mixer.a.hotCues[0]!, 0.123, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.hotCues[7]!, 2.623, accuracy: 1e-9)
        mixer.a.seek(to: 0.41); mixer.a.cue()
        XCTAssertEqual(mixer.a.cuePoint, 0.623, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.position, mixer.a.cuePoint)
        mixer.a.seek(to: 0.93); mixer.a.hotCue(1)
        XCTAssertEqual(mixer.a.hotCues[1]!, 1.123, accuracy: 1e-9)
        mixer.a.seek(to: 0); mixer.a.hotCue(2)
        mixer.a.seek(to: mixer.a.duration); mixer.a.hotCue(3)
        XCTAssertEqual(mixer.a.hotCues[2]!, 0.123, accuracy: 1e-9)
        XCTAssertEqual(mixer.a.hotCues[3]!, 2.623, accuracy: 1e-9)
        mixer.a.setGrid(bpm: 120, offsetMs: 223)
        XCTAssertEqual(mixer.a.cuePoint, 0.723, accuracy: 1e-9, "Custom CUE follows its nearest corrected beat")
        XCTAssertEqual(mixer.b.cuePoint, 0.223, accuracy: 1e-9, "Unchanged initial CUE follows the corrected first beat")
        XCTAssertEqual(mixer.a.hotCues, mixer.b.hotCues)
        for cue in mixer.a.hotCues.compactMap({ $0 }) {
            XCTAssertEqual(MixMath.wrapPhase(mixer.a.grid!.phase(at: cue)), 0, accuracy: 1e-9)
        }
        await library.flush(); XCTAssertNil(library.error)
        let restored = try await LibraryStorage(directory: directory).prepare(imported.track.id)
        XCTAssertEqual(restored.track.hotCues, mixer.a.hotCues)
    }
    @MainActor
    func testHotCueRequiresGridRatherThanSavingAnOffBeatMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        mixer.a.load(try audio(root)); try await loaded(mixer.a)
        XCTAssertNil(mixer.a.grid)
        mixer.a.seek(to: 0.37); mixer.a.hotCue(0)
        XCTAssertNil(mixer.a.hotCues[0]); XCTAssertNotNil(mixer.a.error)
        mixer.a.setGrid(bpm: 120, offsetMs: 123)
        mixer.a.hotCue(0)
        XCTAssertEqual(mixer.a.hotCues[0]!, 0.123, accuracy: 1e-9)
        XCTAssertNil(mixer.a.error)
    }
}
