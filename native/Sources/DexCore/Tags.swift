import Foundation

/// A cover image as the tags hold it.
public struct TagPicture: Equatable, Sendable {
    public let mime: String
    public let data: Data
    public init(mime: String, data: Data) { self.mime = mime; self.data = data }
}

/// Names, the release details and cover art from an audio file's tags, for the
/// track windows and the library's MORE. Ports `src/shared/tags.ts`: ID3v2 (MP3, and the ID3 chunk in AIFF
/// and WAV), FLAC's Vorbis comments and PICTURE block, and the MP4 item list
/// (M4A / AAC). Anything else, or a malformed tag, reads as empty. Album, genre,
/// subgenre, remixer and release come after that port, for MORE.
public struct Tags: Equatable, Sendable {
    public var artist: String?
    public var title: String?
    public var picture: TagPicture?
    public var album: String?
    public var genre: String?
    /// No format has a standard field for this: a custom SUBGENRE tag only.
    public var subgenre: String?
    public var remixer: String?
    /// As the tag writes it, e.g. "2019-12-09"; `Tags.releaseText` formats it.
    public var release: String?
    public init(artist: String? = nil, title: String? = nil, picture: TagPicture? = nil, album: String? = nil,
                genre: String? = nil, subgenre: String? = nil, remixer: String? = nil, release: String? = nil) {
        self.artist = artist; self.title = title; self.picture = picture; self.album = album
        self.genre = genre; self.subgenre = subgenre; self.remixer = remixer; self.release = release
    }

    /// A custom tag's value by its name: a TXXX frame, a Vorbis comment or an MP4 freeform item.
    mutating func fill(custom name: String, _ value: String?) {
        switch name.uppercased() {
        case "ALBUM": album = album ?? value
        case "GENRE": genre = genre ?? value.flatMap(Tags.cleanGenre)
        case "SUBGENRE": subgenre = subgenre ?? value
        case "REMIXER", "MIXARTIST": remixer = remixer ?? value
        case "RELEASEDATE", "DATE", "YEAR": release = release ?? value
        default: break
        }
    }

    /// The first genre, without ID3v1's "(17)" number; a number alone reads as none.
    static func cleanGenre(_ raw: String) -> String? {
        let first = raw.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        let named = first.replacingOccurrences(of: #"^\(\d+\)"#, with: "", options: .regularExpression)
        guard !named.isEmpty, named.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil else { return nil }
        return clean(named)
    }

    /// An ISO date in the system's short format, as System Settings has it;
    /// the month and year from less, the year alone from less again; anything else as written.
    public static func releaseText(_ raw: String, locale: Locale? = nil) -> String {
        let parts = raw.prefix(10).split(separator: "-").map { Int($0) }
        guard let year = parts.first ?? nil, raw.count >= 4 else { return raw }
        var date = DateComponents(calendar: Calendar(identifier: .gregorian), year: year)
        guard parts.count > 1, let month = parts[1], (1...12).contains(month) else { return String(year) }
        date.month = month
        let monthText = locale.map(monthFormatter) ?? currentMonth
        guard parts.count > 2, let day = parts[2], (1...31).contains(day) else { return monthText.string(from: date.date!) }
        date.day = day
        guard date.isValidDate, let whole = date.date else { return monthText.string(from: Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month))!) }
        return (locale.map(dayFormatter) ?? currentDay).string(from: whole)
    }
    private static let currentDay = dayFormatter(.autoupdatingCurrent)
    private static let currentMonth = monthFormatter(.autoupdatingCurrent)
    private static func dayFormatter(_ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }
    private static func monthFormatter(_ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMM")
        return formatter
    }

    /// The file mapped rather than read, so a long WAV costs no memory beyond
    /// the pages the tag sits on.
    public static func read(url: URL) -> Tags {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Tags() }
        return read(data)
    }

    public static func read(_ data: Data) -> Tags {
        data.withUnsafeBytes { raw in
            let bytes = Bytes(raw.bindMemory(to: UInt8.self))
            if bytes.ascii(0, 3) == "ID3" { return readId3(bytes, 0) }
            if bytes.ascii(0, 4) == "fLaC" { return readFlac(bytes) }
            if bytes.ascii(4, 4) == "ftyp" { return readMp4(bytes) }
            if bytes.ascii(0, 4) == "FORM" || bytes.ascii(0, 4) == "RIFF" { return readChunks(bytes) }
            return Tags()
        }
    }
}

/// A view of the file with `Uint8Array`'s forgiving reads: an index past the
/// end reads 0 and a range clamps to the bytes there are.
private struct Bytes {
    let base: UnsafeBufferPointer<UInt8>
    let start: Int
    let count: Int
    init(_ base: UnsafeBufferPointer<UInt8>) { self.base = base; start = 0; count = base.count }
    private init(base: UnsafeBufferPointer<UInt8>, start: Int, count: Int) { self.base = base; self.start = start; self.count = count }

    subscript(_ i: Int) -> Int { i >= 0 && i < count ? Int(base[start + i]) : 0 }

    func sub(_ from: Int, _ to: Int? = nil) -> Bytes {
        let lower = min(max(0, from), count), upper = min(max(0, to ?? count), count)
        return Bytes(base: base, start: start + lower, count: max(0, upper - lower))
    }
    var array: [UInt8] { count == 0 ? [] : Array(base[start..<(start + count)]) }
    var data: Data { count == 0 ? Data() : Data(base[start..<(start + count)]) }

    func ascii(_ at: Int, _ length: Int) -> String {
        String(String.UnicodeScalarView(sub(at, at + length).array.map { Unicode.Scalar($0) }))
    }
    /// The bytes match `pattern` exactly (atom types such as "©nam" are bytes, not UTF-8).
    func matches(_ at: Int, _ pattern: [UInt8]) -> Bool { sub(at, at + pattern.count).array == pattern }

    func u32be(_ i: Int) -> Int { self[i] << 24 | self[i + 1] << 16 | self[i + 2] << 8 | self[i + 3] }
    func u32le(_ i: Int) -> Int { self[i] | self[i + 1] << 8 | self[i + 2] << 16 | self[i + 3] << 24 }
    func synchsafe(_ i: Int) -> Int { self[i] << 21 | self[i + 1] << 14 | self[i + 2] << 7 | self[i + 3] }

    func indexOfZero(from: Int) -> Int? {
        var i = max(0, from)
        while i < count { if self[i] == 0 { return i }; i += 1 }
        return nil
    }
}

private func clean(_ text: String) -> String? {
    var value = Substring(text)
    while value.unicodeScalars.last == "\0" { value = Substring(value.unicodeScalars.dropLast()) }
    // `String.prototype.trim` also takes the byte-order mark.
    let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
    return trimmed.isEmpty ? nil : trimmed
}

/// `TextDecoder`'s UTF-8, UTF-16 and "latin1", which the WHATWG spec reads as windows-1252.
private func decodeText(_ bytes: Bytes, _ encoding: Int) -> String {
    let text: String
    if encoding == 1 || encoding == 2 {
        var little = encoding == 1, start = 0
        if encoding == 1, bytes.count >= 2 {
            if bytes[0] == 0xFF, bytes[1] == 0xFE { start = 2 }
            else if bytes[0] == 0xFE, bytes[1] == 0xFF { little = false; start = 2 }
        }
        let body = bytes.sub(start, start + ((bytes.count - start) & ~1))
        let units = stride(from: 0, to: body.count, by: 2).map {
            UInt16(little ? body[$0] | body[$0 + 1] << 8 : body[$0] << 8 | body[$0 + 1])
        }
        text = String(decoding: units, as: UTF16.self)
    } else if encoding == 3 {
        return utf8(bytes)
    } else {
        return String(String.UnicodeScalarView(bytes.array.map(windows1252)))
    }
    return droppingMark(text)
}

private func utf8(_ bytes: Bytes) -> String { droppingMark(String(decoding: bytes.array, as: UTF8.self)) }

/// The UTF decoders drop a leading byte-order mark.
private func droppingMark(_ text: String) -> String {
    text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
}

private let cp1252High: [UInt32] = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178
]
private func windows1252(_ byte: UInt8) -> Unicode.Scalar {
    (0x80...0x9F).contains(byte) ? Unicode.Scalar(cp1252High[Int(byte) - 0x80])! : Unicode.Scalar(byte)
}

/// Index of the terminator that ends an encoded string, and its width.
private func terminator(_ bytes: Bytes, from: Int, encoding: Int) -> (Int, Int) {
    if encoding == 1 || encoding == 2 {
        var i = from
        while i + 1 < bytes.count { if bytes[i] == 0, bytes[i + 1] == 0 { return (i, 2) }; i += 2 }
        return (bytes.count, 0)
    }
    return bytes.indexOfZero(from: from).map { ($0, 1) } ?? (bytes.count, 0)
}

private func readId3(_ bytes: Bytes, _ at: Int) -> Tags {
    let major = bytes[at + 3], flags = bytes[at + 5]
    let end = min(bytes.count, at + 10 + bytes.synchsafe(at + 6))
    let v22 = major == 2
    let idLength = v22 ? 3 : 4, headerLength = v22 ? 6 : 10
    var i = at + 10
    // An extended header (v2.3 / v2.4) sits between the tag header and the frames.
    if !v22, flags & 0x40 != 0 { i += major == 4 ? bytes.synchsafe(i) : bytes.u32be(i) + 4 }
    var tags = Tags()
    var released: String?, recorded: String?, year: String?, dayMonth: String?
    while i + headerLength <= end {
        let id = bytes.ascii(i, idLength)
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { break }
        let size = v22 ? bytes[i + 3] << 16 | bytes[i + 4] << 8 | bytes[i + 5]
            : major == 4 ? bytes.synchsafe(i + 4) : bytes.u32be(i + 4)
        let body = bytes.sub(i + headerLength, min(end, i + headerLength + size))
        i += headerLength + size
        if body.count == 0 { continue }
        if id == "TIT2" || id == "TT2" { tags.title = tags.title ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TPE1" || id == "TP1" { tags.artist = tags.artist ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TALB" || id == "TAL" { tags.album = tags.album ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TCON" || id == "TCO" { tags.genre = tags.genre ?? Tags.cleanGenre(decodeText(body.sub(1), body[0])) }
        else if id == "TPE4" || id == "TP4" { tags.remixer = tags.remixer ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TDRL" { released = released ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TDRC" { recorded = recorded ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TYER" || id == "TYE" { year = year ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TDAT" || id == "TDA" { dayMonth = dayMonth ?? clean(decodeText(body.sub(1), body[0])) }
        else if id == "TXXX" || id == "TXX" {
            let (nameEnd, width) = terminator(body, from: 1, encoding: body[0])
            tags.fill(custom: decodeText(body.sub(1, nameEnd), body[0]), clean(decodeText(body.sub(nameEnd + width), body[0])))
        }
        else if id == "APIC" || id == "PIC", tags.picture == nil {
            let encoding = body[0]
            let mime: String, p: Int
            if v22 {
                mime = body.ascii(1, 3).uppercased() == "PNG" ? "image/png" : "image/jpeg"
                p = 4
            } else {
                let (mimeEnd, _) = terminator(body, from: 1, encoding: 0)
                let label = body.ascii(1, mimeEnd - 1)
                mime = label.isEmpty ? "image/jpeg" : label
                p = mimeEnd + 1
            }
            let (descEnd, width) = terminator(body, from: p + 1, encoding: encoding)
            let data = body.sub(descEnd + width)
            if data.count > 0 { tags.picture = TagPicture(mime: normaliseMime(mime, data), data: data.data) }
        }
    }
    // v2.3 splits the date: TDAT is DDMM.
    let dated = year.map { year in dayMonth.flatMap { $0.count == 4 ? "\(year)-\($0.suffix(2))-\($0.prefix(2))" : nil } ?? year }
    tags.release = released ?? recorded ?? dated ?? tags.release
    return tags
}

private func readFlac(_ bytes: Bytes) -> Tags {
    var tags = Tags()
    var i = 4
    while i + 4 <= bytes.count {
        let header = bytes[i], type = header & 0x7F
        let length = bytes[i + 1] << 16 | bytes[i + 2] << 8 | bytes[i + 3]
        let block = bytes.sub(i + 4, i + 4 + length)
        if type == 4 {
            let comments = vorbisComments(block)
            tags.title = tags.title ?? comments.title
            tags.artist = tags.artist ?? comments.artist
            tags.album = tags.album ?? comments.album
            tags.genre = tags.genre ?? comments.genre
            tags.subgenre = tags.subgenre ?? comments.subgenre
            tags.remixer = tags.remixer ?? comments.remixer
            tags.release = tags.release ?? comments.release
        } else if type == 6, tags.picture == nil {
            var p = 4
            let mimeLength = block.u32be(p)
            let mime = block.ascii(p + 4, mimeLength)
            p += 4 + mimeLength
            p += 4 + block.u32be(p) + 16
            let dataLength = block.u32be(p)
            let data = block.sub(p + 4, p + 4 + dataLength)
            if data.count > 0 { tags.picture = TagPicture(mime: normaliseMime(mime, data), data: data.data) }
        }
        i += 4 + length
        if header & 0x80 != 0 { break }
    }
    return tags
}

private func vorbisComments(_ block: Bytes) -> Tags {
    var tags = Tags()
    var p = 4 + block.u32le(0)
    let count = block.u32le(p)
    p += 4
    var n = 0
    while n < count, p + 4 <= block.count {
        let length = block.u32le(p)
        let entry = utf8(block.sub(p + 4, p + 4 + length))
        p += 4 + length
        n += 1
        // `indexOf` misses as -1, so `slice(0, -1)` and `slice(0)`.
        let eq = entry.firstIndex(of: "=")
        let key = (eq.map { entry[..<$0] } ?? entry.dropLast()).uppercased()
        let value = clean(String(eq.map { entry[entry.index(after: $0)...] } ?? entry[...]))
        if key == "TITLE" { tags.title = tags.title ?? value }
        else if key == "ARTIST" { tags.artist = tags.artist ?? value }
        else { tags.fill(custom: key, value) }
    }
    return tags
}

private let mp4Containers: Set<String> = ["moov", "udta", "meta", "ilst"]
private let atomTitle: [UInt8] = [0xA9, 0x6E, 0x61, 0x6D], atomArtist: [UInt8] = [0xA9, 0x41, 0x52, 0x54]
private let atomGenre: [UInt8] = [0xA9, 0x67, 0x65, 0x6E], atomDay: [UInt8] = [0xA9, 0x64, 0x61, 0x79]
private let atomAlbum: [UInt8] = [0xA9, 0x61, 0x6C, 0x62]

private func readMp4(_ bytes: Bytes) -> Tags {
    var tags = Tags()
    func data(_ from: Int, _ to: Int) -> (kind: Int, body: Bytes)? {
        guard from + 16 <= to, bytes.ascii(from + 4, 4) == "data" else { return nil }
        let size = min(to - from, bytes.u32be(from))
        return (bytes.u32be(from + 8) & 0xFFFFFF, bytes.sub(from + 16, from + size))
    }
    /// A `----` item: the tag's name in `name`, its value in `data`.
    func freeform(_ from: Int, _ to: Int) {
        var i = from, name: String?, value: String?
        while i + 8 <= to {
            let size = bytes.u32be(i), type = bytes.ascii(i + 4, 4)
            guard size >= 8 else { return }
            let end = min(to, i + size)
            if type == "name", i + 12 <= end { name = utf8(bytes.sub(i + 12, end)) }
            else if type == "data", i + 16 <= end { value = clean(utf8(bytes.sub(i + 16, end))) }
            i = end
        }
        if let name { tags.fill(custom: name, value) }
    }
    // Real files nest four deep; the cap stands in for the JS stack limit on a hostile one.
    func walk(_ from: Int, _ to: Int, depth: Int) {
        guard depth < 32 else { return }
        var i = from
        while i + 8 <= to {
            var size = bytes.u32be(i), header = 8
            let type = bytes.ascii(i + 4, 4)
            if size == 1 {
                // A 64-bit size past the file is clamped to it below anyway.
                size = bytes[i + 8] != 0 || bytes[i + 9] & 0x80 != 0 ? Int.max / 2 : bytes.u32be(i + 8) << 32 | bytes.u32be(i + 12)
                header = 16
            } else if size == 0 { size = to - i }
            if size < header { return }
            let end = min(to, i + min(size, Int.max / 2))
            if mp4Containers.contains(type) { walk(i + header + (type == "meta" ? 4 : 0), end, depth: depth + 1) }
            else if type == "----" { freeform(i + header, end) }
            else if bytes.matches(i + 4, atomGenre) { if let item = data(i + header, end) { tags.genre = tags.genre ?? Tags.cleanGenre(utf8(item.body)) } }
            else if bytes.matches(i + 4, atomAlbum) { if let item = data(i + header, end) { tags.album = tags.album ?? clean(utf8(item.body)) } }
            else if bytes.matches(i + 4, atomDay) { if let item = data(i + header, end) { tags.release = tags.release ?? clean(utf8(item.body)) } }
            else if bytes.matches(i + 4, atomTitle) || bytes.matches(i + 4, atomArtist) || type == "covr" {
                if let item = data(i + header, end) {
                    if type == "covr" {
                        if tags.picture == nil {
                            tags.picture = TagPicture(mime: normaliseMime(item.kind == 14 ? "image/png" : "image/jpeg", item.body), data: item.body.data)
                        }
                    } else if bytes.matches(i + 4, atomTitle) {
                        tags.title = tags.title ?? clean(utf8(item.body))
                    } else {
                        tags.artist = tags.artist ?? clean(utf8(item.body))
                    }
                }
            }
            i = end
        }
    }
    walk(0, bytes.count, depth: 0)
    return tags
}

/// AIFF and WAV keep ID3 in a chunk of their own.
private func readChunks(_ bytes: Bytes) -> Tags {
    let big = bytes.ascii(0, 4) == "FORM"
    var i = 12
    while i + 8 <= bytes.count {
        let id = bytes.ascii(i, 4)
        let size = big ? bytes.u32be(i + 4) : bytes.u32le(i + 4)
        if id.uppercased() == "ID3 ", bytes.ascii(i + 8, 3) == "ID3" { return readId3(bytes, i + 8) }
        i += 8 + size + (size & 1)
    }
    return Tags()
}

/// Trust the bytes over the label: many taggers write image/jpg or nothing.
private func normaliseMime(_ mime: String, _ data: Bytes) -> String {
    if data[0] == 0x89, data[1] == 0x50 { return "image/png" }
    if data[0] == 0xFF, data[1] == 0xD8 { return "image/jpeg" }
    guard mime.hasPrefix("image/") else { return "image/jpeg" }
    var label = mime
    if let jpg = label.range(of: "image/jpg") { label.replaceSubrange(jpg, with: "image/jpeg") }
    return label
}
