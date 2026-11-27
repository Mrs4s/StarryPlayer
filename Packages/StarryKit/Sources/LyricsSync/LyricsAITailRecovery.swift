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
        var current = original
        var issues: [LyricsAIReviewIssue] = []

        if collapsed.count >= 2 {
            let unresolved = issue(for: collapsed.map { lines[$0].index }, draft: draft,
                                   message: "末段时间异常，未能可靠恢复，请试听核对")
            do {
                progress(0)
                let proposal = try LyricsAICTC.decode(evidence, tokens: plan.tokens, terminalPenalty: terminalPenalty) {
                    progress($0 * 0.5)
                }
                try Task.checkCancellation()
                if let anchor = stableAnchor(lines: lines, original: original.spans, proposal: proposal.spans, confidence: before) {
                    let boundary = lines[anchor + 1].tokens.lowerBound
                    let firstFrame = (original.spans[boundary - 1].end / evidence.frameSeconds).rounded()
                    if firstFrame.isFinite, firstFrame >= 0, firstFrame < Double(evidence.frames) {
                        let frameStart = Int(firstFrame)
                        let offset = Double(frameStart) * evidence.frameSeconds
                        let suffix = sliceEvidence(evidence, frames: frameStart..<evidence.frames)
                        let decoded = try LyricsAICTC.decode(suffix, tokens: Array(plan.tokens[boundary...]), terminalPenalty: terminalPenalty) {
                            progress(0.5 + $0 * 0.5)
                        }
                        let candidate = LyricsAICTC.Alignment(
                            raw: Array(original.raw[..<boundary]) + decoded.raw.map { .init(start: $0.start + offset, end: $0.end + offset) },
                            spans: Array(original.spans[..<boundary]) + decoded.spans.map { .init(start: $0.start + offset, end: $0.end + offset) })
                        let after = try confidence(candidate.spans, lines: lines, evidence: evidence, tokens: plan.tokens)
                        let last = lines[lines.count - 1].tokens.lowerBound
                        if tail.filter({ after[$0].collapsed }).count < collapsed.count,
                           original.spans[last].start - candidate.spans[last].start >= 2 {
                            current = candidate
                            let recovered = lines[(anchor + 1)...].map(\.index)
                            issues.append(issue(for: recovered, draft: draft, message: "末段已重新定位，请试听核对"))
                        } else {
                            issues.append(unresolved)
                        }
                    } else {
                        issues.append(unresolved)
                    }
                } else {
                    issues.append(unresolved)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                issues.append(unresolved)
            }
        }

        let mid = try recoverInterludeChasms(current, lines: lines, evidence: evidence, plan: plan, draft: draft)
        progress(1)
        return .init(alignment: mid.alignment, reviewIssues: issues + mid.reviewIssues)
    }

    private static func sliceEvidence(_ evidence: LyricsAICTC.Evidence, frames: Range<Int>) -> LyricsAICTC.Evidence {
        LyricsAICTC.Evidence(
            frames: frames.count, width: evidence.width, blank: evidence.blank,
            logProbabilities: Array(evidence.logProbabilities[(frames.lowerBound * evidence.width)..<(frames.upperBound * evidence.width)]),
            sustain: Array(evidence.sustain[(frames.lowerBound * 8)..<(frames.upperBound * 8)]),
            silent: Array(evidence.silent[frames]),
            duration: Double(frames.count) * evidence.frameSeconds, frameSeconds: evidence.frameSeconds)
    }

    private static func recoverInterludeChasms(_ alignment: LyricsAICTC.Alignment, lines: [Line],
                                               evidence: LyricsAICTC.Evidence, plan: LyricsAIPronunciation,
                                               draft: LyricsDraft) throws -> Result {
        var current = alignment
        var issues: [LyricsAIReviewIssue] = []
        let currentConfidence = try confidence(current.spans, lines: lines, evidence: evidence, tokens: plan.tokens)
        let restBoundaries = explicitRestTokenBoundaries(plan: plan, draft: draft)

        for position in lines.indices {
            try Task.checkCancellation()
            let line = lines[position]
            guard line.tokens.count >= 3 else { continue }
            let rawSpan = current.raw[line.tokens.upperBound - 1].end - current.raw[line.tokens.lowerBound].start
            guard rawSpan >= 8.0,
                  let (chasmGap, splitToken) = widestChasm(in: line.tokens, raw: current.raw, restBoundaries: restBoundaries),
                  chasmGap >= 3.5 else { continue }

            let lowerTime: Double
            if position > 0 {
                guard !currentConfidence[position - 1].collapsed else { continue }
                lowerTime = current.spans[lines[position - 1].tokens.upperBound - 1].end
            } else {
                lowerTime = 0
            }
            let upperTime: Double
            if position + 1 < lines.count {
                guard !currentConfidence[position + 1].collapsed else { continue }
                upperTime = current.spans[lines[position + 1].tokens.lowerBound].start
            } else {
                upperTime = evidence.duration
            }
            guard upperTime > lowerTime + 1.0 else { continue }

            let leftTokens = line.tokens.lowerBound..<splitToken
            let rightTokens = splitToken..<line.tokens.upperBound
            let keepRightCluster: Bool
            if rightTokens.count != leftTokens.count {
                keepRightCluster = rightTokens.count > leftTokens.count
            } else {
                let leftPeak = try confidence(current.spans, lines: [.init(index: line.index, tokens: leftTokens, key: "")],
                                              evidence: evidence, tokens: plan.tokens)[0].meanPeak
                let rightPeak = try confidence(current.spans, lines: [.init(index: line.index, tokens: rightTokens, key: "")],
                                               evidence: evidence, tokens: plan.tokens)[0].meanPeak
                keepRightCluster = rightPeak >= leftPeak
            }

            let windowStart: Double
            let windowEnd: Double
            let penalty: Double?
            if keepRightCluster {
                let lead = min(4.0, max(2.0, 0.6 * Double(leftTokens.count)))
                windowStart = max(lowerTime, current.raw[splitToken].start - lead)
                windowEnd = upperTime
                penalty = nil
            } else {
                let trail = min(4.0, max(2.0, 0.6 * Double(rightTokens.count)))
                windowStart = lowerTime
                windowEnd = min(upperTime, current.raw[splitToken - 1].end + trail)
                penalty = terminalPenalty
            }

            let startFrame = max(0, min(evidence.frames - 1, Int((windowStart / evidence.frameSeconds).rounded(.down))))
            let endFrame = max(startFrame + 1, min(evidence.frames, Int((windowEnd / evidence.frameSeconds).rounded(.up))))
            var localTokens = Array(plan.tokens[line.tokens])
            localTokens[localTokens.count - 1].endsLine = true
            let repeats = zip(localTokens, localTokens.dropFirst()).filter { $0.label == $1.label }.count
            guard endFrame - startFrame >= localTokens.count + repeats else {
                issues.append(issue(for: [line.index], draft: draft, message: "句内存在长空白跨度，请试听核对"))
                continue
            }

            do {
                let slice = sliceEvidence(evidence, frames: startFrame..<endFrame)
                let decoded = try LyricsAICTC.decode(slice, tokens: localTokens, terminalPenalty: penalty)
                let offset = Double(startFrame) * evidence.frameSeconds
                let shiftedRaw = decoded.raw.map { LyricsAICTC.Span(start: $0.start + offset, end: min(upperTime, $0.end + offset)) }
                let shiftedSpans = decoded.spans.map { LyricsAICTC.Span(start: max(lowerTime, $0.start + offset), end: min(upperTime, $0.end + offset)) }
                guard shiftedSpans.allSatisfy({ $0.end > $0.start }),
                      zip(shiftedSpans, shiftedSpans.dropFirst()).allSatisfy({ $0.end <= $1.start + 1e-9 }) else {
                    issues.append(issue(for: [line.index], draft: draft, message: "句内存在长空白跨度，请试听核对"))
                    continue
                }
                var candidate = current
                candidate.raw.replaceSubrange(line.tokens, with: shiftedRaw)
                candidate.spans.replaceSubrange(line.tokens, with: shiftedSpans)
                let afterGap = widestChasm(in: line.tokens, raw: candidate.raw, restBoundaries: restBoundaries)?.gap ?? 0
                let afterConf = try confidence(candidate.spans, lines: [line], evidence: evidence, tokens: plan.tokens)[0]
                if afterGap < 2.0, !afterConf.collapsed,
                   afterConf.meanPeak >= max(0.35, currentConfidence[position].meanPeak - 0.15) {
                    current = candidate
                    issues.append(issue(for: [line.index], draft: draft, message: "跨间奏异常已重新定位，请试听核对"))
                } else {
                    issues.append(issue(for: [line.index], draft: draft, message: "句内存在长空白跨度，请试听核对"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(issue(for: [line.index], draft: draft, message: "句内存在长空白跨度，请试听核对"))
            }
        }
        return .init(alignment: current, reviewIssues: issues)
    }

    private static func explicitRestTokenBoundaries(plan: LyricsAIPronunciation, draft: LyricsDraft) -> Set<Int> {
        var boundaries: Set<Int> = []
        var previous: LyricsAIPronunciation.Unit?
        for unit in plan.units where !unit.tokens.isEmpty {
            defer { previous = unit }
            guard let left = previous, left.line == unit.line, left.syllable < unit.syllable,
                  draft.lines.indices.contains(unit.line), unit.syllable <= draft.lines[unit.line].syllables.count else { continue }
            if draft.lines[unit.line].syllables[(left.syllable + 1)..<unit.syllable].contains(where: \.isRest) {
                boundaries.insert(unit.tokens.lowerBound)
            }
        }
        return boundaries
    }

    private static func widestChasm(in tokens: Range<Int>, raw: [LyricsAICTC.Span],
                                    restBoundaries: Set<Int>) -> (gap: Double, splitToken: Int)? {
        var best: (gap: Double, splitToken: Int)?
        for token in (tokens.lowerBound + 1)..<tokens.upperBound where !restBoundaries.contains(token) {
            let gap = raw[token].start - raw[token - 1].end
            if best == nil || gap > best!.gap { best = (gap, token) }
        }
        return best
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
