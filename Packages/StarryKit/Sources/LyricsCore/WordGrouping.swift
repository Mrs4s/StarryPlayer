import Foundation
import NaturalLanguage

public enum LyricWordGrouping {
    public static func containsChineseJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FDF,   // CJK radicals, Kangxi radicals
                 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B,  // ideographic marks / numerals
                 0x3040...0x30FF,   // Hiragana, Katakana
                 0x3100...0x312F, 0x31A0...0x31BF,  // Bopomofo (+ extended)
                 0x31F0...0x31FF,   // Katakana phonetic extensions
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // Han
                 0xFF66...0xFF9F,   // half-width Katakana
                 0x20000...0x323AF, // Han extensions B…H
                 0x02C9, 0x02CA, 0x02C7, 0x02CB, 0x02D9:  // ˉ ˊ ˇ ˋ ˙
                return true
            default:
                return false
            }
        }
    }

    /// UTF-16 ranges of the words of `text`.
    public static func wordRanges(in text: String) -> [Range<Int>] {
        if containsChineseJapanese(text) {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { r in
                let lower = text.utf16.distance(from: text.utf16.startIndex, to: r.lowerBound)
                return lower..<(lower + text[r].utf16.count)
            }
        }
        var ranges: [Range<Int>] = []
        var start: Int?
        var offset = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf16.count
            if scalar.properties.isWhitespace {
                if let s = start { ranges.append(s..<offset); start = nil }
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let s = start { ranges.append(s..<offset) }
        return ranges
    }

    public static func words(from syllables: [LyricSyllable]) -> [LyricWord] {
        guard !syllables.isEmpty else { return [] }
        let text = syllables.map(\.text).joined()
        let ranges = wordRanges(in: text)
        var words: [LyricWord] = []
        var currentToken: Int?
        var offset = 0
        for syllable in syllables {
            let units = Array(syllable.text.utf16)
            // First non-whitespace UTF-16 unit of the syllable decides its word.
            let lead = units.firstIndex { !(Unicode.Scalar($0).map { $0.properties.isWhitespace } ?? false) }
            let token = lead.flatMap { i in ranges.firstIndex { $0.contains(offset + i) } }
            offset += units.count
            if let token, token != currentToken || words.isEmpty {
                words.append(LyricWord(start: syllable.start, end: syllable.end, text: syllable.text, syllables: [syllable], length: ranges[token].count))
                currentToken = token
            } else if words.isEmpty {
                words.append(LyricWord(start: syllable.start, end: syllable.end, text: syllable.text, syllables: [syllable], length: 0))
            } else {
                words[words.count - 1].syllables.append(syllable)
                words[words.count - 1].text += syllable.text
                words[words.count - 1].end = max(words[words.count - 1].end, syllable.end)
            }
        }
        return words
    }
}
