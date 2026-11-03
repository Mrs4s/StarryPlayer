import AppKit
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorRubyTimingTests {
    private let own = LyricsDraft.RubyAnnotation(syllables: 0...0, isShared: false)

    private func session(_ syllables: [LyricsDraft.Syllable]) -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "ruby-timing-test"), title: "Test", artists: [], duration: 30)
        return LyricsEditorSession(track: track, draft: LyricsDraft(lines: [.init(syllables: syllables)]))
    }

    private var sen: LyricsDraft.Syllable { .init(text: "詮", start: 1, end: 2, ruby: [.init(text: "せ"), .init(text: "ん")]) }

    private func close(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

    @Test func draggingARubyBoundarySnapsAndCommitsOnlyOnTheCurrentDraft() throws {
        let session = session([sen, .init(text: "は", start: 2, end: 3)])
        let edit = try #require(LyricsTimelineRubyAdjustment(session: session, line: 0, annotation: own, piece: 0, edge: .end, range: 0...10, width: 1_000))
        #expect(close(edit.time(translation: -20), 1.3))
        #expect(close(edit.time(translation: -20, onsets: [1.33]), 1.33))
        #expect(close(edit.time(translation: 48), 2))
        let times = edit.preview(translation: -20).rubyTimes(of: own, base: 1...2)
        #expect(close(times[0].end, 1.3) && close(times[1].start, 1.3))
        #expect(edit.commit(translation: -20, in: session))
        #expect(session.canUndo)
        #expect(!edit.commit(translation: -10, in: session))
    }

    @Test func rubyOverASyllableWithoutAnEndCannotBeDragged() {
        var open = sen
        open.end = nil
        let session = session([open])
        #expect(LyricsTimelineRubyAdjustment(session: session, line: 0, annotation: own, piece: 0, edge: .end, range: 0...10, width: 1_000) == nil)
    }

    @Test func stretchingASyllableKeepsTimedRubyAndMovingItCarriesRubyAlong() throws {
        var timed = sen
        timed.ruby = [.init(text: "せ", span: 0...0.3), .init(text: "ん", span: 0.3...1)]
        let session = session([timed])
        let end = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 0), part: .end, range: 0...10, width: 1_000))
        let stretched = end.preview(translation: 100)
        #expect(stretched.syllables[0].end == 3)
        let times = stretched.rubyTimes(of: own, base: 1...3)
        #expect(close(times[1].start, 1.3) && close(times[1].end, 3))
        let body = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 0), part: .body, range: 0...10, width: 1_000))
        #expect(body.preview(translation: 100).syllables[0].ruby == timed.ruby)
    }

    @Test func aPickedRubyPieceFollowsTheCaretAndTakesTypedTimes() throws {
        let session = session([sen, .init(text: "は", start: 2, end: 3)])
        session.selectRuby(piece: 1, at: .init(line: 0, syllable: 0))
        let picked = try #require(session.selectedRuby)
        #expect(picked.piece == 1 && picked.annotation == own)
        #expect(session.rubyFocus == .init(line: 0, syllables: 0...0, piece: 1))
        session.setRubyTime(.start, to: 1.25)
        let times = session.draft.lines[0].rubyTimes(of: own, base: 1...2)
        #expect(close(times[1].start, 1.25) && close(times[0].end, 1.25))
        session.caret = .init(line: 0, syllable: 1)
        #expect(session.selectedRuby == nil)
        session.selectRuby(piece: 0, at: .init(line: 0, syllable: 0))
        session.select(.init(line: 0, syllable: 0))
        #expect(session.rubyPiece == nil)
    }

    @Test func tapsStepThroughRubyPiecesAndTheNextTapEndsTheRun() {
        let session = session([.init(text: "詮", ruby: [.init(text: "せ"), .init(text: "ん")]), .init(text: "は")])
        session.tapsRuby = true
        #expect(session.rubyFocus == .init(line: 0, syllables: 0...0, piece: 0))
        session.tap(at: 1)
        #expect(session.caret == .init(line: 0, syllable: 0) && session.rubyPiece == 1)
        session.tap(at: 1.4)
        #expect(session.caret == .init(line: 0, syllable: 1))
        session.tap(at: 2)
        let line = session.draft.lines[0]
        #expect(line.syllables[0].start == 1 && line.syllables[0].end == 2 && line.syllables[1].start == 2)
        #expect(close(line.rubyTimes(of: own, base: 1...2)[1].start, 1.4))
        #expect(session.rubyTaps == nil)
    }

    @Test func tapsStayOnSyllablesWhileRubyTappingIsOff() {
        let session = session([.init(text: "詮", ruby: [.init(text: "せ"), .init(text: "ん")]), .init(text: "は")])
        session.tap(at: 1)
        #expect(session.caret == .init(line: 0, syllable: 1) && session.rubyTaps == nil)
    }

    @Test func releaseLeavesAPauseBetweenPiecesAndEndsTheRun() {
        let session = session([.init(text: "詮", ruby: [.init(text: "せ"), .init(text: "ん")])])
        session.tapsRuby = true
        session.tap(at: 1)
        session.release(at: 1.2)
        session.tap(at: 1.5)
        session.release(at: 2)
        let line = session.draft.lines[0]
        #expect(line.syllables[0].end == 2)
        let times = line.rubyTimes(of: own, base: 1...2)
        #expect(close(times[0].end, 1.2) && close(times[1].start, 1.5) && close(times[1].end, 2))
    }

    @Test func stepBackUndoesOnePieceAtATimeAndReopensTimedRuby() {
        let session = session([.init(text: "詮", ruby: [.init(text: "せ"), .init(text: "ん")]), .init(text: "は")])
        session.tapsRuby = true
        session.tap(at: 1)
        session.tap(at: 1.4)
        session.stepBack()
        #expect(session.caret == .init(line: 0, syllable: 0) && session.rubyPiece == 1)
        session.tap(at: 1.5)
        session.tap(at: 2)
        #expect(close(session.draft.lines[0].rubyTimes(of: own, base: 1...2)[1].start, 1.5))
        session.stepBack()
        #expect(session.caret == .init(line: 0, syllable: 1))
        session.stepBack()
        #expect(session.caret == .init(line: 0, syllable: 0) && session.rubyPiece == 1)
        #expect(session.draft.lines[0].syllables[0].end == nil)
        session.stepBack()
        #expect(session.draft.lines[0].syllables[0].start == nil && session.rubyPiece == nil)
    }

    @Test func tappingSharedRubySplitsItsSyllablesWhereTheReadingsMeet() {
        let first = LyricsDraft.Syllable(text: "世", groupRuby: [.init(text: "せ"), .init(text: "か"), .init(text: "い")])
        let session = session([first, .init(text: "界", joinsRubyGroup: true), .init(text: "は")])
        session.tapsRuby = true
        session.caret = .init(line: 0, syllable: 1)
        session.tap(at: 0)
        session.tap(at: 0.3)
        session.tap(at: 0.6)
        #expect(session.caret == .init(line: 0, syllable: 2))
        session.tap(at: 1)
        #expect(session.draft.lines[0].syllables.map(\.start) == [0, 0.3, 1])
        #expect(session.draft.lines[0].syllables.map(\.end) == [0.3, 1, nil])
    }

    @Test func undoDropsAnUnfinishedRun() {
        let session = session([.init(text: "詮", ruby: [.init(text: "せ"), .init(text: "ん")])])
        session.tapsRuby = true
        session.tap(at: 1)
        #expect(session.rubyTaps != nil)
        session.undo()
        #expect(session.rubyTaps == nil && session.draft.lines[0].syllables[0].start == nil)
    }
}
