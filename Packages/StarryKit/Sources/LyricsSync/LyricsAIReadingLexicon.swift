import Foundation
import LyricsCore

enum LyricsAIReadingLexicon {
    private static let dictionary: LyricsAIReadingIndex? = {
        guard let url = Bundle.module.url(forResource: "readings", withExtension: "bin", subdirectory: "JapaneseReadings") else { return nil }
        return LyricsAIReadingIndex(contentsOf: url)
    }()

    private static let supplements: [String: [String]] = [
        "明日": ["あした", "あす", "みょうにち"],
        "昨日": ["きのう", "さくじつ"],
        "今日": ["きょう", "こんにち"],
        "私": ["わたし", "わたくし", "あたし"],
        "君": ["きみ", "くん"],
        "何": ["なに", "なん"],
        "一日": ["いちにち", "ついたち"],
        "一人": ["ひとり", "いちにん"],
        "二人": ["ふたり", "ににん"],
        "間": ["あいだ", "ま", "かん"],
        "身体": ["からだ", "しんたい"],
        "人気": ["にんき", "ひとけ"],
        "良い": ["いい", "よい"],
        "運命": ["うんめい", "さだめ"],
        "永遠": ["えいえん", "とわ"],
        "故郷": ["ふるさと", "こきょう"],
        "理由": ["りゆう", "わけ"]
    ]

    static func candidates(for surface: String, defaultReading: String?) -> [String] {
        let key = surface.precomposedStringWithCompatibilityMapping
        let entries = dictionary?.entries(for: key) ?? []
        let preferred = normalizedReading(defaultReading ?? "")
        let parts = entries.filter { $0.reading == preferred }.reduce(0) { $0 | $1.partOfSpeech }
        let ordered = entries.sorted { a, b in
            let aMatches = a.partOfSpeech & parts != 0, bMatches = b.partOfSpeech & parts != 0
            if aMatches != bMatches { return aMatches }
            if a.cost != b.cost { return a.cost < b.cost }
            return a.reading < b.reading
        }
        var result = supplements[key] ?? []
        for entry in ordered where !result.contains(entry.reading) { result.append(entry.reading) }
        return result
    }

    private static func normalizedReading(_ value: String) -> String {
        let value = value.precomposedStringWithCompatibilityMapping
        return String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
    }

    // Synthetic block positions prevent existing timing from biasing romanization proposals.
    static func romanizedSyllables(_ line: LyricsDraft.Line) -> [String]? {
        guard !line.romanization.isEmpty, line.romanization.utf16.count <= 8192,
              line.syllables.count <= 1024,
              line.text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return nil }
        let words = line.syllables.enumerated().map { index, syllable in
            LyricWord(start: Double(index), end: Double(index + 1), text: syllable.text)
        }
        guard let aligned = LyricRomanizationAligner.align(line.romanization, to: words) else { return nil }
        var result = [String](repeating: "", count: words.count)
        for syllable in aligned.flatMap(\.syllables) {
            let index = Int(syllable.start)
            guard result.indices.contains(index) else { return nil }
            result[index] += syllable.text
        }
        return result
    }
}
