import Testing
@testable import LyricsCore

@Suite struct LyricsDraftValidationTests {
    @Test(arguments: [0.5, 1.5, 1.999])
    func rejectsStartsBeforeThePreviousEnd(start: Double) {
        let draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "我", start: 1, end: 2),
            .init(text: "爱", start: start, end: 3),
        ])])
        #expect(draft.firstTimingOverlap == .init(line: 0, syllable: 1))
    }

    @Test(arguments: [2.0, 2.5])
    func allowsTouchingSyllablesAndGaps(start: Double) {
        let draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "我", start: 1, end: 2),
            .init(text: "爱", start: start, end: 3),
        ])])
        #expect(draft.firstTimingOverlap == nil)
    }

    @Test func allowsOverlappingLinesAndChecksBackgroundSyllablesWithinTheirOwnLine() {
        var draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "主唱", start: 1, end: 8)]),
            .init(syllables: [.init(text: "和", start: 2, end: 3), .init(text: "声", start: 3, end: 4)], isBackground: true),
            .init(syllables: []),
            .init(syllables: [.init(text: "对唱", start: 2, end: 5)], singer: .secondary),
        ])
        #expect(draft.firstTimingOverlap == nil)
        draft.lines[1].syllables[1].start = 2.5
        #expect(draft.firstTimingOverlap == .init(line: 1, syllable: 1))
    }

    @Test func missingEndsDoNotHideReversedStarts() {
        let draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "我", start: 3),
            .init(text: "爱", start: 2),
        ])])
        #expect(draft.firstTimingOverlap == .init(line: 0, syllable: 1))
    }

    @Test func untimedSyllablesDoNotHideAnOverlapBetweenKnownTimes() {
        let draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "我", start: 1, end: 4),
            .init(text: "爱"),
            .init(text: "你", start: 3, end: 5),
        ])])
        #expect(draft.firstTimingOverlap == .init(line: 0, syllable: 2))
    }

    @Test func backgroundVocalsNeedALineRightAboveThemToBack() {
        var draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "主", start: 1, end: 2)]),
            .init(syllables: [.init(text: "和", start: 1, end: 2)], isBackground: true),
        ])
        #expect(draft.firstExportIssue == nil)
        draft.lines.append(.init(syllables: [.init(text: "又", start: 2, end: 3)], isBackground: true))
        #expect(draft.firstExportIssue == .strayBackground(line: 2))
        draft.lines[2].isBackground = false
        draft.lines.insert(.init(syllables: []), at: 1)
        #expect(draft.firstExportIssue == .strayBackground(line: 2))
        draft.lines.remove(at: 1)
        draft.lines.insert(.init(syllables: [.init(text: "首", start: 0, end: 1)], isBackground: true), at: 0)
        #expect(draft.firstExportIssue == .strayBackground(line: 0))
    }

    @Test func theFirstIssueInLyricOrderIsReported() {
        let draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "我", start: 1, end: 2), .init(text: "爱", start: 1.5, end: 3)]),
            .init(syllables: [.init(text: "和", start: 1, end: 2)], isBackground: true),
            .init(syllables: [.init(text: "又", start: 2, end: 3)], isBackground: true),
            .init(syllables: [.init(text: "你", start: 5, end: 6), .init(text: "好", start: 4, end: 7)]),
        ])
        #expect(draft.firstExportIssue == .timingOverlap(.init(line: 0, syllable: 1)))
        var later = draft
        later.lines[0].syllables[1].start = 2
        #expect(later.firstExportIssue == .strayBackground(line: 2))
    }

    @Test func allowsEmptyUntimedLineTimedAndPartlyTimedDrafts() throws {
        #expect(LyricsDraft().firstTimingOverlap == nil)
        #expect(try LyricsDraftImport.draft(from: "我爱你").firstTimingOverlap == nil)
        #expect(try LyricsDraftImport.draft(from: "[00:01.00]我爱你\n[00:05.00]再见", pairsTranslations: false).firstTimingOverlap == nil)
        let draft = LyricsDraft(lines: [.init(syllables: [
            .init(text: "我", start: 1, end: 2),
            .init(text: "爱"),
            .init(text: "你", start: 3),
        ])])
        #expect(draft.firstTimingOverlap == nil)
    }
}
