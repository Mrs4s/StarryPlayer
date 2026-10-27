import Foundation
import LyricsCore

struct LyricsAIPronunciation: Sendable {
    struct Unit: Sendable {
        var line: Int
        var syllable: Int
        var tokens: Range<Int>
        var ruby: [Range<Int>]
        var approximate: Bool
    }

    var tokens: [LyricsAICTC.Token]
    var units: [Unit]
    var lines: [Int]
    var estimatedCount: Int
    var backgroundCount: Int

    private static let unknown: Character = "\u{E000}"
    private static let small = Set("ぁぃぅぇぉゃゅょゎゕゖ")
    private static let fallback: [Character: Character] = ["ゎ": "わ", "ゕ": "か", "ゖ": "け", "ゐ": "い", "ゑ": "え", "ゔ": "ぶ"]

    static func make(draft: LyricsDraft, vocabulary: [String: Int], english: [String: String]) throws -> Self {
        var result = Self(tokens: [], units: [], lines: [], estimatedCount: 0, backgroundCount: 0)
        var known = 0
        var firstUnknown = "歌词"
        for (lineIndex, line) in draft.lines.enumerated() {
            try Task.checkCancellation()
            if line.isBackground { result.backgroundCount += 1; continue }
            guard !line.syllables.isEmpty else { continue }
            let automatic = autoReadings(line, english: english)
            let lineStart = result.tokens.count
            var characters: [Character] = []
            let unitsStart = result.units.count
            for (index, syllable) in line.syllables.enumerated() {
                let start = lineStart + characters.count
                var reading: [Character] = []
                var ruby: [Range<Int>] = []
                var approximate = automatic.estimated.contains(index)
                if let parts = syllable.ruby, !parts.isEmpty {
                    for part in parts {
                        guard let kana = annotatedReading(part.text, english: english), !kana.isEmpty else {
                            throw LyricsAIError.unreadable(part.text)
                        }
                        let lower = start + reading.count
                        reading += kana
                        ruby.append(lower..<(start + reading.count))
                    }
                    approximate = false
                } else {
                    reading = automatic.values[index]
                }
                if reading.isEmpty, hasLetters(syllable.text) {
                    reading = [unknown]
                    firstUnknown = String(syllable.text.prefix(40))
                    approximate = true
                }
                if reading.contains(unknown) { approximate = true }
                characters += reading
                result.units.append(Unit(line: lineIndex, syllable: index, tokens: start..<(start + reading.count),
                                         ruby: ruby, approximate: approximate))
                if approximate { result.estimatedCount += 1 }
            }
            guard !characters.isEmpty else {
                result.units.removeSubrange(unitsStart...)
                continue
            }
            var groups: [[Character]] = []
            for char in characters {
                if small.contains(char), !groups.isEmpty, groups[groups.count - 1] != [unknown] {
                    groups[groups.count - 1].append(char)
                } else { groups.append([char]) }
            }
            var previousClass = -1
            for group in groups {
                let own: Int
                if group == ["ー"] { own = (1...5).contains(previousClass) ? previousClass : -1 }
                else { own = sustainClass(group.last!) }
                for character in group {
                    if character == unknown {
                        result.tokens.append(.init(label: 122, sustainClass: -1))
                    } else {
                        let char = vocabulary[String(character)] == nil ? (fallback[character] ?? character) : character
                        guard let id = vocabulary[String(char)], id != 121 else { throw LyricsAIError.unreadable(String(character)) }
                        result.tokens.append(.init(label: id, sustainClass: own))
                        known += 1
                    }
                }
                previousClass = own
            }
            result.tokens[result.tokens.count - 1].endsLine = true
            result.lines.append(lineIndex)
        }
        guard !result.tokens.isEmpty else { throw LyricsAIError.noLyrics }
        guard known > 0 else { throw LyricsAIError.unreadable(firstUnknown) }
        return result
    }

    private struct Readings {
        var values: [[Character]]
        var estimated: Set<Int> = []
    }

    private static func autoReadings(_ line: LyricsDraft.Line, english: [String: String]) -> Readings {
        let text = line.text as NSString
        var starts = [0]
        for s in line.syllables { starts.append(starts.last! + s.text.utf16.count) }
        var result = Readings(values: .init(repeating: [], count: line.syllables.count))
        func assign(_ kana: [Character]?, range: NSRange) {
            let indices = line.syllables.indices.filter { NSIntersectionRange(range, NSRange(location: starts[$0], length: starts[$0 + 1] - starts[$0])).length > 0 }
            guard !indices.isEmpty else { return }
            guard let kana, !kana.isEmpty else {
                for i in indices where line.syllables[i].ruby?.isEmpty != false {
                    result.values[i].append(unknown); result.estimated.insert(i)
                }
                return
            }
            if indices.count == 1 { result.values[indices[0]] += kana; return }
            let parts = indices.map { i -> String in
                text.substring(with: NSIntersectionRange(range, NSRange(location: starts[i], length: starts[i + 1] - starts[i])))
            }
            let own = parts.map(normalizeKana)
            if own.allSatisfy({ $0 != nil }), own.compactMap({ $0 }).flatMap({ $0 }) == kana {
                for (i, value) in zip(indices, own) { result.values[i] += value! }
                return
            }
            // Only a whole-word reading is known. Partition at mora boundaries rather than
            // splitting a romaji consonant; flag these display boundaries for manual review.
            let groups = morae(kana)
            for (position, index) in indices.enumerated() {
                let lo = Int((Double(position) * Double(groups.count) / Double(indices.count)).rounded())
                let hi = Int((Double(position + 1) * Double(groups.count) / Double(indices.count)).rounded())
                result.values[index] += groups[lo..<hi].flatMap { $0 }
                result.estimated.insert(index)
            }
        }
        let tokenizer = CFStringTokenizerCreate(nil, line.text as CFString, CFRange(location: 0, length: text.length),
                                               kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard r.length > 0 else { continue }
            let range = NSRange(location: r.location, length: r.length)
            let surface = text.substring(with: range)
            guard hasLetters(surface) else { continue }
            if let kana = normalizeKana(surface) {
                let corrected: String
                switch surface {
                case "は": corrected = "わ"
                case "へ": corrected = "え"
                case "を": corrected = "お"
                case "こんにちは": corrected = "こんにちわ"
                case "こんばんは": corrected = "こんばんわ"
                default: corrected = String(kana)
                }
                assign(Array(corrected), range: range)
            } else if containsHan(surface) || surface.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                assign(latin.flatMap(romajiKana), range: range)
            } else {
                assign(englishReading(surface, dictionary: english), range: range)
            }
        }
        return result
    }

    private static func annotatedReading(_ text: String, english: [String: String]) -> [Character]? {
        normalizeKana(text) ?? englishReading(text, dictionary: english) ?? romajiKana(text)
    }

    private static func englishReading(_ text: String, dictionary: [String: String]) -> [Character]? {
        let key = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        if key == "a", text == "a" { return ["あ"] }
        if let value = dictionary[key] { return normalizeKana(value) }
        let pieces = key.split(whereSeparator: { $0 == "-" || $0.isWhitespace }).map(String.init)
        if pieces.count > 1 {
            var result: [Character] = []
            for part in pieces {
                guard let value = dictionary[part], let kana = normalizeKana(value) else { return nil }
                result += kana
            }
            return result
        }
        return nil
    }

    private static func romajiKana(_ text: String) -> [Character]? {
        var latin = text.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "’", with: "'")
        // ICU interprets doubled n as a geminate without this nasal separator.
        latin = latin.replacingOccurrences(of: "nn", with: "n'n")
        guard !latin.isEmpty, let value = latin.applyingTransform(StringTransform("Latin-Hiragana"), reverse: false) else { return nil }
        return normalizeKana(value)
    }

    private static func normalizeKana(_ text: String) -> [Character]? {
        // ICU's Katakana→Hiragana transform expands ー to a vowel. The model has a
        // dedicated long-mark token, so convert code points and preserve the mark.
        let normalized = text.precomposedStringWithCompatibilityMapping
        let value = String(String.UnicodeScalarView(normalized.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? UnicodeScalar(scalar.value - 0x60)! : scalar
        }))
        let chars = Array(value.filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.allSatisfy({ c in
            c.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
        }) else { return nil }
        return chars
    }

    private static func morae(_ chars: [Character]) -> [[Character]] {
        var result: [[Character]] = []
        for char in chars {
            if small.contains(char), !result.isEmpty { result[result.count - 1].append(char) }
            else { result.append([char]) }
        }
        return result
    }

    private static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0.value == 0x30FC }
    }
    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
    private static func sustainClass(_ char: Character) -> Int {
        if char == "ん" { return 6 }
        if char == "っ" { return 7 }
        for (index, chars) in ["あかさたなはまやらわがざだばぱゃぁゕ", "いきしちにひみりぎじぢびぴぃゐ", "うくすつぬふむゆるぐずづぶぷゅぅゔ", "えけせてねへめれげぜでべぺぇゑゖ", "おこそとのほもよろをごぞどぼぽょぉ"].enumerated() {
            if chars.contains(char) { return index + 1 }
        }
        return -1
    }
}
