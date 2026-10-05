import Foundation

/// APEv2 (and APEv1) at the end of a file, before an ID3v1 tag: MP3s tagged by foobar2000,
/// Monkey's Audio and WavPack files. Text items are UTF-8 with values separated by NUL; old
/// tools wrote GBK, which is kept as Latin-1 for `TextRepair` when it is not UTF-8.
enum APETag {
    struct Tag {
        var tags = RawTags()
        var picture: EmbeddedPicture?
    }

    /// The tag ending at the end of the file (or before its ID3v1 tag), nil when there is none.
    static func read(_ file: FileReader, lyrics: Bool = false) -> Tag? {
        var end = file.size
        if ID3v2.hasV1(file) { end -= 128 }
        guard end >= 32, let footer = file.read(at: end - 32, count: 32), footer.count == 32, footer.hasASCII("APETAGEX") else { return nil }
        let version = Int(footer.littleEndian(at: 8, count: 4))
        let size = Int(footer.littleEndian(at: 12, count: 4))
        let count = Int(footer.littleEndian(at: 16, count: 4))
        // `size` holds the items and the footer, not a header.
        guard size >= 32, Int64(size) <= end, count < 10_000 else { return nil }
        let itemsStart = end - Int64(size)
        guard let items = file.read(at: itemsStart, count: size - 32) else { return nil }
        var tag = Tag()
        var position = 0
        for _ in 0..<count {
            guard position + 8 < items.count else { break }
            let length = Int(items.littleEndian(at: position, count: 4))
            let flags = items.littleEndian(at: position + 4, count: 4)
            guard let keyEnd = items.bytes(from: position + 8).firstIndex(of: 0) else { break }
            let key = String(decoding: items[(items.startIndex + position + 8)..<keyEnd], as: UTF8.self)
            let valueStart = keyEnd - items.startIndex + 1
            guard length >= 0, valueStart + length <= items.count else { break }
            position = valueStart + length
            // APEv2 item bits 1–2 identify binary data; APEv1 supports text only.
            let binary = version >= 2000 && (flags >> 1) & 3 == 1
            let lowered = key.lowercased()
            if binary {
                guard lowered.hasPrefix("cover art") else { continue }
                let value = items.bytes(from: valueStart, count: length)
                guard let nameEnd = value.firstIndex(of: 0) else { continue }
                let imageStart = nameEnd - value.startIndex + 1
                let picture = EmbeddedPicture(offset: itemsStart + Int64(valueStart + imageStart), length: length - imageStart, type: lowered.contains("front") ? 3 : 0)
                if tag.picture == nil || (!tag.picture!.isFrontCover && picture.isFrontCover) { tag.picture = picture }
                continue
            }
            guard let canonical = TagKey.canonical(key) else { continue }
            if canonical == TagKey.lyrics, !lyrics { continue }
            let value = items.bytes(from: valueStart, count: length)
            let text = String(data: value, encoding: .utf8) ?? latin1(value)
            tag.tags.add(text.components(separatedBy: "\u{0}"), for: canonical)
        }
        return tag
    }
}
