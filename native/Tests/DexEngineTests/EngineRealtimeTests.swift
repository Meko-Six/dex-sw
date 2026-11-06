import CDexDSP
import CDexEngine
import CDexEngineTestSupport
import Foundation
import XCTest
import CoreAudio

/// In the loop there's no allocation, locking, logging, file access or Swift runtime work. Two
/// checks: run every kind of thing the loop does with a counter on the system allocator, and read
/// the compiled objects' imports for anything that could lock, log, touch a file or enter Swift.
final class EngineRealtimeTests: XCTestCase {
    /// The guard must see a real allocation, or its zero means nothing.
    func testTheGuardSeesAnAllocation() {
        dex_guard_install()
        defer { dex_guard_remove() }
        let before = dex_guard_count()
        dex_guard_enter()
        dex_guard_allocate_something()
        dex_guard_leave()
        XCTAssertGreaterThan(dex_guard_count(), before)
    }

    func testRenderNeverAllocates() throws {
        var config = DexEngineConfig()
        config.sampleRate = 48_000
        config.maxFrames = 4096
        config.hostTicksPerSecond = 1e9
        let engine = dex_engine_create(&config)!
        defer { dex_engine_destroy(engine) }
        let beat = 24_000.0
        let clicks = Clicks(first: beat, spacing: beat, bed: 0.1)
        let trackA = clicks.track(seconds: 300, rate: 44_100), trackB = clicks.track(seconds: 300, rate: 48_000)
        var a = trackA.source, b = trackB.source
        dex_engine_load(engine, 0, &a, 0)
        dex_engine_load(engine, 1, &b, 0)
        var out = [[Float]](repeating: [Float](repeating: 0, count: 8192), count: 4)
        var frame: UInt64 = 0
        var allocations: UInt64 = 0
        func render(_ frames: Int) {
            var left = frames
            while left > 0 {
                let n = min(left, [64, 128, 256, 512, 1024, 480, 333, 4096][Int(frame / 7) % 8])
                dex_engine_pump_loader(engine) // the loader's work is on another thread in the app
                out.withUnsafeMutableBufferPointer { all in
                    let p = (0..<4).map { i in all[i].withUnsafeMutableBufferPointer { Optional($0.baseAddress!) } }
                    p.withUnsafeBufferPointer { list in
                        let before = dex_guard_count()
                        dex_guard_enter()
                        dex_engine_render(engine, UInt32(n), frame, list.baseAddress!, 4)
                        dex_guard_leave()
                        allocations += dex_guard_count() - before
                    }
                }
                frame += UInt64(n)
                left -= n
            }
        }
        dex_guard_install()
        defer { dex_guard_remove() }
        dex_engine_set_grid(engine, 0, beat, beat)
        dex_engine_set_grid(engine, 1, beat, beat)
        dex_engine_set_master(engine, 0)
        dex_engine_set_sync(engine, 1, true)
        dex_engine_set_tone(engine, 0, 0.5, 1, 0, 1)
        dex_engine_set_sweep(engine, 1, -0.5)
        dex_engine_set_route(engine, Int32(DEX_ROUTE_MULTICHANNEL), 0.5, 1, 1)
        dex_engine_play(engine, 0, nil)
        dex_engine_play(engine, 1, [jump(to: beat * 3, align: true)])
        render(48_000)
        for tempo in [0.84, 1.16, 1.0] { dex_engine_set_tempo(engine, 0, tempo); render(9600) }
        for target in [beat * 50, beat * 10, beat * 80] {          // seeks on both decks
            dex_engine_jump(engine, 0, [jump(to: target)])
            dex_engine_jump(engine, 1, [jump(to: target + 1000, fadeEnds: false)])
            render(24_000)
        }
        dex_engine_set_loop(engine, 0, true, beat * 90, beat * 90.5)  // short loops wrapping fast
        dex_engine_jump(engine, 0, [jump(to: beat * 90)])
        render(96_000)
        dex_engine_set_loop(engine, 0, false, 0, 0)
        dex_engine_set_key_lock(engine, 0, false); render(9600)       // key lock off and on
        dex_engine_set_key_lock(engine, 0, true); render(9600)
        dex_engine_scrub(engine, 0, true)                              // scrub, fast, both ways
        for speed in [8.0, -8.0, 2.0, 0.0] { dex_engine_scrub_velocity(engine, 0, speed, 0); render(9600) }
        dex_engine_scrub(engine, 0, false); render(9600)
        dex_engine_pause(engine, 1, -1); render(4800)                  // stop, start, master hand-over
        dex_engine_play(engine, 1, nil); render(9600)
        dex_engine_set_sync(engine, 1, false)
        dex_engine_set_master(engine, 1)
        dex_engine_set_sync(engine, 0, true)
        render(24_000)
        dex_engine_jump(engine, 1, [jump(to: beat * 100.5)])           // a real jump on the master
        render(24_000)
        dex_engine_unload(engine, 1); render(4800)                     // and losing a track
        // The app's way in: a device's buffer list and time stamp, sample time running on.
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4096), right = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { left.deallocate(); right.deallocate() }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var stamp = AudioTimeStamp()
        stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        dex_engine_play(engine, 0, nil)
        for n in [512, 512, 480, 1024, 256, 4096, 333] + Array(repeating: 512, count: 200) {
            dex_engine_pump_loader(engine)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: left)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: right)
            stamp.mSampleTime = Double(frame)
            stamp.mHostTime = frame
            let before = dex_guard_count()
            dex_guard_enter()
            dex_engine_render_list(engine, UInt32(n), &stamp, list.unsafeMutablePointer)
            dex_guard_leave()
            allocations += dex_guard_count() - before
            frame += UInt64(n)
        }
        XCTAssertEqual(allocations, 0, String(cString: dex_engine_stretcher_name(engine)))
        print("render allocations:", String(cString: dex_engine_stretcher_name(engine)), allocations, "over \(frame) frames")
        var state = DexEngineState()
        XCTAssertTrue(dex_engine_read_state(engine, &state))
        XCTAssertEqual(state.deck.0.starvedBlocks, 0)
    }

    /// The loop's code can't call what it doesn't import. The loader's file (`Source.o`) is left
    /// out, because it's meant to use locks and call into the file reader: it isn't the loop.
    func testTheLoopImportsNothingThatCouldBlock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        guard let found = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no SwiftPM build folder to read objects from")
        }
        var objects: [URL] = []
        let names: Set<String> = ["DexEngine.o", "Resample.o", "StretchBungee.o", "Stretch.o", "Stretcher.o", "Grain.o", "Grains.o",
                                  "Fourier.o", "Input.o", "Output.o", "Partials.o", "Synthesis.o", "Timing.o", "Window.o", "pffft.o", "fftpack.o",
                                  "Instrumentation.o", "DexMixer.o"]
        // The two build systems name objects differently: DexEngine.o and DexEngine.cpp.o.
        func plainName(_ url: URL) -> String {
            url.lastPathComponent.replacingOccurrences(of: ".cpp.o", with: ".o").replacingOccurrences(of: ".c.o", with: ".o")
        }
        for case let url as URL in found where names.contains(plainName(url)) && !url.path.contains("/Release/") { objects.append(url) }
        guard !objects.isEmpty else { throw XCTSkip("no engine objects found under .build") }
        XCTAssertTrue(objects.contains { plainName($0) == "DexEngine.o" })
        let forbidden = ["pthread_mutex", "pthread_cond", "pthread_rwlock", "os_unfair_lock", "dispatch_", "objc_msgSend", "swift_", "$s",
                         "os_log", "_os_log", "NSLog", "printf", "puts", "fopen", "fread", "fwrite", "open", "read", "write", "close", "lseek",
                         "ExtAudio", "AudioFile", "semaphore_wait", "usleep", "nanosleep", "sleep", "mach_msg", "mutex", "__cxa_guard_acquire"]
        for object in objects {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
            process.arguments = ["-u", object.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let symbols = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for symbol in symbols {
                let bare = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
                // PFFFT's printf is only in validate_pffft_simd, a self-test nothing here calls.
                if plainName(object) == "pffft.o", bare == "printf" || bare == "puts" { continue }
                for word in forbidden where bare == word || (bare.hasPrefix(word) && word.count > 4) || (word.hasPrefix("_") && symbol.hasPrefix(word)) {
                    XCTFail("\(object.lastPathComponent) imports \(symbol)")
                }
            }
        }
        print("real-time imports checked in \(objects.count) objects")
    }
}
