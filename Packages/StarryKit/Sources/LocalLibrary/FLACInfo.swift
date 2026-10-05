import Foundation

/// A FLAC file's metadata blocks: STREAMINFO (exact length, sample rate, bit depth), the Vorbis
/// comment and the pictures (located, not read). Also reads files with an ID3v2 tag in front,
/// whose Vorbis comment AVFoundation then ignores.
enum FLACInfo {
    struct Info {
        var tags = RawTags()
        var picture: EmbeddedPicture?
        var audio: AudioProperties?
    }

    static func read(_ file: FileReader, lyrics: Bool = false) -> Info? {
        var offset: Int64 = 0
        // Some taggers prepend ID3v2 before the FLAC marker.
        if let head = file.read(at: 0, count: 10), head.hasASCII("ID3"), let size = ID3v2.syncsafe(head.bytes(from: 6, count: 4)) {
            offset = 10 + Int64(size) + (head.byte(5) & 0x10 != 0 ? 10 : 0)
        }
        guard let marker = file.read(at: offset, count: 4), marker.hasASCII("fLaC") else { return nil }
        offset += 4
        var info = Info()
        var last = false
        while !last, offset + 4 <= file.size {
            guard let header = file.read(at: offset, count: 4), header.count == 4 else { break }
            last = header.byte(0) & 0x80 != 0
            let type = header.byte(0) & 0x7F
            let length = Int(header.bigEndian(at: 1, count: 3))
            let body = offset + 4
            offset = body + Int64(length)
            switch type {
            case 0:
                guard let block = file.read(at: body, count: length), block.count >= 18 else { continue }
                info.audio = streamInfo(block, fileSize: file.size)
            case 4:
                guard let block = file.read(at: body, count: length) else { continue }
                info.tags = VorbisComment.parse(block, lyrics: lyrics)
            case 6:
                guard let head = file.read(at: body, count: min(length, 1024)), let picture = picture(head, at: body, length: length) else { continue }
                if info.picture == nil || (!info.picture!.isFrontCover && picture.isFrontCover) { info.picture = picture }
            default:
                continue
            }
        }
        return info
    }

    /// STREAMINFO widths: sample rate 20, channels 3, bit depth 5, sample count 36 bits.
    private static func streamInfo(_ block: Data, fileSize: Int64) -> AudioProperties? {
        let packed = block.bigEndian(at: 10, count: 8)
        let sampleRate = Int(packed >> 44)
        let channels = Int((packed >> 41) & 0x7) + 1
        let bits = Int((packed >> 36) & 0x1F) + 1
        let samples = packed & 0xF_FFFF_FFFF
        guard sampleRate > 0 else { return nil }
        let duration = Double(samples) / Double(sampleRate)
        let bitrate = duration > 0 ? Int(Double(fileSize) * 8 / duration) : nil
        return AudioProperties(codec: "flac", duration: duration, sampleRate: sampleRate, bitDepth: bits, channels: channels, bitrate: bitrate)
    }

    static func picture(_ head: Data, at offset: Int64, length: Int) -> EmbeddedPicture? {
        guard head.count >= 8 else { return nil }
        let type = Int(head.bigEndian(at: 0, count: 4))
        let mimeLength = Int(head.bigEndian(at: 4, count: 4))
        let descriptionAt = 8 + mimeLength
        guard head.count >= descriptionAt + 4 else { return nil }
        let descriptionLength = Int(head.bigEndian(at: descriptionAt, count: 4))
        let dataLengthAt = descriptionAt + 4 + descriptionLength + 16
        guard head.count >= dataLengthAt + 4 else { return nil }
        let dataLength = Int(head.bigEndian(at: dataLengthAt, count: 4))
        let imageStart = dataLengthAt + 4
        guard dataLength > 0, imageStart + dataLength <= length else { return nil }
        return EmbeddedPicture(offset: offset + Int64(imageStart), length: dataLength, type: type)
    }
}

enum VorbisComment {
    static func parse(_ block: Data, lyrics: Bool) -> RawTags {
        var tags = RawTags()
        guard block.count >= 8 else { return tags }
        let vendorLength = Int(block.littleEndian(at: 0, count: 4))
        var position = 4 + vendorLength
        guard position + 4 <= block.count else { return tags }
        let count = Int(block.littleEndian(at: position, count: 4))
        position += 4
        for _ in 0..<min(count, 10_000) {
            guard position + 4 <= block.count else { break }
            let length = Int(block.littleEndian(at: position, count: 4))
            position += 4
            guard length >= 0, position + length <= block.count else { break }
            let entry = block.bytes(from: position, count: length)
            position += length
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let name = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            guard let key = TagKey.canonical(name), lyrics || key != TagKey.lyrics else { continue }
            let value = entry[(equals + 1)...]
            tags.add(String(data: value, encoding: .utf8) ?? latin1(value), for: key)
        }
        return tags
    }
}
