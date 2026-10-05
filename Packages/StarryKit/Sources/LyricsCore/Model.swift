import Foundation

/// Unified lyric model: line → word → syllable, with singer, background vocals,
/// translation and romanization. TTML fills every level; YRC has per-character timing only,
/// so each character becomes a word with one syllable.
public struct LyricsDocument: Sendable, Hashable {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case ttml, yrc, qrc, krc, lrc
    }

    public var format: Format
    public var lines: [LyricLine]
    public var metadata: [String: String]

    public init(format: Format, lines: [LyricLine], metadata: [String: String] = [:]) {
        self.format = format
        self.lines = lines
        self.metadata = metadata
    }

    public var hasSyllables: Bool {
        lines.contains { $0.words.count > 1 || ($0.words.first?.syllables.count ?? 0) > 1 }
    }

    public var isEmpty: Bool { lines.isEmpty }

    public var hasTranslation: Bool { lines.contains { $0.translation?.isEmpty == false } }
    public var hasRomanization: Bool { lines.contains { $0.romanization?.isEmpty == false } }
    public var hasBackgroundVocals: Bool { lines.contains { $0.background != nil } }
    public var hasDuet: Bool { lines.contains { $0.singer == .secondary } }
    /// More than one vocalist: lines are laid out narrower so alternating voices read as left /
    /// right.
    public var hasMultipleVocalists: Bool { lines.contains { $0.singer != .primary } }

    /// Index of the line active at `time`, or nil before the first line.
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count - 1, result: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// Instrumental breaks: an intro when the first line starts more than `minimum` seconds in, and
    /// a break wherever the next line starts more than `minimum` seconds after the previous one
    /// ends; a break after a line begins 0.1 s after that line's end. Blank lines (LRC end markers)
    /// do not count as sung.
    public func instrumentalGaps(minimum: TimeInterval = 7) -> [InstrumentalGap] {
        var gaps: [InstrumentalGap] = []
        let sung = lines.indices.filter { !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = sung.first else { return gaps }
        if lines[first].start > minimum {
            gaps.append(InstrumentalGap(afterLine: nil, start: 0, end: lines[first].start))
        }
        for (a, b) in zip(sung, sung.dropFirst()) where lines[b].start - lines[a].end > minimum {
            gaps.append(InstrumentalGap(afterLine: a, start: lines[a].end + 0.1, end: lines[b].start))
        }
        return gaps
    }
}

public struct InstrumentalGap: Sendable, Hashable {
    /// Index of the line the gap follows, nil for the intro.
    public var afterLine: Int?
    public var start: TimeInterval
    public var end: TimeInterval

    public init(afterLine: Int?, start: TimeInterval, end: TimeInterval) {
        self.afterLine = afterLine
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public enum LyricSinger: String, Sendable, Codable {
    case primary, secondary, duet
}

public struct LyricLine: Sendable, Hashable, Identifiable {
    public var id: Int
    /// Includes background-vocal timing.
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [LyricWord]
    public var translation: String?
    public var romanization: String?
    /// Timed romanization: the pronunciation as words with their own syllable timing. When present
    /// the romanization is laid out word by word under the text instead of as a block
    /// (`LyricRomanizationGrouping`).
    public var romanizationWords: [LyricWord]?
    public var singer: LyricSinger
    public var background: LyricBackgroundVocals?
    public var primaryStart: TimeInterval
    public var primaryEnd: TimeInterval
    public var isParagraphStart: Bool

    public init(id: Int, start: TimeInterval, end: TimeInterval, words: [LyricWord], translation: String? = nil, romanization: String? = nil, romanizationWords: [LyricWord]? = nil, singer: LyricSinger = .primary, background: LyricBackgroundVocals? = nil, primaryStart: TimeInterval? = nil, primaryEnd: TimeInterval? = nil, isParagraphStart: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.words = words
        self.translation = translation
        self.romanization = romanization
        self.romanizationWords = romanizationWords
        self.singer = singer
        self.background = background
        self.primaryStart = primaryStart ?? start
        self.primaryEnd = primaryEnd ?? end
        self.isParagraphStart = isParagraphStart
    }

    public var text: String { words.map(\.text).joined() }
    public var duration: TimeInterval { max(0, end - start) }

    public var syllables: [LyricSyllable] { words.flatMap(\.syllables) }

    /// True when the line has usable sub-line timing (more than one timed unit).
    public var hasSyllableTiming: Bool { words.count > 1 || (words.first?.syllables.count ?? 0) > 1 }

    public static func plain(id: Int, start: TimeInterval, end: TimeInterval, text: String, translation: String? = nil) -> LyricLine {
        LyricLine(id: id, start: start, end: end, words: [LyricWord(start: start, end: end, text: text)], translation: translation)
    }
}

public struct LyricBackgroundVocals: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [LyricWord]
    public var translation: String?
    public var romanization: String?
    public var romanizationWords: [LyricWord]?

    public init(start: TimeInterval, end: TimeInterval, words: [LyricWord], translation: String? = nil, romanization: String? = nil, romanizationWords: [LyricWord]? = nil) {
        self.start = start
        self.end = end
        self.words = words
        self.translation = translation
        self.romanization = romanization
        self.romanizationWords = romanizationWords
    }

    public var text: String { words.map(\.text).joined() }
    public var syllables: [LyricSyllable] { words.flatMap(\.syllables) }
    public var hasSyllableTiming: Bool { words.count > 1 || (words.first?.syllables.count ?? 0) > 1 }

    public func isAbove(_ line: LyricLine) -> Bool {
        guard let first = line.words.first?.syllables.first?.start else { return false }
        return start < first
    }
}

public struct LyricWord: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var syllables: [LyricSyllable]
    /// UTF-16 length of the word itself (without surrounding whitespace).
    public var length: Int

    public init(start: TimeInterval, end: TimeInterval, text: String, syllables: [LyricSyllable]? = nil, length: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.syllables = syllables ?? [LyricSyllable(start: start, end: end, text: text)]
        self.length = length ?? text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// Emphasis: a word held longer than one second and shorter than eight UTF-16 units is
    /// emphasised with `factor = min(duration, 2) − 1` (0 … 1); every other word has none.
    public var emphasisFactor: Double {
        guard duration > 1, length > 0, length < 8 else { return 0 }
        return min(duration, 2) - 1
    }
}

public struct LyricSyllable: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: TimeInterval { max(0, end - start) }
}
