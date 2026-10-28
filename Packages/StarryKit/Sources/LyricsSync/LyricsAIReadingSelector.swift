import Foundation
import LyricsCore

enum LyricsAIReadingSelector {
    struct Decision: Sendable {
        var line: Int
        var text: String
        var original: String
        var reading: String
        var gain: Double?
        var uncertain: Bool
    }

    struct Selection: Sendable {
        var plan: LyricsAIPronunciation
        var decisions: [Decision]
        var resolvedCount: Int { decisions.filter { $0.original != $0.reading }.count }
        var uncertainCount: Int { decisions.filter(\.uncertain).count }
    }

    private struct Candidate {
        var reading: String
        var plan: LyricsAIPronunciation
        var score: Double
    }

    static func select(draft: LyricsDraft, plan original: LyricsAIPronunciation, spans: [LyricsAICTC.Span],
                       evidence: LyricsAICTC.Evidence, vocabulary: [String: Int], english: [String: String],
                       maximumCells: Int = 40_000_000) throws -> Selection {
        guard !original.words.isEmpty else { return .init(plan: original, decisions: []) }
        var remaining = maximumCells
        var accepted: [LyricsAIPronunciation.ReadingOverride] = []
        var decisions: [Decision] = []
        let grouped = Dictionary(grouping: original.words, by: \.line)
        for lineIndex in grouped.keys.sorted() {
            try Task.checkCancellation()
            let words = grouped[lineIndex]!
            let units = original.units.filter { $0.line == lineIndex && !$0.tokens.isEmpty }
            guard let first = units.first, let last = units.last else { continue }
            let lower = max(0, Int((spans[first.tokens.lowerBound].start / evidence.frameSeconds).rounded(.down)) - 10)
            let upper = min(evidence.frames, Int((spans[last.tokens.upperBound - 1].end / evidence.frameSeconds).rounded(.up)) + 10)
            let window = lower..<upper
            guard !window.isEmpty, window.count <= 1500 else {
                decisions += words.map { .init(line: lineIndex, text: $0.text, original: $0.reading, reading: $0.reading, gain: nil, uncertain: true) }
                continue
            }
            let draft = LyricsDraft(lines: [draft.lines[lineIndex]])
            var local = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: english)
            var overrides: [LyricsAIPronunciation.ReadingOverride] = []
            func score(_ plan: LyricsAIPronunciation) throws -> Double? {
                let cells = window.count * (plan.tokens.count * 2 + 1)
                guard cells <= remaining else { return nil }
                remaining -= cells
                return try LyricsAICTC.sequenceLogProbability(evidence, labels: plan.tokens.map(\.label), frames: window)
            }
            guard var currentScore = try score(local), currentScore.isFinite else {
                decisions += words.map { .init(line: lineIndex, text: $0.text, original: $0.reading, reading: $0.reading, gain: nil, uncertain: true) }
                continue
            }
            for word in words {
                try Task.checkCancellation()
                var candidates = [Candidate(reading: word.reading, plan: local, score: currentScore)]
                var complete = true
                for reading in word.candidates where reading != word.reading {
                    let proposal = LyricsAIPronunciation.ReadingOverride(line: 0, range: word.range, reading: reading)
                    let candidate: LyricsAIPronunciation
                    do { candidate = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: english, readings: overrides + [proposal]) }
                    catch is CancellationError { throw CancellationError() }
                    catch { continue }
                    if let value = try score(candidate), value.isFinite {
                        candidates.append(.init(reading: reading, plan: candidate, score: value))
                    } else { complete = false }
                }
                candidates.sort { $0.score > $1.score }
                let winner = candidates[0]
                let margin = candidates.count > 1 ? winner.score - candidates[1].score : 0
                let gain = winner.score - currentScore
                // A baseline preference also protects against the length bias of CTC scores.
                let requiredGain = max(4, Double(abs(winner.plan.tokens.count - local.tokens.count)))
                var reading = word.reading
                var uncertain = !complete || candidates.count < 2 || margin < requiredGain
                if complete, winner.reading != word.reading, gain >= requiredGain, margin >= requiredGain {
                    let cells = window.count * (winner.plan.tokens.count * 2 + 1)
                    if cells <= remaining {
                        remaining -= cells
                        if try isHeard(winner.plan, word: word, evidence: evidence, frames: window) {
                            reading = winner.reading
                            local = winner.plan
                            currentScore = winner.score
                            overrides.append(.init(line: 0, range: word.range, reading: reading))
                        } else { uncertain = true }
                    } else { uncertain = true }
                }
                decisions.append(.init(line: lineIndex, text: word.text, original: word.reading,
                                       reading: reading, gain: gain, uncertain: uncertain))
            }
            accepted += overrides.map { .init(line: lineIndex, range: $0.range, reading: $0.reading) }
        }
        guard !accepted.isEmpty else { return .init(plan: original, decisions: decisions) }
        let resolved = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: english, readings: accepted)
        let (cells, overflow) = evidence.frames.multipliedReportingOverflow(by: resolved.tokens.count * 2 + 1)
        guard !overflow, cells <= 160_000_000 else {
            for i in decisions.indices {
                decisions[i].reading = decisions[i].original
                decisions[i].uncertain = true
            }
            return .init(plan: original, decisions: decisions)
        }
        return .init(plan: resolved, decisions: decisions)
    }

    /// A shorter reading must not win just by deleting unheard labels in near-blank audio.
    private static func isHeard(_ plan: LyricsAIPronunciation, word: LyricsAIPronunciation.Word,
                                evidence: LyricsAICTC.Evidence, frames: Range<Int>) throws -> Bool {
        let slice = LyricsAICTC.Evidence(frames: frames.count, width: evidence.width, blank: evidence.blank,
            logProbabilities: Array(evidence.logProbabilities[(frames.lowerBound * evidence.width)..<(frames.upperBound * evidence.width)]),
            sustain: Array(evidence.sustain[(frames.lowerBound * 8)..<(frames.upperBound * 8)]),
            silent: Array(evidence.silent[frames]), duration: Double(frames.count) * evidence.frameSeconds,
            frameSeconds: evidence.frameSeconds)
        let spans: [LyricsAICTC.Span]
        do { spans = try LyricsAICTC.align(slice, tokens: plan.tokens) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        let units = plan.units.filter { word.syllables.contains($0.syllable) && !$0.tokens.isEmpty }
        guard let first = units.first, let last = units.last else { return false }
        var peaks: [Float] = []
        for token in first.tokens.lowerBound..<last.tokens.upperBound {
            guard plan.tokens[token].label != 122 else { return false }
            let lower = max(0, Int((spans[token].start / evidence.frameSeconds).rounded()))
            let upper = min(frames.count, Int((spans[token].end / evidence.frameSeconds).rounded()))
            guard upper > lower else { return false }
            let peak = (lower..<upper).map {
                exp(evidence.logProbabilities[(frames.lowerBound + $0) * evidence.width + plan.tokens[token].label])
            }.max() ?? 0
            peaks.append(peak)
        }
        return !peaks.isEmpty && peaks.filter { $0 >= 0.2 }.count * 2 >= peaks.count
            && peaks.reduce(0, +) / Float(peaks.count) >= 0.25
    }
}
