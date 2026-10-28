import Foundation
import LyricsCore
import LyricsSync
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor @Suite struct LyricsEditorAITimingTests {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting = false
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    private func session() -> LyricsEditorSession {
        LyricsEditorSession(track: Track(id: TrackRef(source: .local, id: "ai-editor-test"), title: "AI fixture", artists: [], duration: 10),
                            draft: LyricsDraft(lines: [.init(syllables: [.init(text: "あ"), .init(text: "い")], translation: "keep")]))
    }
    private var configuration: LyricsEditorAITimingState.Configuration {
        .init(directory: URL(fileURLWithPath: "/unused-model-fixture"), backend: .neuralEngine)
    }
    private var source: LyricsEditorAudio.AIAlignmentSource {
        .init(file: URL(fileURLWithPath: "/unused-audio-fixture.wav"), identity: "audio-one")
    }
    private nonisolated static func aligned(_ original: LyricsDraft) -> LyricsAIAlignmentResult {
        var draft = original
        for i in draft.lines[0].syllables.indices {
            draft.lines[0].syllables[i].start = Double(i + 1)
            draft.lines[0].syllables[i].end = Double(i + 2)
        }
        return .init(draft: draft, alignedLines: 1, alignedSyllables: draft.lines[0].syllables.count)
    }
    private func wait(_ state: LyricsEditorAITimingState) async throws {
        for _ in 0..<200 where state.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!state.isWorking)
    }
    private func wait(_ gate: Gate) async throws {
        for _ in 0..<200 {
            if await gate.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Work did not reach its gate")
    }

    @Test func previewDoesNotMutateLyricsAndApplyIsOneUndoableEdit() async throws {
        let session = session(), before = session.draft
        let state = LyricsEditorAITimingState { request, _ in Self.aligned(request.draft) }
        let source = source
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(state)
        #expect(session.draft == before)
        #expect(!session.canUndo)
        let expected = try #require(state.result).draft
        #expect(state.apply(in: session, configuration: configuration, audioIdentity: source.identity))
        #expect(session.draft == expected)
        session.undo()
        #expect(session.draft == before)
        #expect(!session.canUndo)
        session.redo()
        #expect(session.draft == expected)
        #expect(session.draft.lines[0].translation == "keep")
    }

    @Test func cancelledWorkCannotPublishEvenWhenTheWorkerReturnsAResult() async throws {
        let gate = Gate(), session = session(), before = session.draft
        let state = LyricsEditorAITimingState { request, _ in await gate.wait(); return Self.aligned(request.draft) }
        let source = source
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(gate)
        state.cancel()
        #expect(state.isCancelling)
        await gate.open()
        try await wait(state)
        #expect(state.result == nil)
        #expect(state.notice != nil)
        #expect(session.draft == before)
        #expect(!session.canUndo)
    }

    @Test func editsDuringInferenceInvalidateTheSnapshot() async throws {
        let gate = Gate(), session = session()
        let state = LyricsEditorAITimingState { request, _ in await gate.wait(); return Self.aligned(request.draft) }
        let source = source
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(gate)
        session.edit { $0.lines[0].translation = "new edit" }
        let edited = session.draft
        await gate.open()
        try await wait(state)
        #expect(state.result == nil)
        #expect(state.error != nil)
        #expect(session.draft == edited)
    }

    @Test func previewRejectsChangedBackendAudioAndUndoHistory() async throws {
        let session = session(), source = source
        let state = LyricsEditorAITimingState { request, _ in Self.aligned(request.draft) }
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(state)
        #expect(state.canApply(in: session, configuration: configuration, audioIdentity: source.identity))
        var changed = configuration; changed.backend = .gpu
        #expect(!state.canApply(in: session, configuration: changed, audioIdentity: source.identity))
        changed = configuration; changed.englishSplit = .word
        #expect(!state.canApply(in: session, configuration: changed, audioIdentity: source.identity))
        #expect(!state.canApply(in: session, configuration: configuration, audioIdentity: "different-audio"))
        session.edit { $0.lines[0].translation = "temporary" }
        session.undo()
        #expect(!state.apply(in: session, configuration: configuration, audioIdentity: source.identity))
        #expect(session.draft.timedCount == 0)
    }

    @Test(arguments: [false, true])
    func optionalResplittingPreservesBackgroundAndLeavesDraftUntouched(enabled: Bool) async throws {
        let session = twoLineSession(), source = source
        session.edit {
            $0.lines[0].syllables = [.init(text: "你好")]
            $0.lines[1] = .init(syllables: [.init(text: "背景", start: 8, end: 9)], isBackground: true)
        }
        let before = session.draft
        var configuration = configuration
        configuration.resplitSyllables = enabled
        let state = LyricsEditorAITimingState { request, _ in Self.aligned(request.draft) }
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(state)
        let result = try #require(state.result)
        #expect(result.draft.lines[0].syllables.map(\.text) == (enabled ? ["你", "好"] : ["你好"]))
        #expect(result.draft.lines[1] == before.lines[1])
        #expect(session.draft == before)
    }

    private func twoLineSession() -> LyricsEditorSession {
        LyricsEditorSession(track: Track(id: TrackRef(source: .local, id: "ai-editor-partial"), title: "AI fixture", artists: [], duration: 10),
                            draft: LyricsDraft(lines: [.init(syllables: [.init(text: "あ")]), .init(syllables: [.init(text: "い")])]))
    }
    private nonisolated static func alignedEveryLine(_ original: LyricsDraft) -> LyricsAIAlignmentResult {
        var draft = original
        for i in draft.lines.indices {
            draft.lines[i].syllables[0].start = Double(i + 1)
            draft.lines[i].syllables[0].end = Double(i + 2)
        }
        return .init(draft: draft, alignedLines: draft.lines.count, alignedSyllables: draft.lines.count)
    }

    @Test func applyWritesOnlyTheSelectedLinesAsOneUndoableEdit() async throws {
        let session = twoLineSession(), before = session.draft, source = source
        let state = LyricsEditorAITimingState { request, _ in Self.alignedEveryLine(request.draft) }
        state.start(configuration: configuration, in: session, prepareAudio: { source }, currentAudioIdentity: { source.identity })
        try await wait(state)
        let result = try #require(state.result)
        #expect(state.retimedLines == before.lines.map(\.id))
        #expect(state.selection == Set(before.lines.map(\.id)))
        state.selection = []
        #expect(!state.apply(in: session, configuration: configuration, audioIdentity: source.identity))
        #expect(session.draft == before)
        #expect(!session.canUndo)
        #expect(state.result != nil)
        state.selection = [before.lines[1].id]
        #expect(state.apply(in: session, configuration: configuration, audioIdentity: source.identity))
        #expect(session.draft.lines[0] == before.lines[0])
        #expect(session.draft.lines[1] == result.draft.lines[1])
        #expect(state.selection.isEmpty)
        session.undo()
        #expect(session.draft == before)
        #expect(!session.canUndo)
    }
}
