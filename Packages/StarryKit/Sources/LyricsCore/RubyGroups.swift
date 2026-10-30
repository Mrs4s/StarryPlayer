import Foundation

/// A reading shared by a contiguous run of syllables, each retaining its own timing.
public struct LyricRubyGroup: Sendable, Hashable {
    public static let namespace = "urn:ttml:extensions:shared-ruby:1"

    /// Indices of the syllables, in the array the group was found in.
    public var syllables: ClosedRange<Int>
    public var ruby: [LyricRuby]

    public init(syllables: ClosedRange<Int>, ruby: [LyricRuby]) {
        self.syllables = syllables
        self.ruby = ruby
    }

    public static func groups(in syllables: [LyricSyllable]) -> [LyricRubyGroup] {
        var result: [LyricRubyGroup] = []
        var index = 0
        while index < syllables.count {
            guard !syllables[index].groupRuby.isEmpty else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < syllables.count, syllables[end + 1].joinsRubyGroup, syllables[end + 1].groupRuby.isEmpty { end += 1 }
            result.append(LyricRubyGroup(syllables: index...end, ruby: syllables[index].groupRuby))
            index = end + 1
        }
        return result
    }

    /// Includes individual syllable ruby as groups of one.
    public static func annotations(in syllables: [LyricSyllable]) -> [LyricRubyGroup] {
        var result: [LyricRubyGroup] = []
        var groups = groups(in: syllables)[...]
        var index = 0
        while index < syllables.count {
            if let group = groups.first, group.syllables.lowerBound == index {
                result.append(group)
                groups = groups.dropFirst()
                index = group.syllables.upperBound + 1
            } else {
                if !syllables[index].ruby.isEmpty { result.append(LyricRubyGroup(syllables: index...index, ruby: syllables[index].ruby)) }
                index += 1
            }
        }
        return result
    }

    /// Clears orphan joins and ruby on rests, converts single-syllable groups to ordinary ruby,
    /// and clamps shared timing to the group's duration.
    public static func normalized(_ syllables: [LyricSyllable]) -> [LyricSyllable] {
        var result = syllables
        var head: Int?
        func close(before end: Int) {
            guard let first = head else { return }
            head = nil
            guard end - 1 > first else {
                if result[first].ruby.isEmpty { result[first].ruby = result[first].groupRuby }
                result[first].groupRuby = []
                return
            }
            for index in first..<end { result[index].ruby = [] }
            let lo = result[first].start, hi = max(result[end - 1].end, lo)
            result[first].groupRuby = result[first].groupRuby.map { piece in
                let start = min(max(piece.start, lo), hi)
                return LyricRuby(start: start, end: min(max(piece.end, start), hi), text: piece.text)
            }
        }
        for index in result.indices {
            if result[index].isRest {
                close(before: index)
                result[index].groupRuby = []
                result[index].joinsRubyGroup = false
            } else if !result[index].groupRuby.isEmpty {
                close(before: index)
                head = index
                result[index].joinsRubyGroup = false
            } else if result[index].joinsRubyGroup {
                if head == nil { result[index].joinsRubyGroup = false }
            } else {
                close(before: index)
            }
        }
        close(before: result.count)
        return result
    }

    /// Preserves trailing spaces between pieces as word breaks (`eternal |love`).
    /// Drops blank pieces and trims surrounding whitespace elsewhere.
    public static func cleaned(_ pieces: [String]) -> [String] {
        var result = pieces.compactMap { raw -> String? in
            let piece = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            let body = piece.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return piece.last?.isWhitespace == true ? body + " " : body
        }
        if let last = result.indices.last { result[last] = result[last].trimmingCharacters(in: .whitespaces) }
        return result
    }

    // MARK: AMLL TTML extension

    static func encode(_ pieces: [String]) -> String {
        pieces.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }.joined(separator: "|")
    }

    static func decode(_ text: String) -> [String]? {
        var pieces: [String] = []
        var piece = ""
        var escaped = false
        for character in text {
            if escaped {
                piece.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                pieces.append(piece)
                piece = ""
            } else {
                piece.append(character)
            }
        }
        pieces.append(piece)
        guard pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return cleaned(pieces)
    }

    static func decodeTimes(_ text: String) -> [(start: TimeInterval, end: TimeInterval)]? {
        var result: [(start: TimeInterval, end: TimeInterval)] = []
        for pair in text.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let start = TTMLParser.parseTime(String(parts[0])), let end = TTMLParser.parseTime(String(parts[1])),
                  end >= start else { return nil }
            result.append((start, end))
        }
        return result.isEmpty ? nil : result
    }
}
