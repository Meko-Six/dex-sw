import Foundation
import DexCore

/// The deck's loop: off, or a region and its bounds. A request commits at once, because the
/// engine plays loops from its own cache; only the deck decides when a moved loop lands.
@MainActor
final class DeckLoopController {
    struct Prepared { let region: LoopRegion; let audio: LoopAudio }
    private(set) var current: Prepared? { willSet { changed?() } }
    private(set) var beats = 8.0 { willSet { if beats != newValue { changed?() } } }
    var changed: (() -> Void)?
    /// The loop is in place; the shift is how far it moved the playhead (bar jumps), 0 for a resize.
    var committed: ((LoopAudio, Double) -> Void)?
    var failed: ((DeckProblem) -> Void)?
    /// The loaded file's rate, which loop bounds are rounded to.
    var sampleRate = 48_000.0
    func select(_ beats: Double) { self.beats = beats }
    func request(_ region: LoopRegion, shift: Double = 0, grid: BeatGrid, duration: Double) -> Bool {
        let bounds = region.bounds(grid: grid)
        guard bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              bounds.lowerBound >= 0, bounds.upperBound <= duration else {
            failed?(.loopOutsideTrack); return false
        }
        let audio = LoopAudio(start: bounds.lowerBound, end: bounds.upperBound, sampleRate: sampleRate)
        current = Prepared(region: region, audio: audio)
        committed?(audio, shift)
        return true
    }
    func clear() { current = nil }
}
