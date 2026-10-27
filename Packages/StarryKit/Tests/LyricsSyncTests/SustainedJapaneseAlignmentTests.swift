import AudioProcessing
import Foundation
import LyricsCore
import LyricsSync
import Testing

@Suite struct SustainedJapaneseAlignmentTests {
    private struct Fixture: Decodable {
        struct Onset: Decodable { var time: Double; var strength: Float }
        var texts: [String]
        var range: [Double]
        var reference: [Double]
        var referenceEnds: [Double]
        var firstFrame: Int
        var energy: [Float]
        var onsets: [Onset]
        var frameDuration: Double
        var centerOffset: Double

        var analysis: VocalOnsetDetector.Analysis {
            var activity = VocalActivity(frameCount: firstFrame + energy.count)
            for (offset, level) in energy.enumerated() {
                activity.energy[firstFrame + offset] = level
                activity.valid[firstFrame + offset] = true
            }
            return .init(onsets: onsets.map { .init(time: $0.time, strength: $0.strength) }, activity: activity,
                         frameDuration: frameDuration, centerOffset: centerOffset)
        }
    }

    @Test func realPhrasesWithMissingAttacksAndHeldEndingsDoNotDriftIntoTheNextSyllable() throws {
        let url = try #require(Bundle.module.url(forResource: "SustainedJapanesePhrases", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var allErrors: [Double] = []
        for (index, fixture) in fixtures.enumerated() {
            let line = LyricsDraft.Line(syllables: fixture.texts.map { .init(text: $0) }, start: fixture.range[0], end: fixture.range[1])
            let result = try LyricsLineAligner.align(line, in: fixture.range[0]...fixture.range[1], analysis: fixture.analysis)
            let starts = try result.line.syllables.map { try #require($0.start) }
            let errors = zip(starts, fixture.reference).map { abs($0 - $1) }
            let mean = errors.reduce(0, +) / Double(errors.count)
            #expect(mean < 0.08, "Phrase \(index + 1): mean onset error \(mean) s")
            #expect(errors.max()! < 0.25, "Phrase \(index + 1): maximum onset error \(errors.max()!) s")
            #expect(result.line.syllables.last!.end! <= fixture.range[1])
            allErrors += errors
        }
        #expect(allErrors.count == 51)
        #expect(allErrors.reduce(0, +) / Double(allErrors.count) < 0.06)
        #expect(allErrors.filter { $0 <= 0.1 }.count >= 40)
    }

    @Test func sokuonRetainsItsDurationInsideTheKanjiBlockThatContainsIt() {
        let line = LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "出会った"))
        #expect(LyricsTimingWeights.weights(for: line, language: .japanese) == [1, 2, 1])
        let profile = LyricsTimingWeights.profile(for: line, language: .japanese)
        #expect(profile.syllables[1].internalAttacks == 0)
    }

    @Test func calibrationDoesNotReplaceCorrectWeakBoundariesWithTheNextLouderAttack() throws {
        let url = try #require(Bundle.module.url(forResource: "SustainedJapanesePhrases", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var errors: [Double] = []
        for fixture in fixtures {
            let syllables = fixture.texts.indices.map { LyricsDraft.Syllable(text: fixture.texts[$0], start: fixture.reference[$0], end: fixture.referenceEnds[$0]) }
            let line = LyricsDraft.Line(syllables: syllables)
            let result = try LyricsLineAligner.align(line, in: fixture.range[0]...fixture.range[1], analysis: fixture.analysis, mode: .calibrate)
            errors += zip(result.line.syllables, fixture.reference).map { abs($0.start! - $1) }
        }
        #expect(errors.reduce(0, +) / Double(errors.count) < 0.04)
        #expect(errors.max()! < 0.15)
    }

    @Test func compoundReadingsStayApproximateUntilTheUserProvidesPerBlockRuby() {
        var line = LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "未来"))
        #expect(LyricsTimingWeights.weights(for: line, language: .japanese) == [1.5, 1.5])
        line.syllables[0].ruby = [.init(text: "み")]
        line.syllables[1].ruby = [.init(text: "らい")]
        #expect(LyricsTimingWeights.weights(for: line, language: .japanese) == [1, 2])
    }

    @Test func theParticleHeUsesItsSungVowelInsteadOfAnExpectedHConsonant() {
        let line = LyricsDraft.Line(syllables: LyricsDraftImport.syllables(in: "旅へ行こう"))
        let profile = LyricsTimingWeights.profile(for: line, language: .japanese)
        #expect(profile.syllables[1].attack == .vowel)
    }
}
