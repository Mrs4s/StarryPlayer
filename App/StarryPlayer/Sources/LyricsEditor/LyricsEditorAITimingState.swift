import Foundation
import LyricsCore
import LyricsSync
import Observation

@MainActor @Observable
final class LyricsEditorAITimingState {
    struct Configuration: Equatable, Sendable {
        var directory: URL
        var backend: LyricsAIBackend
        var resplitSyllables = false
        var englishSplit: LyricsAIEnglishSplit = .automatic
    }
    struct Request: Sendable {
        var draft: LyricsDraft
        var audio: URL
        var configuration: Configuration
    }
    struct ModelInfo: Sendable {
        var name: String
        var hasEnglishReadings: Bool
    }
    typealias Work = @Sendable (Request, @escaping @Sendable (LyricsAIProgress) -> Void) async throws -> LyricsAIAlignmentResult

    private(set) var modelInfo: ModelInfo?
    private(set) var modelError: String?
    private(set) var isCheckingModel = false
    private(set) var isWorking = false
    private(set) var isCancelling = false
    private(set) var progress = LyricsAIProgress(0, "")
    private(set) var result: LyricsAIAlignmentResult?
    private(set) var original: LyricsDraft?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var retimedLines: [UUID] = []
    var selection: Set<UUID> = []
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var modelRequest = UUID()
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var completed: (configuration: Configuration, revision: Int, audio: String)?
    @ObservationIgnored private var validatedDirectory: URL?
    private let worker: LyricsAIAligner
    private let perform: Work

    init(work: Work? = nil) {
        let worker = LyricsAIAligner()
        self.worker = worker
        perform = work ?? { request, progress in
            try await worker.align(request.draft, vocals: request.audio,
                                   modelDirectory: request.configuration.directory,
                                   backend: request.configuration.backend, englishSplit: request.configuration.englishSplit, progress: progress)
        }
    }

    func validate(_ directory: URL?) {
        invalidate()
        modelTask?.cancel()
        modelRequest = UUID()
        modelInfo = nil; modelError = nil; validatedDirectory = nil
        guard let directory else { isCheckingModel = false; return }
        let id = modelRequest
        isCheckingModel = true
        modelTask = Task { [weak self] in
            let task = Task.detached(priority: .userInitiated) {
                let bundle = try LyricsAIModelBundle.load(from: directory)
                return ModelInfo(name: bundle.name, hasEnglishReadings: !bundle.englishReadings.isEmpty)
            }
            do {
                let info = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.modelRequest == id, !Task.isCancelled else { return }
                self.modelInfo = info
                self.validatedDirectory = directory
                self.isCheckingModel = false
                self.modelTask = nil
            } catch {
                guard let self, self.modelRequest == id, !Task.isCancelled else { return }
                self.modelError = error.localizedDescription
                self.isCheckingModel = false
                self.modelTask = nil
            }
        }
    }

    func isModelReady(at directory: URL?) -> Bool { directory != nil && validatedDirectory == directory && modelInfo != nil }

    func invalidate() {
        cancel()
        result = nil; completed = nil; original = nil; error = nil; notice = nil
        retimedLines = []; selection = []
    }

    func cancel() {
        guard isWorking else { return }
        isCancelling = true
        progress = LyricsAIProgress(progress.fraction, "正在停止…")
        workTask?.cancel()
    }

    func dispose() {
        cancel()
        modelTask?.cancel()
        modelRequest = UUID()
        let worker = worker
        Task { await worker.releaseWhenIdle() }
    }

    func start(configuration: Configuration, in session: LyricsEditorSession,
               prepareAudio: @escaping @MainActor () async throws -> LyricsEditorAudio.AIAlignmentSource,
               currentAudioIdentity: @escaping @MainActor () -> String) {
        guard !isWorking else { return }
        let draft = session.draft, revision = session.revision
        guard !draft.isEmpty else { error = "请先导入歌词。"; return }
        request = UUID()
        let id = request, perform = perform
        result = nil; completed = nil; error = nil; notice = nil
        retimedLines = []; selection = []
        original = draft
        isWorking = true; isCancelling = false
        progress = .init(0, "准备人声…")
        workTask = Task { [weak self] in
            do {
                let audio = try await prepareAudio()
                try Task.checkCancellation()
                guard session.revision == revision else { throw LyricsAIError.alignment("歌词已改变，请重新打轴") }
                var input = draft
                if configuration.resplitSyllables {
                    for index in input.lines.indices where !input.lines[index].isBackground {
                        input.lines[index].resplitSyllables()
                    }
                }
                let result = try await perform(Request(draft: input, audio: audio.file, configuration: configuration)) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.request == id, self.isWorking, !self.isCancelling else { return }
                        self.progress = progress
                    }
                }
                try Task.checkCancellation()
                guard let self, self.request == id else { return }
                guard session.revision == revision, currentAudioIdentity() == audio.identity else {
                    throw LyricsAIError.alignment("歌词或人声已改变，请重新打轴")
                }
                self.result = result
                self.retimedLines = zip(draft.lines, result.draft.lines).filter { $0.0 != $0.1 }.map { $0.1.id }
                self.selection = Set(self.retimedLines)
                self.completed = (configuration, revision, audio.identity)
                self.progress = .init(1, "打轴完成，请试听后应用")
                self.finish()
            } catch {
                guard let self, self.request == id else { return }
                if Task.isCancelled || error is CancellationError { self.notice = "已停止，歌词没有改变" }
                else { self.error = error.localizedDescription }
                self.finish()
            }
        }
    }

    private func finish() {
        isWorking = false; isCancelling = false; workTask = nil
    }

    func canApply(in session: LyricsEditorSession, configuration: Configuration?, audioIdentity: String) -> Bool {
        guard let completed, let result, !isWorking, completed.configuration == configuration,
              completed.revision == session.revision, completed.audio == audioIdentity else { return false }
        return original?.lines.map(\.id) == session.draft.lines.map(\.id)
            && result.draft.lines.map(\.id) == session.draft.lines.map(\.id)
    }

    @discardableResult
    func apply(in session: LyricsEditorSession, configuration: Configuration?, audioIdentity: String) -> Bool {
        guard canApply(in: session, configuration: configuration, audioIdentity: audioIdentity), let result else {
            error = "歌词、模型设置或音频已改变，请重新打轴。"
            return false
        }
        let lines = selection.intersection(retimedLines)
        guard !lines.isEmpty else {
            error = "请至少选择一行。"
            return false
        }
        var draft = session.draft
        for index in draft.lines.indices where lines.contains(draft.lines[index].id) {
            draft.lines[index] = result.draft.lines[index]
        }
        session.edit { $0 = draft }
        session.flash("已应用 \(lines.count) 行 AI 时间，请试听复核，可用 ⌘Z 撤销")
        self.result = nil; completed = nil
        retimedLines = []; selection = []
        return true
    }
}
