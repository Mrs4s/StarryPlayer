import Foundation
import LyricsCore

extension LyricsAIAligner {
    nonisolated static func apply(_ spans: [LyricsAICTC.Span], plan: LyricsAIPronunciation,
                                  to source: LyricsDraft, englishSplit: LyricsAIEnglishSplit = .automatic,
                                  reviewIssues: [LyricsAIReviewIssue] = []) throws -> LyricsAIAlignmentResult {
        guard spans.count == plan.tokens.count else { throw LyricsAIError.alignment("结果与歌词数量不一致") }
        var draft = source
        var alignedSyllables = 0
        var issues = reviewIssues
        var splitIDs: [UUID: [UUID]] = [:]
        for lineIndex in plan.lines {
            guard draft.lines.indices.contains(lineIndex) else { throw LyricsAIError.alignment("歌词结构已改变") }
            var line = draft.lines[lineIndex]
            let units = plan.units.filter { $0.line == lineIndex }
            var timing = [LyricsAICTC.Span?](repeating: nil, count: line.syllables.count)
            for unit in units where !unit.tokens.isEmpty {
                guard line.syllables.indices.contains(unit.syllable), unit.tokens.lowerBound >= 0,
                      unit.tokens.upperBound <= spans.count else { throw LyricsAIError.alignment("字块映射无效") }
                let start = spans[unit.tokens.lowerBound].start
                let end = spans[unit.tokens.upperBound - 1].end
                guard start.isFinite, end.isFinite, start >= 0, end > start else { throw LyricsAIError.alignment("生成了无效时间区间") }
                timing[unit.syllable] = .init(start: start, end: end)
            }
            try placeStructuralUnits(&timing)
            for unit in units {
                guard let span = timing[unit.syllable] else { throw LyricsAIError.alignment("结果缺少字块时间") }
                if unit.approximate {
                    let syllable = line.syllables[unit.syllable]
                    issues.append(.init(syllableIDs: [syllable.id], kind: .estimatedReading,
                                        message: "第 \(lineIndex + 1) 行「\(syllable.text.prefix(40))」：读音或词内边界为估计值"))
                }
                line.syllables[unit.syllable].start = span.start
                line.syllables[unit.syllable].end = span.end
                if var ruby = line.syllables[unit.syllable].ruby, ruby.count == unit.ruby.count, !ruby.isEmpty {
                    for index in ruby.indices {
                        let range = unit.ruby[index]
                        guard !range.isEmpty, range.upperBound <= spans.count else { continue }
                        let lo = min(max((spans[range.lowerBound].start - span.start) / (span.end - span.start), 0), 1)
                        let hi = min(max((spans[range.upperBound - 1].end - span.start) / (span.end - span.start), lo), 1)
                        ruby[index].span = lo...hi
                    }
                    line.syllables[unit.syllable].ruby = ruby
                }
            }
            if englishSplit != .word {
                for unit in units.reversed() where unit.english.count > 1 {
                    let original = line.syllables[unit.syllable]
                    let pieces = englishPieces(unit, spans: spans, bounds: .init(start: original.start!, end: original.end!), mode: englishSplit)
                    let replacements = pieces.enumerated().map { index, piece in
                        var syllable = original
                        if index > 0 { syllable.id = UUID() }
                        syllable.text = piece.text
                        syllable.start = piece.start
                        syllable.end = piece.end
                        return syllable
                    }
                    splitIDs[original.id] = replacements.map(\.id)
                    line.syllables.replaceSubrange(unit.syllable...unit.syllable, with: replacements)
                }
            }
            alignedSyllables += line.syllables.count
            line.start = nil
            line.end = nil
            draft.lines[lineIndex] = line
        }
        issues = issues.map { issue in
            var issue = issue
            issue.syllableIDs = issue.syllableIDs.flatMap { splitIDs[$0] ?? [$0] }
            return issue
        }
        return .init(draft: draft, alignedLines: plan.lines.count, alignedSyllables: alignedSyllables,
                     skippedBackgroundLines: plan.backgroundCount, reviewIssues: issues)
    }

    private struct EnglishPiece {
        var text: String
        var tokens: Range<Int>
        var start: TimeInterval
        var end: TimeInterval
        var endsInLongMark: Bool
        var duration: TimeInterval { end - start }
    }

    private nonisolated static func englishPieces(_ unit: LyricsAIPronunciation.Unit, spans: [LyricsAICTC.Span], bounds: LyricsAICTC.Span,
                                                  mode: LyricsAIEnglishSplit) -> [EnglishPiece] {
        var result: [EnglishPiece] = []
        for piece in unit.english {
            let tokens = (unit.tokens.lowerBound + piece.tokens.lowerBound)..<(unit.tokens.lowerBound + piece.tokens.upperBound)
            var current = EnglishPiece(text: piece.text, tokens: tokens, start: max(bounds.start, spans[tokens.lowerBound].start),
                                       end: min(bounds.end, spans[tokens.upperBound - 1].end), endsInLongMark: piece.endsInLongMark)
            if let previous = result.last {
                let held = previous.tokens.upperBound - 1
                let mark = spans[held]
                if previous.endsInLongMark, previous.tokens.count > 1, mark.end - mark.start >= 0.3,
                   current.duration < mark.end - mark.start {
                    // Transfer a long mark that absorbed the following syllable's hold.
                    result[result.count - 1].tokens = previous.tokens.lowerBound..<held
                    let boundary = min(max(mark.start, bounds.start), bounds.end)
                    result[result.count - 1].end = boundary
                    result[result.count - 1].endsInLongMark = false
                    current.tokens = held..<tokens.upperBound
                    current.start = boundary
                }
            }
            if let previous = result.last,
               current.duration <= 1e-9 || previous.duration <= 1e-9
                || (mode == .automatic && (current.duration <= 0.06 + 1e-9 || previous.duration <= 0.06 + 1e-9)) {
                result[result.count - 1].text += current.text
                result[result.count - 1].tokens = previous.tokens.lowerBound..<current.tokens.upperBound
                result[result.count - 1].end = max(previous.end, current.end)
                result[result.count - 1].endsInLongMark = current.endsInLongMark
            } else { result.append(current) }
        }
        return result
    }

    // Give punctuation at least 1 ms so TTML rounding preserves a nonzero interval.
    private nonisolated static func placeStructuralUnits(_ timing: inout [LyricsAICTC.Span?]) throws {
        var first = 0
        while first < timing.count {
            if timing[first] != nil { first += 1; continue }
            var end = first + 1
            while end < timing.count, timing[end] == nil { end += 1 }
            let count = end - first, length = Double(count) * 0.001
            let previous = first > 0 ? timing[first - 1] : nil
            let next = end < timing.count ? timing[end] : nil
            let lower: Double
            if let previous, let next, next.start - previous.end >= length {
                lower = previous.end
            } else if previous == nil, let next, next.start >= length {
                lower = next.start - length
            } else if let previous, previous.end - previous.start > length + 0.001 {
                lower = previous.end - length
                timing[first - 1]?.end = lower
            } else if let next, next.end - next.start > length + 0.001 {
                lower = next.start
                timing[end]?.start += length
            } else {
                throw LyricsAIError.alignment("请将单独的标点或空白合并到相邻字块")
            }
            for offset in 0..<count {
                timing[first + offset] = .init(start: lower + Double(offset) * 0.001,
                                              end: lower + Double(offset + 1) * 0.001)
            }
            first = end
        }
    }
}
