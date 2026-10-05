import Foundation

/// ID3v2.2–2.4 reader preserving multiple values and lazy artwork offsets.
/// Keep ISO-8859-1 text as Latin-1 for later legacy-encoding repair.
enum ID3v2 {
    struct Tag {
        var tags = RawTags()
        var picture: EmbeddedPicture?
        var size: Int
    }

    /// Frames larger than this that are not text are skipped, not read.
    private static let skipAbove = 4096

    /// The tag at `offset` (0 for MP3/FLAC; DSF and AIFF say where theirs is), nil when there is
    /// none. `lyrics`: read USLT / SYLT (left out while scanning).
    static func read(_ file: FileReader, at offset: Int64 = 0, lyrics: Bool = false) -> Tag? {
        guard let header = file.read(at: offset, count: 10), header.count == 10, header.hasASCII("ID3") else { return nil }
        let major = Int(header.byte(3))
        let flags = header.byte(5)
        guard (2...4).contains(major), let size = syncsafe(header.bytes(from: 6, count: 4)) else { return nil }
        let footer = major == 4 && flags & 0x10 != 0 ? 10 : 0
        var tag = Tag(size: 10 + size + footer)
        let unsynchronised = flags & 0x80 != 0
        var position = offset + 10
        let end = offset + 10 + Int64(size)

        // A whole tag unsynchronised (v2.2/2.3) cannot be walked frame by frame on disk; it is
        // read whole, unless it is too large to be anything but a damaged header.
        if unsynchronised, major < 4 {
            guard size <= 16 << 20, let body = file.read(at: position, count: size) else { return tag }
            let frames = MemoryFrames(data: removeUnsynchronisation(body), major: major)
            frames.forEach { id, body in
                if id == "APIC" || id == "PIC" {
                    if let picture = picture(fromBody: body, major: major) { keep(picture, in: &tag) }
                } else {
                    add(id, body, major: major, to: &tag, lyrics: lyrics)
                }
            }
            return tag
        }

        if major >= 3, flags & 0x40 != 0, let extended = file.read(at: position, count: 4), extended.count == 4 {
            let length = major == 4 ? (syncsafe(extended) ?? 0) : Int(extended.bigEndian(at: 0, count: 4)) + 4
            position += Int64(length)
        }

        let headerLength = major == 2 ? 6 : 10
        while position + Int64(headerLength) <= end {
            guard let frameHeader = file.read(at: position, count: headerLength), frameHeader.count == headerLength, frameHeader.byte(0) != 0 else { break }
            let idLength = major == 2 ? 3 : 4
            let id = String(decoding: frameHeader.bytes(from: 0, count: idLength), as: UTF8.self)
            let length: Int
            switch major {
            case 2: length = Int(frameHeader.bigEndian(at: 3, count: 3))
            case 3: length = Int(frameHeader.bigEndian(at: 4, count: 4))
            default:
                // Some v2.4 writers put plain sizes: a size that is not syncsafe, or whose syncsafe
                // reading runs past the tag, is read plainly.
                let plain = Int(frameHeader.bigEndian(at: 4, count: 4))
                if let safe = syncsafe(frameHeader.bytes(from: 4, count: 4)), Int64(safe) <= end - position - 10 {
                    length = safe
                } else {
                    length = plain
                }
            }
            let bodyStart = position + Int64(headerLength)
            guard length > 0, bodyStart + Int64(length) <= end else { break }
            let frameFlags = major == 2 ? 0 : frameHeader.byte(9)
            defer { position = bodyStart + Int64(length) }

            if id == "APIC" || id == "PIC" {
                readPicture(file, at: bodyStart, length: length, major: major, frameFlags: frameFlags, into: &tag)
                continue
            }
            guard length <= skipAbove || isWanted(id, lyrics: lyrics), let raw = file.read(at: bodyStart, count: length) else { continue }
            guard let body = frameBody(raw, major: major, flags: frameFlags) else { continue }
            add(id, body, major: major, to: &tag, lyrics: lyrics)
        }
        return tag
    }

    /// ID3v1 (the last 128 bytes, `TAG`): title, artist, album, year, track, genre. Text is
    /// Latin-1 here too.
    static func readV1(_ file: FileReader) -> RawTags? {
        guard file.size >= 128, let data = file.read(at: file.size - 128, count: 128), data.hasASCII("TAG") else { return nil }
        func text(_ offset: Int, _ count: Int) -> String {
            let bytes = data.bytes(from: offset, count: count)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return latin1(bytes[bytes.startIndex..<end])
        }
        var tags = RawTags()
        tags.add(text(3, 30), for: TagKey.title)
        tags.add(text(33, 30), for: TagKey.artist)
        tags.add(text(63, 30), for: TagKey.album)
        tags.add(text(93, 4), for: TagKey.date)
        if data.byte(125) == 0, data.byte(126) != 0 { tags.add(String(data.byte(126)), for: TagKey.track) }
        let genre = Int(data.byte(127))
        if genre < Genres.id3v1.count { tags.add(Genres.id3v1[genre], for: TagKey.genre) }
        return tags
    }

    static func hasV1(_ file: FileReader) -> Bool {
        file.size >= 128 && file.read(at: file.size - 128, count: 3).map { $0.hasASCII("TAG") } == true
    }

    private static func isWanted(_ id: String, lyrics: Bool) -> Bool {
        id.hasPrefix("T") || id == "UFID" || id == "UFI" || (lyrics && ["USLT", "ULT", "SYLT", "SLT"].contains(id))
    }

    /// The frame's content with v2.3/2.4 extras removed: a data length indicator, a grouping
    /// byte, per-frame unsynchronisation. nil for compressed or encrypted frames.
    private static func frameBody(_ raw: Data, major: Int, flags: UInt8) -> Data? {
        var body = raw
        switch major {
        case 3:
            if flags & 0xC0 != 0 { return nil }
            if flags & 0x20 != 0 { body = body.bytes(from: 1) }
        case 4:
            if flags & 0x0C != 0 { return nil }
            if flags & 0x40 != 0 { body = body.bytes(from: 1) }
            if flags & 0x01 != 0 { body = body.bytes(from: 4) }
            if flags & 0x02 != 0 { body = removeUnsynchronisation(body) }
        default: break
        }
        return body
    }

    private static func add(_ id: String, _ body: Data, major: Int, to tag: inout Tag, lyrics: Bool) {
        guard !body.isEmpty else { return }
        if let key = TagKey.id3Frames[id] {
            let values = strings(body.bytes(from: 1), encoding: body.byte(0))
            tag.tags.add(key == TagKey.genre ? values.flatMap(Genres.id3v2) : values, for: key)
            return
        }
        switch id {
        case "TXXX", "TXX":
            let encoding = body.byte(0)
            let (description, rest) = terminated(body.bytes(from: 1), encoding: encoding)
            guard let key = TagKey.canonical(description) else { return }
            tag.tags.add(strings(rest, encoding: encoding), for: key)
        case "UFID", "UFI":
            let (owner, identifier) = terminated(body, encoding: 0)
            if owner == "http://musicbrainz.org" { tag.tags.add(String(decoding: identifier, as: UTF8.self), for: TagKey.musicBrainzTrack) }
        case "USLT", "ULT":
            guard lyrics, body.count > 4 else { return }
            let encoding = body.byte(0)
            let (_, text) = terminated(body.bytes(from: 4), encoding: encoding)
            tag.tags.add(decode(text, encoding: encoding), for: TagKey.lyrics)
        case "SYLT", "SLT":
            guard lyrics, let lrc = syncedLyrics(body) else { return }
            tag.tags.add(lrc, for: TagKey.syncedLyrics)
        default:
            break
        }
    }

    /// Notes where the picture is: its header is read (a few bytes), the image is not.
    private static func readPicture(_ file: FileReader, at offset: Int64, length: Int, major: Int, frameFlags: UInt8, into tag: inout Tag) {
        let plain = major == 2 || (major == 3 && frameFlags & 0xE0 == 0) || (major == 4 && frameFlags & 0x4F == 0)
        if !plain {
            guard let raw = file.read(at: offset, count: length), let body = frameBody(raw, major: major, flags: frameFlags),
                  let picture = picture(fromBody: body, major: major) else { return }
            keep(picture, in: &tag)
            return
        }
        guard let head = file.read(at: offset, count: min(length, 512)), let (type, imageStart) = pictureHeader(head, major: major) else { return }
        let picture = EmbeddedPicture(offset: offset + Int64(imageStart), length: length - imageStart, type: type)
        if picture.length > 0 { keep(picture, in: &tag) }
    }

    private static func picture(fromBody body: Data, major: Int) -> EmbeddedPicture? {
        guard let (type, imageStart) = pictureHeader(body, major: major), imageStart < body.count else { return nil }
        return EmbeddedPicture(length: body.count - imageStart, data: Data(body.bytes(from: imageStart)), type: type)
    }

    private static func pictureHeader(_ body: Data, major: Int) -> (type: Int, imageStart: Int)? {
        guard body.count > 4 else { return nil }
        let encoding = body.byte(0)
        var cursor = 1
        if major == 2 {
            cursor += 3
        } else {
            guard let end = body.bytes(from: 1).firstIndex(of: 0) else { return nil }
            cursor = end - body.startIndex + 1
        }
        guard cursor < body.count else { return nil }
        let type = Int(body.byte(cursor))
        cursor += 1
        let (_, rest) = terminatedRaw(body.bytes(from: cursor), encoding: encoding)
        return (type, rest.startIndex - body.startIndex)
    }

    /// The front cover wins over other pictures; otherwise the first one stays.
    private static func keep(_ picture: EmbeddedPicture, in tag: inout Tag) {
        if tag.picture == nil || (tag.picture?.isFrontCover == false && picture.isFrontCover) { tag.picture = picture }
    }

    static func syncedLyrics(_ body: Data) -> String? {
        guard body.count > 6 else { return nil }
        let encoding = body.byte(0)
        // Only milliseconds (2); MPEG frame counts need the frame rate.
        guard body.byte(4) == 2 else { return nil }
        var (_, rest) = terminated(body.bytes(from: 6), encoding: encoding)
        var entries: [(ms: Int, text: String)] = []
        while !rest.isEmpty {
            let (text, after) = terminatedRaw(rest, encoding: encoding)
            guard after.count >= 4 else { break }
            entries.append((Int(after.bigEndian(at: 0, count: 4)), decode(text, encoding: encoding)))
            rest = after.bytes(from: 4)
        }
        guard !entries.isEmpty else { return nil }
        func stamp(_ ms: Int) -> String { String(format: "%02d:%02d.%02d", ms / 60000, ms / 1000 % 60, ms % 1000 / 10) }
        let syllables = entries.contains { $0.text.hasPrefix("\n") || $0.text.hasPrefix("\r") } && entries.count > 1
        guard syllables else {
            return entries.map { "[\(stamp($0.ms))]\($0.text.trimmingCharacters(in: .newlines))" }.joined(separator: "\n")
        }
        var lines: [String] = []
        var line = ""
        for entry in entries {
            let text = entry.text
            if text.hasPrefix("\n") || text.hasPrefix("\r") || line.isEmpty {
                if !line.isEmpty { lines.append(line) }
                line = "[\(stamp(entry.ms))]"
            }
            line += "<\(stamp(entry.ms))>\(text.trimmingCharacters(in: .newlines))"
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    static func strings(_ data: Data, encoding: UInt8) -> [String] {
        var values: [String] = []
        var rest = data
        while !rest.isEmpty {
            let (value, after) = terminatedRaw(rest, encoding: encoding)
            values.append(decode(value, encoding: encoding))
            if after.count == rest.count { break }
            rest = after
        }
        return values
    }

    private static func terminated(_ data: Data, encoding: UInt8) -> (String, Data) {
        let (raw, rest) = terminatedRaw(data, encoding: encoding)
        return (decode(raw, encoding: encoding), rest)
    }

    private static func terminatedRaw(_ data: Data, encoding: UInt8) -> (Data, Data) {
        if encoding == 1 || encoding == 2 {
            var index = data.startIndex
            while index + 1 < data.endIndex {
                if data[index] == 0, data[index + 1] == 0 { return (data[data.startIndex..<index], data[(index + 2)...]) }
                index += 2
            }
            // No terminator: nothing follows (an empty slice at the end, so offsets stay right).
            return (data, data[data.endIndex...])
        }
        guard let index = data.firstIndex(of: 0) else { return (data, data[data.endIndex...]) }
        return (data[data.startIndex..<index], data[(index + 1)...])
    }

    static func decode(_ data: Data, encoding: UInt8) -> String {
        switch encoding {
        case 1:
            if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            // A BOM left out: little-endian, as Windows writes it.
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        case 2:
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        case 3:
            // Not UTF-8 after all: kept as Latin-1 for the repair to read.
            return String(data: data, encoding: .utf8) ?? latin1(data)
        default:
            return latin1(data)
        }
    }

    /// A 28-bit syncsafe integer; nil when a byte has its high bit set (not syncsafe).
    static func syncsafe(_ data: Data) -> Int? {
        guard data.count == 4, data.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return data.reduce(0) { $0 << 7 | Int($1) }
    }

    static func removeUnsynchronisation(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if previous == 0xFF, byte == 0 {
                previous = byte
                continue
            }
            out.append(byte)
            previous = byte
        }
        return out
    }

    private struct MemoryFrames {
        var data: Data
        var major: Int

        func forEach(_ body: (String, Data) -> Void) {
            let headerLength = major == 2 ? 6 : 10
            var position = 0
            while position + headerLength <= data.count, data.byte(position) != 0 {
                let id = String(decoding: data.bytes(from: position, count: major == 2 ? 3 : 4), as: UTF8.self)
                let length = major == 2 ? Int(data.bigEndian(at: position + 3, count: 3)) : Int(data.bigEndian(at: position + 4, count: 4))
                let start = position + headerLength
                guard length > 0, start + length <= data.count else { break }
                let flags = major == 2 ? 0 : data.byte(position + 9)
                if let frame = ID3v2.frameBody(data.bytes(from: start, count: length), major: major, flags: flags) { body(id, frame) }
                position = start + length
            }
        }
    }
}

/// Bytes as ISO-8859-1: each byte is its own code point, so nothing is lost and `TextRepair` can
/// take the bytes back.
func latin1(_ data: Data) -> String {
    String(data: data, encoding: .isoLatin1) ?? ""
}
