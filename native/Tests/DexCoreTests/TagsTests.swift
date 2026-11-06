import XCTest
@testable import DexCore

/// Ports `tests/tags.test.ts`.
final class TagsTests: XCTestCase {
    private let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]
    private let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 4, 5]

    private func bytes(_ parts: Any...) -> [UInt8] {
        parts.flatMap { part -> [UInt8] in
            if let text = part as? String { return Array(text.utf8) }
            if let raw = part as? [UInt8] { return raw }
            return (part as! [Int]).map { UInt8($0) }
        }
    }
    private func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    private func le32(_ n: Int) -> [UInt8] { be32(n).reversed() }
    private func safe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 127), UInt8(n >> 14 & 127), UInt8(n >> 7 & 127), UInt8(n & 127)] }
    private func id3(_ major: Int, _ frames: [UInt8]) -> [UInt8] { bytes("ID3", [major, 0, 0], safe(frames.count), frames) }
    private func frame(_ major: Int, _ id: String, _ body: [UInt8]) -> [UInt8] {
        bytes(id, major == 4 ? safe(body.count) : be32(body.count), [0, 0], body)
    }
    private func read(_ raw: [UInt8]) -> Tags { Tags.read(Data(raw)) }

    func testId3v23Utf16TextAndAPicture() {
        let utf16 = { (text: String) -> [UInt8] in [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] } }
        let frames = bytes(
            frame(3, "TIT2", bytes([1], utf16("Ocean"))),
            frame(3, "TPE1", bytes([1], utf16("Patrick Topping"))),
            frame(3, "APIC", bytes([0], "image/jpg", [0, 3], "cover", [0], jpeg)))
        let tags = read(bytes(id3(3, frames), [0xFF, 0xFB, 0, 0]))
        XCTAssertEqual(tags.title, "Ocean")
        XCTAssertEqual(tags.artist, "Patrick Topping")
        XCTAssertEqual(tags.picture?.mime, "image/jpeg")
        XCTAssertEqual(tags.picture.map { Array($0.data) }, jpeg)
    }

    func testId3v24Utf8FramesWithSynchsafeSizes() {
        let frames = bytes(frame(4, "TIT2", bytes([3], "Glüe")), frame(4, "TPE1", bytes([3], "Bicep")))
        XCTAssertEqual(read(id3(4, frames)), Tags(artist: "Bicep", title: "Glüe"))
    }

    func testFlacVorbisCommentsAndThePictureBlock() {
        let comments = ["TITLE=Latch", "artist=Disclosure"]
        let vorbis = bytes(le32(3), "Dex", le32(comments.count), comments.flatMap { bytes(le32($0.utf8.count), $0) })
        let picture = bytes(be32(3), be32(9), "image/png", be32(0), be32(1), be32(1), be32(24), be32(0), be32(png.count), png)
        let block = { (type: Int, body: [UInt8], last: Bool) -> [UInt8] in
            self.bytes([(last ? 0x80 : 0) | type, body.count >> 16 & 255, body.count >> 8 & 255, body.count & 255], body)
        }
        let tags = read(bytes("fLaC", block(0, [UInt8](repeating: 0, count: 34), false), block(4, vorbis, false), block(6, picture, true)))
        XCTAssertEqual(tags.title, "Latch")
        XCTAssertEqual(tags.artist, "Disclosure")
        XCTAssertEqual(tags.picture.map { Array($0.data) }, png)
    }

    func testMp4ItemList() {
        // Atom types are bytes: '©' is 0xa9, not UTF-8.
        let atom = { (type: String, body: [UInt8]) -> [UInt8] in
            self.bytes(self.be32(8 + body.count), type.unicodeScalars.map { UInt8($0.value) }, body)
        }
        let data = { (kind: Int, payload: [UInt8]) -> [UInt8] in atom("data", self.bytes(self.be32(kind), self.be32(0), payload)) }
        let ilst = atom("ilst", bytes(atom("©nam", data(1, bytes("Jealous"))), atom("©ART", data(1, bytes("Mochakk"))),
                                      atom("covr", data(13, jpeg))))
        let file = bytes(atom("ftyp", bytes("M4A ", be32(0))), atom("moov", atom("udta", atom("meta", bytes(be32(0), ilst)))))
        let tags = read(file)
        XCTAssertEqual(tags.title, "Jealous")
        XCTAssertEqual(tags.artist, "Mochakk")
        XCTAssertEqual(tags.picture.map { Array($0.data) }, jpeg)
    }

    func testAiffId3ChunkAndAnythingUnreadable() {
        let tag = id3(3, frame(3, "TIT2", bytes([0], "Glue")))
        let aiff = bytes("FORM", be32(4 + 8 + tag.count), "AIFF", "ID3 ", be32(tag.count), tag)
        XCTAssertEqual(read(aiff).title, "Glue")
        XCTAssertEqual(read([UInt8](repeating: 0, count: 16)), Tags())
        XCTAssertEqual(read(bytes("ID3", [3, 0, 0], safe(50))), Tags())
    }

    /// Truncated and hostile input reads as empty or partial, never traps.
    func testTruncatedTagsNeverTrap() {
        let frames = bytes(frame(3, "TIT2", bytes([1], [0xFF, 0xFE, 0x4F, 0])), frame(3, "APIC", bytes([1], "image/png", [0, 3], [0x41, 0], jpeg)))
        let whole = id3(3, frames)
        for length in 0...whole.count { _ = read(Array(whole.prefix(length))) }
        let deep = (0..<200).reduce([UInt8]()) { inner, _ in bytes(be32(8 + inner.count), "moov", inner) }
        XCTAssertEqual(read(bytes([0, 0, 0, 8], "ftyp") + deep), Tags())
        XCTAssertEqual(read(bytes([0, 0, 0, 8], "ftyp", [0, 0, 0, 1], "moov", [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])), Tags())
    }
}

/// Label, genre, subgenre, remixer and release, for the library's MORE.
final class TagDetailsTests: XCTestCase {
    private func bytes(_ parts: Any...) -> [UInt8] {
        parts.flatMap { part -> [UInt8] in
            if let text = part as? String { return Array(text.utf8) }
            if let raw = part as? [UInt8] { return raw }
            return (part as! [Int]).map { UInt8($0) }
        }
    }
    private func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    private func le32(_ n: Int) -> [UInt8] { be32(n).reversed() }
    private func safe(_ n: Int) -> [UInt8] { [UInt8(n >> 21 & 127), UInt8(n >> 14 & 127), UInt8(n >> 7 & 127), UInt8(n & 127)] }
    private func text(_ id: String, _ value: String) -> [UInt8] {
        let body = bytes([3], value)
        return bytes(id, safe(body.count), [0, 0], body)
    }
    private func id3(_ frames: [UInt8]) -> Tags { Tags.read(Data(bytes("ID3", [4, 0, 0], safe(frames.count), frames))) }

    func testId3ReadsTheDetailsAndPrefersTheReleaseDate() {
        let custom = bytes([3], "SUBGENRE", [0], "Progressive")
        let tags = id3(bytes(text("TALB", "Hidden Patterns"), text("TCON", "Psy-Trance"), text("TPE4", "Rinkadink"),
                             text("TDRC", "2018-01-01"), text("TDRL", "2019-12-09"),
                             bytes("TXXX", safe(custom.count), [0, 0], custom)))
        XCTAssertEqual(tags.album, "Hidden Patterns")
        XCTAssertEqual(tags.genre, "Psy-Trance")
        XCTAssertEqual(tags.remixer, "Rinkadink")
        XCTAssertEqual(tags.release, "2019-12-09")
        XCTAssertEqual(tags.subgenre, "Progressive")
    }

    func testGenreNumbersFromId3v1ReadAsNone() {
        XCTAssertNil(id3(text("TCON", "(17)")).genre)
        XCTAssertNil(id3(text("TCON", "17")).genre)
        XCTAssertEqual(id3(text("TCON", "(17)Rock")).genre, "Rock")
    }

    func testFlacCommentsNameTheDetails() {
        let comments = ["ALBUM=Iboga", "GENRE=Psy-Trance", "SUBGENRE=Full-On", "REMIXER=Silent Sphere", "DATE=2019"]
        let vorbis = bytes(le32(3), "Dex", le32(comments.count), comments.flatMap { bytes(le32($0.utf8.count), $0) })
        let block = bytes([0x84, vorbis.count >> 16 & 255, vorbis.count >> 8 & 255, vorbis.count & 255], vorbis)
        let tags = Tags.read(Data(bytes("fLaC", block)))
        XCTAssertEqual(tags, Tags(album: "Iboga", genre: "Psy-Trance", subgenre: "Full-On", remixer: "Silent Sphere", release: "2019"))
    }

    func testMp4GenreDayAndFreeformAlbum() {
        func atom(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] { bytes(be32(body.count + 8), type, body) }
        func item(_ type: [UInt8], _ value: String) -> [UInt8] { atom(type, atom(Array("data".utf8), bytes(be32(1), be32(0), value))) }
        let free = atom(Array("----".utf8), bytes(atom(Array("mean".utf8), bytes(be32(0), "com.apple.iTunes")),
                                                  atom(Array("name".utf8), bytes(be32(0), "ALBUM")),
                                                  atom(Array("data".utf8), bytes(be32(1), be32(0), "Iboga"))))
        let list = atom(Array("ilst".utf8), bytes(item([0xA9, 0x67, 0x65, 0x6E], "Psy-Trance"), item([0xA9, 0x64, 0x61, 0x79], "2019-12-09"), free))
        let raw = bytes(atom(Array("ftyp".utf8), Array("M4A ".utf8)), atom(Array("moov".utf8), atom(Array("udta".utf8), atom(Array("meta".utf8), bytes(be32(0), list)))))
        let tags = Tags.read(Data(raw))
        XCTAssertEqual(tags.genre, "Psy-Trance")
        XCTAssertEqual(tags.release, "2019-12-09")
        XCTAssertEqual(tags.album, "Iboga")
    }

    func testReleaseTextFollowsTheLocale() {
        let british = Locale(identifier: "en_GB"), american = Locale(identifier: "en_US")
        XCTAssertEqual(Tags.releaseText("2019-12-09", locale: british), "09/12/2019")
        XCTAssertEqual(Tags.releaseText("2019-12-09T00:00:00Z", locale: british), "09/12/2019")
        XCTAssertEqual(Tags.releaseText("2019-12-09", locale: american), "12/9/19")
        XCTAssertEqual(Tags.releaseText("2019-12", locale: british), "12/2019")
        XCTAssertEqual(Tags.releaseText("2019", locale: british), "2019")
        XCTAssertEqual(Tags.releaseText("summer", locale: british), "summer")
    }

    func testReleaseTextKeepsTheMonthOfAnImpossibleDay() {
        XCTAssertEqual(Tags.releaseText("2019-02-31", locale: Locale(identifier: "en_GB")), "02/2019")
    }

    func testAMp4AlbumItemIsRead() {
        func atom(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] { bytes(be32(body.count + 8), type, body) }
        let item = atom([0xA9, 0x61, 0x6C, 0x62], atom(Array("data".utf8), bytes(be32(1), be32(0), "Hidden Patterns")))
        let raw = bytes(atom(Array("ftyp".utf8), Array("M4A ".utf8)), atom(Array("moov".utf8), atom(Array("udta".utf8), atom(Array("meta".utf8), bytes(be32(0), atom(Array("ilst".utf8), item))))))
        XCTAssertEqual(Tags.read(Data(raw)).album, "Hidden Patterns")
    }
}
