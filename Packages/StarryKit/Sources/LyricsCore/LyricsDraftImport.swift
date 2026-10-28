import Foundation

public enum LyricsDraftImport {
    public enum Kind: Sendable, Hashable {
        case empty
        case plainText
        case lineTimed
        case lineTimedFormat(LyricsDocument.Format)
        case syllableTimed(LyricsDocument.Format)
    }

    public static func kind(of text: String) -> Kind {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let format = LyricsFormatDetector.detect(text)
        if format == .srt { return .lineTimedFormat(.srt) }
        if format == .ass, text.range(of: #"\\[kK][fFoO]?\d"#, options: .regularExpression) == nil { return .lineTimedFormat(.ass) }
        if format != .lrc { return .syllableTimed(format) }
        if LRCContent.hasInlineTiming(text) { return .syllableTimed(.lrc) }
        return stampedLines(text).isEmpty ? .plainText : .lineTimed
    }

    /// Line-timed LRC can pair same-time rows as lyrics, translation, and romanization.
    public static func draft(from text: String, pairsTranslations: Bool = true) throws -> LyricsDraft {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        switch LyricsFormatDetector.detect(text) {
        case .rl: return try RLParser.source(text).draft()
        case .krl: return try KRLParser.source(text).draft()
        case .nicokara: return try NicokaraParser.source(text).draft()
        case .ass: return try ASSParser.source(text).draft()
        default: break
        }
        switch kind(of: text) {
        case .empty:
            throw LyricsParseError.empty
        case .plainText:
            return plainDraft(text)
        case .lineTimed:
            return try LRCContent(text).draft(pairsTranslations: pairsTranslations)
        case .lineTimedFormat(let format):
            return LyricsDraft(document: try LyricsParsing.parse(text, format: format))
        case .syllableTimed(let format):
            if format == .lrc { return try LRCContent(text).draft(pairsTranslations: pairsTranslations) }
            let draft = LyricsDraft(document: try LyricsParsing.parse(text, format: format))
            guard !draft.isEmpty else { throw LyricsParseError.empty }
            return draft
        }
    }

    private static func plainDraft(_ text: String) -> LyricsDraft {
        var lines: [LyricsDraft.Line] = []
        var paragraph = true
        for raw in text.components(separatedBy: .newlines) {
            let content = raw.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else {
                paragraph = true
                continue
            }
            lines.append(LyricsDraft.Line(syllables: syllables(in: content), isParagraphStart: paragraph))
            paragraph = false
        }
        return LyricsDraft(lines: lines)
    }

    static func stampedLines(_ text: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = LRCParser.parseTimestamp(tag) else { break }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let content = rest.trimmingCharacters(in: .whitespaces)
            for time in times { result.append((time, content)) }
        }
        return result
    }

    // MARK: Syllables

    /// Splits a line into syllables to time: Chinese, Japanese and Korean by character (a small
    /// kana or `ー` stays with the one before), other scripts by word. With a `|` in the line it
    /// splits only at `|` and between words, for syllables set by hand (`Hel|lo world`).
    /// Punctuation goes with the syllable before it, an opening bracket or quote with the one
    /// after. Joined, the syllables give the line back, less its `|` and repeated spaces.
    public static func syllables(in text: String, explicitBoundaries: Bool = true, preservesLineBreaks: Bool = false) -> [LyricsDraft.Syllable] {
        let explicit = explicitBoundaries && text.contains("|")
        var parts: [String] = []
        var prefix = ""
        var wordOpen = false
        for character in text {
            if explicit, character == "|" {
                wordOpen = false
                continue
            }
            if character.isWhitespace {
                if preservesLineBreaks, character.isNewline, let last = parts.indices.last {
                    parts[last] = parts[last].trimmingCharacters(in: .whitespaces) + "\n"
                    wordOpen = false
                    continue
                }
                if let last = parts.indices.last, !parts[last].hasSuffix(" ") { parts[last] += " " }
                wordOpen = false
                continue
            }
            let afterSpace = parts.last?.hasSuffix(" ") ?? true
            if isOpening(character) || (afterSpace && (character == "\"" || character == "'")) {
                prefix.append(character)
                wordOpen = false
                continue
            }
            // After a space (`Rock & roll`) the mark is a syllable of its own.
            if attachesBackward(character), !afterSpace {
                parts[parts.count - 1].append(character)
                continue
            }
            let single = !explicit && isSingleSyllable(character)
            if single || !wordOpen || parts.isEmpty {
                parts.append(prefix + String(character))
                prefix = ""
                wordOpen = !single
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        if !prefix.isEmpty {
            if parts.isEmpty { parts.append(prefix) } else { parts[parts.count - 1] += prefix }
        }
        if let last = parts.indices.last { parts[last] = parts[last].trimmingCharacters(in: .whitespaces) }
        return parts.filter { !$0.isEmpty }.map { LyricsDraft.Syllable(text: $0) }
    }

    private static func isSingleSyllable(_ character: Character) -> Bool {
        let string = String(character)
        if LyricWordGrouping.containsChineseJapanese(string) { return true }
        // Hangul syllables and jamo.
        return character.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }

    private static let smallKana: Set<Character> = Set("ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶーㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ")
    private static let opening: Set<Character> = Set("([{（［｛「『【〔〈《“‘¿¡")

    private static func isOpening(_ character: Character) -> Bool { opening.contains(character) }

    private static func attachesBackward(_ character: Character) -> Bool {
        smallKana.contains(character) || (character.isPunctuation && !isOpening(character)) || character == "～" || character == "~"
    }
}
