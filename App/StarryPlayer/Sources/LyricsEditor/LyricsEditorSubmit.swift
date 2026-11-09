import AppKit
import LyricsCore
import LyricsProviders
import Observation
import SwiftUI

// MARK: - State

/// Kept on the session, so a submission keeps going and its form survives while other panels are open.
@MainActor @Observable
final class LyricsEditorSubmitState {
    enum Account: Equatable {
        case unknown, loading
        case ready(AMLLSubmission.Author)
        case failed(String)
    }

    enum Phase: Equatable {
        case editing
        case submitting(AMLLPullRequest.Step)
        case failed(String)
        case done(AMLLPullRequest.Result)
    }

    private(set) var account: Account = .unknown
    private(set) var phase: Phase = .editing
    private(set) var reason: AMLLSubmission.Reason = .new
    var title = ""
    var remarks = ""
    var readGuide = false
    private(set) var problems: [AMLLSubmission.Problem] = []
    private(set) var exportIssue: LyricsDraft.ExportIssue?
    private(set) var submitted: AMLLPullRequest.Result?
    @ObservationIgnored private var ttml: String?

    var isSubmitting: Bool {
        if case .submitting = phase { true } else { false }
    }

    var canSubmit: Bool {
        guard case .ready = account, !isSubmitting, readGuide, ttml != nil, exportIssue == nil, problems.isEmpty else { return false }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func prepare(_ session: LyricsEditorSession) {
        if title.isEmpty { title = AMLLSubmission.title(metadata: session.exportMetadata, reason: reason) }
        if case .failed = phase { phase = .editing }
        refresh(session)
        switch account {
        case .unknown, .failed: Task { await loadAccount() }
        case .loading, .ready: break
        }
    }

    func choose(_ reason: AMLLSubmission.Reason) {
        self.reason = reason
        title = AMLLSubmission.retag(title, as: reason)
    }

    /// Validate the exported TTML rather than the editable draft.
    func refresh(_ session: LyricsEditorSession) {
        let draft = session.draft
        exportIssue = draft.firstExportIssue
        do {
            let text = try session.writeLyrics(format: .ttml).text
            ttml = text
            problems = AMLLSubmission.problems(ttml: text, metadata: session.exportMetadata, untimedSyllables: draft.syllableCount - draft.timedCount)
        } catch {
            ttml = nil
            problems = [.unreadable(error.localizedDescription)]
        }
    }

    func loadAccount() async {
        guard let client = Self.client() else {
            account = .failed(GitHubError.cliMissing.localizedDescription)
            return
        }
        account = .loading
        do {
            account = .ready(try await client.account())
        } catch {
            account = .failed(error.localizedDescription)
        }
    }

    func submit(_ session: LyricsEditorSession) async {
        guard canSubmit, case .ready(let author) = account, let client = Self.client() else { return }
        session.credit(author)
        refresh(session)
        guard let ttml, problems.isEmpty, exportIssue == nil else { return }
        phase = .submitting(.forking)
        let submission = AMLLPullRequest.Submission(ttml: ttml, title: title.trimmingCharacters(in: .whitespaces),
                                                    metadata: session.exportMetadata, remarks: remarks)
        do {
            let result = try await client.submit(submission, as: author) { [weak self] step in await self?.advance(step) }
            submitted = result
            phase = .done(result)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func finish() {
        phase = .editing
        title = ""
        remarks = ""
    }

    private func advance(_ step: AMLLPullRequest.Step) {
        if isSubmitting { phase = .submitting(step) }
    }

    private static func client() -> AMLLPullRequest? {
        GitHubCLI.locate().map { AMLLPullRequest(api: GitHubCLI(executable: $0)) }
    }
}

private extension AMLLPullRequest.Step {
    var title: String {
        switch self {
        case .forking: "正在 fork 歌词库…"
        case .branching: "正在新建分支…"
        case .uploading: "正在上传歌词…"
        case .opening: "正在开 Pull Request…"
        }
    }
}

// MARK: - Panel

struct LyricsEditorSubmit: View {
    let session: LyricsEditorSession
    var back: () -> Void
    var editMetadata: () -> Void
    var close: () -> Void
    @Bindable private var state: LyricsEditorSubmitState
    @Environment(\.theme) private var theme
    @FocusState private var remarksFocused: Bool
    @State private var copied = false

    init(session: LyricsEditorSession, back: @escaping () -> Void, editMetadata: @escaping () -> Void, close: @escaping () -> Void) {
        self.session = session
        self.back = back
        self.editMetadata = editMetadata
        self.close = close
        state = session.amllSubmit
    }

    var body: some View {
        EditorPanel(title: "提交到 AMLL TTML DB",
                    subtitle: "在你的 GitHub fork 里提交这份 TTML，向 amll-dev/amll-ttml-db 开 Pull Request。合并后文件原样进入歌词库，不会被机器人重新生成。",
                    width: 640, close: close) {
            Group {
                if case .done(let result) = state.phase {
                    done(result)
                } else {
                    form
                }
            }
            .animation(Motion.hover, value: state.phase)
        }
        .onAppear { state.prepare(session) }
        .onChange(of: session.revision) { _, _ in state.refresh(session) }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountRow
            if let submitted = state.submitted {
                SubmitBanner(tone: .info, systemImage: "arrow.triangle.pull",
                             text: "这次编辑已经开过 Pull Request #\(submitted.number)。再提交会另开一个；要改已提交的歌词，请往 \(submitted.fork) 的 \(submitted.branch) 分支推送新的提交。",
                             actionTitle: "打开") { NSWorkspace.shared.open(submitted.url) }
            }
            checks
            fields
            if case .failed(let message) = state.phase {
                SubmitBanner(tone: .error, systemImage: "exclamationmark.octagon.fill", text: "没能开 Pull Request：" + message)
                    .transition(.opacity)
            }
            footer
        }
    }

    private var accountRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
            switch state.account {
            case .unknown, .loading:
                Text("正在读取 GitHub CLI 的登录状态…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 8)
                ProgressView().controlSize(.small)
            case .ready(let author):
                VStack(alignment: .leading, spacing: 2) {
                    Text("以 @\(author.login) 提交")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                    Text("使用 GitHub CLI（gh）的登录。你的 GitHub ID 和用户名会写进 TTML，歌词库按它们统计贡献。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PillButton(title: "重试", variant: .secondary, height: 26) {
                    Task { await state.loadAccount() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("投稿检查")
            if state.exportIssue == nil, state.problems.isEmpty {
                Label("歌曲信息、平台 ID 和逐字时间都齐了", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.exportKept)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let issue = state.exportIssue {
                            CheckRow(text: LyricsEditorSession.describe(issue), actionTitle: "去修改") {
                                session.reveal(issue)
                                close()
                            }
                        }
                        ForEach(state.problems, id: \.self) { problem in
                            CheckRow(text: problem.message, actionTitle: actionTitle(for: problem)) { act(on: problem) }
                        }
                    }
                }
                .frame(maxHeight: 170)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Pull Request")
            row("提交缘由") {
                Picker("提交缘由", selection: Binding(get: { state.reason }, set: { state.choose($0) })) {
                    ForEach(AMLLSubmission.Reason.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
            }
            row("标题") {
                TextField("[歌词提交] 歌手 - 歌名", text: $state.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }
            row("备注", top: true) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $state.remarks)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurface)
                        .scrollContentBackground(.hidden)
                        .focused($remarksFocused)
                        .padding(6)
                    if state.remarks.isEmpty {
                        Text(remarksPlaceholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 72)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous)
                    .strokeBorder(theme.primary.opacity(remarksFocused ? 0.35 : 0), lineWidth: 1))
                .animation(Motion.hover, value: remarksFocused)
            }
            HStack(spacing: 4) {
                Toggle("我已阅读并遵守歌词库的", isOn: $state.readGuide)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurface)
                TextLink(text: "投稿规范", color: theme.primary, hoverColor: theme.primary) {
                    NSWorkspace.shared.open(AMLLSubmission.guideURL)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.leading, 82)
        }
    }

    private var remarksPlaceholder: String {
        switch state.reason {
        case .new: "选填。网易云音乐里听不到这首歌时，可以附上音源链接，方便审核。"
        case .correction: "写明原投稿的 PR 编号和改了什么，例如：对 #1234 的修正：调整第 3 行的时间轴。"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            PillButton(title: "返回导出", systemName: "chevron.left", variant: .ghost, height: 32, action: back)
                .disabled(state.isSubmitting)
            if case .submitting(let step) = state.phase {
                ProgressView().controlSize(.small)
                Text(step.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            PillButton(title: "取消", variant: .ghost, height: 32, action: close)
            PillButton(title: "开 Pull Request", systemName: "arrow.triangle.pull", variant: .filled, height: 32) {
                Task { await state.submit(session) }
            }
            .disabled(!state.canSubmit)
            .opacity(state.canSubmit ? 1 : 0.45)
            .keyboardShortcut(.defaultAction)
            .help("fork 歌词库，在新分支里提交 raw-lyrics 下的 TTML 文件，再开 Pull Request（↩）")
        }
        .animation(Motion.hover, value: state.canSubmit)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.onSurfaceVariant)
    }

    private func row<Content: View>(_ label: String, top: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 70, alignment: .leading)
                .padding(.top, top ? 7 : 0)
            content()
        }
    }

    private func actionTitle(for problem: AMLLSubmission.Problem) -> String? {
        if problem.isMetadata { return "去填写" }
        if case .untimedSyllables = problem { return "去打点" }
        return nil
    }

    private func act(on problem: AMLLSubmission.Problem) {
        if problem.isMetadata { return editMetadata() }
        guard case .untimedSyllables = problem else { return }
        if let position = session.draft.firstUntimed { session.select(position) }
        close()
    }

    // MARK: Done

    private func done(_ result: AMLLPullRequest.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.exportKept)
                VStack(alignment: .leading, spacing: 4) {
                    Text("已开 Pull Request #\(result.number)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                    Text("审核员会在 Pull Request 里留言。要修改歌词，往 \(result.fork) 的 \(result.branch) 分支推送新的提交就行。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                detail("链接", result.url.absoluteString)
                detail("文件", result.path)
                detail("分支", "\(result.fork):\(result.branch)")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
            HStack(spacing: 10) {
                PillButton(title: copied ? "已拷贝" : "拷贝链接", systemName: copied ? "checkmark" : "doc.on.doc", variant: .tertiary, height: 32) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
                    withAnimation(Motion.selection) { copied = true }
                }
                Spacer(minLength: 0)
                PillButton(title: "在浏览器中打开", systemName: "safari", variant: .secondary, height: 32) {
                    NSWorkspace.shared.open(result.url)
                }
                PillButton(title: "完成", variant: .filled, height: 32) {
                    state.finish()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.onSurface.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Rows

private struct CheckRow: View {
    var text: String
    var actionTitle: String?
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.exportLost)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurface.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                PillButton(title: actionTitle, variant: .secondary, height: 24, action: action)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.exportLost.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
    }
}

private struct SubmitBanner: View {
    enum Tone { case info, error }

    var tone: Tone
    var systemImage: String
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    private var color: Color { tone == .error ? theme.exportLost : theme.primary }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                PillButton(title: actionTitle, variant: .secondary, height: 26, action: action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}
