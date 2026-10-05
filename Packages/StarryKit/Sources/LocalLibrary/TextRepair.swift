import Foundation

/// An encoding older tags and text files use without saying so.
public enum LegacyEncoding: String, Codable, Sendable, CaseIterable {
    /// UTF-8 that a reader took for Windows-1252 (RIFF INFO through AVFoundation).
    case utf8
    case gb18030
    case big5
    case shiftJIS
    case eucKR

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .gb18030: "简体中文（GBK / GB18030）"
        case .big5: "繁体中文（Big5）"
        case .shiftJIS: "日文（Shift-JIS）"
        case .eucKR: "韩文（EUC-KR）"
        }
    }

    var foundation: String.Encoding {
        let cf: CFStringEncodings? = switch self {
        case .utf8: nil
        case .gb18030: .GB_18030_2000
        case .big5: .big5_HKSCS_1999
        case .shiftJIS: .dosJapanese
        case .eucKR: .dosKorean
        }
        guard let cf else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }
}

/// Repair legacy tag bytes misread as Latin-1. Score encodings across a folder,
/// not a single string, to avoid corrupting valid names such as `Sigur Rós`.
public enum TextRepair {
    /// The bytes behind `text` if it could be another encoding misread as Latin-1 / Windows-1252:
    /// every character one byte, some of them above ASCII. nil otherwise.
    public static func misreadBytes(_ text: String) -> Data? {
        var bytes = Data()
        bytes.reserveCapacity(text.unicodeScalars.count)
        var high = false
        for scalar in text.unicodeScalars {
            let byte: UInt8
            if scalar.value < 0x100 {
                byte = UInt8(scalar.value)
            } else if let mapped = windows1252[scalar.value] {
                byte = mapped
            } else {
                return nil
            }
            if byte >= 0x80 { high = true }
            bytes.append(byte)
        }
        return high ? bytes : nil
    }

    /// `text` read again as `encoding`, when it is misread text that decodes cleanly; else nil.
    public static func repaired(_ text: String, as encoding: LegacyEncoding) -> String? {
        guard let bytes = misreadBytes(text), let decoded = decode(bytes, as: encoding), decoded != text else { return nil }
        return decoded
    }

    /// The encoding the misread strings of one folder most likely are, nil when none stands out
    /// (a folder of Western names with accents votes for nothing).
    public static func vote(_ texts: some Sequence<String>) -> LegacyEncoding? {
        var tally: [LegacyEncoding: Double] = [:]
        var candidates = 0
        for text in texts {
            guard let bytes = misreadBytes(text) else { continue }
            candidates += 1
            guard let (encoding, score) = best(bytes) else { continue }
            tally[encoding, default: 0] += score
        }
        guard candidates > 0, let (winner, total) = tally.max(by: { $0.value < $1.value }) else { return nil }
        let needed = candidates <= 2 ? 0.9 * Double(candidates) : 0.6 * Double(candidates)
        return total >= needed ? winner : nil
    }

    /// The best reading of `bytes` and its score (0…1), when one reaches 0.75.
    static func best(_ bytes: Data) -> (LegacyEncoding, Double)? {
        var best: (LegacyEncoding, Double)?
        for encoding in LegacyEncoding.allCases {
            guard let decoded = decode(bytes, as: encoding) else { continue }
            let value = score(decoded, as: encoding)
            if value > (best?.1 ?? 0) { best = (encoding, value) }
        }
        guard let best, best.1 >= 0.75 else { return nil }
        return best
    }

    /// Text file bytes (LRC, CUE): BOM, then strict UTF-8, then the legacy encoding that reads
    /// best, GB18030 when nothing stands out. `preferred` (the folder's tag encoding) goes first.
    public static func decodeText(_ data: Data, preferred: LegacyEncoding? = nil) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let preferred, let text = decode(data, as: preferred) { return text }
        if let (encoding, _) = best(data), let text = decode(data, as: encoding) { return text }
        return decode(data, as: .gb18030) ?? String(data: data, encoding: .isoLatin1)
    }

    static func decode(_ bytes: Data, as encoding: LegacyEncoding) -> String? {
        guard let text = String(data: bytes, encoding: encoding.foundation), !text.contains("\u{FFFD}") else { return nil }
        // Control characters mean the bytes were not this encoding.
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" || (0x80..<0xA0).contains($0.value) }) else { return nil }
        return text
    }

    static func score(_ decoded: String, as encoding: LegacyEncoding) -> Double {
        var total = 0.0
        var count = 0
        for scalar in decoded.unicodeScalars where !scalar.isASCII {
            count += 1
            total += weight(scalar, in: encoding)
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private static func weight(_ scalar: Unicode.Scalar, in encoding: LegacyEncoding) -> Double {
        switch encoding {
        case .utf8:
            // Valid multi-byte UTF-8 hardly ever happens by chance.
            return 1
        case .gb18030:
            guard let (lead, trail) = doubleByte(scalar, encoding), trail >= 0xA1 else { return 0 }
            switch lead {
            case 0xB0...0xD7: return 1           // GB2312 level 1
            case 0xD8...0xF7: return 0.6         // level 2
            case 0xA1...0xA9: return 0.7         // punctuation, full-width forms, kana
            default: return 0                    // GBK extensions
            }
        case .big5:
            guard let (lead, _) = doubleByte(scalar, encoding) else { return 0 }
            switch lead {
            case 0xA4...0xC6: return 1           // common characters
            case 0xC9...0xF9: return 0.5         // less common characters
            case 0xA1...0xA3: return 0.7         // punctuation
            default: return 0
            }
        case .shiftJIS:
            if (0x3041...0x30FF).contains(scalar.value) { return 1 }      // kana
            if (0xFF61...0xFF9F).contains(scalar.value) { return 0.1 }    // half-width kana
            guard let (lead, _) = doubleByte(scalar, encoding) else { return 0 }
            switch lead {
            case 0x88...0x97: return 1           // JIS level 1 kanji
            case 0x98...0x9F, 0xE0...0xEA: return 0.5
            case 0x81...0x84: return 0.7         // punctuation, full-width forms
            default: return 0
            }
        case .eucKR:
            if (0xAC00...0xD7A3).contains(scalar.value) {
                guard let (lead, _) = doubleByte(scalar, encoding) else { return 0.2 }
                return (0xB0...0xC8).contains(lead) ? 1 : 0.2
            }
            guard let (lead, _) = doubleByte(scalar, encoding) else { return 0 }
            return (0xA1...0xA9).contains(lead) ? 0.7 : 0.2
        }
    }

    private static func doubleByte(_ scalar: Unicode.Scalar, _ encoding: LegacyEncoding) -> (UInt8, UInt8)? {
        guard let data = String(Character(scalar)).data(using: encoding.foundation), data.count == 2 else { return nil }
        return (data.byte(0), data.byte(1))
    }

    private static let windows1252: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E,
        0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
        0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]
}
