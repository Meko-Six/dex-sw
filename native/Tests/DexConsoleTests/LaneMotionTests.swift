import XCTest
import CoreGraphics
import SwiftUI
@testable import DexConsole
import DexCore

final class LaneMotionTests: XCTestCase {
    private let perPixel = 12.0 / 2096

    func testAtRestTheColumnsSitOnThePixelGrid() {
        let columns = TrackWave.columns(start: 40.1234, perPixel: perPixel, width: 2096, moving: false)
        XCTAssertEqual(columns.first, (40.1234 / perPixel).rounded(.down))
        XCTAssertEqual(columns.slide, 0)
        XCTAssertEqual(columns.count, 2096)
    }

    /// The columns stay fixed in track time and the view slides over them.
    func testMovingLandsExactlyOnTheStart() {
        for start in [-3.0, 0, 0.001, 40.1234, 299.99] {
            let columns = TrackWave.columns(start: start, perPixel: perPixel, width: 2096, moving: true)
            XCTAssertEqual((columns.first + columns.slide) * perPixel, start, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(columns.slide, 0)
            XCTAssertLessThan(columns.slide, 1)
            XCTAssertEqual(columns.count, 2097, "The extra column fills the gap the slide opens at the right")
        }
    }

    /// An even scroll has an even offset: no steps from rounding to a whole column.
    func testMovingDoesNotStep() {
        var previous: Double?
        for frame in 0..<600 {
            let start = 40 + Double(frame) / 60
            let columns = TrackWave.columns(start: start, perPixel: perPixel, width: 2096, moving: true)
            let offset = columns.first + columns.slide
            if let previous { XCTAssertEqual(offset - previous, 1 / 60 / perPixel, accuracy: 1e-6) }
            previous = offset
        }
    }

    /// Markers move with the waveform: a beat under column c stays on that column.
    func testMarkersShareTheWaveformsOffset() {
        let scale: CGFloat = 2, width: CGFloat = 1048, start = 40.1234, time = 44.5
        let span = 12.0, perPixel = span / Double(width * scale)
        let columns = TrackWave.columns(start: start, perPixel: perPixel, width: Int(width * scale), moving: true)
        let onWave = (time / perPixel - columns.first - columns.slide) / scale
        let marker = (time - start) / span * width
        XCTAssertEqual(lanePlace(marker, scale, true), onWave, accuracy: 1e-6)
    }

    func testPlaceSnapsOnlyAtRest() {
        XCTAssertEqual(lanePlace(10.3, 2, false), 10.5)
        XCTAssertEqual(lanePlace(10.3, 2, true), 10.3)
        let rect = CGRect(x: 10.3, y: 0, width: 1, height: 7)
        XCTAssertEqual(lanePlace(rect, 2, true), rect)
        XCTAssertEqual(lanePlace(rect, 2, false).minX, 10.5)
    }

    private func music(seconds: Double = 60) throws -> WaveformData {
        let count = Int(seconds * 200)
        var payload = Data(capacity: count * WaveformData.bytesPerBin)
        for index in 0..<count {
            let beat = Float((Double(index) / 96).truncatingRemainder(dividingBy: 1))
            let low = 0.6 * (1 - beat) * (1 - beat), mid = 0.1 + 0.1 * Float(index % 7) / 7, high = 0.05 + 0.15 * Float(index % 11) / 11
            WaveformData.append(WaveformBin(peak: low, rms: low, low: low, mid: mid, high: high), to: &payload)
        }
        return try WaveformData(sampleRate: 48_000, sourceFrames: Int64(count) * 240, framesPerBin: 240, payload: payload)
    }

    /// The tiles must meet exactly as if the whole view had been worked out at once.
    func testTilesMeetWithoutASeam() throws {
        let data = try music()
        for perPixel in [12.0 / 2096, 48.0 / 2096, 1.0 / 2096] {
            let first = 3 * WaveTiles.columns, width = WaveTiles.columns
            let whole = TrackWave.envelopes(data, first: Double(first), perPixel: perPixel, columns: width * 2)
            let left = TrackWave.envelopes(data, first: Double(first), perPixel: perPixel, columns: width + 2)
            let right = TrackWave.envelopes(data, first: Double(first + width), perPixel: perPixel, columns: width + 2)
            let joined = Array(left[0..<(width * 3)]) + Array(right[0..<(width * 3)])
            let differing = zip(joined, whole).enumerated().filter { abs($1.0 - $1.1) > 1e-4 }
            XCTAssertEqual(differing.count, 0, "\(perPixel)")
        }
    }

    func testTilesAreReusedAndBounded() throws {
        let data = try music()
        let shape = TrackWave.Shape(height: 148, oneSided: false, amp: 0.96)
        let tiles = WaveTiles(limit: 2 << 20)
        let first = try XCTUnwrap(tiles.tile(data: data, index: 0, perPixel: 12.0 / 2096, shape: shape, density: 1))
        XCTAssertTrue(tiles.tile(data: data, index: 0, perPixel: 12.0 / 2096, shape: shape, density: 1) === first)
        XCTAssertEqual(tiles.built, 1)
        XCTAssertFalse(tiles.tile(data: data, index: 0, perPixel: 24.0 / 2096, shape: shape, density: 1) === first, "Zoom changes the tile")
        XCTAssertFalse(tiles.tile(data: data, index: 0, perPixel: 12.0 / 2096, shape: shape, density: 2) === first, "Density changes the tile")
        for index in 0..<200 { _ = tiles.tile(data: data, index: index, perPixel: 12.0 / 2096, shape: shape, density: 1) }
        XCTAssertLessThanOrEqual(tiles.residentBytes, 2 << 20)
    }

    /// Tiled and direct drawing are the same picture, so pausing changes nothing visible.
    @MainActor func testTiledDrawingMatchesDirectDrawing() throws {
        let data = try music()
        func render(tiled: Bool) throws -> [UInt8] {
            let view = TrackWave(data: data, start: 10.125, span: 12, tiled: tiled).frame(width: 1048, height: 74).background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return pixels
        }
        let direct = try render(tiled: false), tiled = try render(tiled: true)
        XCTAssertEqual(direct.count, tiled.count)
        var differing = 0
        for index in direct.indices where abs(Int(direct[index]) - Int(tiled[index])) > 40 { differing += 1 }
        XCTAssertLessThan(Double(differing) / Double(direct.count), 0.001)
    }

    private func wave() throws -> WaveformData {
        var payload = Data()
        for _ in 0..<100 { WaveformData.append(WaveformBin(peak: 1, rms: 1, low: 1, mid: 1, high: 1), to: &payload) }
        return try WaveformData(sampleRate: 48_000, sourceFrames: 24_000, framesPerBin: 240, payload: payload)
    }

    func testAWaveformOnlyRedrawsWhenItChanges() throws {
        let data = try wave()
        let wave = TrackWave(data: data, start: 0, span: 0.5, oneSided: true)
        XCTAssertEqual(wave, TrackWave(data: data, start: 0, span: 0.5, oneSided: true))
        XCTAssertNotEqual(wave, TrackWave(data: data, start: 0.1, span: 0.5, oneSided: true))
        XCTAssertNotEqual(wave, TrackWave(data: try self.wave(), start: 0, span: 0.5, oneSided: true))
    }

    /// Only a deck's own clock speaks up, and a playing lane publishes nothing.
    @MainActor func testClocksAreSeparate() {
        let clock = ConsoleClock()
        var heard = 0
        let listening = clock.lane("A").objectWillChange.sink { _ in heard += 1 }
        clock.lane("A").set(1, publish: false)
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(clock.lane("A").position, 1)
        clock.lane("A").set(2, publish: true)
        XCTAssertEqual(heard, 1)
        clock.lane("B").set(3, publish: true)
        clock.deck("A").position = 4
        clock.meter.meters = .silent
        XCTAssertEqual(heard, 1)
        XCTAssertTrue(clock.lane("A") === clock.lane("A"))
        withExtendedLifetime(listening) {}
    }

    /// A frame moves only lanes whose deck plays; stopping leaves none mid-frame.
    @MainActor func testFramesMoveOnlyPlayingLanes() {
        let clock = ConsoleClock()
        clock.lane("A").heard = { 10 + $0 }
        clock.lane("B").heard = { _ in nil }
        clock.lane("B").set(5, publish: false)
        clock.running = true
        var stillLaneSpoke = 0
        let listening = clock.lane("B").objectWillChange.sink { _ in stillLaneSpoke += 1 }
        clock.frame(ahead: 0.25)
        clock.frame(ahead: 0.25)
        XCTAssertEqual(stillLaneSpoke, 0)
        withExtendedLifetime(listening) {}
        XCTAssertEqual(clock.lane("A").moving, 10.25)
        XCTAssertNil(clock.lane("B").moving)
        XCTAssertEqual(clock.lane("B").position, 5)
        clock.running = false
        XCTAssertNil(clock.lane("A").moving)
    }
}
