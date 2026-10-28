import Foundation

/// Leading tags repeat lines; tags after text mark syllables.
struct LRCContent {
    struct Segment {
        var text: String
        var start: TimeInterval
        var end: TimeInterval?
    }

    struct Entry {
        var start: TimeInterval
        var text: String
        var segments: [Segment]?
        var end: TimeInterval?
    }

    var entries: [Entry] = []
    var metadata: [String: String] = [:]

    private struct Tag {
        var range: Range<String.Index>
        var time: TimeInterval
        var angle: Bool
    }

    private static func tags(in line: String) -> [Tag] {
        let expression = try! NSRegularExpression(pattern: #"(\[|<)(\d+:\d{2}(?:[.:]\d{1,3})?(?::\d{2,3})?)(\]|>)"#)
        return expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range, in: line), let body = Range(match.range(at: 2), in: line),
                  (line[range.lowerBound] == "[") == (line[line.index(before: range.upperBound)] == "]"),
                  let time = LRCParser.parseTimestamp(line[body]) else { return nil }
            return Tag(range: range, time: time, angle: line[range.lowerBound] == "<")
        }
    }

    static func hasInlineTiming(_ text: String) -> Bool {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let tags = tags(in: line)
            guard let first = tags.first, !first.angle, first.range.lowerBound == line.startIndex else { continue }
            if tags.contains(where: \.angle) { return true }
            for (a, b) in zip(tags, tags.dropFirst()) where !line[a.range.upperBound..<b.range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        return false
    }

    init(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsParseError.empty }
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let body = line[line.index(after: line.startIndex)..<close]
                guard LRCParser.parseTimestamp(body) == nil, let colon = body.firstIndex(of: ":"),
                      !body[..<colon].isEmpty, body[..<colon].allSatisfy({ $0.isLetter || $0 == "_" }) else { break }
                metadata[String(body[..<colon]).lowercased()] = String(body[body.index(after: colon)...])
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            let tags = Self.tags(in: line)
            guard let first = tags.first, !first.angle, first.range.lowerBound == line.startIndex else { continue }
            var leading: [Tag] = []
            var cursor = line.startIndex
            for tag in tags {
                guard !tag.angle, tag.range.lowerBound == cursor else { break }
                leading.append(tag)
                cursor = tag.range.upperBound
            }
            let angles = tags.filter(\.angle)
            let inline = !angles.isEmpty || leading.count < tags.count
            if !inline {
                let body = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
                for tag in leading { entries.append(Entry(start: tag.time, text: body)) }
                continue
            }
            let timedTags = angles.isEmpty ? tags : angles
            guard zip(timedTags, timedTags.dropFirst()).allSatisfy({ $0.time <= $1.time }) else {
                throw LyricsParseError.malformed("LRC: 时间标签必须按顺序排列")
            }
            var segments: [Segment] = []
            if !angles.isEmpty, let angle = angles.first, cursor < angle.range.lowerBound {
                let prefix = String(line[cursor..<angle.range.lowerBound])
                if !prefix.isEmpty { segments.append(Segment(text: prefix, start: first.time, end: angle.time)) }
            }
            for (index, tag) in timedTags.enumerated() {
                let next = index + 1 < timedTags.count ? timedTags[index + 1] : nil
                let body = String(line[tag.range.upperBound..<(next?.range.lowerBound ?? line.endIndex)])
                if !body.isEmpty { segments.append(Segment(text: body, start: tag.time, end: next?.time)) }
            }
            let release = timedTags.last.flatMap { $0.range.upperBound == line.endIndex ? $0.time : nil }
            let repeats = angles.isEmpty ? [first] : leading
            for repeatTag in repeats {
                let shift = repeatTag.time - first.time
                entries.append(Entry(start: repeatTag.time, text: segments.map(\.text).joined(), segments: segments.map {
                    Segment(text: $0.text, start: $0.start + shift, end: $0.end.map { $0 + shift })
                }, end: release.map { $0 + shift }))
            }
        }
        if let raw = metadata.removeValue(forKey: "offset"), let offset = Double(raw), offset.isFinite {
            let delta = -offset / 1000
            for index in entries.indices {
                entries[index].start = max(0, entries[index].start + delta)
                entries[index].end = entries[index].end.map { max(0, $0 + delta) }
                entries[index].segments = entries[index].segments?.map {
                    Segment(text: $0.text, start: max(0, $0.start + delta), end: $0.end.map { max(0, $0 + delta) })
                }
            }
        }
        entries = entries.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    func document() -> LyricsDocument {
        let lines = entries.enumerated().map { index, entry -> LyricLine in
            let next = entries.dropFirst(index + 1).first { $0.start > entry.start }?.start
            let lastStart = entry.segments?.last?.start ?? entry.start
            let inferred = next.flatMap { $0 > lastStart ? $0 : nil } ?? lastStart + 5
            let end = max(entry.start, entry.end ?? inferred)
            guard let segments = entry.segments else { return .plain(id: index, start: entry.start, end: end, text: entry.text) }
            let syllables = segments.map { LyricSyllable(start: $0.start, end: max($0.start, $0.end ?? end), text: $0.text) }
            return LyricLine(id: index, start: entry.start, end: max(end, syllables.map(\.end).max() ?? end), words: LyricWordGrouping.words(from: syllables))
        }
        return LyricsDocument(format: .lrc, lines: lines, metadata: metadata)
    }

    func draft(pairsTranslations: Bool) -> LyricsDraft {
        // Same-start rows with inline timing are separate voices, not translations.
        let pairsLineTranslations = pairsTranslations && entries.allSatisfy { $0.segments == nil }
        var lines: [LyricsDraft.Line] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            var end = index + 1
            while end < entries.count, abs(entries[end].start - entry.start) < 0.0005 { end += 1 }
            let group = entries[index..<end].filter { !$0.text.isEmpty }
            let next = end < entries.count ? entries[end].start : nil
            for (offset, entry) in group.enumerated() {
                if pairsLineTranslations, (1...2).contains(offset), !lines.isEmpty {
                    if offset == 1 { lines[lines.count - 1].translation = entry.text }
                    if offset == 2 { lines[lines.count - 1].romanization = entry.text }
                    continue
                }
                let syllables = entry.segments.map { $0.map { LyricsDraft.Syllable(text: $0.text, start: $0.start, end: $0.end) } }
                    ?? LyricsDraftImport.syllables(in: entry.text, explicitBoundaries: false)
                lines.append(.init(syllables: syllables, isParagraphStart: lines.isEmpty, start: entry.start, end: entry.end ?? next))
            }
            index = end
        }
        return LyricsDraft(lines: lines, metadata: metadata)
    }
}
