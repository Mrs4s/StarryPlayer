import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAIReadingSelectorTests {
    private let alphabet = Array("あいうえおかきくけこがぎぐげござじずぜぞさしすせそたちつてとだぢづでどなにぬねのはひふへほばびぶべぼまみむめもやゆよらりるれろわをんっゃゅょー")

    private var vocabulary: [String: Int] {
        Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { (String($0.element), $0.offset) })
    }

    private func evidence(_ reading: String, silent: Bool = false) -> LyricsAICTC.Evidence {
        let labels = [121] + reading.flatMap { char in [Int](repeating: vocabulary[String(char)]!, count: 4) + [121] } + [121]
        let rows = labels.map { label -> [Float] in
            var row = [Float](repeating: (1 - 0.98) / 122, count: 123)
            row[silent ? 121 : label] = 0.98
            return row.map(log)
        }
        let sustain = labels.flatMap { _ -> [Float] in
            var row = [Float](repeating: 0.001, count: 8)
            row[0] = 0.993
            return row.map(log)
        }
        return .init(frames: rows.count, width: 123, blank: 121, logProbabilities: rows.flatMap { $0 },
                     sustain: sustain, silent: .init(repeating: silent, count: rows.count), duration: Double(rows.count) * 0.02)
    }

    private func select(_ draft: LyricsDraft, audio: String, silent: Bool = false) throws -> LyricsAIReadingSelector.Selection {
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        let heard = evidence(audio, silent: silent)
        let spans = try LyricsAICTC.align(heard, tokens: plan.tokens)
        return try LyricsAIReadingSelector.select(draft: draft, plan: plan, spans: spans, evidence: heard,
                                                  vocabulary: vocabulary, english: [:])
    }

    private func text(_ plan: LyricsAIPronunciation) -> String {
        let inverse = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })
        return plan.tokens.map { inverse[$0.label] ?? "?" }.joined()
    }

    @Test func audioSelectsEitherCommonReadingOfAshitaWithoutRubyOrRomanization() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "ま"), .init(text: "た"), .init(text: "明"), .init(text: "日")])])
        let ashita = try select(draft, audio: "またあした")
        #expect(text(ashita.plan) == "またあした")
        #expect(ashita.decisions.first(where: { $0.text == "明日" })?.reading == "あした")
        let asu = try select(draft, audio: "またあす")
        #expect(text(asu.plan) == "またあす")
        #expect(asu.decisions.first(where: { $0.text == "明日" })?.reading == "あす")
    }

    @Test func dictionaryAlternativesOutsideTheSmallSupplementAreChosenByTheAudio() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "市場")])])
        #expect(try text(select(draft, audio: "いちば").plan) == "いちば")
        #expect(try text(select(draft, audio: "しじょう").plan) == "しじょう")
    }

    @Test func multipleWordsInOneLineKeepTheirOwnOverridesAndTokenMappings() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "私"), .init(text: "も"), .init(text: "明"), .init(text: "日")])])
        let result = try select(draft, audio: "わたしもあした")
        #expect(text(result.plan) == "わたしもあした")
        #expect(result.decisions.first(where: { $0.text == "私" })?.reading == "わたし")
        #expect(result.decisions.first(where: { $0.text == "明日" })?.reading == "あした")
    }

    @Test func explicitRubyIsNeverReplacedByAcousticCandidates() throws {
        let syllable = LyricsDraft.Syllable(text: "明日", ruby: [.init(text: "あす")])
        let draft = LyricsDraft(lines: [.init(syllables: [syllable], romanization: "a shi ta")])
        let result = try select(draft, audio: "あした")
        #expect(text(result.plan) == "あす")
        #expect(result.decisions.isEmpty)
        #expect(result.resolvedCount == 0)
    }

    @Test func changingTokenCountPreservesRubyMappingsAfterTheSelectedWord() throws {
        let line = LyricsDraft.Line(syllables: [.init(text: "明日"), .init(text: "愛", ruby: [.init(text: "あ"), .init(text: "い")])])
        let background = LyricsDraft.Line(syllables: [.init(text: "明日", start: 5, end: 6)], isBackground: true)
        let draft = LyricsDraft(lines: [line, background])
        let selected = try select(draft, audio: "あしたあい")
        let heard = evidence("あしたあい")
        let spans = try LyricsAICTC.align(heard, tokens: selected.plan.tokens)
        let applied = try LyricsAIAligner.apply(spans, plan: selected.plan, to: draft)
        let ruby = try #require(applied.draft.lines[0].syllables[1].ruby)
        #expect(ruby.map(\.text) == ["あ", "い"])
        #expect(ruby.allSatisfy { $0.span != nil })
        #expect(ruby[0].span!.upperBound <= ruby[1].span!.lowerBound)
        #expect(applied.draft.lines[1] == background)
        #expect(selected.decisions.allSatisfy { $0.line == 0 })
    }

    @Test func partlyAnnotatedWordAndMergedNeighbourTextCannotBeOverwritten() throws {
        let partial = LyricsDraft(lines: [.init(syllables: [.init(text: "明"), .init(text: "日", ruby: [.init(text: "す")])])])
        #expect(try select(partial, audio: "あした").decisions.isEmpty)
        let merged = LyricsDraft(lines: [.init(syllables: [.init(text: "また明日")])])
        #expect(try select(merged, audio: "またあした").decisions.isEmpty)
    }

    @Test func romanizationProposesAReadingOutsideTheDictionary() throws {
        #expect(!LyricsAIReadingLexicon.candidates(for: "未来", defaultReading: "みらい").contains("みら"))
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "未来"), .init(text: "だ")], romanization: "mi ra da")])
        let result = try select(draft, audio: "みらだ")
        #expect(text(result.plan) == "みらだ")
        #expect(result.decisions.contains { $0.text == "未来" && $0.reading == "みら" })
    }

    @Test func audioCanRejectAnIncorrectRomanizationProposal() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "未来"), .init(text: "だ")], romanization: "mi ra da")])
        let original = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        let result = try select(draft, audio: text(original))
        #expect(result.plan.tokens == original.tokens)
        #expect(result.resolvedCount == 0)
    }

    @Test func silenceCannotChooseAShorterPronunciationByDeletingUnheardLabels() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "私")])])
        let original = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        let result = try select(draft, audio: "わたくし", silent: true)
        #expect(result.plan.tokens == original.tokens)
        #expect(result.resolvedCount == 0)
        #expect(result.uncertainCount > 0)
    }

    @Test func equallySupportedReadingsKeepTheContextDefaultAndRequireReview() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "君")])])
        let original = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        var heard = evidence("きみ")
        for frame in 0..<heard.frames {
            for (a, b) in [("き", "く"), ("み", "ん")] {
                let first = vocabulary[a]!, second = vocabulary[b]!
                if heard.logProbabilities[frame * 123 + first] > log(0.9) {
                    heard.logProbabilities[frame * 123 + first] = log(0.49)
                    heard.logProbabilities[frame * 123 + second] = log(0.49)
                }
            }
        }
        let spans = try LyricsAICTC.align(heard, tokens: original.tokens)
        let result = try LyricsAIReadingSelector.select(draft: draft, plan: original, spans: spans, evidence: heard,
                                                       vocabulary: vocabulary, english: [:])
        #expect(result.plan.tokens == original.tokens)
        #expect(result.uncertainCount == 1)
        #expect(result.resolvedCount == 0)
    }

    @Test func changedReadingRetainsStableDisplayBoundariesAndOriginalDocumentContent() throws {
        let line = LyricsDraft.Line(syllables: [.init(text: "「明"), .init(text: "日。」")], translation: "tomorrow", romanization: "a shi ta")
        let draft = LyricsDraft(lines: [line], metadata: ["musicName": "fixture"])
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:])
        let word = try #require(plan.words.first { $0.text == "明日" })
        let changed = try LyricsAIPronunciation.make(draft: draft, vocabulary: vocabulary, english: [:],
            readings: [.init(line: 0, range: word.range, reading: "あした")])
        let inverse = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })
        let perBlock = changed.units.map { unit in changed.tokens[unit.tokens].map { inverse[$0.label]! }.joined() }
        #expect(perBlock == ["あ", "した"])
        let heard = evidence("あした")
        let spans = try LyricsAICTC.align(heard, tokens: changed.tokens)
        let applied = try LyricsAIAligner.apply(spans, plan: changed, to: draft)
        #expect(applied.draft.lines[0].syllables.map(\.id) == line.syllables.map(\.id))
        #expect(applied.draft.lines[0].text == line.text)
        #expect(applied.draft.lines[0].translation == line.translation)
        #expect(applied.draft.lines[0].romanization == line.romanization)
        #expect(applied.draft.lines[0].syllables.allSatisfy { $0.ruby == nil })
        #expect(applied.draft.metadata == draft.metadata)
    }

    @Test func forwardScoreMatchesEnumeratedCTCPathsIncludingRepeatedLabels() throws {
        let rows: [[Float]] = [[0.2, 0.7, 0.1], [0.6, 0.3, 0.1], [0.2, 0.7, 0.1], [0.5, 0.1, 0.4]]
        let evidence = LyricsAICTC.Evidence(frames: rows.count, width: 3, blank: 0,
            logProbabilities: rows.flatMap { $0.map(log) }, sustain: [], silent: [], duration: 0.08)
        for target in [[1], [1, 1], [1, 2]] {
            var probability = 0.0
            for encoded in 0..<81 {
                var value = encoded, path: [Int] = []
                for _ in rows { path.append(value % 3); value /= 3 }
                var collapsed: [Int] = [], previous = -1
                for label in path {
                    if label != previous, label != 0 { collapsed.append(label) }
                    previous = label
                }
                if collapsed == target {
                    probability += zip(rows, path).reduce(1.0) { $0 * Double($1.0[$1.1]) }
                }
            }
            let value = try LyricsAICTC.sequenceLogProbability(evidence, labels: target, frames: 0..<rows.count)
            let actual = try #require(value)
            #expect(abs(actual - log(probability)) < 1e-6)
        }
        #expect(try LyricsAICTC.sequenceLogProbability(evidence, labels: [1, 1], frames: 0..<2) == -.infinity)
        #expect(try LyricsAICTC.sequenceLogProbability(evidence, labels: [3], frames: 0..<4) == nil)
    }
}
