import XCTest
@testable import DexCore

/// The playlist rules of `src/shared/playlist.ts`.
final class PlaylistsTests: XCTestCase {
    func testNewPlaylistsTakeTheNextFreeName() {
        var lists = Playlists.create([], id: "a")
        lists = Playlists.create(lists, id: "b")
        lists = Playlists.create(lists, id: "c", name: "new PLAYLIST")
        XCTAssertEqual(lists.map(\.name), ["New playlist", "New playlist 2", "new PLAYLIST 3"])
    }

    func testRenameKeepsNamesApartAndIgnoresBlanks() {
        let lists = [Playlist(id: "a", name: "Warm up"), Playlist(id: "b", name: "Peak")]
        XCTAssertEqual(Playlists.rename(lists, id: "b", to: "warm up")[1].name, "warm up 2")
        XCTAssertEqual(Playlists.rename(lists, id: "a", to: "Warm up")[0].name, "Warm up")
        XCTAssertEqual(Playlists.rename(lists, id: "a", to: "   "), lists)
    }

    func testAddAppendsOnlyNewTracksInOrder() {
        let lists = [Playlist(id: "a", name: "A", trackIDs: ["1"])]
        XCTAssertEqual(Playlists.add(lists, id: "a", tracks: ["2", "1", "3", "2"])[0].trackIDs, ["1", "2", "3"])
        XCTAssertEqual(Playlists.remove(lists, id: "a", track: "1")[0].trackIDs, [])
        XCTAssertEqual(Playlists.delete(lists, id: "a"), [])
    }

    func testForgetTakesATrackOutOfEveryPlaylist() {
        let lists = [Playlist(id: "a", name: "A", trackIDs: ["1", "2"]), Playlist(id: "b", name: "B", trackIDs: ["2"])]
        XCTAssertEqual(Playlists.forget(lists, track: "2").map(\.trackIDs), [["1"], []])
    }

    func testSavedPlaylistsAreMadeSafe() {
        let saved = [Playlist(id: "a", name: " ", trackIDs: ["1", "gone", "1", "2"]),
                     Playlist(id: "a", name: "Twice"), Playlist(id: "", name: "No id")]
        let lists = Playlists.normalize(saved, known: ["1", "2"])
        XCTAssertEqual(lists, [Playlist(id: "a", name: "New playlist", trackIDs: ["1", "2"])])
    }
}
