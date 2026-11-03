import Foundation
import Testing
@testable import LyricsCore

struct RubyTimingTests {
    typealias Ruby = LyricsDraft.Ruby

    private func spans(_ pieces: [Ruby]?) -> [[Double]] {
        (pieces ?? []).map { piece in piece.span.map { [round($0.lowerBound * 1000) / 1000, round($0.upperBound * 1000) / 1000] } ?? [] }
    }

    private func draft(_ syllables: [LyricsDraft.Syllable]) -> LyricsDraft {
        LyricsDraft(lines: [LyricsDraft.Line(syllables: syllables)])
    }

    @Test func splittingATimedPieceSharesItsTimeAndJoiningCoversThePieces() {
        let whole = [Ruby(text: "せん", span: 0.2...0.8)]
        let split = Ruby.resegmented(["せ", "ん"], from: whole)
        #expect(split.map(\.text) == ["せ", "ん"])
        #expect(spans(split) == [[0.2, 0.5], [0.5, 0.8]])
        let pieces = [Ruby(text: "せ", span: 0...0.3), Ruby(text: "ん", span: 0.4...1)]
        #expect(spans(Ruby.resegmented(["せん"], from: pieces)) == [[0, 1]])
    }

    @Test func smallKanaRideOnTheMoraBeforeThem() {
        let split = Ruby.resegmented(["きょ", "う"], from: [Ruby(text: "きょう", span: 0...1)])
        #expect(spans(split) == [[0, 0.5], [0.5, 1]])
    }

    @Test func aDifferentReadingKeepsSpansOnlyPieceForPiece() {
        let old = [Ruby(text: "せ", span: 0...0.3), Ruby(text: "ん", span: 0.3...1)]
        #expect(spans(Ruby.resegmented(["か", "い"], from: old)) == [[0, 0.3], [0.3, 1]])
        #expect(Ruby.resegmented(["かい"], from: old).allSatisfy { $0.span == nil })
        #expect(Ruby.resegmented(["せ", "ん"], from: [Ruby(text: "せん")]).allSatisfy { $0.span == nil })
    }

    @Test func stretchingASyllableKeepsTimedRubyBoundariesWhereTheyWereSung() {
        let original = LyricsDraft.Line(syllables: [.init(text: "詮", start: 10, end: 11, ruby: [Ruby(text: "せ", span: 0...0.4), Ruby(text: "ん", span: 0.4...1)])])
        var longer = original
        longer.syllables[0].end = 12
        #expect(spans(longer.keepingRubyTiming(from: original).syllables[0].ruby) == [[0, 0.2], [0.2, 1]])
        var later = original
        later.syllables[0].start = 10.2
        #expect(spans(later.keepingRubyTiming(from: original).syllables[0].ruby) == [[0, 0.25], [0.25, 1]])
    }

    @Test func movingASyllableOrSqueezingAPieceAwayKeepsProportionalRuby() {
        let original = LyricsDraft.Line(syllables: [.init(text: "詮", start: 10, end: 11, ruby: [Ruby(text: "せ", span: 0...0.4), Ruby(text: "ん", span: 0.4...1)])])
        var moved = original
        moved.syllables[0].start = 12
        moved.syllables[0].end = 13
        #expect(moved.keepingRubyTiming(from: original) == moved)
        var squeezed = original
        squeezed.syllables[0].start = 10.399
        #expect(squeezed.keepingRubyTiming(from: original) == squeezed)
        var untimed = original
        untimed.syllables[0].ruby = [Ruby(text: "せ"), Ruby(text: "ん")]
        var stretched = untimed
        stretched.syllables[0].end = 12
        #expect(stretched.keepingRubyTiming(from: untimed) == stretched)
    }

    @Test func stretchingASharedGroupKeepsItsInnerBoundaries() {
        var syllables: [LyricsDraft.Syllable] = [.init(text: "今", start: 0, end: 1), .init(text: "日", start: 1, end: 2)]
        syllables[0].groupRuby = [Ruby(text: "きょ", span: 0...0.5), Ruby(text: "う", span: 0.5...1)]
        syllables[1].joinsRubyGroup = true
        let original = LyricsDraft.Line(syllables: syllables)
        var stretched = original
        stretched.syllables[1].end = 3
        #expect(spans(stretched.keepingRubyTiming(from: original).syllables[0].groupRuby) == [[0, 0.333], [0.333, 1]])
    }

    @Test func draggingTheBoundaryBetweenPiecesMovesBothWithinTheirNeighbours() {
        let line = LyricsDraft.Line(syllables: [.init(text: "詮", start: 10, end: 11, ruby: [Ruby(text: "せ"), Ruby(text: "ん")])])
        let annotation = LyricsDraft.RubyAnnotation(syllables: 0...0, isShared: false)
        let moved = line.movingRubyEdge(.end, ofPiece: 0, in: annotation, base: 10...11, to: 10.3)
        #expect(spans(moved.syllables[0].ruby) == [[0, 0.3], [0.3, 1]])
        let clamped = line.movingRubyEdge(.start, ofPiece: 1, in: annotation, base: 10...11, to: 12)
        #expect(spans(clamped.syllables[0].ruby) == [[0, 0.98], [0.98, 1]])
        let gap = line.movingRubyEdge(.start, ofPiece: 0, in: annotation, base: 10...11, to: 10.1)
        #expect(spans(gap.syllables[0].ruby) == [[0.1, 0.5], [0.5, 1]])
        #expect(line.rubyTimes(of: annotation, base: 10...11).map(\.start) == [10, 10.5])
    }

    @Test func mergingTimedWithUntimedRubyPlacesTheUntimedWithinItsOwnPart() {
        var d = draft([.init(text: "今", start: 10, end: 11, ruby: [Ruby(text: "き"), Ruby(text: "ょ")]), .init(text: "日", start: 11, end: 13, ruby: [Ruby(text: "う", span: 0.5...1)])])
        d.mergeWithNext(at: .init(line: 0, syllable: 0))
        #expect(spans(d.lines[0].syllables[0].ruby) == [[0, 0.167], [0.167, 0.333], [0.667, 1]])
        var untimed = draft([.init(text: "今", start: 10, end: 11, ruby: [Ruby(text: "きょ")]), .init(text: "日", start: 11, end: 12)])
        untimed.mergeWithNext(at: .init(line: 0, syllable: 0))
        #expect(untimed.lines[0].syllables[0].ruby == [Ruby(text: "きょ"), Ruby(text: "日")])
    }

    @Test func splittingASyllableGivesEachCharacterItsReading() {
        var d = draft([.init(text: "世界", start: 0, end: 3, ruby: [Ruby(text: "せかい")])])
        d.splitSyllable(at: .init(line: 0, syllable: 0))
        let parts = d.lines[0].syllables
        #expect(parts.map(\.text) == ["世", "界"])
        #expect(parts.map { $0.ruby?.map(\.text) } == [["せ"], ["かい"]])
        #expect(parts.map(\.start) == [0, 1] && parts.map(\.end) == [1, 3])
        #expect(parts.allSatisfy { $0.groupRuby == nil && !$0.joinsRubyGroup })
    }

    @Test func splittingTimedRubyKeepsEveryPieceWhereItIsSung() {
        var d = draft([.init(text: "世界", start: 0, end: 1, ruby: [Ruby(text: "せ", span: 0...0.2), Ruby(text: "か", span: 0.2...0.6), Ruby(text: "い", span: 0.6...1)])])
        d.splitSyllable(at: .init(line: 0, syllable: 0))
        let parts = d.lines[0].syllables
        #expect(parts.map(\.start) == [0, 0.2] && parts.map(\.end) == [0.2, 1])
        #expect(parts[1].ruby?.map(\.text) == ["か", "い"])
        #expect(spans(parts[0].ruby) == [[0, 1]] && spans(parts[1].ruby) == [[0, 0.5], [0.5, 1]])
    }

    @Test func splittingKanaLeavesItWithoutRubyAndAnUnsplittableReadingIsShared() {
        var d = draft([.init(text: "見る", start: 0, end: 2, ruby: [Ruby(text: "みる")])])
        d.splitSyllable(at: .init(line: 0, syllable: 0))
        #expect(d.lines[0].syllables.map { $0.ruby?.map(\.text) } == [["み"], nil])
        var english = draft([.init(text: "ラブ", start: 0, end: 2, ruby: [Ruby(text: "love")])])
        english.splitSyllable(at: .init(line: 0, syllable: 0))
        let parts = english.lines[0].syllables
        #expect(parts[0].groupRuby == [Ruby(text: "love")] && parts.map(\.joinsRubyGroup) == [false, true])
        #expect(parts.allSatisfy { $0.ruby == nil })
    }

    @Test func sharingRubyStartsFromTheSyllablesOwnTiming() {
        var d = draft([.init(text: "今", start: 0, end: 1, ruby: [Ruby(text: "きょ", span: 0...1)]), .init(text: "日", start: 1, end: 2, ruby: [Ruby(text: "う", span: 0...1)])])
        let positions = [LyricsDraft.Position(line: 0, syllable: 0), .init(line: 0, syllable: 1)]
        d.setGroupRuby("きょう", over: positions)
        #expect(spans(d.lines[0].syllables[0].groupRuby) == [[0, 1]])
        d.setGroupRuby("きょ|う", over: positions)
        #expect(spans(d.lines[0].syllables[0].groupRuby) == [[0, 0.5], [0.5, 1]])
    }

    @Test func sharedRubySplitsBackOntoItsSyllablesWithItsTiming() {
        var syllables: [LyricsDraft.Syllable] = [.init(text: "世", start: 0, end: 1), .init(text: "界", start: 1, end: 3)]
        syllables[0].groupRuby = [Ruby(text: "せ", span: 0...0.2), Ruby(text: "かい", span: 0.2...1)]
        syllables[1].joinsRubyGroup = true
        var d = draft(syllables)
        let split = d.splitSharedRuby(at: .init(line: 0, syllable: 1))
        #expect(split)
        let parts = d.lines[0].syllables
        #expect(parts.allSatisfy { $0.groupRuby == nil && !$0.joinsRubyGroup })
        #expect(parts.map { $0.ruby?.map(\.text) } == [["せ"], ["かい"]])
        #expect(spans(parts[0].ruby) == [[0, 0.6]] && spans(parts[1].ruby) == [[0, 1]])
        var english = draft([.init(text: "運", start: 0, end: 1, groupRuby: [Ruby(text: "destiny")]), .init(text: "命", start: 1, end: 2, joinsRubyGroup: true)])
        let refused = english.splitSharedRuby(at: .init(line: 0, syllable: 0))
        #expect(!refused)
    }

    @Test func kanaRubySplitsIntoMoraeAndKeepsItsTiming() {
        var d = draft([
            .init(text: "今日", start: 0, end: 1, ruby: [Ruby(text: "きょう", span: 0...1)]),
            .init(text: "運命", start: 1, end: 2, ruby: [Ruby(text: "destiny")]),
            .init(text: "詮", start: 2, end: 3, ruby: [Ruby(text: "セン")]),
        ])
        let all = (0..<3).map { LyricsDraft.Position(line: 0, syllable: $0) }
        let changed = d.splitRubyIntoMorae(at: all)
        #expect(changed == 2)
        #expect(d.lines[0].syllables.map { $0.ruby?.map(\.text) ?? [] } == [["きょ", "う"], ["destiny"], ["セ", "ン"]])
        #expect(spans(d.lines[0].syllables[0].ruby) == [[0, 0.5], [0.5, 1]])
        #expect(d.lines[0].syllables[2].ruby?.allSatisfy { $0.span == nil } == true)
        let again = d.splitRubyIntoMorae(at: all)
        #expect(again == 0)
    }

    @Test func tappedPiecesTimeTheRubyAndEndTheSyllable() {
        let line = LyricsDraft.Line(syllables: [.init(text: "詮", start: 0, ruby: [Ruby(text: "せ"), Ruby(text: "ん")])])
        let tapped = line.timingRuby(.init(syllables: 0...0, isShared: false), starts: [10, 10.4], ends: [nil, nil], end: 11)
        #expect(tapped.syllables[0].start == 10 && tapped.syllables[0].end == 11)
        #expect(spans(tapped.syllables[0].ruby) == [[0, 0.4], [0.4, 1]])
        let paused = line.timingRuby(.init(syllables: 0...0, isShared: false), starts: [10, 10.6], ends: [10.2, nil], end: 11)
        #expect(spans(paused.syllables[0].ruby) == [[0, 0.2], [0.6, 1]])
    }

    @Test func tappedSharedRubySplitsItsSyllablesWhereTheirReadingsMeet() {
        var syllables: [LyricsDraft.Syllable] = [.init(text: "世"), .init(text: "界")]
        syllables[0].groupRuby = [Ruby(text: "せ"), Ruby(text: "か"), Ruby(text: "い")]
        syllables[1].joinsRubyGroup = true
        let line = LyricsDraft.Line(syllables: syllables)
        let group = LyricsDraft.RubyAnnotation(syllables: 0...1, isShared: true)
        let tapped = line.timingRuby(group, starts: [0, 0.3, 0.6], ends: [nil, nil, nil], end: 1)
        #expect(tapped.syllables.map(\.start) == [0, 0.3] && tapped.syllables.map(\.end) == [0.3, 1])
        #expect(spans(tapped.syllables[0].groupRuby) == [[0, 0.3], [0.3, 0.6], [0.6, 1]])
        var english = line
        english.syllables[0].groupRuby = [Ruby(text: "des"), Ruby(text: "ti"), Ruby(text: "ny")]
        let kept = english.timingRuby(group, starts: [0, 0.2, 0.5], ends: [nil, nil, nil], end: 1, fallback: [0.25])
        #expect(kept.syllables[1].start == 0.25)
        #expect(english.timingRuby(group, starts: [0, 0.2, 0.5], ends: [nil, nil, nil], end: 1).syllables[1].start == 0.5)
    }

    private var retimedSen: LyricsDraft.Line {
        let line = LyricsDraft.Line(syllables: [.init(text: "詮", start: 10, end: 11, ruby: [Ruby(text: "せ"), Ruby(text: "ん")]), .init(text: "は", start: 11, end: 12)])
        return line.movingRubyEdge(.end, ofPiece: 0, in: .init(syllables: 0...0, isShared: false), base: 10...11, to: 10.25)
    }

    @Test(arguments: [TTMLWriter.Format.amll, .ttml2])
    func editedRubyTimingSurvivesTTML(format: TTMLWriter.Format) throws {
        let document = LyricsDraft(lines: [retimedSen]).document()
        let parsed = try TTMLParser.parse(TTMLWriter.write(document, format: format))
        let ruby = try #require(parsed.lines.first?.syllables.first?.ruby)
        #expect(ruby.map(\.start) == [10, 10.25] && ruby.map(\.end) == [10.25, 11])
    }

    @Test func editedRubyTimingSurvivesNicokara() throws {
        let output = try LyricsExport.write(LyricsDraft(lines: [retimedSen]), format: .nicokaraRuby)
        let ruby = try #require(try NicokaraParser.parse(output.text).lines.first?.syllables.first?.ruby)
        #expect(ruby.map(\.text) == ["せ", "ん"])
        #expect(abs(ruby[1].start - 10.25) < 0.011 && abs(ruby[0].end - 10.25) < 0.011)
    }
}
