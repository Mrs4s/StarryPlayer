import Foundation
import LyricsCore

extension LyricsAIAligner {
    nonisolated static func apply(_ spans: [LyricsAICTC.Span], plan: LyricsAIPronunciation,
                                  to source: LyricsDraft) throws -> LyricsAIAlignmentResult {
        guard spans.count == plan.tokens.count else { throw LyricsAIError.alignment("结果与歌词数量不一致") }
        var draft = source
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
            line.start = nil
            line.end = nil
            draft.lines[lineIndex] = line
        }
        return .init(draft: draft, alignedLines: plan.lines.count, alignedSyllables: plan.units.count,
                     estimatedReadings: plan.estimatedCount, skippedBackgroundLines: plan.backgroundCount)
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
