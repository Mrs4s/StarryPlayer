import AudioProcessing
import Foundation
import LyricsCore
import LyricsSync
import Observation

@MainActor @Observable
final class LyricsEditorAlignmentState {
    struct Input: Equatable, Sendable {
        var range: ClosedRange<TimeInterval>
        var mode: LyricsLineAligner.Mode
        var language: LyricsTimingWeights.Language
        var maximumAdjustment: TimeInterval
        var voice: LyricsEditorAudio.HintVoice
    }

    let original: LyricsDraft.Line
    let revision: Int
    let duration: TimeInterval
    let suggestedRange: ClosedRange<TimeInterval>?
    var start: String
    var end: String
    var mode: LyricsLineAligner.Mode
    var language = LyricsTimingWeights.Language.automatic
    var maximumAdjustment: TimeInterval = 0.35
    var voice = LyricsEditorAudio.HintVoice.all
    private(set) var result: LyricsLineAligner.Result?
    private(set) var isWorking = false
    private(set) var error: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var completedInput: Input?

    init(line: LyricsDraft.Line, revision: Int, duration: TimeInterval, playhead: TimeInterval) {
        original = line
        self.revision = revision
        self.duration = duration
        if let range = line.timedRange, range.upperBound > range.lowerBound {
            suggestedRange = range
        } else if let start = line.start, start < duration {
            suggestedRange = start...duration
        } else {
            suggestedRange = nil
        }
        let timed = line.syllables.contains(where: \.isTimed)
        mode = timed ? .calibrate : .arrange
        let lower = max(0, (line.timedRange?.lowerBound ?? playhead) - (timed ? 0.35 : 0))
        let fallbackEnd = lower + max(2, Double(line.syllables.count) * 0.4)
        let originalEnd = line.timedRange?.upperBound
        let inferredEnd = !timed && line.start != nil && line.end == nil ? duration
            : (originalEnd.flatMap { $0 > lower + 0.02 ? $0 : nil } ?? fallbackEnd)
        let upper = min(duration, inferredEnd + (timed ? 0.35 : 0))
        start = LyricsEditorFormat.time(lower, digits: 3)
        end = LyricsEditorFormat.time(upper, digits: 3)
    }

    var input: Input? {
        guard let lower = LyricsEditorFormat.seconds(from: start), let upper = LyricsEditorFormat.seconds(from: end),
              lower.isFinite, upper.isFinite, lower >= 0, upper <= duration, upper > lower,
              upper - lower >= Double(original.syllables.count) * 0.02, !original.syllables.isEmpty else { return nil }
        return Input(range: lower...upper, mode: mode, language: language, maximumAdjustment: maximumAdjustment, voice: voice)
    }

    func invalidate() {
        cancel()
        result = nil
        completedInput = nil
        error = nil
    }

    func cancel() {
        request = UUID()
        work?.cancel()
        work = nil
        isWorking = false
    }

    func analyze(applyingTo session: LyricsEditorSession? = nil,
                 using analyze: @escaping @MainActor (Input) async throws -> VocalOnsetDetector.Analysis) {
        invalidate()
        guard let input else {
            let message = "请填写有效的行范围，结束时间不能超过歌曲时长。"
            error = message
            session?.flash(message)
            return
        }
        let id = request
        let line = original
        isWorking = true
        session?.flash("正在准备人声并自动排字…")
        work = Task { [weak self] in
            do {
                let analysis = try await analyze(input)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try LyricsLineAligner.align(line, in: input.range, analysis: analysis, mode: input.mode,
                                               language: input.language, maximumAdjustment: input.maximumAdjustment)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.request == id, self.input == input, !Task.isCancelled else { return }
                self.result = result
                self.completedInput = input
                self.isWorking = false
                self.work = nil
                if let session, !self.apply(in: session) {
                    session.flash("歌词已改变，本次自动排字结果未应用")
                }
            } catch {
                guard let self, self.request == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.isWorking = false
                self.work = nil
                session?.flash("自动排字未能完成：\(error.localizedDescription)")
            }
        }
    }

    func canApply(in session: LyricsEditorSession) -> Bool {
        result != nil && completedInput == input && !isWorking && session.revision == revision
            && session.draft.lines.contains(original)
    }

    @discardableResult
    func apply(in session: LyricsEditorSession) -> Bool {
        guard canApply(in: session), let result,
              let index = session.draft.lines.firstIndex(where: { $0.id == original.id }) else {
            error = "歌词或设置已改变，请关闭后重新打开自动排字。"
            return false
        }
        session.edit { $0.lines[index] = result.line }
        session.flash(result.estimatedCount == 0 ? "已对齐当前行，请试听复核，可撤销"
                      : "已对齐当前行，\(result.estimatedCount) 个音节的起点为估计，请复核，可撤销")
        return true
    }
}

@MainActor
final class LyricsEditorAutoAlignment {
    private struct Job {
        var id: UUID
        var task: Task<Void, Never>
    }
    private var jobs: [UUID: Job] = [:]
    var pendingCount: Int { jobs.count }

    func cancelAll() {
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
    }

    func schedule(lineID: UUID, in session: LyricsEditorSession, duration: TimeInterval, endedByNextLine: Bool = false,
                  analyze: @escaping @MainActor (ClosedRange<TimeInterval>) async throws -> VocalOnsetDetector.Analysis) {
        guard let original = session.draft.lines.first(where: { $0.id == lineID }),
              LyricsEditorSession.hasCompleteTiming(original), duration.isFinite, duration > 0 else { return }
        let starts = original.syllables.compactMap(\.start), ends = original.syllables.compactMap(\.end)
        guard let first = starts.min(), let last = ends.max() else { return }
        let lower = max(0, first - 0.35), upper = min(duration, last + (endedByNextLine ? 0 : 0.35))
        guard upper - lower >= Double(original.syllables.count) * 0.02 else { return }
        let range = lower...upper
        var source = original
        if endedByNextLine {
            // The next line's tap may follow a pause; infer the preceding release from audio.
            source.syllables[source.syllables.count - 1].end = nil
            source.end = nil
        }
        let alignmentSource = source
        let epoch = session.historyEpoch
        let id = UUID()
        jobs[lineID]?.task.cancel()
        let task = Task { [weak self, weak session] in
            defer {
                if self?.jobs[lineID]?.id == id { self?.jobs[lineID] = nil }
            }
            do {
                try Task.checkCancellation()
                let analysis = try await analyze(range)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .utility) {
                    try LyricsLineAligner.align(alignmentSource, in: range, analysis: analysis, mode: .calibrate)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, let session, !Task.isCancelled, self.jobs[lineID]?.id == id,
                      session.historyEpoch == epoch,
                      let index = session.draft.lines.firstIndex(where: { $0.id == lineID }),
                      session.draft.lines[index] == original else { return }
                guard result.matchedCount > 0 else { return }
                guard result.line != original else { return }
                session.edit { $0.lines[index] = result.line }
                session.flash("第 \(index + 1) 行已自动校准，可撤销")
            } catch {
                guard let self, let session, !Task.isCancelled, self.jobs[lineID]?.id == id,
                      session.historyEpoch == epoch,
                      session.draft.lines.contains(original) else { return }
                session.flash("自动排字未能完成，已保留人工打点")
            }
        }
        jobs[lineID] = Job(id: id, task: task)
    }
}
