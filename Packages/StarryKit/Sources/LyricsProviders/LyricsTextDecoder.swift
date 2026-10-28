import Foundation

/// Legacy encodings overlap, so rank successful decodes by character frequency.
enum LyricsTextDecoder {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE, 0, 0]) { return String(data: data.dropFirst(4), encoding: .utf32LittleEndian) }
        if data.starts(with: [0, 0, 0xFE, 0xFF]) { return String(data: data.dropFirst(4), encoding: .utf32BigEndian) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        let encodings: [CFStringEncodings] = [.GB_18030_2000, .dosJapanese, .big5_HKSCS_1999]
        var best: (text: String, score: Double)?
        for candidate in encodings {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(candidate.rawValue)))
            guard let text = String(data: data, encoding: encoding), !text.unicodeScalars.contains(where: {
                $0 == "\u{FFFD}" || $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" || (0x80..<0xA0).contains($0.value)
            }) else { continue }
            let scalars = text.unicodeScalars.filter { !$0.isASCII }
            var total = 0.0
            for scalar in scalars {
                if (0xE000...0xF8FF).contains(scalar.value) { total -= 8; continue }
                if candidate == .dosJapanese {
                    if (0x3041...0x30FF).contains(scalar.value) { total += 1; continue }
                    if (0xFF61...0xFF9F).contains(scalar.value) { total += 0.1; continue }
                }
                guard let bytes = String(scalar).data(using: encoding), bytes.count == 2 else { continue }
                let lead = bytes[bytes.startIndex], trail = bytes[bytes.index(after: bytes.startIndex)]
                switch candidate {
                case .GB_18030_2000:
                    if trail >= 0xA1 {
                        if (0xB0...0xD7).contains(lead) { total += 1 }
                        else if (0xD8...0xF7).contains(lead) { total += 0.6 }
                        else if (0xA1...0xA9).contains(lead) { total += 0.7 }
                    }
                case .dosJapanese:
                    if (0x88...0x97).contains(lead) { total += 1 }
                    else if (0x98...0x9F).contains(lead) || (0xE0...0xEA).contains(lead) { total += 0.5 }
                    else if (0x81...0x84).contains(lead) { total += 0.7 }
                default:
                    if (0xA4...0xC6).contains(lead) { total += 1 }
                    else if (0xC9...0xF9).contains(lead) { total += 0.5 }
                    else if (0xA1...0xA3).contains(lead) { total += 0.7 }
                }
            }
            let score = total / Double(max(1, scalars.count))
            if score > (best?.score ?? -.infinity) { best = (text, score) }
        }
        return best?.text
    }
}
