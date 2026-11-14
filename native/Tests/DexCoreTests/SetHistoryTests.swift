import XCTest
import DexCore

/// The set history: what the crowd heard, the played marks, NEW SET, and when a track counts.
final class SetHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlaysMarkTracksUntilANewSet() {
        var history = SetHistory(now: start)
        history.record("a", at: start.addingTimeInterval(60))
        history.record("b", at: start.addingTimeInterval(300))
        XCTAssertEqual(history.played, ["a", "b"])
        history.newSet(at: start.addingTimeInterval(3600))
        XCTAssertEqual(history.played, [])
        XCTAssertEqual(history.sets.count, 2)
        XCTAssertEqual(history.sets[0].plays.map(\.track), ["a", "b"])
    }

    func testNewSetOnAnEmptySetMakesNoEmptySets() {
        var history = SetHistory(now: start)
        history.newSet(at: start.addingTimeInterval(10))
        history.newSet(at: start.addingTimeInterval(20))
        XCTAssertEqual(history.sets.count, 1)
        XCTAssertEqual(history.current.startedAt, start.addingTimeInterval(20))
    }

    func testASetSavesAsAPlaylistInPlayOrderEachOnce() {
        var history = SetHistory(now: start)
        for track in ["b", "a", "b", "c"] { history.record(track, at: start) }
        XCTAssertEqual(history.tracks(of: history.current.id), ["b", "a", "c"])
    }

    func testForgottenAndUnknownTracksLeaveEverySet() {
        var history = SetHistory(now: start)
        history.record("a", at: start); history.record("gone", at: start)
        history.newSet(at: start)
        history.record("a", at: start)
        history.forget("a")
        XCTAssertEqual(history.sets.flatMap(\.plays).map(\.track), ["gone"])
        let kept = SetHistory.normalize(history, known: ["a"])
        XCTAssertTrue(kept.sets.allSatisfy(\.plays.isEmpty))
    }

    func testOnlyWhatTheCrowdHearsCounts() {
        XCTAssertTrue(PlayCounter.heard(playing: true, previewing: false, level: 1, crossfadeSide: 1))
        XCTAssertFalse(PlayCounter.heard(playing: true, previewing: true, level: 1, crossfadeSide: 1), "a CUE preview")
        XCTAssertFalse(PlayCounter.heard(playing: false, previewing: false, level: 1, crossfadeSide: 1))
        XCTAssertFalse(PlayCounter.heard(playing: true, previewing: false, level: 0.2, crossfadeSide: 1), "LEVEL nearly down")
        XCTAssertFalse(PlayCounter.heard(playing: true, previewing: false, level: 1, crossfadeSide: 0), "crossfader on the other side")
    }

    func testATrackCountsOnceAfterThirtySecondsHeardInAll() {
        var counter = PlayCounter()
        let track = UUID()
        var counted: [UUID] = []
        for second in 0..<70 {
            // Heard for 20 s, cut for 10 s, then heard again: it counts at 30 s heard, once.
            let heard = !(20..<30).contains(second)
            if let id = counter.advance(deck: "A", track: track, heard: heard, dt: 1) { counted.append(id) }
            if second == 38 { XCTAssertTrue(counted.isEmpty) }
            if second == 39 { XCTAssertEqual(counted, [track]) }
        }
        XCTAssertEqual(counted, [track])
    }

    func testANewTrackOnTheDeckStartsItsOwnCount() {
        var counter = PlayCounter()
        let first = UUID(), second = UUID()
        for _ in 0..<20 { _ = counter.advance(deck: "A", track: first, heard: true, dt: 1) }
        var counted: UUID?
        for _ in 0..<29 { counted = counter.advance(deck: "A", track: second, heard: true, dt: 1) ?? counted }
        XCTAssertNil(counted)
        XCTAssertEqual(counter.advance(deck: "A", track: second, heard: true, dt: 1), second)
    }
}
