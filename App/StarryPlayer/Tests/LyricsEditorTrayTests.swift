import Foundation
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorTrayTests {
    private func session(_ lines: [LyricsDraft.Line], tracks: [LyricsDraft.Track] = []) -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "tray-test"), title: "Test", artists: [], duration: 60)
        return LyricsEditorSession(track: track, draft: LyricsDraft(lines: lines, tracks: tracks))
    }

    private func placement(_ session: LyricsEditorSession, line: Int = 0, run: Range<Int>) throws -> LyricsTimelinePlacement {
        try #require(LyricsTimelinePlacement(session: session, line: line, run: run, range: 0...10, width: 1_000))
    }

    private func times(_ line: LyricsDraft.Line) -> [[TimeInterval]] {
        line.syllables.map { [$0.start ?? -1, $0.end ?? -1] }
    }

    private func close(_ a: [[TimeInterval]], _ b: [[TimeInterval]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) < 1e-9 } }
    }

    @Test func theTrayHoldsEachLinesRunsOfUntimedSyllables() {
        let lines = [
            LyricsDraft.Line(syllables: [.init(text: "a"), .init(text: "b", start: 1), .init(text: "c"), .init(text: "d")]),
            LyricsDraft.Line(syllables: [.init(text: "e", start: 2)]),
            LyricsDraft.Line(syllables: [.init(text: "f")]),
        ]
        #expect(LyricsTimelineView.untimedRuns(in: lines) == [.init(line: 0, syllables: 0..<1), .init(line: 0, syllables: 2..<4), .init(line: 2, syllables: 0..<1)])
    }

    @Test func anUntimedLineLandsAtThePointerTimedInARow() throws {
        let session = session([.init(syllables: [.init(text: "我"), .init(text: "爱"), .init(text: "你")])])
        let drop = try placement(session, run: 0..<3)
        let line = drop.preview(at: 2.004)
        #expect(close(times(line), [[2, 2.3], [2.3, 2.6], [2.6, 2.9]]))
        #expect(drop.commit(at: 2.004, in: session))
        #expect(session.draft.lines[0] == line)
        #expect(session.caret == .init(line: 0, syllable: 0))
        session.undo()
        #expect(session.draft.timedCount == 0)
    }

    @Test func aRunLandsBetweenTheTimedSyllablesAroundItInItsLine() throws {
        let session = session([.init(syllables: [.init(text: "一", start: 1, end: 1.5), .init(text: "二"), .init(text: "三", start: 3, end: 3.5)])])
        let drop = try placement(session, run: 1..<2)
        #expect(close([times(drop.preview(at: 0.2))[1]], [[1.5, 1.8]]))
        #expect(close([times(drop.preview(at: 9))[1]], [[2.98, 3]]))
        #expect(drop.preview(at: 9).syllables[2] == session.draft.lines[0].syllables[2])
    }

    @Test func aRunSticksToNearbyEdgesAndOnsetsUnlessSnappingIsOff() throws {
        let session = session([.init(syllables: [.init(text: "一")])])
        let drop = try placement(session, run: 0..<1)
        #expect(drop.preview(at: 4.05, edges: [4.1]).syllables[0].start == 4.1)
        #expect(drop.preview(at: 4.05, edges: [4.2]).syllables[0].start == 4.05)
        #expect(drop.preview(at: 4.05, onsets: [4.07]).syllables[0].start == 4.07)
        #expect(drop.preview(at: 4.05).syllables[0].start == 4.05)
    }

    @Test func aFreshLineEndsBeforeTheNextLineOfItsVoiceWhenThereIsRoom() throws {
        let session = session([
            .init(syllables: "一二三四五".map { .init(text: String($0)) }),
            .init(syllables: [.init(text: "对", start: 5.2, end: 7)], singer: .secondary),
            .init(syllables: [.init(text: "六", start: 6, end: 7)]),
        ])
        let drop = try placement(session, run: 0..<5)
        let squeezed = drop.preview(at: 5)
        #expect(squeezed.syllables.first?.start == 5)
        #expect(close([[squeezed.syllables.last!.end!]], [[6]]))
        // Too close to fit: it runs on over the next line rather than shrink to nothing.
        #expect(close([[drop.preview(at: 5.9).syllables.last!.end!]], [[7.4]]))
    }

    @Test func aWholeLRCLineKeepsItsLengthAndLosesItsLineTimingOncePlaced() throws {
        let session = session([.init(syllables: [.init(text: "ab"), .init(text: "cd"), .init(text: "efgh")], start: 10, end: 12)])
        let line = try placement(session, run: 0..<3).preview(at: 20)
        #expect(close(times(line), [[20, 20.5], [20.5, 21], [21, 22]]))
        #expect(line.start == nil)
        #expect(line.end == nil)
        #expect(try placement(session, run: 0..<3).preview(at: 10.04).syllables[0].start == 10)
    }

    @Test func stagedSyllablesComeBackWithTheirLengthsAndGaps() throws {
        let session = session([.init(syllables: [
            .init(text: "我", start: 1, end: 1.5), .init(text: "爱", start: 1.5, end: 2.2), .init(text: "你", start: 2.6, end: 3),
        ], start: 1, end: 3)])
        session.stageLine(0)
        #expect(session.draft.timedCount == 0)
        #expect(session.draft.lines[0].start == nil)
        let drop = try placement(session, run: 0..<3)
        #expect(close(times(drop.preview(at: 10)), [[10, 10.5], [10.5, 11.2], [11.6, 12]]))
        session.undo()
        #expect(session.draft.lines[0].syllables[2].start == 2.6)
        #expect(session.draft.lines[0].start == 1)
    }

    @Test func aSyllableStagedAloneKeepsItsLengthBetweenItsNeighbours() throws {
        let session = session([.init(syllables: [.init(text: "我", start: 1, end: 1.5), .init(text: "爱", start: 1.5, end: 2.2), .init(text: "你", start: 2.6, end: 3)])])
        session.stage([.init(line: 0, syllable: 1)])
        #expect(session.draft.lines[0].syllables.map(\.isTimed) == [true, false, true])
        let drop = try placement(session, run: 1..<2)
        #expect(close([times(drop.preview(at: 1.7))[1]], [[1.7, 2.4]]))
        #expect(close([times(drop.preview(at: 2.2))[1]], [[2.2, 2.6]]))
    }

    @Test func aStalePlacementCannotOverwriteAnotherEdit() throws {
        let session = session([.init(syllables: [.init(text: "我")])])
        let drop = try placement(session, run: 0..<1)
        session.edit { $0.lines[0].translation = "I" }
        #expect(!drop.commit(at: 1, in: session))
        #expect(session.draft.lines[0].translation == "I")
        #expect(session.draft.timedCount == 0)
        #expect(LyricsTimelinePlacement(session: session, line: 0, run: 0..<2, range: 0...10, width: 1_000) == nil)
    }

    @Test func placingALineOntoATrackLaneMovesItThere() throws {
        let track = LyricsDraft.Track(name: "和声")
        let session = session([.init(syllables: [.init(text: "啊")])], tracks: [track])
        #expect(try placement(session, run: 0..<1).commit(at: 3, lane: .track(track.id), in: session))
        #expect(session.draft.lines[0].track == track.id)
    }

    @Test func commandDraggingMovesTheWholeLineAndCanChangeItsTrack() throws {
        let track = LyricsDraft.Track(name: "和声")
        let session = session([.init(syllables: [.init(text: "一", start: 1, end: 2), .init(text: "二", start: 2, end: 3)], start: 1, end: 3)], tracks: [track])
        let drag = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 1), part: .line, range: 0...10, width: 1_000))
        let moved = drag.preview(translation: 50)
        #expect(close(times(moved), [[1.5, 2.5], [2.5, 3.5]]))
        #expect(moved.start == 1.5)
        #expect(moved.end == 3.5)
        #expect(close(times(drag.preview(translation: -1_000)), [[0, 1], [1, 2]]))
        #expect(drag.preview(translation: 20, onsets: [1.23]).syllables[0].start == 1.23)
        #expect(drag.commit(translation: 0, lane: .track(track.id), in: session))
        #expect(session.draft.lines[0].track == track.id)
        #expect(session.draft.lines[0].syllables[0].start == 1)
        let body = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 1), part: .body, range: 0...10, width: 1_000))
        #expect(body.preview(translation: 0, lane: .track(nil)).track == track.id)
    }

    @Test func tracksTakeFreeNamesAndRemovingOneReturnsItsLines() {
        let session = session([.init(syllables: [.init(text: "a", start: 1, end: 2)])])
        let first = session.addTrack(moving: session.draft.lines[0].id)
        #expect(session.draft.lines[0].track == first)
        session.addTrack()
        #expect(session.draft.tracks.map(\.name) == ["轨道 1", "轨道 2"])
        session.removeTrack(first)
        #expect(session.draft.lines[0].track == nil)
        session.addTrack()
        #expect(session.draft.tracks.map(\.name) == ["轨道 2", "轨道 1"])
        session.renameTrack(session.draft.tracks[0].id, to: "和声")
        #expect(session.draft.tracks[0].name == "和声")
        session.undo()
        #expect(session.draft.tracks[0].name == "轨道 2")
    }

    @Test func exportRefusesBackgroundVocalsWithNoLineToBackAndSaysWhere() {
        let session = session([
            .init(syllables: [.init(text: "主", start: 1, end: 2)]),
            .init(syllables: []),
            .init(syllables: [.init(text: "和", start: 1, end: 2)], isBackground: true),
        ])
        #expect(session.exportTTML() == nil)
        #expect(session.caret == .init(line: 2, syllable: 0))
        #expect(session.flashText?.contains("第 3 行是背景人声") == true)
        session.edit { $0.lines.remove(at: 1) }
        #expect(session.exportTTML() != nil)
    }

    @Test func aProjectReopensWithItsTracksUntimedSyllablesAndSongInformation() throws {
        let track = LyricsDraft.Track(name: "和声")
        let source = session([
            .init(syllables: [.init(text: "我", start: 1, end: 2), .init(text: "爱")], track: track.id),
            .init(syllables: [.init(text: "你")], start: 3, end: 4),
        ], tracks: [track])
        source.metadata.append(.init(key: "isrc", value: "X"))
        let target = session([])
        target.open(try LyricsProject(data: source.project.data()))
        #expect(target.draft == source.draft)
        #expect(target.metadata.map(\.key) == source.metadata.map(\.key))
        #expect(target.metadata.map(\.value) == source.metadata.map(\.value))
        #expect(target.projectFileName == "Test.starrylyrics")
        target.undo()
        #expect(target.draft.isEmpty)
    }
}
