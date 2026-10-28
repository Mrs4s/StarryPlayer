import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorSessionTests {
    private func session(_ text: String) throws -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "song"), title: "Song", artists: [ArtistRef(id: "a", name: "A"), ArtistRef(id: "b", name: "B")], album: AlbumRef(id: "al", name: "Album"), duration: 200)
        let session = LyricsEditorSession(track: track)
        session.replace(with: try LyricsDraftImport.draft(from: text))
        return session
    }

    private func times(_ session: LyricsEditorSession, line: Int) -> [[TimeInterval?]] {
        session.draft.lines[line].syllables.map { [$0.start, $0.end] }
    }

    @Test func differentNamedPerformersDoNotShareTheSameTimingVoice() {
        let alice = LyricsDraft.Line(syllables: [.init(text: "A")], singer: .secondary, agentIDs: ["alice"])
        let bob = LyricsDraft.Line(syllables: [.init(text: "B")], singer: .secondary, agentIDs: ["bob"])
        let aliceAgain = LyricsDraft.Line(syllables: [.init(text: "C")], singer: .secondary, agentIDs: ["alice"])
        #expect(!LyricsEditorSession.sameVoice(alice, bob))
        #expect(LyricsEditorSession.sameVoice(alice, aliceAgain))
    }

    @Test func tapsStartEachSyllableAndEndTheOneBefore() throws {
        let session = try session("我爱你\n再见")
        #expect(session.caret == .init(line: 0, syllable: 0))
        session.tap(at: 1)
        session.tap(at: 1.5)
        session.tap(at: 2)
        #expect(times(session, line: 0) == [[1, 1.5], [1.5, 2], [2, nil]])
        #expect(session.caret == .init(line: 1, syllable: 0))
        session.release(at: 2.6)
        session.tap(at: 4)
        #expect(times(session, line: 0)[2] == [2, 2.6])
        #expect(times(session, line: 1)[0] == [4, nil])
    }

    @Test func aManuallyTimedLineCompletesOnlyWhenItsLastEndIsRecorded() throws {
        let session = try session("我爱你\n再见")
        let first = session.draft.lines[0].id
        #expect(session.tap(at: 1) == nil)
        #expect(session.tap(at: 1.5) == nil)
        #expect(session.tap(at: 2) == nil)
        #expect(session.release(at: 2.5) == first)
        #expect(session.release(at: 2.6) == nil)
        #expect(session.tap(at: 3) == nil)
    }

    @Test func startingTheNextLineCanCompleteThePreviousLineExactlyOnce() throws {
        let session = try session("你好\n再见")
        let first = session.draft.lines[0].id, second = session.draft.lines[1].id
        #expect(session.tap(at: 1) == nil)
        #expect(session.tap(at: 1.5) == nil)
        #expect(session.tap(at: 3) == first)
        #expect(session.draft.lines[0].syllables.last?.end == 3)
        #expect(session.tap(at: 3.5) == nil)
        #expect(session.release(at: 4) == second)
        #expect(session.release(at: 4.1) == nil)
    }

    @Test func incompleteRowsAndOtherVoicesAreNotReportedAsCompleted() throws {
        let session = try session("你好\n再见")
        session.select(.init(line: 0, syllable: 1))
        #expect(session.tap(at: 1) == nil)
        #expect(session.release(at: 1.5) == nil)
        session.select(.init(line: 0, syllable: 0))
        session.tap(at: 2)
        session.tap(at: 2.5)
        session.edit { $0.lines[1].singer = .secondary }
        #expect(session.tap(at: 3) == nil)
        #expect(session.draft.lines[0].syllables.last?.end == nil)
    }

    @Test func selectedSyllablesStaySelectedThroughQuickEdits() throws {
        let session = try session("我爱你\n再见")
        let texts = { session.draft.lines.map(\.text) }
        session.select(.init(line: 0, syllable: 1))
        session.extendSelection(to: .init(line: 1, syllable: 0))
        #expect(session.selectedPositions == [.init(line: 0, syllable: 1), .init(line: 0, syllable: 2), .init(line: 1, syllable: 0)])
        session.moveToNewLine()
        #expect(texts() == ["我", "见", "爱你再"])
        #expect(session.selection.count == 3)
        #expect(session.caret == .init(line: 2, syllable: 0))
        session.moveToLine(by: -1)
        #expect(texts() == ["我", "见爱你再"])
        session.undo()
        #expect(texts() == ["我", "见", "爱你再"])
        #expect(session.selection.count == 3)
        session.toggleSelection(.init(line: 2, syllable: 2))
        #expect(session.canMergeSelection)
        session.mergeSelection()
        #expect(session.draft.lines[2].syllables.map(\.text) == ["爱你", "再"])
        #expect(session.selectedPositions == [.init(line: 2, syllable: 0)])
    }

    @Test func withoutASelectionQuickEditsActAtTheCaret() throws {
        let session = try session("我爱你\n再见")
        let texts = { session.draft.lines.map(\.text) }
        session.select(.init(line: 0, syllable: 0))
        session.moveToNewLine()
        #expect(texts() == ["我爱你", "再见"])
        session.select(.init(line: 0, syllable: 1))
        session.moveToNewLine()
        #expect(texts() == ["我", "爱你", "再见"])
        session.moveToLine(by: 1)
        #expect(texts() == ["我", "你", "爱再见"])
        session.delete()
        #expect(texts() == ["我", "你", "再见"])
    }

    @Test func movingALineKeepsTheCaretOnItsSyllable() throws {
        let session = try session("我爱你\n再见\n明天")
        let texts = { session.draft.lines.map(\.text) }
        session.select(.init(line: 1, syllable: 1))
        session.moveLine(by: -1)
        #expect(texts() == ["再见", "我爱你", "明天"])
        #expect(session.caret == .init(line: 0, syllable: 1))
        session.moveLine(by: -1)
        #expect(texts() == ["再见", "我爱你", "明天"])
        session.moveLine(by: 1, id: session.draft.lines[2].id)
        #expect(texts() == ["再见", "我爱你", "明天"])
        session.moveLine(by: -1, id: session.draft.lines[2].id)
        #expect(texts() == ["再见", "明天", "我爱你"])
        #expect(session.caret == .init(line: 0, syllable: 1))
        session.undo()
        #expect(texts() == ["再见", "我爱你", "明天"])
    }

    @Test func toggleStartsFromTheCaretAndAPlainClickClears() throws {
        let session = try session("我爱你")
        session.select(.init(line: 0, syllable: 0))
        session.toggleSelection(.init(line: 0, syllable: 2))
        #expect(session.selectedPositions == [.init(line: 0, syllable: 0), .init(line: 0, syllable: 2)])
        #expect(!session.canMergeSelection)
        session.toggleSelection(.init(line: 0, syllable: 0))
        #expect(session.selectedPositions == [.init(line: 0, syllable: 2)])
        session.selectAll()
        #expect(session.selection.count == 3)
        session.select(.init(line: 0, syllable: 1))
        #expect(session.selection.isEmpty)
    }

    @Test func tappingADuetPartnersLineLeavesTheLineBeforeAlone() throws {
        let session = try session("我爱你\n再见\n明天")
        session.edit { $0.lines[1].singer = .secondary }
        session.tap(at: 1)
        session.tap(at: 2)
        session.tap(at: 3)
        session.release(at: 6)
        session.tap(at: 4)
        #expect(times(session, line: 0)[2] == [3, 6])
        #expect(times(session, line: 1)[0] == [4, nil])
        session.tap(at: 5)
        session.edit { $0.lines[2].singer = .secondary }
        session.tap(at: 7)
        #expect(times(session, line: 1)[1] == [5, 7])
    }

    @Test func draggedEdgesStickToTheEdgesTheyFace() {
        #expect(LyricsTimelineAdjustment.stick(1.04, to: [1.0], reach: 0.05) == 1.0)
        #expect(LyricsTimelineAdjustment.stick(1.06, to: [1.0], reach: 0.05) == 1.06)
        #expect(LyricsTimelineAdjustment.stick(1.03, to: [1.0, 1.05], reach: 0.05) == 1.05)
        #expect(LyricsTimelineAdjustment.stick(1.03, to: [nil], reach: 0.05) == 1.03)
        #expect(LyricsTimelineAdjustment.stick(1.03, to: [], reach: 0.05) == 1.03)
    }

    @Test func stepBackTakesTheLastTapBackAndUndoRestoresIt() throws {
        let session = try session("我爱你")
        session.tap(at: 1)
        session.tap(at: 2)
        session.stepBack()
        #expect(session.caret == .init(line: 0, syllable: 1))
        #expect(times(session, line: 0)[1] == [nil, nil])
        session.undo()
        #expect(session.caret == .init(line: 0, syllable: 2))
        #expect(times(session, line: 0)[1] == [2, nil])
        session.redo()
        #expect(times(session, line: 0)[1] == [nil, nil])
    }

    @Test func dragAdjustmentsUndoInOneStep() throws {
        let session = try session("我爱")
        session.tap(at: 1)
        let drag = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 0), part: .body, range: 0...10, width: 1_000))
        let revision = session.revision
        let document = session.document
        _ = drag.preview(translation: 10)
        #expect(drag.preview(translation: 20).syllables[0].start == 1.2)
        #expect(session.revision == revision)
        #expect(session.document == document)
        #expect(times(session, line: 0)[0][0] == 1)
        #expect(drag.commit(translation: 20, in: session))
        #expect(session.revision == revision + 1)
        #expect(times(session, line: 0)[0][0] == 1.2)
        #expect(!drag.commit(translation: 30, in: session))
        session.undo()
        #expect(times(session, line: 0)[0][0] == 1)
        session.redo()
        #expect(times(session, line: 0)[0][0] == 1.2)
    }

    @Test func exportCarriesTheSongAndReadsBack() throws {
        let session = try session("我爱你")
        session.tap(at: 1)
        session.tap(at: 2)
        session.tap(at: 3)
        session.release(at: 4)
        let ttml = try #require(session.exportTTML())
        #expect(ttml.contains(#"<amll:meta key="musicName" value="Song"/>"#))
        #expect(ttml.contains(#"<amll:meta key="artists" value="A"/><amll:meta key="artists" value="B"/>"#))
        #expect(ttml.contains(#"<body dur="03:20.000">"#))
        let parsed = try TTMLParser.parse(ttml)
        #expect(parsed.lines.first?.syllables.map(\.start) == [1, 2, 3])
        #expect(parsed.lines.first?.end == 4)
        #expect(session.exportFileName == "A / B - Song.ttml".replacingOccurrences(of: "/", with: "／"))
    }

    @Test func overlappingTimingCanBeEditedAndPreviewedButCannotBeExportedUntilFixed() throws {
        let session = try session("我爱你")
        session.tap(at: 1)
        session.tap(at: 2)
        session.tap(at: 3)
        session.release(at: 4)
        session.markSaved()
        session.edit { $0.lines[0].syllables[0].end = 2.5 }
        #expect(session.draft.lines[0].syllables[0].end == 2.5)
        #expect(session.document.lines[0].syllables[0].end == 2.5)
        let draft = session.draft
        let revision = session.revision

        #expect(session.exportTTML() == nil)
        #expect(session.caret == .init(line: 0, syllable: 1))
        #expect(session.flashText == "无法导出：第 1 行第 2 个音节早于前一音节的结束时间")
        #expect(session.draft == draft)
        #expect(session.revision == revision)
        #expect(session.hasUnsavedChanges)

        session.undo()
        #expect(session.exportTTML() != nil)
        session.redo()
        #expect(session.exportTTML() == nil)
        session.edit { $0.lines[0].syllables[1].start = 2.5 }
        let parsed = try TTMLParser.parse(#require(session.exportTTML()))
        #expect(parsed.lines[0].syllables.map(\.start) == [1, 2.5, 3])
    }

    @Test func metadataStartsFromTheSongAndTakesWhatImportsBring() throws {
        let session = try session("我")
        #expect(session.metadata.map(\.key) == ["musicName", "artists", "artists", "album"])
        session.replace(with: LyricsDraft(lines: session.draft.lines, metadata: ["musicName": "Other", "ncmMusicId": "42"]))
        #expect(session.metadata.filter { $0.key == "musicName" }.map(\.value) == ["Song"])
        #expect(session.metadata.last?.key == "ncmMusicId")
        session.metadata[0].value = "Song (Live)"
        session.metadata.append(.init(key: "ttmlAuthorGithubLogin", value: " someone "))
        session.metadata.append(.init(key: "isrc", value: ""))
        let ttml = session.ttml()
        #expect(ttml.contains(#"<amll:meta key="musicName" value="Song (Live)"/>"#))
        #expect(ttml.contains(#"<amll:meta key="ttmlAuthorGithubLogin" value="someone"/>"#))
        #expect(!ttml.contains("isrc"))
    }

    @Test(arguments: [1.0, 0.5])
    func tapLeadIsMeasuredInRealTime(rate: Double) throws {
        let session = try session("我爱")
        session.tapLead = 0.1
        session.tap(at: 1, rate: rate)
        #expect(times(session, line: 0)[0][0] == 1 - 0.1 * rate)
    }

    @Test func selectingALineGoesToItsFirstSyllableToTime() throws {
        let session = try session("我爱\n你好")
        session.edit { $0.lines.append(LyricsDraft.Line(syllables: [])) }
        session.caret = .init(line: 1, syllable: 0)
        session.tap(at: 1)
        session.selectLine(1)
        #expect(session.caret == .init(line: 1, syllable: 1))
        session.selectLine(0)
        #expect(session.caret == .init(line: 0, syllable: 0))
        session.selectLine(1)
        #expect(session.caret == .init(line: 1, syllable: 1))
        session.selectLine(2)
        session.selectLine(9)
        #expect(session.caret == .init(line: 1, syllable: 1))
    }

    @Test func playbackStartIsTheSyllablesOrWhereItsLineIsExpected() throws {
        let session = try session("我爱\n你好\n再见")
        session.tap(at: 2)
        session.tap(at: 3)
        #expect(session.playbackStart(of: .init(line: 0, syllable: 1)) == 3)
        session.caret = .init(line: 2, syllable: 0)
        session.tap(at: 10)
        let middle = try #require(session.playbackStart(of: .init(line: 1, syllable: 1)))
        #expect(middle >= 3 && middle < 10)
        #expect(session.playbackStart(of: .init(line: 9, syllable: 0)) == nil)
    }

    @Test func cachedTimingTracksEditsDragsUndoRedoAndReplacement() throws {
        let session = try session("我爱\n你好\n再见")
        func check() {
            #expect(session.timedRanges == session.draft.lines.map(\.timedRange))
            #expect(session.lineWindows == session.draft.lineWindows())
            #expect(session.timedEnd == (session.draft.lines.compactMap { $0.timedRange?.upperBound }.max() ?? 0))
        }
        check()
        session.tap(at: 2)
        session.release(at: 3)
        check()
        let drag = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 0), part: .end, range: 0...10, width: 100))
        drag.commit(translation: 30, in: session)
        check()
        session.undo()
        check()
        session.redo()
        check()
        session.edit { $0.lines.removeFirst() }
        check()
        session.replace(with: LyricsDraft())
        check()
    }

    @Test func timelineViewportPansAndZoomsWithinTheSong() {
        let viewport = LyricsTimelineViewport()
        viewport.pan(10...14, by: 3, duration: 100)
        #expect(viewport.manual == 13...17)
        viewport.pan(2...6, by: -5, duration: 100)
        #expect(viewport.manual == 0...4)
        viewport.pan(95...99, by: 3, duration: 100)
        #expect(viewport.manual == 96...100)
        viewport.pan(98...102, by: 1, duration: 100)
        #expect(viewport.manual == 98...102)
        viewport.zoom(10...14, by: 0.5, around: 11, duration: 100)
        #expect(viewport.manual == 10.5...12.5)
        viewport.zoom(10...14, by: 0.01, around: 12, duration: 100)
        #expect(viewport.manual == 11.5...12.5)
        viewport.zoom(10...14, by: 100, around: 12, duration: 100)
        #expect(viewport.manual == 0...100)
    }

    @Test func timelineViewportDerivesAnInitialRangeAndRespectsManualPositioning() throws {
        let session = try session("我爱\n你好")
        let viewport = LyricsTimelineViewport()
        #expect(viewport.range(caretLine: nil, in: session) == nil)
        #expect(viewport.range(caretLine: 0, in: session) == 0...4)
        #expect(viewport.range(caretLine: 1, in: session) == 2.5...6.5)
        viewport.manual = 10...14
        #expect(viewport.range(caretLine: 0, in: session) == 10...14)
        viewport.manual = nil
        session.edit { $0.lines[0].syllables = [] }
        #expect(viewport.range(caretLine: 0, in: session) == nil)
        #expect(viewport.range(caretLine: 9, in: session) == nil)
    }

    @Test func theInitialViewStaysFixedWhenTimingChangesAfterSelection() throws {
        let session = try session("[00:02.00]我爱你")
        let viewport = LyricsTimelineViewport()
        viewport.selectionChanged(from: nil, to: 0, in: session)
        let initial = try #require(viewport.range(caretLine: 0, in: session))
        session.tap(at: 2.1)
        session.tap(at: 2.7)
        session.tap(at: 3.1)
        session.release(at: 3.8)
        session.edit { $0.lines[0].start = nil; $0.lines[0].end = nil }
        #expect(viewport.range(caretLine: 0, in: session) == initial)
    }

    @Test func selectingALongerLyricLineKeepsTheInitialViewWidth() throws {
        let session = try session("[00:02.00]我\n[00:03.00]这一行很长\n[01:00.00]再见")
        let viewport = LyricsTimelineViewport()
        let previous = try #require(viewport.range(caretLine: 0, in: session))
        session.selectLine(1)
        viewport.selectionChanged(from: 0, to: 1, in: session)
        let current = try #require(viewport.range(caretLine: 1, in: session))
        #expect(current == previous)
    }
}
