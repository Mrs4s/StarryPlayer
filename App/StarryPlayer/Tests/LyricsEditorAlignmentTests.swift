import AudioProcessing
import Foundation
import LyricsCore
import LyricsSync
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor @Suite struct LyricsEditorAlignmentTests {
    private func session(_ text: String = "[00:02.00]我爱你\n[00:05.00]再见") throws -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "alignment-test"), title: "Alignment", artists: [], album: nil, duration: 20)
        return LyricsEditorSession(track: track, draft: try LyricsDraftImport.draft(from: text))
    }

    private func evidence(_ times: [Double] = [2.05, 2.65, 3.9]) -> VocalOnsetDetector.Analysis {
        VocalOnsetDetector.Analysis(onsets: times.map { VocalOnset(time: $0, strength: 0.9) },
                                    activity: VocalActivity(frameCount: 0), frameDuration: 0.01, centerOffset: 0)
    }

    private func wait(_ state: LyricsEditorAlignmentState) async throws {
        for _ in 0..<200 where state.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!state.isWorking)
    }

    private func wait(_ automatic: LyricsEditorAutoAlignment) async throws {
        for _ in 0..<200 where automatic.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(automatic.pendingCount == 0)
    }

    private func manuallyTimedSession() throws -> LyricsEditorSession {
        let session = try session()
        session.tap(at: 2.1)
        session.tap(at: 2.7)
        session.tap(at: 4)
        session.release(at: 4.8)
        return session
    }

    @Test func lrcRangeIsUsedAndPreviewDoesNotChangeTheDraftUntilApplied() async throws {
        let session = try session()
        let before = session.draft
        let state = LyricsEditorAlignmentState(line: before.lines[0], revision: session.revision, duration: 20, playhead: 10)
        #expect(state.input?.range == 2...5)
        #expect(state.mode == .arrange)
        state.analyze { _ in evidence() }
        try await wait(state)
        try #require(state.result != nil)
        #expect(session.draft == before)
        #expect(state.canApply(in: session))
        #expect(state.apply(in: session))
        #expect(session.draft.lines[0].syllables.map(\.start) == [2.05, 2.65, 3.9])
        #expect(session.draft.lines[1] == before.lines[1])
        let applied = session.draft
        session.undo()
        #expect(session.draft == before)
        session.redo()
        #expect(session.draft == applied)
    }

    @Test func importedSyllableTimingDefaultsToCalibrationAndAPaddedSearchRange() throws {
        let session = try session()
        session.tap(at: 2.2)
        session.tap(at: 3.2)
        session.tap(at: 4.2)
        session.release(at: 5)
        session.edit { $0.lines[0].start = nil; $0.lines[0].end = nil }
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 0)
        #expect(state.mode == .calibrate)
        #expect(abs(state.input!.range.lowerBound - 1.85) < 0.001)
        #expect(abs(state.input!.range.upperBound - 5.35) < 0.001)
    }

    @Test(arguments: [false, true])
    func quickAlignmentAppliesAndCanBeUndone(timed: Bool) async throws {
        let session = try timed ? manuallyTimedSession() : session()
        let before = session.draft
        let state = LyricsEditorAlignmentState(line: before.lines[0], revision: session.revision, duration: 20, playhead: 10)
        state.analyze(applyingTo: session) { _ in evidence() }
        try await wait(state)
        #expect(session.draft.lines[0].syllables.map(\.start) == [2.05, 2.65, 3.9])
        session.undo()
        #expect(session.draft == before)
    }

    @Test(arguments: [false, true])
    func quickAlignmentCannotOverwriteEditsEvenAfterUndo(undoesEdit: Bool) async throws {
        let session = try session()
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 0)
        let gate = Gate()
        state.analyze(applyingTo: session) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        session.edit { $0.lines[0].translation = "edited during analysis" }
        if undoesEdit { session.undo() }
        let before = session.draft
        gate.finish(evidence())
        try await wait(state)
        #expect(session.draft == before)
        #expect(state.error != nil)
        #expect(session.flashText == "歌词已改变，本次自动排字结果未应用")
    }

    @Test func failedQuickAlignmentPreservesTimingAndReportsTheError() async throws {
        let session = try manuallyTimedSession()
        let before = session.draft
        let state = LyricsEditorAlignmentState(line: before.lines[0], revision: session.revision, duration: 20, playhead: 0)
        state.analyze(applyingTo: session) { _ in throw CocoaError(.fileReadNoSuchFile) }
        try await wait(state)
        #expect(session.draft == before)
        #expect(state.error != nil)
        #expect(session.flashText?.hasPrefix("自动排字未能完成：") == true)
    }

    @Test func lastLrcLineWithoutAnEndCanUseTheSongEnding() throws {
        let session = try session("[00:12.00]星空很美")
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 0)
        #expect(state.input?.range == 12...20)
        #expect(state.suggestedRange == 12...20)
    }

    @Test func changingTheDraftOrOptionsPreventsAnOldPreviewFromBeingApplied() async throws {
        let session = try session()
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 0)
        state.analyze { _ in evidence() }
        try await wait(state)
        #expect(state.canApply(in: session))
        state.language = .japanese
        #expect(!state.canApply(in: session))
        state.language = .automatic
        session.edit { $0.lines[0].translation = "changed while analyzing" }
        #expect(!state.apply(in: session))
        #expect(session.draft.lines[0].syllables.allSatisfy { $0.start == nil })
    }

    @Test(arguments: [false, true])
    func cancelledAnalysisCannotRestoreAPreviewOrChangeTheDraft(appliesAutomatically: Bool) async throws {
        let session = try session()
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 0)
        let gate = Gate()
        state.analyze(applyingTo: appliesAutomatically ? session : nil) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        state.cancel()
        gate.finish(evidence())
        for _ in 0..<10 { await Task.yield() }
        #expect(state.result == nil)
        #expect(!state.canApply(in: session))
        #expect(session.draft.lines[0].syllables.allSatisfy { $0.start == nil })
    }

    @Test func manualRangesAreValidatedBeforeAudioWork() async throws {
        let session = try session("我爱你")
        let state = LyricsEditorAlignmentState(line: session.draft.lines[0], revision: session.revision, duration: 20, playhead: 7)
        #expect(state.input?.range.lowerBound == 7)
        state.start = "00:08.000"
        state.end = "00:10.000"
        #expect(state.input?.range == 8...10)
        state.end = "00:21.000"
        var invoked = false
        state.analyze { _ in invoked = true; return evidence() }
        #expect(!invoked)
        #expect(state.input == nil && state.error != nil && !state.isWorking)
        state.end = "invalid"
        #expect(state.input == nil)
    }

    @Test func automaticCalibrationCanFinishWhileTheUserKeepsTappingTheNextLine() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), gate = Gate()
        automatic.schedule(lineID: session.draft.lines[0].id, in: session, duration: 20) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        session.tap(at: 5.2)
        session.tap(at: 5.8)
        let manual = session.draft, caret = session.caret
        gate.finish(evidence())
        try await wait(automatic)
        #expect(session.draft.lines[0].syllables.map(\.start) == [2.05, 2.65, 3.9])
        #expect(session.draft.lines[1] == manual.lines[1])
        #expect(session.caret == caret)
        session.undo()
        #expect(session.draft == manual)
    }

    @Test func automaticResultsCannotOverwriteARetappedLine() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), gate = Gate()
        automatic.schedule(lineID: session.draft.lines[0].id, in: session, duration: 20) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        session.select(.init(line: 0, syllable: 0))
        session.tap(at: 2.3)
        let edited = session.draft
        gate.finish(evidence())
        try await wait(automatic)
        #expect(session.draft == edited)
    }

    @Test func undoInvalidatesAutomaticWorkEvenIfTheOriginalLineIsRestored() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), gate = Gate()
        automatic.schedule(lineID: session.draft.lines[0].id, in: session, duration: 20) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        let before = session.draft
        session.edit { $0.lines[1].translation = "temporary" }
        session.undo()
        #expect(session.draft == before)
        gate.finish(evidence())
        try await wait(automatic)
        #expect(session.draft == before)
    }

    @Test func disablingAutomaticAlignmentDiscardsItsLateResult() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), gate = Gate()
        automatic.schedule(lineID: session.draft.lines[0].id, in: session, duration: 20) { _ in await gate.read() }
        while !gate.started { await Task.yield() }
        let before = session.draft
        automatic.cancelAll()
        gate.finish(evidence())
        for _ in 0..<20 { await Task.yield() }
        #expect(automatic.pendingCount == 0)
        #expect(session.draft == before)
    }

    @Test func twoCompletedLinesCanBeCalibratedWithoutInvalidatingEachOther() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), first = Gate(), second = Gate()
        automatic.schedule(lineID: session.draft.lines[0].id, in: session, duration: 20) { _ in await first.read() }
        session.tap(at: 5.2)
        session.tap(at: 5.8)
        session.release(at: 6.4)
        automatic.schedule(lineID: session.draft.lines[1].id, in: session, duration: 20) { _ in await second.read() }
        while !first.started || !second.started { await Task.yield() }
        #expect(automatic.pendingCount == 2)
        second.finish(evidence([5.1, 5.7]))
        first.finish(evidence())
        try await wait(automatic)
        #expect(session.draft.lines[0].syllables.map(\.start) == [2.05, 2.65, 3.9])
        #expect(session.draft.lines[1].syllables.map(\.start) == [5.1, 5.7])
    }

    @Test func aNewManualPassReplacesTheOldAttemptForThatLine() async throws {
        let session = try manuallyTimedSession()
        let automatic = LyricsEditorAutoAlignment(), first = Gate(), second = Gate()
        let id = session.draft.lines[0].id
        automatic.schedule(lineID: id, in: session, duration: 20) { _ in await first.read() }
        while !first.started { await Task.yield() }
        session.select(.init(line: 0, syllable: 0))
        session.tap(at: 2.2)
        session.tap(at: 2.8)
        session.tap(at: 4.1)
        #expect(session.release(at: 4.9) == id)
        automatic.schedule(lineID: id, in: session, duration: 20) { _ in await second.read() }
        while !second.started { await Task.yield() }
        first.finish(evidence())
        for _ in 0..<20 { await Task.yield() }
        #expect(automatic.pendingCount == 1)
        second.finish(evidence([2.15, 2.75, 4]))
        try await wait(automatic)
        #expect(session.draft.lines[0].syllables.map(\.start) == [2.15, 2.75, 4])
    }

    @Test(arguments: [false, true])
    func completionByTheNextLineDoesNotCrossThatLineOrIncludeThePause(hasPause: Bool) async throws {
        let session = try session()
        session.tap(at: 2.1)
        session.tap(at: 2.7)
        session.tap(at: 4)
        let completed = try #require(session.tap(at: 6.1))
        let nextLine = session.draft.lines[1]
        var activity = VocalActivity(frameCount: 700)
        activity.energy = .init(repeating: -100, count: 700)
        activity.valid = .init(repeating: true, count: 700)
        for frame in 200...(hasPause ? 470 : 640) { activity.energy[frame] = -15 }
        for frame in 610...640 { activity.energy[frame] = -15 }
        let analysis = VocalOnsetDetector.Analysis(onsets: [2.05, 2.65, 3.9, 6.1].map { .init(time: $0, strength: 0.9) },
                                                  activity: activity, frameDuration: 0.01, centerOffset: 0)
        let automatic = LyricsEditorAutoAlignment()
        automatic.schedule(lineID: completed, in: session, duration: 20, endedByNextLine: true) { _ in analysis }
        try await wait(automatic)
        #expect(session.draft.lines[0].syllables.last!.end! <= 6.1)
        if hasPause { #expect(session.draft.lines[0].syllables.last!.end! < 4.8) }
        #expect(session.draft.lines[1] == nextLine)
    }

    @MainActor private final class Gate {
        var started = false
        var continuation: CheckedContinuation<VocalOnsetDetector.Analysis, Never>?
        func read() async -> VocalOnsetDetector.Analysis {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ analysis: VocalOnsetDetector.Analysis) {
            continuation?.resume(returning: analysis)
            continuation = nil
        }
    }
}
