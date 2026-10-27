import Foundation

/// Duration priors for display blocks, not a claim that every mora has an audible attack.
public enum LyricsTimingWeights {
    public enum Language: String, CaseIterable, Sendable, Hashable {
        case automatic, chinese, japanese
    }

    public enum Attack: Sendable {
        case vowel, sonorant, other
    }

    public struct Syllable: Sendable {
        public var weight: Double
        public var internalAttacks: Double
        public var attack: Attack
        public var approximateReading: Bool
    }

    public struct Profile: Sendable {
        public var syllables: [Syllable]
        public var japanese: Bool
    }

    public static func weights(for line: LyricsDraft.Line, language: Language) -> [Double] {
        profile(for: line, language: language).syllables.map(\.weight)
    }

    public static func profile(for line: LyricsDraft.Line, language: Language) -> Profile {
        let japanese = language == .japanese || (language == .automatic && line.text.unicodeScalars.contains(where: LyricRomanizationAligner.isKana))
        var readings: [[[Character]]]
        if japanese, !line.syllables.isEmpty {
            let syllables = line.syllables.map { LyricSyllable(start: 0, end: 1, text: $0.text) }
            readings = LyricRomanizationAligner.readings(of: syllables, text: line.text, locale: "ja").map { LyricRomanizationAligner.split(morae: $0) }
        } else {
            readings = .init(repeating: [], count: line.syllables.count)
        }
        let rubies = line.syllables.map { ($0.ruby ?? []).map(\.text).joined() }
        let groups = japanese ? tokenGroups(in: line) : []
        // Display blocks containing っ need a vowel and its closure. An even split
        // of a compound reading can otherwise assign the vowel to the preceding kanji.
        for group in groups {
            for index in group.dropFirst() where rubies[index].isEmpty && containsHan(line.syllables[index].text) {
                let previous = index - 1
                guard rubies[previous].isEmpty, containsHan(line.syllables[previous].text),
                      line.syllables[index].text.contains(where: { $0 == "っ" || $0 == "ッ" }) else { continue }
                let minimum = minimumMorae(in: line.syllables[index].text)
                while readings[index].count < minimum, readings[previous].count > minimumMorae(in: line.syllables[previous].text) {
                    readings[index].insert(readings[previous].removeLast(), at: 0)
                }
            }
        }
        var result = line.syllables.enumerated().map { index, syllable -> Syllable in
            let fallback = Double(max(1, syllable.text.filter { $0.isLetter || $0.isNumber }.count))
            guard japanese else { return Syllable(weight: fallback, internalAttacks: max(0, fallback - 1), attack: .other, approximateReading: false) }
            let ruby = rubies[index]
            var units = ruby.isEmpty ? readings[index] : LyricRomanizationAligner.split(morae: LyricRomanizationAligner.fold(ruby.applyingTransform(.toLatin, reverse: false) ?? ruby))
            if ruby.isEmpty, groups.contains(index..<(index + 1)) {
                switch syllable.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "は": units = [Array("wa")]
                case "へ": units = [Array("e")]
                case "を": units = [Array("o")]
                default: break
                }
            }
            let weight = units.isEmpty ? fallback : Double(units.count)
            let first = units.first?.first
            let attack: Attack = first.map { "aeiou".contains($0) ? .vowel : ("ywrlmn".contains($0) ? .sonorant : .other) } ?? .other
            let surface = syllable.text.filter { $0.unicodeScalars.contains { LyricRomanizationAligner.isKana($0) || LyricRomanizationAligner.isHan($0) } }
            let closures = surface.reversed().prefix { $0 == "っ" || $0 == "ッ" }.count
            // A tokenizer may spell a final closure as "tsu". It consumes time,
            // but is not another vowel attack inside this display block.
            let nuclei = units.dropLast(min(closures, units.count)).filter { $0.contains(where: { "aeiou".contains($0) }) }.count
            let internalAttacks = syllable.text.contains("ー") ? 0 : min(max(0, weight - 1), Double(max(0, nuclei - 1)))
            return Syllable(weight: weight, internalAttacks: internalAttacks, attack: attack, approximateReading: ruby.isEmpty && containsHan(syllable.text))
        }
        // A tokenizer supplies the reading of a whole kanji compound, not exact
        // per-character readings. Keep its total duration without inventing which
        // character gets an extra mora (e.g. a three-mora, two-kanji compound).
        for group in groups {
            var index = group.lowerBound
            while index < group.upperBound {
                guard rubies[index].isEmpty, onlyHan(line.syllables[index].text) else { index += 1; continue }
                var end = index + 1
                while end < group.upperBound, rubies[end].isEmpty, onlyHan(line.syllables[end].text) { end += 1 }
                if end - index > 1 {
                    let mean = result[index..<end].reduce(0) { $0 + $1.weight } / Double(end - index)
                    for part in index..<end {
                        result[part].weight = mean
                        result[part].internalAttacks = 0
                    }
                }
                index = end
            }
        }
        return Profile(syllables: result, japanese: japanese)
    }

    private static func containsHan(_ text: String) -> Bool { text.unicodeScalars.contains(where: LyricRomanizationAligner.isHan) }
    private static func onlyHan(_ text: String) -> Bool {
        let scalars = text.trimmingCharacters(in: .whitespaces).unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy(LyricRomanizationAligner.isHan)
    }

    private static func minimumMorae(in text: String) -> Int {
        let small: Set<Character> = Set("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ")
        return max(1, text.filter { character in
            !small.contains(character) && character.unicodeScalars.contains { LyricRomanizationAligner.isHan($0) || LyricRomanizationAligner.isKana($0) }
        }.count)
    }

    private static func tokenGroups(in line: LyricsDraft.Line) -> [Range<Int>] {
        let text = line.text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, line.text as CFString, CFRange(location: 0, length: text.length),
                                               kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var offsets = [0]
        for syllable in line.syllables { offsets.append(offsets.last! + syllable.text.utf16.count) }
        var groups: [Range<Int>] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let parts = line.syllables.indices.filter { offsets[$0] < token.location + token.length && offsets[$0 + 1] > token.location }
            if let first = parts.first, let last = parts.last { groups.append(first..<(last + 1)) }
        }
        return groups
    }
}
