import XCTest
import AVFoundation
import Darwin
import Combine
@testable import DexAudio
import DexCore

final class HardeningTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DexHardening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func audio(_ root: URL, name: String = "test", seconds: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(name + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        chunk.frameLength = 48_000
        for second in 0..<seconds {
            for i in 0..<48_000 {
                chunk.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * (second < 2 ? 220 : 880) / 48_000)) * 0.25
                chunk.floatChannelData![1][i] = 0.15
            }
            try file.write(from: chunk)
        }
        return url
    }
    func testIndependentStoresMergeImportsGridAndDifferentCueSlots() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let a = LibraryStorage(directory: directory), b = LibraryStorage(directory: directory)
        let first = try await a.importFile(audio(root))
        var malformed = first.track; malformed.hotCues = []
        do { try await a.update(malformed); XCTFail("Malformed metadata must be rejected before computing field changes") }
        catch { XCTAssertTrue(error is LibraryError) }
        _ = try await b.open()
        let second = try await a.importFile(audio(root, name: "other", seconds: 3))
        var fromA = first.track
        fromA.grid = try BeatGrid(bpm: 125, offsetMs: 17, confidence: 1)
        fromA.gridUncertain = false; fromA.hotCues[0] = 0.5
        try await a.update(fromA)
        var fromB = first.track; fromB.hotCues[7] = 2.75
        try await b.update(fromB)
        let restored = try await LibraryStorage(directory: directory).open()
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.contains { $0.id == second.track.id })
        let track = try XCTUnwrap(restored.first { $0.id == first.track.id })
        XCTAssertEqual(track.grid?.bpm, 125)
        XCTAssertEqual(track.hotCues[0], 0.5); XCTAssertEqual(track.hotCues[7], 2.75)
    }
    func testCacheWriteFailureDoesNotPreventImportOrReload() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("cache directory obstructed".utf8).write(to: directory.appendingPathComponent("Analysis"))
        let store = LibraryStorage(directory: directory)
        let imported = try await store.importFile(audio(root))
        XCTAssertNotNil(imported.warning)
        let loaded = try await LibraryStorage(directory: directory).prepare(imported.track.id)
        XCTAssertEqual(loaded.track, imported.track)
        XCTAssertEqual(loaded.overview.peaks.count, 2048)
        XCTAssertNotNil(loaded.warning)
        _ = try AVAudioFile(forReading: loaded.url)
    }
    func testUnchangedReimportSkipsCopyAndChangedSameNameDoesNot() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStorage(directory: root.appendingPathComponent("Library"))
        let source = try audio(root)
        let first = try await store.importFile(source)
        let before = await store.copiedBytes
        let again = try await store.importFile(source)
        let after = await store.copiedBytes
        XCTAssertEqual(first.track.id, again.track.id); XCTAssertEqual(before, after)
        _ = try audio(root, seconds: 3)
        let changed = try await store.importFile(source)
        XCTAssertNotEqual(first.track.id, changed.track.id)
        let copied = await store.copiedBytes
        XCTAssertGreaterThan(copied, after)
    }
    @MainActor
    func testRapidEditsCoalesceAndFlushKeepsLatestValues() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))
        let prepared = try await library.prepare(url: audio(root))
        let before = await library.persistenceCommits
        for i in 0..<200 {
            var cues = library.tracks[0].hotCues; cues[i % 8] = Double(i) / 100
            library.edit(prepared.track.id, grid: try BeatGrid(bpm: 120 + Double(i) / 100), uncertain: false, hotCues: cues)
        }
        await library.flush()
        XCTAssertNil(library.error); XCTAssertFalse(library.saving)
        let after = await library.persistenceCommits
        XCTAssertEqual(after - before, 1, "One burst should become one catalog transaction")
        let restored = try await LibraryStorage(directory: root.appendingPathComponent("Library")).prepare(prepared.track.id)
        XCTAssertEqual(restored.track.grid?.bpm, 121.99)
        XCTAssertEqual(restored.track.hotCues[7], 1.99)
    }
    func testLargeImportMemoryIsBoundedAndCancellationCleansStaging() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large-invalid.wav")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: 512 * 1024 * 1024); try file.close()
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStorage(directory: directory)
        // The import's own memory, sampled every millisecond while it runs, against where it started:
        // the process's lifetime peak would count every earlier test's audio too.
        let sampler = FootprintSampler()
        do { _ = try await store.importFile(source); XCTFail("Fixture deliberately has no audio header") } catch {}
        let growth = sampler.stop()
        print("HARDENED IMPORT peakGrowthMiB=\(Double(growth) / 1_048_576)")
        XCTAssertLessThan(growth, 200 * 1024 * 1024, "512 MiB source must not be retained in RAM")
        let cancelled = Task { try await store.importFile(source) }
        var sawStaging = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Audio").path)
                .contains(where: { $0.hasPrefix(".import-") }) { sawStaging = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(sawStaging, "Cancel an actual active copy, not just a queued request")
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled import must not commit") } catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Audio").path).isEmpty)
    }
    @MainActor
    func testConcurrentDeckImportsShareWorkAndIndependentCancellation() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try audio(root, seconds: 24)
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))
        await library.open()
        let first = Task { try await library.prepare(url: url) }
        let second = Task { try await library.prepare(url: url) }
        for _ in 0..<500 where library.importWaiterCount < 2 { await Task.yield() }
        XCTAssertEqual(library.importWaiterCount, 2)
        first.cancel()
        let result = try await second.value
        do { _ = try await first.value; XCTFail("Cancelled deck selection must not commit") } catch is CancellationError {}
        XCTAssertEqual(library.tracks.count, 1)
        XCTAssertEqual(result.track.duration, 24)
        let copied = await library.importedBytes
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        XCTAssertEqual(copied, Int64(size), "Two deck requests must copy/analyze once")
        XCTAssertEqual(library.importWaiterCount, 0)
    }
    @MainActor
    private func load(_ mixer: NativeMixer, _ url: URL, both: Bool = false) async throws {
        try mixer.enableOfflineRendering()
        mixer.a.load(url); if both { mixer.b.load(url) }
        let deadline = ContinuousClock.now + .seconds(60)
        while (mixer.a.loading || mixer.b.loading) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !mixer.a.loading, !mixer.b.loading, mixer.a.duration > 0 else {
            XCTFail("Deck preparation did not complete before transport testing")
            throw NSError(domain: "DexTestPreparation", code: 1)
        }
        XCTAssertNil(mixer.a.error); XCTAssertNil(mixer.b.error)
        mixer.a.setGrid(bpm: 120); if both { mixer.b.setGrid(bpm: 120); mixer.b.toggleSync() }
        mixer.start(); XCTAssertNil(mixer.error)
    }
    @MainActor
    @discardableResult
    private func render(_ mixer: NativeMixer, seconds: Double) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 1024)!
        var peak: Float = 0, finite = true
        for _ in 0..<Int(ceil(seconds * 48_000 / 1024)) {
            if try mixer.renderOffline(into: buffer) == .success {
                for i in 0..<Int(buffer.frameLength) {
                    let value = buffer.floatChannelData![0][i]
                    finite = finite && value.isFinite
                    peak = max(peak, abs(value))
                }
            }
        }
        mixer.a.refreshPosition(); mixer.b.refreshPosition()
        XCTAssertTrue(finite); XCTAssertLessThanOrEqual(peak, 1.001)
        return peak
    }
    @MainActor
    func testCueSeekResizeAndPlayheadUpdatesWorkTogether() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        mixer.a.seek(to: 3); mixer.a.hotCue(0)
        mixer.a.seek(to: 0); mixer.a.setLoopBeats(2); mixer.a.toggleLoop()
        mixer.a.togglePlay(); try render(mixer, seconds: 0.3)
        var controlUpdates = 0, displayUpdates = 0
        let controls = mixer.a.objectWillChange.sink { controlUpdates += 1 }
        let display = mixer.a.playhead.objectWillChange.sink { displayUpdates += 1 }
        for _ in 0..<4 { try render(mixer, seconds: 0.05) }
        XCTAssertEqual(controlUpdates, 0); XCTAssertGreaterThan(displayUpdates, 0)
        withExtendedLifetime((controls, display)) {}
        mixer.a.hotCue(0)
        XCTAssertEqual(mixer.a.hotCues[0], 3); XCTAssertFalse(mixer.a.loopActive)
        XCTAssertGreaterThan(try render(mixer, seconds: 0.7), 0.01)
        XCTAssertGreaterThanOrEqual(mixer.a.position, 3)
        XCTAssertLessThan(mixer.a.position, 3.7)
        mixer.a.cueDown(); mixer.a.cueUp()
        XCTAssertFalse(mixer.a.playing); XCTAssertEqual(mixer.a.position, 0)
        mixer.a.cueDown(); mixer.a.togglePlay(); mixer.a.cueUp()
        XCTAssertTrue(mixer.a.playing)
    }
    @MainActor
    func testPlayheadFollowsWhatTheListenerHears() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        mixer.a.togglePlay(); try render(mixer, seconds: 1)
        // The engine's own delay (its limiter's look-ahead) is in the position already.
        let graph = mixer.a.position + mixer.a.outputDelay
        mixer.a.outputDelay = 0.25
        mixer.a.refreshPosition()
        XCTAssertEqual(mixer.a.position, graph - 0.25, accuracy: 1e-6)
        // Pausing freezes the waveform where it is, with no jump to graph time.
        mixer.a.togglePlay()
        let paused = mixer.a.position
        XCTAssertEqual(paused, graph - 0.25, accuracy: 1e-3)
        // It stays put until the restarted audio has come through the delay.
        mixer.a.togglePlay(); try render(mixer, seconds: 0.2)
        XCTAssertEqual(mixer.a.position, paused, accuracy: 1e-6)
        try render(mixer, seconds: 0.3)
        XCTAssertGreaterThan(mixer.a.position, paused + 0.1)
    }
    @MainActor
    func testASeekMovesTheWaveformOnceItIsHeard() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        mixer.a.outputDelay = 0.25
        mixer.a.togglePlay(); try render(mixer, seconds: 1)
        let before = mixer.a.position
        mixer.a.seek(to: 4)
        XCTAssertEqual(mixer.a.position, before, accuracy: 0.05)
        try render(mixer, seconds: 0.2)
        XCTAssertLessThan(mixer.a.position, 4)
        try render(mixer, seconds: 0.3)
        XCTAssertGreaterThanOrEqual(mixer.a.position, 4)
    }
    @MainActor
    func testAHotCueLandsOnTheBeatThatWasHeard() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        let grid = try XCTUnwrap(mixer.a.grid)
        mixer.a.outputDelay = 0.35 * grid.beatSeconds / 0.5
        mixer.a.togglePlay(); try render(mixer, seconds: 3)
        mixer.a.refreshPosition()
        let heard = mixer.a.position
        mixer.a.hotCue(0)
        XCTAssertEqual(mixer.a.hotCues[0], grid.cueTime(near: heard, duration: mixer.a.duration))
    }
    @MainActor
    func testJogIgnoresTheOutputDelay() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        mixer.a.outputDelay = 0.25
        mixer.a.seek(to: 2); mixer.a.beginJog()
        XCTAssertEqual(mixer.a.position, 2, accuracy: 1e-6)
        mixer.a.cancelJog(resume: false)
    }
    @MainActor
    func testALoopFromAHeardPositionStaysInsideIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        let grid = try XCTUnwrap(mixer.a.grid)
        mixer.a.outputDelay = 0.3
        mixer.a.setLoopBeats(0.5)
        mixer.a.togglePlay(); try render(mixer, seconds: 2)
        mixer.a.toggleLoop()
        XCTAssertTrue(mixer.a.loopActive)
        XCTAssertGreaterThan(try render(mixer, seconds: 1), 0.01)
        let bounds = try XCTUnwrap(mixer.a.loopBounds)
        XCTAssertEqual(bounds.upperBound - bounds.lowerBound, grid.beatSeconds / 2, accuracy: 1e-3)
        XCTAssertTrue(bounds.contains(mixer.a.position), "\(mixer.a.position) outside \(bounds)")
    }
    @MainActor
    func testInterruptionFreezesBothDecksAndResumesOnlyAllowedPlayback() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root), both: true)
        mixer.a.togglePlay(); mixer.b.togglePlay(); try render(mixer, seconds: 0.4)
        let before = mixer.a.position
        mixer.start() // Reappearance/start is idempotent while already playing.
        try render(mixer, seconds: 0.1)
        XCTAssertGreaterThan(mixer.a.position, before)
        mixer.handle(.interruptionBegan)
        mixer.handle(.configurationChanged) // Engine reconfiguration must not erase resume intent.
        let stoppedA = mixer.a.position, stoppedB = mixer.b.position
        XCTAssertEqual(mixer.audioState, .interrupted)
        XCTAssertFalse(mixer.a.playing); XCTAssertFalse(mixer.b.playing)
        try await Task.sleep(for: .milliseconds(30))
        mixer.a.refreshPosition(); XCTAssertEqual(mixer.a.position, stoppedA)
        mixer.handle(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(mixer.a.playing); XCTAssertTrue(mixer.b.playing)
        XCTAssertGreaterThan(try render(mixer, seconds: 0.3), 0.01)
        XCTAssertGreaterThan(mixer.b.position, stoppedB)
        mixer.handle(.interruptionBegan)
        mixer.handle(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(mixer.a.playing); XCTAssertFalse(mixer.b.playing)
        XCTAssertTrue(mixer.a.audioAvailable)
    }
    @MainActor
    func testOutputResetPressureAndCuePreviewRecovery() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mixer = NativeMixer(); defer { mixer.shutdown(); AudioMemoryBudget.shared.setPressure(false) }
        try await load(mixer, audio(root))
        mixer.a.seek(to: 0.5); mixer.a.cueDown(); try render(mixer, seconds: 0.15)
        mixer.handle(.interruptionBegan); mixer.handle(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(mixer.a.playing); XCTAssertEqual(mixer.a.position, 0.5)
        mixer.a.togglePlay(); try render(mixer, seconds: 0.1)
        mixer.handle(.outputChanged)
        XCTAssertEqual(mixer.audioState, .ready); XCTAssertFalse(mixer.a.playing)
        let stopped = mixer.a.position
        mixer.a.togglePlay(); try render(mixer, seconds: 0.2)
        XCTAssertNil(mixer.notice)
        XCTAssertGreaterThan(mixer.a.position, stopped)
        mixer.a.setLoopBeats(2); mixer.a.toggleLoop()
        try render(mixer, seconds: 0.2)
        mixer.a.setLoopBeats(4)
        mixer.handle(.memoryWarning)
        XCTAssertTrue(mixer.a.loopActive); XCTAssertTrue(mixer.a.playing)
        XCTAssertGreaterThan(try render(mixer, seconds: 0.3), 0.01)
        let grid = mixer.a.grid
        mixer.a.lowDB = -13; mixer.a.trimDB = -2; mixer.a.keyLock = false
        mixer.a.kills.high = true; mixer.a.filter = -0.2
        mixer.handle(.servicesLost)
        mixer.handle(.foreground) // A foreground event must not revive lost media services.
        XCTAssertEqual(mixer.audioState, .unavailable)
        mixer.handle(.servicesReset)
        XCTAssertEqual(mixer.audioState, .ready); XCTAssertNil(mixer.error)
        XCTAssertFalse(mixer.a.playing); XCTAssertEqual(mixer.a.grid, grid)
        XCTAssertTrue(mixer.a.loopActive)
        XCTAssertEqual(mixer.a.toneGains[0], pow(10, -13 / 20), accuracy: 1e-6)
        XCTAssertEqual(mixer.a.toneGains[2], 0); XCTAssertEqual(mixer.a.toneGains[3], pow(10, -2 / 20), accuracy: 1e-6)
        XCTAssertLessThan(mixer.a.sweep, 0)
        XCTAssertEqual(mixer.a.trimDB, -2); XCTAssertFalse(mixer.a.keyLock)
        mixer.a.togglePlay()
        XCTAssertGreaterThan(try render(mixer, seconds: 0.3), 0.01)
    }
    @MainActor
    func testRefreshWhileSavingPreservesLocalAndRemoteSlots() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let library = NativeLibrary(directory: directory)
        let original = try await library.prepare(url: audio(root))
        let remote = LibraryStorage(directory: directory)
        _ = try await remote.open()
        var localCues = original.track.hotCues; localCues[0] = 0.25
        library.edit(original.track.id, grid: original.track.grid, uncertain: original.track.gridUncertain, hotCues: localCues)
        var other = original.track; other.hotCues[7] = 2.75
        try await remote.update(other)
        await library.open(); await library.flush(); await library.open()
        XCTAssertEqual(library.tracks[0].hotCues[0], 0.25)
        XCTAssertEqual(library.tracks[0].hotCues[7], 2.75)
    }
    @MainActor
    func testTwoDeckEnduranceWithLibrarySyncLoopsCuesAndRecovery() async throws {
        guard let setting = ProcessInfo.processInfo.environment["DEX_NATIVE_SOAK_CYCLES"],
              let cycles = Int(setting), (20...2000).contains(cycles) else {
            throw XCTSkip("Set DEX_NATIVE_SOAK_CYCLES=20…2000 for the combined endurance check.")
        }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source: URL
        if let real = ProcessInfo.processInfo.environment["DEX_NATIVE_REFERENCE_AUDIO"] { source = URL(fileURLWithPath: real) }
        else { source = try audio(root, seconds: 60) } // Long enough for the cues at 30 s and every loop.
        let library = NativeLibrary(directory: root.appendingPathComponent("Library"))
        let beforeBudget = AudioMemoryBudget.shared.reservedBytes
        let mixer = NativeMixer(library: library)
        defer { mixer.shutdown(); AudioMemoryBudget.shared.setPressure(false) }
        try await load(mixer, source, both: true)
        mixer.a.toggleSync()
        let base = mixer.a.duration > 40 ? 30.0 : 0.0
        mixer.a.seek(to: base + 0.25); mixer.a.hotCue(0)
        mixer.a.seek(to: base + 2.75); mixer.a.hotCue(1)
        mixer.a.seek(to: base); mixer.b.seek(to: base)
        mixer.a.togglePlay(); mixer.b.togglePlay()
        var memory: [Double] = []
        var audiblePeak: Float = 0
        for cycle in 0..<cycles {
            let deck = cycle.isMultiple(of: 2) ? mixer.a : mixer.b
            if cycle.isMultiple(of: 5) {
                deck.beginJog()
                for _ in 0..<500 where !deck.jog.ready { try await Task.sleep(for: .milliseconds(2)) }
                deck.jog.move(displacement: 0.1)
                try render(mixer, seconds: 0.032)
                deck.jog.move(displacement: 0.2); deck.jog.release()
                try render(mixer, seconds: 0.12)
            }
            if cycle.isMultiple(of: 6) { deck.jump(direction: cycle.isMultiple(of: 12) ? 1 : -1) }
            if cycle.isMultiple(of: 9) { deck.cueDown(); deck.cueUp(); if !deck.playing { deck.togglePlay() } }
            deck.hotCue(0)
            if deck.loopActive { deck.toggleLoop() }
            deck.setLoopBeats([0.5, 1, 2, 4][cycle % 4]); deck.toggleLoop()
            XCTAssertNil(deck.error)
            audiblePeak = max(audiblePeak, try render(mixer, seconds: 0.2))
            deck.setLoopBeats([1, 2, 4, 0.5][cycle % 4])
            try render(mixer, seconds: 0.18)
            if cycle.isMultiple(of: 8) { deck.hotCue(1); try render(mixer, seconds: 0.12) }
            if cycle.isMultiple(of: 10) { mixer.setMaster(deck); deck.tempo = 1.02 }
            if cycle.isMultiple(of: 15) { deck.setGrid(bpm: 120 + Double(cycle % 3), offsetMs: 0) }
            if cycle.isMultiple(of: 20) {
                mixer.handle(.interruptionBegan); mixer.handle(.configurationChanged)
                mixer.handle(.interruptionEnded(shouldResume: true))
            }
            if cycle.isMultiple(of: 30) {
                mixer.handle(.outputChanged); mixer.a.togglePlay(); mixer.b.togglePlay()
            }
            if cycle.isMultiple(of: 40) {
                mixer.handle(.servicesLost); mixer.handle(.servicesReset)
                mixer.a.togglePlay(); mixer.b.togglePlay()
            }
            XCTAssertNil(mixer.error)
            audiblePeak = max(audiblePeak, try render(mixer, seconds: 0.12))
            XCTAssertTrue(mixer.a.playing); XCTAssertTrue(mixer.b.playing)
            deck.hotCue(7, clear: true); deck.hotCue(7)
            if cycle.isMultiple(of: 10) { await library.flush(); XCTAssertNil(library.error) }
            if cycle.isMultiple(of: 20) {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                if result == KERN_SUCCESS { memory.append(Double(info.phys_footprint) / 1_048_576) }
            }
        }
        await library.flush(); XCTAssertNil(library.error)
        XCTAssertGreaterThan(audiblePeak, 0.01)
        mixer.shutdown()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, beforeBudget)
        if memory.count > 2 {
            let warmed = memory.dropFirst()
            XCTAssertLessThan((warmed.max() ?? 0) - (warmed.min() ?? 0), 24, "Prepared audio/control work should plateau after warming")
        }
        print("TWO-DECK SOAK cycles=\(cycles) physicalMiB-every20=\(memory)")
    }
    @MainActor
    func testALoopHoldsNoMemoryOfItsOwn() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let before = AudioMemoryBudget.shared.reservedBytes
        let mixer = NativeMixer(); defer { mixer.shutdown() }
        try await load(mixer, audio(root))
        let loaded = AudioMemoryBudget.shared.reservedBytes
        mixer.a.setLoopBeats(2); mixer.a.toggleLoop()
        // The engine plays a loop from its own cache, so a loop holds no memory of its own at all.
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, loaded)
        mixer.a.togglePlay(); mixer.a.toggleLoop()
        XCTAssertTrue(mixer.a.playing); XCTAssertFalse(mixer.a.loopActive)
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, loaded)
        XCTAssertGreaterThan(try render(mixer, seconds: 0.2), 0.01)
        mixer.shutdown()
        XCTAssertEqual(AudioMemoryBudget.shared.reservedBytes, before)
    }

}

/// The process's memory, sampled every millisecond on its own thread: the most either its
/// footprint or its resident size (which counts file pages mapped in too) rose above where it
/// was when sampling began.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true, peak: Int64 = 0
    private let start: (footprint: Int64, resident: Int64)
    init() {
        start = Self.memory()
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let growth = self.growth()
                lock.withLock { peak = max(peak, growth) }
                usleep(1000)
            }
        }
    }
    private func growth() -> Int64 {
        let now = Self.memory()
        return max(now.footprint - start.footprint, now.resident - start.resident)
    }
    func stop() -> Int64 {
        let last = growth()
        return lock.withLock { running = false; return max(peak, last) }
    }
    static func memory() -> (footprint: Int64, resident: Int64) {
        var vm = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        var basic = mach_task_basic_info(), basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &basic) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount) } }
        return (Int64(vm.phys_footprint), Int64(basic.resident_size))
    }
}
