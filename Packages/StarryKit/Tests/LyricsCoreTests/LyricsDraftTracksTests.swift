import Foundation
import Testing
@testable import LyricsCore

@Suite struct LyricsDraftTracksTests {
    private func slots(_ draft: LyricsDraft) -> [LyricsDraft.Slot] {
        let lanes = draft.lanes
        return draft.lines.indices.map { draft.slot(ofLine: $0, in: lanes) }
    }

    @Test func linesOnATrackTakeItsLaneAndBackgroundVocalsFollowTheLineTheyBack() {
        let track = LyricsDraft.Track(name: "和声")
        var draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "a")]),
            .init(syllables: [.init(text: "b")], singer: .secondary),
            .init(syllables: [.init(text: "(b)")], isBackground: true),
            .init(syllables: [.init(text: "c")], singer: .duet),
            .init(syllables: [.init(text: "(c)")], isBackground: true),
        ], tracks: [track])
        #expect(draft.lanes == [.lead, .secondary, .track(track.id)])
        #expect(slots(draft) == [.init(lane: 0, background: false), .init(lane: 1, background: false), .init(lane: 1, background: true),
                                 .init(lane: 0, background: false), .init(lane: 0, background: true)])
        draft.lines[3].track = track.id
        draft.lines[2].track = track.id
        #expect(slots(draft) == [.init(lane: 0, background: false), .init(lane: 1, background: false), .init(lane: 2, background: false),
                                 .init(lane: 2, background: false), .init(lane: 2, background: true)])
        draft.lines[1].track = track.id
        #expect(draft.lanes == [.lead, .track(track.id)])
        draft.removeTrack(track.id)
        #expect(draft.lanes == [.lead, .secondary])
        #expect(draft.lines.allSatisfy { $0.track == nil })
    }

    @Test func aLineOnATrackThatIsGoneIsDrawnByItsSinger() {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "b")], singer: .secondary, track: UUID())])
        #expect(draft.lanes == [.lead, .secondary])
        #expect(slots(draft) == [.init(lane: 1, background: false)])
    }

    @Test func overlappingLinesGoOnTracksThatAreReusedOnceFree() {
        func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, background: Bool = false) -> LyricsDraft.Line {
            .init(syllables: [.init(text: text, start: start, end: end)], isBackground: background)
        }
        var draft = LyricsDraft(lines: [
            line("一", 0, 4),
            line("二", 3, 6),
            line("三", 5, 7),
            line("四", 5.5, 8),
            line("五", 7, 9),
            line("（和）", 7.5, 8.5, background: true),
            .init(syllables: [.init(text: "未打点")]),
        ])
        let moved = draft.separateOverlaps { LyricsDraft.Track(name: "轨道 \($0.count + 1)") }
        #expect(moved == 2)
        #expect(draft.tracks.map(\.name) == ["轨道 1", "轨道 2"])
        let (first, second) = (draft.tracks[0].id, draft.tracks[1].id)
        #expect(draft.lines.map(\.track) == [nil, first, nil, second, nil, nil, nil])
        #expect(draft.separateOverlaps { _ in LyricsDraft.Track(name: "多余") } == 0)
        #expect(draft.tracks.count == 2)
    }

    @Test func aFreeTrackIsReusedBeforeANewOneIsMade() {
        let track = LyricsDraft.Track(name: "和声")
        var draft = LyricsDraft(lines: [
            .init(syllables: [.init(text: "一", start: 0, end: 4)]),
            .init(syllables: [.init(text: "二", start: 1, end: 2)]),
        ], tracks: [track])
        #expect(draft.separateOverlaps { _ in LyricsDraft.Track(name: "新") } == 1)
        #expect(draft.tracks == [track])
        #expect(draft.lines[1].track == track.id)
    }

    @Test func movedSyllablesTakeTheirLinesTrack() {
        let track = LyricsDraft.Track(name: "和声")
        var draft = LyricsDraft(lines: [.init(syllables: [.init(text: "一"), .init(text: "二")], track: track.id)], tracks: [track])
        let index = draft.moveSyllablesToNewLine([.init(line: 0, syllable: 1)])
        #expect(index == 1)
        #expect(draft.lines[1].track == track.id)
    }
}
