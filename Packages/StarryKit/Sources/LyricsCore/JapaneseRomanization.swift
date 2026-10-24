import Foundation

/// Offline Japanese readings for whole lyric lines. Tokenize the complete line so kanji
/// compounds retain their context, regardless of how the editor split the timed syllables.
public enum JapaneseRomanization {
    /// Han-only lines are deliberately interpreted as Japanese: callers explicitly choose
    /// Japanese romanization. This is a script check, not language detection.
    public static func containsJapaneseScript(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) && (LyricRomanizationAligner.isKana($0) || LyricRomanizationAligner.isHan($0))
        }
    }

    /// Returns nil for non-Japanese text or an unreadable token. Never fall back to a generic
    /// Han-to-Latin transform, which would supply Mandarin readings for Japanese kanji.
    public static func romanize(_ text: String) -> String? {
        guard containsJapaneseScript(text) else { return nil }
        let source = text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString,
                                               CFRange(location: 0, length: source.length),
                                               kCFStringTokenizerUnitWordBoundary,
                                               Locale(identifier: "ja") as CFLocale)
        var output = ""
        var cursor = 0
        var converted = false
        var previousWasWord = false
        var previousWasJapanese = false
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.length > 0 else { continue }
            if range.location > cursor {
                let gap = source.substring(with: NSRange(location: cursor, length: range.location - cursor))
                guard !containsJapaneseScript(gap) else { return nil }
                output += gap
                previousWasWord = false
            }
            let surface = source.substring(with: NSRange(location: range.location, length: range.length))
            let japanese = containsJapaneseScript(surface)
            let word = surface.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            let reading: String
            if japanese {
                guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                      !latin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !containsJapaneseScript(latin) else { return nil }
                // The tokenizer gives spelling-based readings for these particles/greetings.
                switch surface {
                case "は": reading = "wa"
                case "へ": reading = "e"
                case "を": reading = "o"
                case "こんにちは": reading = "konnichiwa"
                case "こんばんは": reading = "konbanwa"
                default: reading = latin.precomposedStringWithCanonicalMapping
                }
                converted = true
            } else {
                reading = surface
            }
            if previousWasWord && word && (previousWasJapanese || japanese) { output += " " }
            output += reading
            previousWasWord = word
            previousWasJapanese = japanese
            cursor = range.location + range.length
        }
        if cursor < source.length {
            let tail = source.substring(from: cursor)
            guard !containsJapaneseScript(tail) else { return nil }
            output += tail
        }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return converted && !result.isEmpty ? result : nil
    }
}
