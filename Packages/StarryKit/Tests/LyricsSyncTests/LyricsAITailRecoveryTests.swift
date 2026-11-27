import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAITailRecoveryTests {
    private struct Fixture: Sendable {
        var draft: LyricsDraft
        var plan: LyricsAIPronunciation
        var evidence: LyricsAICTC.Evidence
        var alignment: LyricsAICTC.Alignment
    }

    private func fixture(earlyTail: Bool = true, sparseLines: Bool = false) throws -> Fixture {
        let frames = 900, width = 34
        var scores = Array(repeating: log(Float(0.01) / Float(width - 1)), count: frames * width)
        var sustain = Array(repeating: log(Float(0.001)), count: frames * 8)
        for frame in 0..<frames {
            scores[frame * width] = log(0.99)
            sustain[frame * 8] = log(0.993)
        }
        var draft = LyricsDraft(lines: [])
        var tokens: [LyricsAICTC.Token] = []
        var units: [LyricsAIPronunciation.Unit] = []
        var lines: [Int] = []
        for row in 0..<8 {
            if sparseLines && row == 0 {
                draft.lines.append(.init(syllables: [.init(text: "line 4", start: 1, end: 2)], isBackground: true))
            }
            if sparseLines && row == 5 { draft.lines.append(.init(syllables: [])) }
            let index = draft.lines.count, lower = tokens.count
            draft.lines.append(.init(syllables: [.init(text: "line \(row)")]))
            lines.append(index)
            for part in 0..<4 {
                let label = row * 4 + part + 1
                tokens.append(.init(label: label, sustainClass: 1, endsLine: part == 3))
                let weak = !earlyTail && row >= 5
                let start = weak ? 800 + (row - 5) * 4 + part : 10 + row * 35 + part * 7
                let duration = weak ? 1 : 5
                for frame in start..<(start + duration) {
                    for column in 0..<width { scores[frame * width + column] = log(Float(0.005) / Float(width - 2)) }
                    scores[frame * width] = log(weak ? 0.95 : 0.005)
                    scores[frame * width + label] = log(weak ? 0.045 : 0.99)
                    if !weak {
                        sustain[frame * 8] = log(0.001)
                        sustain[frame * 8 + 1] = log(0.993)
                    }
                }
            }
            units.append(.init(line: index, syllable: 0, tokens: lower..<tokens.count, ruby: [], approximate: false))
        }
        let plan = LyricsAIPronunciation(tokens: tokens, units: units, lines: lines, estimatedCount: 0,
                                         backgroundCount: sparseLines ? 1 : 0)
        let evidence = LyricsAICTC.Evidence(frames: frames, width: width, blank: 0, logProbabilities: scores,
            sustain: sustain, silent: Array(repeating: false, count: frames), duration: Double(frames) * 0.02)
        let alignment = try LyricsAICTC.decode(evidence, tokens: tokens)
        return .init(draft: draft, plan: plan, evidence: evidence, alignment: alignment)
    }

    private func collapsed(_ original: Fixture, from line: Int = 5, strong: Bool = false) -> Fixture {
        var result = original
        for token in (line * 4)..<result.plan.tokens.count {
            let frame = 800 + token - line * 4
            let span = LyricsAICTC.Span(start: Double(frame) * 0.02, end: Double(frame + 1) * 0.02)
            result.alignment.raw[token] = span
            result.alignment.spans[token] = span
            if strong {
                let width = result.evidence.width
                for column in 0..<width { result.evidence.logProbabilities[frame * width + column] = log(Float(0.005) / Float(width - 2)) }
                result.evidence.logProbabilities[frame * width] = log(0.005)
                result.evidence.logProbabilities[frame * width + result.plan.tokens[token].label] = log(0.99)
            }
        }
        return result
    }

    private func recover(_ fixture: Fixture) throws -> LyricsAITailRecovery.Result {
        try LyricsAITailRecovery.recover(fixture.alignment, evidence: fixture.evidence, plan: fixture.plan, draft: fixture.draft)
    }

    @Test(arguments: [false, true])
    func reliableTimingDoesNotTriggerRecovery(shortSounds: Bool) throws {
        let original = try fixture()
        let input = shortSounds ? collapsed(original, strong: true) : original
        let result = try recover(input)
        #expect(result.alignment.raw == input.alignment.raw)
        #expect(result.alignment.spans == input.alignment.spans)
        #expect(result.reviewIssues.isEmpty)
    }

    @Test func suffixRecoveryKeepsTheReliablePrefixAndPreservesBackground() throws {
        let clean = try fixture(sparseLines: true)
        let input = collapsed(clean)
        let result = try recover(input)
        #expect(Array(result.alignment.raw.prefix(20)) == Array(input.alignment.raw.prefix(20)))
        for (actual, expected) in zip(result.alignment.spans, clean.alignment.spans) {
            #expect(abs(actual.start - expected.start) < 1e-9)
            #expect(abs(actual.end - expected.end) < 1e-9)
        }
        let issue = try #require(result.reviewIssues.first)
        #expect(result.reviewIssues.count == 1)
        #expect(issue.kind == .uncertainTiming)
        #expect(issue.message.contains("末段已重新定位"))
        let ids = clean.plan.lines.suffix(3).flatMap { clean.draft.lines[$0].syllables.map(\.id) }
        #expect(issue.syllableIDs == ids)
        let applied = try LyricsAIAligner.apply(result.alignment.spans, plan: clean.plan, to: clean.draft, reviewIssues: result.reviewIssues)
        #expect(applied.draft.lines[0] == clean.draft.lines[0])
        #expect(applied.draft.lines[6] == clean.draft.lines[6])
        #expect(applied.reviewIssues == result.reviewIssues)
    }

    @Test func repeatedAnchorTextCannotAuthorizeMovingTheTail() throws {
        var input = collapsed(try fixture())
        input.draft.lines[1].syllables[0].text = "final chorus"
        input.draft.lines[4].syllables[0].text = "Ｆｉｎａｌ　Ｃｈｏｒｕｓ！"
        let result = try recover(input)
        #expect(result.alignment.raw == input.alignment.raw)
        #expect(result.alignment.spans == input.alignment.spans)
        #expect(result.reviewIssues.count == 1)
        #expect(result.reviewIssues[0].message.contains("未能可靠恢复"))
    }

    @Test func aProposalThatMovesTheFirstHalfIsRejected() throws {
        let input = collapsed(try fixture(), from: 3)
        let result = try recover(input)
        #expect(result.alignment.spans == input.alignment.spans)
        #expect(result.alignment.raw == input.alignment.raw)
        #expect(result.reviewIssues.count == 1)
    }

    @Test func unresolvedCollapseIsKeptAndMarkedForReview() throws {
        let input = try fixture(earlyTail: false)
        let result = try recover(input)
        #expect(result.alignment.spans == input.alignment.spans)
        #expect(result.alignment.raw == input.alignment.raw)
        #expect(result.reviewIssues.count == 1)
        #expect(result.reviewIssues[0].message.contains("末段时间异常"))
    }

    @Test func terminalBackgroundIsExplicitAndKeepsARealHeldLastSound() throws {
        let frames = 12, width = 4
        var rows = Array(repeating: [Float](repeating: -10, count: width), count: frames)
        rows[0][0] = 0; rows[1][1] = 0; rows[2][2] = 0
        for frame in 3..<11 { rows[frame][3] = 0 }
        rows[11][2] = -0.5
        let rest = [Float(0.993), 0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001].map(log)
        var evidence = LyricsAICTC.Evidence(frames: frames, width: width, blank: 0, logProbabilities: rows.flatMap { $0 },
            sustain: Array(repeating: rest, count: frames).flatMap { $0 }, silent: Array(repeating: false, count: frames), duration: 0.24)
        let tokens: [LyricsAICTC.Token] = [.init(label: 1, sustainClass: 1), .init(label: 2, sustainClass: 2, endsLine: true)]
        let ordinary = try LyricsAICTC.decode(evidence, tokens: tokens)
        let recovered = try LyricsAICTC.decode(evidence, tokens: tokens, terminalPenalty: 4)
        #expect(ordinary.raw[1].end > recovered.raw[1].end)
        #expect(recovered.raw[1].start == 0.04)
        for frame in 2..<7 { evidence.logProbabilities[frame * width + 2] = -0.01 }
        let held = try LyricsAICTC.decode(evidence, tokens: tokens, terminalPenalty: 4)
        #expect(held.raw[1].end >= 0.14)
    }

    @Test func midSongInterludeChasmRecoversStrandedOpeningTokensWithinNeighbouringAnchors() throws {
        let frames = 700, width = 20
        var scores = Array(repeating: log(Float(0.01) / Float(width - 1)), count: frames * width)
        var sustain = Array(repeating: log(Float(0.001)), count: frames * 8)
        for frame in 0..<frames {
            scores[frame * width] = log(0.99)
            sustain[frame * 8] = log(0.993)
        }
        func place(label: Int, startFrame: Int, count: Int = 4) {
            for frame in startFrame..<(startFrame + count) {
                for column in 0..<width { scores[frame * width + column] = log(Float(0.005) / Float(width - 2)) }
                scores[frame * width] = log(0.005)
                scores[frame * width + label] = log(0.99)
                sustain[frame * 8] = log(0.001)
                sustain[frame * 8 + 1] = log(0.993)
            }
        }
        // Line 0 around 0.4s..1.0s (frames 20..50)
        for i in 0..<4 { place(label: 1 + i, startFrame: 20 + i * 7) }
        // Line 1 true singing around 9.0s..10.2s (frames 450..510), 6 tokens (labels 5..10)
        for i in 0..<6 { place(label: 5 + i, startFrame: 450 + i * 9) }
        // Line 2 around 11.0s..11.6s (frames 550..580)
        for i in 0..<4 { place(label: 11 + i, startFrame: 550 + i * 7) }

        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "前句")]),
            .init(syllables: [.init(text: "間奏後の句")]),
            .init(syllables: [.init(text: "後句")])
        ])
        let tokens: [LyricsAICTC.Token] =
            (0..<4).map { .init(label: 1 + $0, sustainClass: 1, endsLine: $0 == 3) } +
            (0..<6).map { .init(label: 5 + $0, sustainClass: 1, endsLine: $0 == 5) } +
            (0..<4).map { .init(label: 11 + $0, sustainClass: 1, endsLine: $0 == 3) }
        let plan = LyricsAIPronunciation(
            tokens: tokens,
            units: [
                .init(line: 0, syllable: 0, tokens: 0..<4, ruby: [], approximate: false),
                .init(line: 1, syllable: 0, tokens: 4..<10, ruby: [], approximate: false),
                .init(line: 2, syllable: 0, tokens: 10..<14, ruby: [], approximate: false)
            ],
            lines: [0, 1, 2], estimatedCount: 0, backgroundCount: 0
        )
        let ev = LyricsAICTC.Evidence(frames: frames, width: width, blank: 0, logProbabilities: scores,
                                      sustain: sustain, silent: Array(repeating: false, count: frames), duration: Double(frames) * 0.02)
        var corrupted = try LyricsAICTC.decode(ev, tokens: tokens)
        // Simulate first token of Line 1 stranded at 1.4s (frame 70) before an 7.7s interlude chasm!
        corrupted.raw[4] = .init(start: 1.40, end: 1.44)
        corrupted.spans[4] = .init(start: 1.40, end: 1.48)

        let recovered = try LyricsAITailRecovery.recover(corrupted, evidence: ev, plan: plan, draft: draft)
        #expect(recovered.alignment.spans[4].start >= 8.8)
        #expect(recovered.alignment.spans[4].end <= recovered.alignment.spans[5].start + 1e-9)
        #expect(recovered.reviewIssues.count == 1)
        #expect(recovered.reviewIssues[0].message.contains("跨间奏异常已重新定位"))
    }
}
