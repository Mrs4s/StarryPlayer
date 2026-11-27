import Foundation
import LyricsCore

struct LyricsAIPronunciation: Sendable {
    struct ReadingOverride: Sendable {
        var line: Int
        var range: NSRange
        var reading: String
    }

    struct Word: Sendable {
        var line: Int
        var range: NSRange
        var syllables: Range<Int>
        var text: String
        var reading: String
        var candidates: [String]
    }

    struct Unit: Sendable {
        var line: Int
        var syllable: Int
        var tokens: Range<Int>
        var ruby: [Range<Int>]
        var approximate: Bool
        var english: [LyricsAIEnglishSyllables.Piece] = []
        /// Token ranges for the whole group's ruby pieces, stored on its first unit.
        var groupRuby: [Range<Int>] = []
    }

    var tokens: [LyricsAICTC.Token]
    var units: [Unit]
    var lines: [Int]
    var estimatedCount: Int
    var backgroundCount: Int
    var words: [Word] = []

    private static let unknown: Character = "\u{E000}"
    private static let small = Set("ぁぃぅぇぉゃゅょゎゕゖ")
    private static let fallback: [Character: Character] = ["ゎ": "わ", "ゕ": "か", "ゖ": "け", "ゐ": "い", "ゑ": "え", "ゔ": "ぶ"]

    static func make(draft: LyricsDraft, vocabulary: [String: Int], english: [String: String],
                     readings: [ReadingOverride] = []) throws -> Self {
        var result = Self(tokens: [], units: [], lines: [], estimatedCount: 0, backgroundCount: 0)
        var known = 0
        var firstUnknown = "歌词"
        for (lineIndex, sourceLine) in draft.lines.enumerated() {
            try Task.checkCancellation()
            if sourceLine.isBackground { result.backgroundCount += 1; continue }
            guard !sourceLine.syllables.isEmpty else { continue }
            let line = alignmentLine(sourceLine)
            let automatic = autoReadings(line, english: english, overrides: readings.filter { $0.line == lineIndex })
            let shared = sharedReadings(line, english: english)
            result.words += automatic.words.map { word in
                var word = word
                word.line = lineIndex
                return word
            }
            let lineStart = result.tokens.count
            var characters: [Character] = []
            let unitsStart = result.units.count
            let englishWords = LyricsAIEnglishSyllables.wordRanges(in: line.syllables.map(\.text).joined())
            var textOffset = 0
            for (index, syllable) in line.syllables.enumerated() {
                let textRange = NSRange(location: textOffset, length: syllable.text.utf16.count)
                textOffset += textRange.length
                let start = lineStart + characters.count
                var reading: [Character] = []
                var ruby: [Range<Int>] = []
                var approximate = automatic.estimated.contains(index)
                if let share = shared[index] {
                    reading = share.reading
                    approximate = share.estimated
                } else if let parts = syllable.ruby, !parts.isEmpty {
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
                // Empty shares stay between neighbours rather than adding an unknown token.
                if reading.isEmpty, shared[index] == nil, hasLetters(syllable.text) {
                    reading = [unknown]
                    firstUnknown = String(syllable.text.prefix(40))
                    approximate = true
                }
                if reading.contains(unknown) { approximate = true }
                characters += reading
                var unit = Unit(line: lineIndex, syllable: index, tokens: start..<(start + reading.count),
                                ruby: ruby, approximate: approximate)
                unit.groupRuby = shared[index]?.pieces.map { (start + $0.lowerBound)..<(start + $0.upperBound) } ?? []
                let words = englishWords.filter { NSIntersectionRange($0, textRange).length > 0 }
                if !approximate, ruby.isEmpty, shared[index] == nil, !syllable.isRest, syllable.checkpoints == nil, !syllable.hasRelease,
                   words.count == 1, let word = words.first, NSIntersectionRange(word, textRange) == word {
                    let local = NSRange(location: word.location - textRange.location, length: word.length)
                    let source = syllable.text as NSString
                    if !hasLetters(source.substring(to: local.location)), !hasLetters(source.substring(from: NSMaxRange(local))) {
                        unit.english = LyricsAIEnglishSyllables.pieces(text: syllable.text, wordRange: local, reading: reading)
                    }
                }
                result.units.append(unit)
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
                for (position, character) in group.enumerated() {
                    if character == unknown {
                        result.tokens.append(.init(label: 122, sustainClass: -1))
                    } else {
                        let char = vocabulary[String(character)] == nil ? (fallback[character] ?? character) : character
                        guard let id = vocabulary[String(char)], id != 121 else { throw LyricsAIError.unreadable(String(character)) }
                        result.tokens.append(.init(label: id, sustainClass: own,
                                                   isStandaloneVowel: group.count == 1 && "あいうえお".contains(char),
                                                   isMoraContinuation: position > 0, isLongMark: char == "ー"))
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

    // English ruby on katakana is a display gloss; align the written Japanese pronunciation.
    private static func alignmentLine(_ source: LyricsDraft.Line) -> LyricsDraft.Line {
        var line = source
        for index in source.syllables.indices {
            let syllable = source.syllables[index]
            if isEnglishLoanwordRuby(syllable.ruby, for: syllable.text) {
                line.syllables[index].ruby = nil
            }
        }
        for group in LyricsDraft.rubyGroups(in: source.syllables) {
            let text = group.map { source.syllables[$0].text }.joined()
            if isEnglishLoanwordRuby(source.syllables[group.lowerBound].groupRuby, for: text) {
                line.syllables[group.lowerBound].groupRuby = nil
                for index in group { line.syllables[index].joinsRubyGroup = false }
            }
        }
        return line
    }

    private static func isEnglishLoanwordRuby(_ ruby: [LyricsDraft.Ruby]?, for source: String) -> Bool {
        guard let ruby, !ruby.isEmpty else { return false }
        let letters = source.precomposedStringWithCompatibilityMapping.filter {
            $0.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        guard letters.unicodeScalars.contains(where: { (0x30A1...0x30FA).contains($0.value) }),
              normalizeKana(letters) != nil else { return false }
        let reading = ruby.map(\.text).joined().folding(options: [.diacriticInsensitive, .widthInsensitive],
                                                     locale: Locale(identifier: "en_US_POSIX"))
        let latin = reading.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !latin.isEmpty && latin.allSatisfy { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }

    private struct Readings {
        var values: [[Character]]
        var estimated: Set<Int> = []
        var words: [Word] = []
    }

    private struct Share {
        var reading: [Character]
        var estimated: Bool
        /// Ruby-piece ranges within the group, only on the first syllable.
        var pieces: [Range<Int>]
    }

    private static func sharedReadings(_ line: LyricsDraft.Line, english: [String: String]) -> [Int: Share] {
        var result: [Int: Share] = [:]
        for group in LyricsDraft.rubyGroups(in: line.syllables) {
            var pieces: [[Character]] = []
            for piece in line.syllables[group.lowerBound].groupRuby ?? [] {
                let kana = annotatedReading(piece.text.trimmingCharacters(in: .whitespaces), english: english) ?? []
                pieces.append(kana.isEmpty ? [unknown] : kana)
            }
            let reading = pieces.flatMap { $0 }
            var ranges: [Range<Int>] = []
            for piece in pieces { ranges.append((ranges.last?.upperBound ?? 0)..<((ranges.last?.upperBound ?? 0) + piece.count)) }
            let texts = group.map { line.syllables[$0].text }
            let (shares, estimated) = pieces.count == group.count ? (pieces, false) : divide(reading, among: texts)
            for (position, member) in group.enumerated() {
                result[member] = Share(reading: shares[position], estimated: estimated || shares[position].contains(unknown),
                                       pieces: position == 0 ? ranges : [])
            }
        }
        return result
    }

    private static func divide(_ reading: [Character], among texts: [String]) -> (shares: [[Character]], estimated: Bool) {
        let parts = texts.map { $0.trimmingCharacters(in: .whitespaces) }
        if !reading.contains(unknown) {
            let word = texts.joined().trimmingCharacters(in: .whitespaces)
            if LyricsAIEnglishSyllables.wordRanges(in: word) == [NSRange(location: 0, length: word.utf16.count)] {
                var offsets: [Int] = [], offset = 0
                for part in parts.dropLast() { offset += part.count; offsets.append(offset) }
                let boundaries = LyricsAIEnglishSyllables.tokenCuts(word: word, reading: reading, cuts: offsets)
                if boundaries.count == parts.count - 1 {
                    let edges = [0] + boundaries + [reading.count]
                    return (parts.indices.map { Array(reading[edges[$0]..<edges[$0 + 1]]) }, false)
                }
            }
            if let aligned = JapaneseReadingAlignment.align(reading: String(reading), to: parts),
               aligned.map(\.reading).joined() == String(reading) {
                return (aligned.map { Array($0.reading) }, aligned.contains(where: \.isEstimated))
            }
        }
        let groups = morae(reading)
        let shares = parts.indices.map { position -> [Character] in
            let lo = Int((Double(position) * Double(groups.count) / Double(parts.count)).rounded())
            let hi = Int((Double(position + 1) * Double(groups.count) / Double(parts.count)).rounded())
            return groups[lo..<hi].flatMap { $0 }
        }
        return (shares, true)
    }

    private static func autoReadings(_ line: LyricsDraft.Line, english: [String: String],
                                     overrides: [ReadingOverride]) -> Readings {
        // Rest blocks are not sung, but must still occupy their source-text offsets.
        let text = line.syllables.map(\.text).joined() as NSString
        var starts = [0]
        for s in line.syllables { starts.append(starts.last! + s.text.utf16.count) }
        var result = Readings(values: .init(repeating: [], count: line.syllables.count))
        let annotated = Set(line.syllables.indices.filter { line.syllables[$0].ruby?.isEmpty == false })
            .union(LyricsDraft.rubyGroups(in: line.syllables).flatMap { Array($0) })
        func assign(_ kana: [Character]?, range: NSRange, replacement: [Character]?) {
            let indices = line.syllables.indices.filter { NSIntersectionRange(range, NSRange(location: starts[$0], length: starts[$0 + 1] - starts[$0])).length > 0 }
            guard !indices.isEmpty else { return }
            guard let kana, !kana.isEmpty else {
                for i in indices where !annotated.contains(i) {
                    result.values[i].append(unknown); result.estimated.insert(i)
                }
                return
            }
            if indices.count == 1 { result.values[indices[0]] += replacement ?? kana; return }
            let parts = indices.map { i -> String in
                text.substring(with: NSIntersectionRange(range, NSRange(location: starts[i], length: starts[i + 1] - starts[i])))
            }
            let own = parts.map(normalizeKana)
            if replacement == nil, own.allSatisfy({ $0 != nil }), own.compactMap({ $0 }).flatMap({ $0 }) == kana {
                for (i, value) in zip(indices, own) { result.values[i] += value! }
                return
            }
            if LyricsAIEnglishSyllables.wordRanges(in: text.substring(with: range)) == [NSRange(location: 0, length: range.length)] {
                var offsets: [Int] = [], offset = 0
                for part in parts.dropLast() { offset += part.count; offsets.append(offset) }
                let boundaries = LyricsAIEnglishSyllables.tokenCuts(word: text.substring(with: range), reading: kana, cuts: offsets)
                if boundaries.count == indices.count - 1 {
                    let edges = [0] + boundaries + [kana.count]
                    for (position, index) in indices.enumerated() { result.values[index] += kana[edges[position]..<edges[position + 1]] }
                    return
                }
            }
            if let aligned = JapaneseReadingAlignment.align(reading: String(replacement ?? kana), to: parts) {
                for (index, part) in zip(indices, aligned) {
                    result.values[index] += Array(part.reading)
                    if part.isEstimated { result.estimated.insert(index) }
                }
                return
            }
            let groups = morae(kana)
            var original: [[Character]] = []
            for (position, index) in indices.enumerated() {
                let lo = Int((Double(position) * Double(groups.count) / Double(indices.count)).rounded())
                let hi = Int((Double(position + 1) * Double(groups.count) / Double(indices.count)).rounded())
                original.append(groups[lo..<hi].flatMap { $0 })
                result.estimated.insert(index)
            }
            let pieces = replacement.map { redistribute($0, preserving: original) } ?? original
            for (index, piece) in zip(indices, pieces) { result.values[index] += piece }
        }
        let romanized = LyricsAIReadingLexicon.romanizedSyllables(line)
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: text.length),
                                               kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard r.length > 0 else { continue }
            let range = NSRange(location: r.location, length: r.length)
            let surface = text.substring(with: range)
            guard hasLetters(surface) else { continue }
            let kana: [Character]?
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
                assign(Array(corrected), range: range, replacement: nil)
                continue
            } else if let counted = numberReading(surface) {
                kana = geminateBeforeTrillionIfNeeded(counted, surface: surface, after: NSMaxRange(range), in: text)
            } else if containsHan(surface) || surface.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                let rawKana = latin.flatMap(romajiKana) ?? singleDigitReading(surface)
                kana = rawKana.map { geminateBeforeTrillionIfNeeded($0, surface: surface, after: NSMaxRange(range), in: text) }
            } else {
                kana = englishReading(surface, dictionary: english)
            }
            let indices = line.syllables.indices.filter { NSIntersectionRange(range, NSRange(location: starts[$0], length: starts[$0 + 1] - starts[$0])).length > 0 }
            let editable = !indices.isEmpty && indices.allSatisfy { index in
                guard !annotated.contains(index) else { return false }
                let lower = starts[index], upper = starts[index + 1]
                guard upper <= text.length else { return false }
                let before = text.substring(with: NSRange(location: lower, length: max(0, range.location - lower)))
                let afterStart = min(upper, NSMaxRange(range))
                let after = text.substring(with: NSRange(location: afterStart, length: upper - afterStart))
                return !hasLetters(before) && !hasLetters(after)
            }
            let explicitOverride = editable ? overrides.first(where: { $0.range == range }).flatMap { normalizeKana($0.reading) } : nil
            let defaultOverride = kana.flatMap { lyricDefaultReading(surface: surface, base: $0) }
            let replacement = explicitOverride ?? defaultOverride
            assign(kana ?? replacement, range: range, replacement: replacement)
            guard editable, containsHan(surface) else { continue }
            var candidates = LyricsAIReadingLexicon.candidates(for: surface, defaultReading: kana.map { String($0) })
            if let base = kana.map({ String($0) }), !candidates.contains(base) { candidates.append(base) }
            if let romanized {
                let latin = indices.map { romanized[$0] }.joined()
                if let proposed = romajiKana(latin), proposed.count <= 64 { candidates.insert(String(proposed), at: 0) }
            }
            let reading = String(replacement ?? kana ?? [unknown])
            var unique = [reading]
            for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
            if unique.count > 1 {
                result.words.append(.init(line: 0, range: range, syllables: indices.first!..<(indices.last! + 1),
                                          text: surface, reading: reading, candidates: Array(unique.prefix(6))))
            }
        }
        return result
    }

    private static func redistribute(_ kana: [Character], preserving original: [[Character]]) -> [[Character]] {
        var result = [[Character]](repeating: [], count: original.count)
        var lower = 0, upper = kana.count, first = 0, end = original.count
        while first < end, !original[first].isEmpty, original[first].count <= upper - lower,
              Array(kana[lower..<(lower + original[first].count)]) == original[first] {
            result[first] = original[first]; lower += original[first].count; first += 1
        }
        while end > first, !original[end - 1].isEmpty, original[end - 1].count <= upper - lower,
              Array(kana[(upper - original[end - 1].count)..<upper]) == original[end - 1] {
            end -= 1; result[end] = original[end]; upper -= original[end].count
        }
        if first == end {
            if lower < upper, !result.isEmpty { result[result.count - 1] += kana[lower..<upper] }
            return result
        }
        let groups = morae(Array(kana[lower..<upper])), count = end - first
        for position in 0..<count {
            let lo = Int((Double(position) * Double(groups.count) / Double(count)).rounded())
            let hi = Int((Double(position + 1) * Double(groups.count) / Double(count)).rounded())
            result[first + position] = groups[lo..<hi].flatMap { $0 }
        }
        return result
    }

    private static let lyricReadings: [String: (prose: String, lyric: String)] = [
        "私": ("わたくし", "わたし"),
        "身体": ("しんたい", "からだ"),
        "君": ("くん", "きみ"),
        "明日": ("あす", "あした"),
        "良い": ("よい", "いい"),
        "言う": ("ゆう", "いう"),
        "間": ("あいだ", "ま")
    ]

    private static let lyricStems: [(surface: String, prose: String, lyric: String)] = [
        ("瞬", "しばたた", "またた"),
        ("埋も", "うずも", "うも")
    ]

    private static let letterReadings: [Character: String] = [
        "a": "えー", "b": "びー", "c": "しー", "d": "でぃー", "e": "いー", "f": "えふ", "g": "じー",
        "h": "えいち", "i": "あい", "j": "じぇー", "k": "けー", "l": "える", "m": "えむ", "n": "えぬ",
        "o": "おー", "p": "ぴー", "q": "きゅー", "r": "あーる", "s": "えす", "t": "てぃー", "u": "ゆー",
        "v": "ぶい", "w": "だぶりゅー", "x": "えっくす", "y": "わい", "z": "ぜっと"
    ]

    private static let englishOverrides: [String: String] = [
        "to": "とぅー", "yeah": "いぇー", "at": "あっと", "so": "そー",
        "i'm": "あいむ", "i'll": "あいる", "i've": "あいぶ", "let's": "れっつ",
        "can't": "きゃんと", "won't": "うぉんと", "didn't": "でぃどぅんと",
        "isn't": "いずんと", "doesn't": "だずんと", "don't": "どんと",
        "you're": "ゆあ", "you'll": "ゆーる", "we're": "うぃあ",
        "that's": "ざっつ", "what's": "わっつ", "it's": "いっつ"
    ]

    private static let contractionFallbacks: [String: String] = [
        "im": "あいむ", "ive": "あいぶ", "lets": "れっつ", "cant": "きゃんと",
        "wont": "うぉんと", "didnt": "でぃどぅんと", "isnt": "いずんと",
        "doesnt": "だずんと", "dont": "どんと", "youre": "ゆあ", "youll": "ゆーる",
        "thats": "ざっつ", "whats": "わっつ", "woah": "うぉー", "whoa": "うぉー", "nah": "なー"
    ]

    private static let apostropheSuffixes: [String: String] = [
        "m": "む", "re": "あ", "ll": "る", "ve": "ぶ", "d": "ど", "t": "と"
    ]

    private static let productivePrefixes: [(prefix: String, reading: String)] = [
        ("re", "り"), ("un", "あん"), ("non", "のん"), ("pre", "ぷり")
    ]

    private static let strictRomajiTable: [String: String] = {
        var table: [String: String] = [
            "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
            "ya": "や", "yu": "ゆ", "yo": "よ", "wa": "わ", "wo": "を",
            "shi": "し", "chi": "ち", "tsu": "つ", "fu": "ふ", "ji": "じ",
            "she": "しぇ", "che": "ちぇ", "je": "じぇ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ"
        ]
        let rows: [(String, [String])] = [
            ("k", ["か", "き", "く", "け", "こ"]), ("g", ["が", "ぎ", "ぐ", "げ", "ご"]),
            ("s", ["さ", "し", "す", "せ", "そ"]), ("z", ["ざ", "じ", "ず", "ぜ", "ぞ"]),
            ("t", ["た", "ち", "つ", "て", "と"]), ("d", ["だ", "ぢ", "づ", "で", "ど"]),
            ("n", ["な", "に", "ぬ", "ね", "の"]), ("h", ["は", "ひ", "ふ", "へ", "ほ"]),
            ("b", ["ば", "び", "ぶ", "べ", "ぼ"]), ("p", ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"]),
            ("m", ["ま", "み", "む", "め", "も"]), ("r", ["ら", "り", "る", "れ", "ろ"]),
            ("l", ["ら", "り", "る", "れ", "ろ"])
        ]
        let vowels = ["a", "i", "u", "e", "o"]
        for (c, kanaRow) in rows {
            for (v, k) in zip(vowels, kanaRow) { table[c + v] = k }
        }
        let glides: [(String, String)] = [
            ("ky", "き"), ("gy", "ぎ"), ("sh", "し"), ("sy", "し"),
            ("j", "じ"), ("jy", "じ"), ("zy", "じ"), ("ch", "ち"), ("ty", "ち"),
            ("ny", "に"), ("hy", "ひ"), ("by", "び"), ("py", "ぴ"),
            ("my", "み"), ("ry", "り"), ("ly", "り")
        ]
        for (c, base) in glides {
            for (v, small) in [("a", "ゃ"), ("u", "ゅ"), ("o", "ょ")] { table[c + v] = base + small }
        }
        return table
    }()

    private static func lyricDefaultReading(surface: String, base: [Character]) -> [Character]? {
        let key = surface.precomposedStringWithCompatibilityMapping
        let reading = String(base)
        if let entry = lyricReadings[key], entry.prose == reading, entry.lyric != reading {
            return Array(entry.lyric)
        }
        for stem in lyricStems where key.hasPrefix(stem.surface) && reading.hasPrefix(stem.prose) {
            return Array(stem.lyric + reading.dropFirst(stem.prose.count))
        }
        return nil
    }

    private static func singleDigitReading(_ surface: String) -> [Character]? {
        let normalized = surface.precomposedStringWithCompatibilityMapping
        let map: [String: String] = [
            "0": "ぜろ", "1": "いち", "2": "に", "3": "さん", "4": "よん",
            "5": "ご", "6": "ろく", "7": "なな", "8": "はち", "9": "きゅう"
        ]
        return map[normalized].map(Array.init)
    }

    private static func geminateBeforeTrillionIfNeeded(_ kana: [Character], surface: String, after end: Int, in text: NSString) -> [Character] {
        let normalized = surface.precomposedStringWithCompatibilityMapping
        guard normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              end < text.length, text.substring(with: NSRange(location: end, length: 1)) == "兆" else { return kana }
        let str = String(kana)
        for (ending, geminated) in [("いち", "いっ"), ("はち", "はっ"), ("じゅう", "じゅっ")] where str.hasSuffix(ending) {
            return Array(str.dropLast(ending.count) + geminated)
        }
        return kana
    }

    private static func numberReading(_ surface: String) -> [Character]? {
        let normalized = surface.precomposedStringWithCompatibilityMapping
        guard normalized.count >= 2 else { return nil }
        let unitMap: [Character: String] = ["万": "まん", "億": "おく", "兆": "ちょう"]
        var digitsSlice = Substring(normalized)
        var trailingUnit = ""
        if let last = digitsSlice.last, let unit = unitMap[last] {
            trailingUnit = unit
            digitsSlice = digitsSlice.dropLast()
        }
        guard !digitsSlice.isEmpty, digitsSlice.count <= 16,
              digitsSlice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if digitsSlice.first == "0" {
            guard trailingUnit.isEmpty else { return nil }
            var out: [Character] = []
            for ch in digitsSlice {
                guard let part = singleDigitReading(String(ch)) else { return nil }
                out += part
            }
            return out
        }
        guard let value = UInt64(digitsSlice) else { return nil }
        func withUnit(_ reading: String, _ unit: String) -> String {
            var adjusted = reading
            if unit == "ちょう" {
                for (ending, geminated) in [("いち", "いっ"), ("はち", "はっ"), ("じゅう", "じゅっ")] where adjusted.hasSuffix(ending) {
                    adjusted = String(adjusted.dropLast(ending.count)) + geminated
                    break
                }
            }
            return adjusted + unit
        }
        func belowTenThousand(_ part: UInt64) -> String {
            let digits = ["", "いち", "に", "さん", "よん", "ご", "ろく", "なな", "はち", "きゅう"]
            var result = ""
            for (power, divisor, name) in [(3, UInt64(1000), "せん"), (2, UInt64(100), "ひゃく"), (1, UInt64(10), "じゅう"), (0, UInt64(1), "")] {
                let digit = Int((part / divisor) % 10)
                if digit == 3 && power == 2 { result += "さんびゃく" }
                else if digit == 6 && power == 2 { result += "ろっぴゃく" }
                else if digit == 8 && power == 2 { result += "はっぴゃく" }
                else if digit == 3 && power == 3 { result += "さんぜん" }
                else if digit == 8 && power == 3 { result += "はっせん" }
                else if digit == 1 && power > 0 { result += name }
                else if digit > 0 { result += digits[digit] + name }
            }
            return result
        }
        var reading = ""
        for (divisor, name) in [(UInt64(1_000_000_000_000), "ちょう"), (UInt64(100_000_000), "おく"), (UInt64(10_000), "まん"), (UInt64(1), "")] {
            let part = (value / divisor) % 10_000
            if part > 0 { reading += withUnit(belowTenThousand(part), name) }
        }
        guard !reading.isEmpty else { return nil }
        return Array(withUnit(reading, trailingUnit))
    }

    private static func annotatedReading(_ text: String, english: [String: String]) -> [Character]? {
        normalizeKana(text) ?? englishReading(text, dictionary: english) ?? romajiKana(text)
    }

    private static func englishReading(_ text: String, dictionary: [String: String]) -> [Character]? {
        let normalized = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
        let key = normalized.lowercased()
        if key == "a", normalized == "a" { return ["あ"] }
        guard !dictionary.isEmpty else { return nil }
        let pieces = normalized.split(whereSeparator: { "-‐‑–".contains($0) || $0.isWhitespace }).map(String.init)
        if pieces.count > 1 {
            var result: [Character] = []
            for part in pieces {
                guard let kana = englishWordReading(part, dictionary: dictionary, allowArticleA: true) else { return nil }
                result += kana
            }
            return result
        }
        return englishWordReading(normalized, dictionary: dictionary, allowArticleA: normalized == "a")
    }

    private static func knownEnglishWord(_ plain: String, dictionary: [String: String]) -> [Character]? {
        if let override = englishOverrides[plain] { return Array(override) }
        if let value = dictionary[plain], let kana = normalizeKana(value) { return kana }
        return nil
    }

    private static func englishWordReading(_ raw: String, dictionary: [String: String], allowArticleA: Bool) -> [Character]? {
        let word = raw.lowercased()
        guard !word.isEmpty else { return nil }
        if word.count == 1, let ch = word.first, let letter = letterReadings[ch] {
            return ch == "a" && allowArticleA ? ["あ"] : Array(letter)
        }
        if let override = englishOverrides[word] { return Array(override) }
        if let value = dictionary[word], let kana = normalizeKana(value) { return kana }
        if let apostrophe = word.lastIndex(of: "'"), apostrophe > word.startIndex {
            let base = String(word[..<apostrophe])
            let suffix = String(word[word.index(after: apostrophe)...])
            if suffix == "s", let stem = englishWordReading(base, dictionary: dictionary, allowArticleA: false) {
                let voiceless = base.last.map { "ptkf".contains($0) } == true
                return stem + [voiceless ? "す" : "ず"]
            } else if let ending = apostropheSuffixes[suffix],
                      let stem = englishWordReading(base, dictionary: dictionary, allowArticleA: false) {
                return stem + Array(ending)
            }
        }
        let plain = word.replacingOccurrences(of: "'", with: "")
        guard !plain.isEmpty else { return nil }
        if let kana = knownEnglishWord(plain, dictionary: dictionary) { return kana }
        if let fallback = contractionFallbacks[plain] { return Array(fallback) }
        if let romaji = strictRomaji(plain) { return romaji }
        if let inflected = englishInflection(plain, dictionary: dictionary) { return inflected }
        if let compound = englishCompoundOrRepeat(plain, dictionary: dictionary) { return compound }
        if plain.count <= 6, plain.allSatisfy({ letterReadings[$0] != nil }),
           !plain.contains(where: { "aiueoy".contains($0) }) {
            return Array(plain.compactMap { letterReadings[$0] }.joined())
        }
        return nil
    }

    private static func englishInflection(_ plain: String, dictionary: [String: String]) -> [Character]? {
        if plain.count > 4, plain.hasSuffix("ies") {
            let stem = String(plain.dropLast(3)) + "y"
            if let base = knownEnglishWord(stem, dictionary: dictionary) { return base + ["ず"] }
        }
        if plain.count > 3, plain.hasSuffix("es") {
            let stem = String(plain.dropLast(2))
            if let base = knownEnglishWord(stem, dictionary: dictionary) {
                let sibilant = ["s", "z", "x", "sh", "ch"].contains { stem.hasSuffix($0) }
                return base + Array(sibilant ? "いず" : "ず")
            }
        }
        if plain.count > 3, plain.hasSuffix("s"), !plain.hasSuffix("ss") {
            let stem = String(plain.dropLast())
            if let base = knownEnglishWord(stem, dictionary: dictionary) {
                let voiceless = stem.last.map { "ptkf".contains($0) } == true
                return base + [voiceless ? "す" : "ず"]
            }
        }
        for (prefix, prefixKana) in productivePrefixes where plain.hasPrefix(prefix) {
            let stem = String(plain.dropFirst(prefix.count))
            if stem.count >= 4, let base = knownEnglishWord(stem, dictionary: dictionary) {
                return Array(prefixKana) + base
            }
        }
        return nil
    }

    private static func englishCompoundOrRepeat(_ plain: String, dictionary: [String: String]) -> [Character]? {
        let chars = Array(plain)
        if chars.count >= 4 {
            for unitLen in 2...(chars.count / 2) where chars.count.isMultiple(of: unitLen) {
                let unit = String(chars[0..<unitLen])
                let repeats = chars.count / unitLen
                guard (1..<repeats).allSatisfy({ String(chars[($0 * unitLen)..<(($0 + 1) * unitLen)]) == unit }) else { continue }
                if let unitReading = knownEnglishWord(unit, dictionary: dictionary)
                    ?? contractionFallbacks[unit].map(Array.init)
                    ?? strictRomaji(unit) {
                    return Array(repeating: unitReading, count: repeats).flatMap { $0 }
                }
            }
        }
        guard chars.count >= 6 else { return nil }
        for cut in stride(from: chars.count - 3, through: 3, by: -1) {
            let head = String(chars[0..<cut]), tail = String(chars[cut..<chars.count])
            if let left = knownEnglishWord(head, dictionary: dictionary),
               let right = knownEnglishWord(tail, dictionary: dictionary) {
                return left + right
            }
        }
        return nil
    }

    private static func strictRomaji(_ word: String) -> [Character]? {
        let chars = Array(word)
        guard !chars.isEmpty else { return nil }
        var kana = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "n", i + 1 == chars.count || !"aiueoy".contains(chars[i + 1]) {
                kana += "ん"
                i += (i + 2 == chars.count && chars[i + 1] == "n") ? 2 : 1
                continue
            }
            if i + 1 < chars.count, chars[i] == chars[i + 1], !"aiueon".contains(chars[i]), chars[i].isASCII, chars[i].isLetter {
                kana += "っ"
                i += 1
                continue
            }
            var matched = false
            for size in [3, 2, 1] where i + size <= chars.count {
                let slice = String(chars[i..<(i + size)])
                if let mapped = strictRomajiTable[slice] {
                    kana += mapped
                    i += size
                    matched = true
                    break
                }
            }
            if !matched { return nil }
        }
        return kana.isEmpty ? nil : Array(kana)
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
        })).precomposedStringWithCanonicalMapping
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
