import Foundation

/// QRC timestamps are absolute milliseconds and follow each syllable.
public enum QRCParser: LyricsParser {
    public static let format: LyricsDocument.Format = .qrc

    public static func parse(_ text: String) throws -> LyricsDocument {
        let content = unwrap(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LyricsParseError.empty }
        var lines: [LyricLine] = []
        var metadata: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let header = KaraokeLine.header(line) else {
                KaraokeLine.readMetadata(line, into: &metadata)
                continue
            }
            let syllables = KaraokeLine.tokens(in: header.body, open: "(", close: ")", textBeforeTag: true).compactMap { token -> LyricSyllable? in
                guard token.numbers.count >= 2 else { return nil }
                return LyricSyllable(start: token.numbers[0] / 1000, end: (token.numbers[0] + token.numbers[1]) / 1000, text: token.text)
            }
            if let built = KaraokeLine.make(id: lines.count, start: header.start / 1000, end: (header.start + header.duration) / 1000, syllables: syllables) {
                lines.append(built)
            }
        }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        return LyricsDocument(format: .qrc, lines: lines, metadata: metadata)
    }

    /// The `LyricContent` attribute of the first `<Lyric_N>` element, or the text itself when it
    /// is not wrapped. Lyric text may contain raw quotes, so the attribute ends at `"/>`.
    static func unwrap(_ text: String) -> String {
        guard let attribute = text.range(of: "LyricContent=\"") else { return text }
        let rest = text[attribute.upperBound...]
        let end = rest.range(of: "\"/>")?.lowerBound ?? rest.range(of: "\"", options: .backwards)?.lowerBound ?? rest.endIndex
        return XMLEntities.decode(String(rest[..<end]))
    }
}

/// KRC syllable offsets are relative to the line start. `language` type 1 is
/// translation; type 0 is romanization.
public enum KRCParser: LyricsParser {
    public static let format: LyricsDocument.Format = .krc

    public static func parse(_ text: String) throws -> LyricsDocument {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !trimmed.isEmpty else { throw LyricsParseError.empty }
        var lines: [LyricLine] = []
        var metadata: [String: String] = [:]
        var language: [String: [[String]]] = [:]

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[language:"), line.hasSuffix("]") {
                language = decodeLanguage(String(line.dropFirst(10).dropLast()))
                continue
            }
            guard let header = KaraokeLine.header(line) else {
                KaraokeLine.readMetadata(line, into: &metadata)
                continue
            }
            let lineStart = header.start
            let syllables = KaraokeLine.tokens(in: header.body, open: "<", close: ">", textBeforeTag: false).compactMap { token -> LyricSyllable? in
                guard token.numbers.count >= 2 else { return nil }
                let start = lineStart + token.numbers[0]
                return LyricSyllable(start: start / 1000, end: (start + token.numbers[1]) / 1000, text: XMLEntities.decode(token.text))
            }
            if let built = KaraokeLine.make(id: lines.count, start: lineStart / 1000, end: (lineStart + header.duration) / 1000, syllables: syllables) {
                lines.append(built)
            }
        }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        for (index, row) in (language["translation"] ?? []).enumerated() where index < lines.count {
            let value = collapse(row.joined(separator: " "))
            if !value.isEmpty { lines[index].translation = value }
        }
        for (index, row) in (language["romanization"] ?? []).enumerated() where index < lines.count {
            let value = collapse(row.joined())
            guard !value.isEmpty else { continue }
            lines[index].romanization = value
            lines[index].romanizationWords = timedRomanization(row, syllables: lines[index].syllables)
        }
        return LyricsDocument(format: .krc, lines: lines, metadata: metadata)
    }

    static func decodeLanguage(_ base64: String) -> [String: [[String]]] {
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return [:] }
        var result: [String: [[String]]] = [:]
        for entry in content {
            guard let type = entry["type"] as? Int, let rows = entry["lyricContent"] as? [[String]] else { continue }
            let key = type == 1 ? "translation" : type == 0 ? "romanization" : nil
            guard let key, result[key] == nil else { continue }
            result[key] = rows
        }
        return result
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One romanization string per syllable: each takes its syllable's times, whitespace inside
    /// the strings separates words. Rows of another length cannot be paired and stay text only.
    static func timedRomanization(_ row: [String], syllables: [LyricSyllable]) -> [LyricWord]? {
        guard row.count == syllables.count else { return nil }
        let timed = zip(row, syllables).compactMap { text, syllable -> LyricSyllable? in
            text.isEmpty ? nil : LyricSyllable(start: syllable.start, end: syllable.end, text: text)
        }
        guard timed.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) else { return nil }
        return KaraokeLine.make(id: 0, start: timed[0].start, end: timed[timed.count - 1].end, syllables: timed)?.words
    }
}

enum KaraokeLine {
    struct Header {
        var start: Double
        var duration: Double
        var body: Substring
    }

    struct Token {
        var text: String
        var numbers: [Double]
    }

    static func header(_ line: String) -> Header? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let fields = line[line.index(after: line.startIndex)..<close].split(separator: ",")
        guard fields.count >= 2, let start = Double(fields[0]), let duration = Double(fields[1]) else { return nil }
        return Header(start: start, duration: duration, body: line[line.index(after: close)...])
    }

    static func readMetadata(_ line: String, into metadata: inout [String: String]) {
        guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { return }
        let key = line[line.index(after: line.startIndex)..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { return }
        metadata[String(key)] = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
    }

    /// Splits `body` at numeric tags `open n,n[,n] close`. With `textBeforeTag` a syllable's text
    /// precedes its tag (QRC), otherwise it follows (YRC, KRC). Anything that does not parse as
    /// a tag stays part of the text, so lyrics may contain the bracket characters themselves.
    static func tokens(in body: Substring, open: Character, close: Character, textBeforeTag: Bool) -> [Token] {
        var tags: [(range: Range<Substring.Index>, numbers: [Double])] = []
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == open, let tag = numericTag(in: body, at: index, close: close) {
                tags.append(tag)
                index = tag.range.upperBound
            } else {
                index = body.index(after: index)
            }
        }
        var tokens: [Token] = []
        for (n, tag) in tags.enumerated() {
            let text: Substring
            if textBeforeTag {
                let from = n == 0 ? body.startIndex : tags[n - 1].range.upperBound
                text = body[from..<tag.range.lowerBound]
            } else {
                let to = n + 1 < tags.count ? tags[n + 1].range.lowerBound : body.endIndex
                text = body[tag.range.upperBound..<to]
            }
            tokens.append(Token(text: String(text), numbers: tag.numbers))
        }
        return tokens
    }

    private static func numericTag(in body: Substring, at start: Substring.Index, close: Character) -> (range: Range<Substring.Index>, numbers: [Double])? {
        var numbers: [Double] = []
        var digits = ""
        var index = body.index(after: start)
        while index < body.endIndex {
            let c = body[index]
            if c.isASCII, c.isNumber || (c == "-" && digits.isEmpty) {
                digits.append(c)
            } else if c == "," || c == close {
                guard let value = Double(digits) else { return nil }
                numbers.append(value)
                digits = ""
                if c == close {
                    guard numbers.count >= 2 else { return nil }
                    return (start..<body.index(after: index), numbers)
                }
            } else {
                return nil
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// A line from timed syllables grouped into words; nil when the line has no text.
    static func make(id: Int, start: TimeInterval, end: TimeInterval, syllables: [LyricSyllable]) -> LyricLine? {
        let timed = syllables.filter { !$0.text.isEmpty }
        guard timed.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) else { return nil }
        var words = LyricWordGrouping.words(from: timed)
        if let w = words.indices.last {
            words[w].text = String(words[w].text.trimmingTrailingWhitespace())
            while let s = words[w].syllables.indices.last {
                let text = String(words[w].syllables[s].text.trimmingTrailingWhitespace())
                if text.isEmpty, words[w].syllables.count > 1 {
                    words[w].syllables.removeLast()
                    continue
                }
                words[w].syllables[s].text = text
                break
            }
        }
        let lineStart = min(start, words.first?.start ?? start)
        let lineEnd = max(end, words.last?.end ?? end)
        return LyricLine(id: id, start: lineStart, end: lineEnd, words: words)
    }
}

enum XMLEntities {
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = text[text.index(after: index)..<semicolon]
                if let decoded = entity(name) {
                    result.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(c)
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ name: Substring) -> Character? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}

extension String {
    func trimmingTrailingWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return self[..<end]
    }
}
