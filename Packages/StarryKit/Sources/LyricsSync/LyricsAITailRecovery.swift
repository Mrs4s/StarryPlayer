import Foundation
import LyricsCore

enum LyricsAITailRecovery {
    struct Result: Sendable {
        var alignment: LyricsAICTC.Alignment
        var reviewIssues: [LyricsAIReviewIssue] = []
    }

    private struct Line {
        var index: Int
        var tokens: Range<Int>
        var key: String
    }

    private struct Confidence {
        var collapsed: Bool
        var meanPeak: Double
    }

    private static let terminalPenalty = 4.0

    static func recover(_ original: LyricsAICTC.Alignment, evidence: LyricsAICTC.Evidence,
                        plan: LyricsAIPronunciation, draft: LyricsDraft,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> Result {
        try Task.checkCancellation()
        guard original.spans.count == plan.tokens.count, original.raw.count == plan.tokens.count,
              evidence.frames > 0, evidence.width > 0, evidence.frameSeconds.isFinite, evidence.frameSeconds > 0,
              evidence.duration.isFinite, evidence.duration > 0,
              let lines = lines(in: plan, draft: draft), lines.count >= 2 else { return .init(alignment: original) }
        let (values, overflow) = evidence.frames.multipliedReportingOverflow(by: evidence.width)
        guard !overflow, evidence.logProbabilities.count == values,
              plan.tokens.allSatisfy({ (0..<evidence.width).contains($0.label) }),
              original.spans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= evidence.duration + 1e-6 }) else {
            return .init(alignment: original)
        }
        let before = try confidence(original.spans, lines: lines, evidence: evidence, tokens: plan.tokens)
        let tail = Array(lines.indices.suffix(4))
        let collapsed = tail.filter { before[$0].collapsed }
        guard collapsed.count >= 2 else { return .init(alignment: original) }

        let unresolved = issue(for: collapsed.map { lines[$0].index }, draft: draft,
                               message: "末段时间异常，未能可靠恢复，请试听核对")
        do {
            progress(0)
            let proposal = try LyricsAICTC.decode(evidence, tokens: plan.tokens, terminalPenalty: terminalPenalty) {
                progress($0 * 0.5)
            }
            try Task.checkCancellation()
            guard let anchor = stableAnchor(lines: lines, original: original.spans, proposal: proposal.spans, confidence: before) else {
                progress(1)
                return .init(alignment: original, reviewIssues: [unresolved])
            }
            let boundary = lines[anchor + 1].tokens.lowerBound
            let firstFrame = (original.spans[boundary - 1].end / evidence.frameSeconds).rounded()
            guard firstFrame.isFinite, firstFrame >= 0, firstFrame < Double(evidence.frames) else {
                return .init(alignment: original, reviewIssues: [unresolved])
            }
            let frameStart = Int(firstFrame)
            let offset = Double(frameStart) * evidence.frameSeconds
            let suffix = LyricsAICTC.Evidence(
                frames: evidence.frames - frameStart, width: evidence.width, blank: evidence.blank,
                logProbabilities: Array(evidence.logProbabilities[(frameStart * evidence.width)...]),
                sustain: Array(evidence.sustain[(frameStart * 8)...]), silent: Array(evidence.silent[frameStart...]),
                duration: evidence.duration - offset, frameSeconds: evidence.frameSeconds)
            let decoded = try LyricsAICTC.decode(suffix, tokens: Array(plan.tokens[boundary...]), terminalPenalty: terminalPenalty) {
                progress(0.5 + $0 * 0.5)
            }
            let result = LyricsAICTC.Alignment(
                raw: Array(original.raw[..<boundary]) + decoded.raw.map { .init(start: $0.start + offset, end: $0.end + offset) },
                spans: Array(original.spans[..<boundary]) + decoded.spans.map { .init(start: $0.start + offset, end: $0.end + offset) })
            let after = try confidence(result.spans, lines: lines, evidence: evidence, tokens: plan.tokens)
            let last = lines[lines.count - 1].tokens.lowerBound
            guard tail.filter({ after[$0].collapsed }).count < collapsed.count,
                  original.spans[last].start - result.spans[last].start >= 2 else {
                return .init(alignment: original, reviewIssues: [unresolved])
            }
            let recovered = lines[(anchor + 1)...].map(\.index)
            return .init(alignment: result, reviewIssues: [issue(for: recovered, draft: draft,
                                                               message: "末段已重新定位，请试听核对")])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            progress(1)
            return .init(alignment: original, reviewIssues: [unresolved])
        }
    }

    private static func lines(in plan: LyricsAIPronunciation, draft: LyricsDraft) -> [Line]? {
        var ranges: [Int: Range<Int>] = [:]
        for unit in plan.units where !unit.tokens.isEmpty {
            guard draft.lines.indices.contains(unit.line), draft.lines[unit.line].syllables.indices.contains(unit.syllable),
                  unit.tokens.lowerBound >= 0, unit.tokens.upperBound <= plan.tokens.count else { return nil }
            let previous = ranges[unit.line] ?? unit.tokens
            ranges[unit.line] = min(previous.lowerBound, unit.tokens.lowerBound)..<max(previous.upperBound, unit.tokens.upperBound)
        }
        var result: [Line] = []
        var cursor = 0
        for index in plan.lines {
            guard draft.lines.indices.contains(index), !draft.lines[index].isBackground,
                  let range = ranges.removeValue(forKey: index), range.lowerBound == cursor,
                  plan.tokens[range.upperBound - 1].endsLine else { return nil }
            result.append(.init(index: index, tokens: range, key: normalized(draft.lines[index].text)))
            cursor = range.upperBound
        }
        return cursor == plan.tokens.count && ranges.isEmpty ? result : nil
    }

    private static func confidence(_ spans: [LyricsAICTC.Span], lines: [Line], evidence: LyricsAICTC.Evidence,
                                   tokens: [LyricsAICTC.Token]) throws -> [Confidence] {
        var result: [Confidence] = []
        for line in lines {
            try Task.checkCancellation()
            var weak = 0
            var total = 0.0
            for token in line.tokens {
                let lower = Int(max(0, min(Double(evidence.frames - 1), floor(spans[token].start / evidence.frameSeconds + 1e-7))))
                let upper = Int(min(Double(evidence.frames), max(Double(lower + 1), ceil(spans[token].end / evidence.frameSeconds - 1e-7))))
                var peak: Float = -.infinity
                for frame in lower..<upper {
                    peak = max(peak, evidence.logProbabilities[frame * evidence.width + tokens[token].label])
                }
                let probability = Double(exp(peak))
                if probability < 0.1 { weak += 1 }
                total += probability
            }
            let duration = spans[line.tokens.upperBound - 1].end - spans[line.tokens.lowerBound].start
            result.append(.init(collapsed: line.tokens.count >= 4 && duration <= 0.04 * Double(line.tokens.count) + 1e-7
                                && weak * 2 >= line.tokens.count, meanPeak: total / Double(line.tokens.count)))
        }
        return result
    }

    private static func stableAnchor(lines: [Line], original: [LyricsAICTC.Span], proposal: [LyricsAICTC.Span],
                                     confidence: [Confidence]) -> Int? {
        let differences = lines.map { line in
            line.tokens.map { max(abs(original[$0].start - proposal[$0].start), abs(original[$0].end - proposal[$0].end)) }.max() ?? 0
        }
        guard let first = differences.firstIndex(where: { $0 > 0.2 }), first > lines.count / 2 else { return nil }
        let counts = Dictionary(grouping: lines, by: \.key).mapValues(\.count)
        return (lines.count / 2..<first).reversed().first { index in
            !lines[index].key.isEmpty && counts[lines[index].key] == 1 && confidence[index].meanPeak >= 0.5
                && !confidence[index].collapsed && differences[index] <= 0.12 + 1e-9
        }
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: scalars.append(scalar)
            default: break
            }
        }
        return String(scalars)
    }

    private static func issue(for lines: [Int], draft: LyricsDraft, message: String) -> LyricsAIReviewIssue {
        let first = (lines.first ?? 0) + 1, last = (lines.last ?? 0) + 1
        let range = first == last ? "第 \(first) 行" : "第 \(first)–\(last) 行"
        return .init(syllableIDs: lines.flatMap { draft.lines[$0].syllables.map(\.id) }, kind: .uncertainTiming,
                     message: range + "：" + message)
    }
}
