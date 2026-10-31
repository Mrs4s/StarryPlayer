import AppKit
import LyricsCore
import SwiftUI

// MARK: - Choices

enum LyricsExportChoice: Hashable, Identifiable {
    case format(LyricsExportFormat)
    case project

    struct Group {
        var title: String
        var choices: [LyricsExportChoice]
    }

    static let groups: [Group] = [
        Group(title: "逐字歌词", choices: [.format(.ttml), .format(.ttml2)]),
        Group(title: "LRC", choices: [.format(.lrcLine), .format(.lrcEnhanced), .format(.lrcWord), .format(.kra)]),
        Group(title: "卡拉 OK", choices: [.format(.ass), .format(.nicokara), .format(.nicokaraRuby), .format(.krl), .format(.rl), .format(.kasugamuki)]),
        Group(title: "字幕与文本", choices: [.format(.srt), .format(.txt2ass), .format(.txt)]),
        Group(title: "编辑器", choices: [.project]),
    ]

    static let all = groups.flatMap(\.choices)

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .format(let format): format.rawValue
        case .project: "project"
        }
    }

    init?(storageValue: String) {
        if storageValue == "project" {
            self = .project
        } else if let format = LyricsExportFormat(rawValue: storageValue) {
            self = .format(format)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .format(let format): format.title
        case .project: "歌词工程"
        }
    }

    var fileExtension: String {
        switch self {
        case .format(let format): format.fileExtension
        case .project: LyricsProject.fileExtension
        }
    }

    var summary: String {
        switch self {
        case .format(let format): format.summary
        case .project: "Starry Player 的编辑工程，原样保存编辑器里的一切，之后打开就能接着编辑。"
        }
    }
}

extension LyricsExportFormat {
    var title: String {
        switch self {
        case .ttml: "AMLL TTML"
        case .ttml2: "TTML2"
        case .lrcLine: "LRC · 逐行"
        case .lrcEnhanced: "LRC · 增强型"
        case .lrcWord: "LRC · 逐字"
        case .kra: "KRA"
        case .txt: "纯文本"
        case .txt2ass: "txt2ass"
        case .srt: "SRT"
        case .ass: "ASS · 卡拉 OK"
        case .nicokara: "Nicokara"
        case .nicokaraRuby: "Nicokara · 带注音"
        case .rl: "RL 编辑模式"
        case .kasugamuki: "春日向注音"
        case .krl: "Kirakara（KRL）"
        }
    }

    var summary: String {
        switch self {
        case .ttml: "AMLL 播放器和歌词库使用的逐字歌词，也是「应用到这首歌」保存的格式。"
        case .ttml2: "注音按 TTML2 标准的 ruby 结构写出，适合 AMLL 以外支持 TTML2 的软件。"
        case .lrcLine: "每行一个时间，几乎所有播放器都能读。"
        case .lrcEnhanced: "在每行的时间之外，用 <mm:ss.xxx> 标出每个音节的时间。"
        case .lrcWord: "每个音节前后都用 [mm:ss.xxx] 标出时间。"
        case .kra: "精确到百分之一秒的逐字 LRC。"
        case .txt: "只有歌词文字，每行一句，不带时间。"
        case .txt2ass: "txt2ass 的输入文本：每行一个时间，交给它生成字幕。"
        case .srt: "每行一条字幕，适合视频播放器和剪辑软件。"
        case .ass: "用 \\kf 逐字填色的 ASS 字幕，可以直接用在视频里。"
        case .nicokara: "ニコカラ卡拉 OK 字幕使用的逐字 LRC，歌曲信息写成 @Title 等标签。"
        case .nicokaraRuby: "在 Nicokara 的基础上，用 @Ruby 行写出带时间的注音。"
        case .rl: "RL 的编辑文本，保留多拍、休止和还没打完的点，适合交给别人接着打点。"
        case .kasugamuki: "春日向注音使用的文本，带逐字时间和注音。"
        case .krl: "Kirakara 的卡拉 OK 歌词，用【@角色】标出演唱者，并保留逐字音译。"
        }
    }
}

// MARK: - Report

struct LyricsExportReport {
    enum Content: CaseIterable, Hashable {
        case timing, syllableTiming, translation, romanization, ruby, agents, background, metadata, editingState

        var title: String {
            switch self {
            case .timing: "歌词时间"
            case .syllableTiming: "逐字时间"
            case .translation: "翻译"
            case .romanization: "音译"
            case .ruby: "注音"
            case .agents: "演唱角色"
            case .background: "背景人声"
            case .metadata: "歌曲信息"
            case .editingState: "打点编辑状态"
            }
        }

        var systemImage: String {
            switch self {
            case .timing: "clock"
            case .syllableTiming: "text.word.spacing"
            case .translation: "character.bubble"
            case .romanization: "character.phonetic"
            case .ruby: "textformat.superscript"
            case .agents: "person.2"
            case .background: "music.mic"
            case .metadata: "info.circle"
            case .editingState: "metronome"
            }
        }

        var lossNote: String? {
            switch self {
            case .syllableTiming: "只保留每行的时间"
            case .agents: "不会标出每句由谁演唱"
            case .editingState: "多拍、休止和还没结束的音节，需要时另存歌词工程"
            default: nil
            }
        }
    }

    enum Status: Hashable {
        case kept
        case partial(String)
        case lost
    }

    struct Entry {
        var output: LyricsExport.Output?
        var error: String?
        var statuses: [Content: Status] = [:]

        var lossCount: Int { statuses.values.filter { $0 != .kept }.count }
    }

    private(set) var contents: [Content] = []
    private(set) var absent: [Content] = []
    private var issue: LyricsDraft.ExportIssue?
    private(set) var entries: [LyricsExportFormat: Entry] = [:]
    private(set) var untimedSyllables = 0
    private var timingFormats: Set<LyricsExportFormat> = []

    @MainActor init(session: LyricsEditorSession) {
        let draft = session.draft
        issue = draft.firstExportIssue
        untimedSyllables = draft.syllableCount - draft.timedCount
        var present = Self.contents(of: session)
        for format in LyricsExportFormat.allCases {
            if session.needsTiming(for: format) { timingFormats.insert(format) }
            do {
                let output = try session.writeLyrics(format: format)
                let statuses = Self.statuses(for: output.losses)
                present.formUnion(statuses.keys)
                entries[format] = Entry(output: output, statuses: statuses)
            } catch {
                entries[format] = Entry(error: error.localizedDescription)
            }
        }
        contents = Content.allCases.filter(present.contains)
        absent = Content.allCases.filter { !present.contains($0) }
    }

    func status(of content: Content, in choice: LyricsExportChoice) -> Status? {
        guard case .format(let format) = choice else { return .kept }
        guard let entry = entries[format], entry.output != nil else { return nil }
        return entry.statuses[content] ?? .kept
    }

    func blockingIssue(for choice: LyricsExportChoice) -> LyricsDraft.ExportIssue? {
        guard case .format(let format) = choice, format != .txt else { return nil }
        return issue
    }

    func infersTiming(for choice: LyricsExportChoice) -> Bool {
        guard case .format(let format) = choice else { return false }
        return timingFormats.contains(format)
    }

    private static func statuses(for losses: [LyricsExport.Loss]) -> [Content: Status] {
        var result: [Content: Status] = [:]
        for loss in losses {
            let (content, status) = effect(of: loss)
            if result[content] != .lost { result[content] = status }
        }
        return result
    }

    private static func effect(of loss: LyricsExport.Loss) -> (Content, Status) {
        switch loss {
        case .timing: (.timing, .lost)
        case .lineEndTiming: (.timing, .partial("重叠歌词各自的结束时间不会保留"))
        case .syllableTiming: (.syllableTiming, .lost)
        case .translation: (.translation, .lost)
        case .romanization: (.romanization, .lost)
        case .ruby: (.ruby, .lost)
        case .sharedRuby: (.ruby, .partial("跨音节的共享注音不会保留"))
        case .agents: (.agents, .lost)
        case .agentDetails: (.agents, .partial("只保留演唱名称，角色 ID、类型、别名、颜色、组合成员和扮演关系不会保留"))
        case .backgroundGrouping: (.background, .partial("会单独输出为歌词行，不再跟随主歌词"))
        case .metadata: (.metadata, .partial("这个格式不支持的字段不会写入"))
        case .editingState: (.editingState, .lost)
        }
    }

    @MainActor private static func contents(of session: LyricsEditorSession) -> Set<Content> {
        let draft = session.draft
        let document = session.document
        var result: Set<Content> = []
        if draft.lines.contains(where: { $0.timedRange != nil }) { result.insert(.timing) }
        if draft.timedCount > 0, document.hasSyllables { result.insert(.syllableTiming) }
        if document.hasTranslation { result.insert(.translation) }
        if document.hasRomanization { result.insert(.romanization) }
        if document.hasRuby { result.insert(.ruby) }
        if !document.agents.isEmpty || document.hasMultipleVocalists || document.lines.contains(where: { !$0.agentIDs.isEmpty }) {
            result.insert(.agents)
        }
        if document.hasBackgroundVocals { result.insert(.background) }
        if !session.exportMetadata.isEmpty { result.insert(.metadata) }
        if draft.hasAuthoringTiming || document.hasAuthoringTiming { result.insert(.editingState) }
        return result
    }
}

// MARK: - Dialog

struct LyricsEditorExport: View {
    private static let choiceKey = "starry.lyricsEditor.exportChoice"
    private static let edgeFade: CGFloat = 10

    let session: LyricsEditorSession
    var close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: LyricsExportChoice
    @State private var report: LyricsExportReport?
    @State private var step = 1
    @State private var appeared = false
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @Namespace private var selection

    init(session: LyricsEditorSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        let stored = UserDefaults.standard.string(forKey: Self.choiceKey).flatMap(LyricsExportChoice.init(storageValue:))
        _choice = State(initialValue: stored ?? .format(.ttml))
    }

    private var entry: LyricsExportReport.Entry? {
        guard case .format(let format) = choice else { return nil }
        return report?.entries[format]
    }

    private var issue: LyricsDraft.ExportIssue? { report?.blockingIssue(for: choice) }

    private var canExport: Bool {
        guard report != nil, issue == nil else { return false }
        return choice == .project || entry?.output != nil
    }

    private var canCopy: Bool { choice != .project && canExport }

    private var selectionAnimation: Animation { reduceMotion ? Motion.hover : Motion.selection }

    var body: some View {
        EditorPanel(title: "导出歌词", width: 860, close: close) {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 0) {
                    formatList
                        .frame(width: 248)
                    Rectangle()
                        .fill(theme.outlineVariant.opacity(0.7))
                        .frame(width: 1)
                        .padding(.horizontal, 20)
                    detail
                }
                .frame(minHeight: 380, maxHeight: 520)
                footer
            }
        }
        .onAppear {
            report = LyricsExportReport(session: session)
            installKeys()
            withAnimation(reduceMotion ? Motion.hover : Motion.reveal) { appeared = true }
        }
        .onChange(of: session.revision) { _, _ in
            withAnimation(Motion.hover) { report = LyricsExportReport(session: session) }
        }
        .onDisappear {
            removeKeys()
            copyReset?.cancel()
        }
    }

    // MARK: Formats

    private var formatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(LyricsExportChoice.groups.enumerated()), id: \.offset) { index, group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 2 : 12)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.choices) { item in
                            ExportFormatRow(title: item.title, recommended: item == .format(.ttml), badge: badge(for: item),
                                            selected: item == choice, selection: selection) {
                                select(item)
                            }
                            .id(item)
                        }
                    }
                }
                .padding(.trailing, 4)
                .padding(.vertical, Self.edgeFade)
                .animation(Motion.hover, value: report == nil)
            }
            .scrollEdgeFade(Self.edgeFade)
            .padding(.top, -Self.edgeFade)
            .onAppear { proxy.scrollTo(choice) }
            .onChange(of: choice) { _, item in
                withAnimation(Motion.popover) { proxy.scrollTo(item) }
            }
        }
    }

    private func badge(for item: LyricsExportChoice) -> ExportFormatRow.Badge? {
        guard let report else { return nil }
        guard case .format(let format) = item else { return .complete }
        guard let entry = report.entries[format], entry.output != nil else { return .blocked }
        return entry.lossCount == 0 ? .complete : .losses(entry.lossCount)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                header(for: choice)
                    .id(choice)
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: CGFloat(step) * 8)),
                                            removal: .opacity))
            }
            notice
            contentSection
            previewSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(for item: LyricsExportChoice) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                Text("." + item.fileExtension)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(theme.onSurface.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(item.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notice: some View {
        if let issue {
            ExportNotice(tone: .error, systemImage: "exclamationmark.octagon.fill", text: "无法导出：" + LyricsEditorSession.describe(issue),
                         actionTitle: "去修改") {
                session.reveal(issue)
                close()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else if let error = entry?.error {
            ExportNotice(tone: .error, systemImage: "exclamationmark.octagon.fill", text: "这个格式导不出：\(error)")
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else if let report, report.infersTiming(for: choice) {
            ExportNotice(tone: .warning, systemImage: "clock.badge.exclamationmark",
                         text: "还有 \(report.untimedSyllables) 个音节没有打点，导出时会按前后已打点的时间平均分配。")
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("这首歌的内容")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 8)
                if let tally {
                    Text(tally)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.numericText())
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if let report {
                        ForEach(Array(report.contents.enumerated()), id: \.element) { index, content in
                            ExportContentRow(content: content, status: report.status(of: content, in: choice), order: index, appeared: appeared)
                        }
                        if !report.absent.isEmpty {
                            Text("这首歌没有" + report.absent.map(\.title).joined(separator: "、") + "，不受格式影响。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                        }
                        if choice != .project, (entry?.lossCount ?? 0) > 0 {
                            TextLink(text: "要原样留下全部内容，可以另存歌词工程 →", color: theme.onSurfaceVariant, hoverColor: theme.primary) {
                                select(.project)
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Self.edgeFade)
            }
            .scrollEdgeFade(Self.edgeFade)
            .padding(.vertical, -Self.edgeFade)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tally: String? {
        guard let report, !report.contents.isEmpty else { return nil }
        let statuses = report.contents.compactMap { report.status(of: $0, in: choice) }
        guard !statuses.isEmpty else { return nil }
        let partial = statuses.filter { if case .partial = $0 { true } else { false } }.count
        let lost = statuses.filter { $0 == .lost }.count
        var parts = ["保留 \(statuses.count - partial - lost) 项"]
        if partial > 0 { parts.append("部分保留 \(partial) 项") }
        if lost > 0 { parts.append("丢失 \(lost) 项") }
        return parts.joined(separator: " · ")
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(choice == .project ? "工程会一并保存" : "文件预览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                if let text = entry?.output?.text {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.numericText())
                }
            }
            ZStack(alignment: .topLeading) {
                previewBody
                    .id(choice)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
            .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous).strokeBorder(theme.onSurface.opacity(0.06), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        if choice == .project {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["没打点的音节和虚拟轨", "多拍、休止和还没结束的音节", "之后用「打开歌词工程」（⌘O）接着编辑"], id: \.self) { item in
                    Label(item, systemImage: "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurface.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let text = entry?.output?.text {
            Text(String(text.prefix(1200)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.onSurface.opacity(0.78))
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .accessibilityLabel("文件预览")
        } else {
            Text(report == nil ? "" : "没有可以预览的内容")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if choice != .project {
                copyButton.transition(.opacity)
            }
            Spacer(minLength: 0)
            PillButton(title: "取消", variant: .ghost, height: 32, action: close)
            PillButton(title: choice == .project ? "保存工程…" : "导出…",
                       systemName: choice == .project ? "square.and.arrow.down.on.square" : "square.and.arrow.up",
                       variant: .filled, height: 32, action: commit)
                .disabled(!canExport)
                .opacity(canExport ? 1 : 0.45)
                .keyboardShortcut(.defaultAction)
                .help(choice == .project ? "保存歌词工程（↩）" : "导出 \(choice.title)（↩）")
        }
        .animation(Motion.hover, value: canExport)
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 7) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "已拷贝" : "拷贝文本")
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .disabled(!canCopy)
        .opacity(canCopy ? 1 : 0.45)
        .keyboardShortcut("c", modifiers: .command)
        .help("把 \(choice.title) 文本拷贝到剪贴板（⌘C）")
    }

    // MARK: Actions

    private func select(_ item: LyricsExportChoice) {
        guard item != choice else { return }
        let order = LyricsExportChoice.all
        step = (order.firstIndex(of: item) ?? 0) >= (order.firstIndex(of: choice) ?? 0) ? 1 : -1
        copyReset?.cancel()
        copied = false
        withAnimation(selectionAnimation) { choice = item }
    }

    private func move(by offset: Int) {
        let order = LyricsExportChoice.all
        guard let index = order.firstIndex(of: choice) else { return }
        select(order[min(max(index + offset, 0), order.count - 1)])
    }

    private func remember() {
        UserDefaults.standard.set(choice.storageValue, forKey: Self.choiceKey)
    }

    private func commit() {
        guard canExport else { return }
        remember()
        let done: (Bool) -> Void = { saved in if saved { close() } }
        switch choice {
        case .project:
            model.saveLyricsProject(session, completion: done)
        case .format(let format):
            guard let output = entry?.output else { return }
            model.saveExportedLyrics(output, format: format, from: session, completion: done)
        }
    }

    private func copy() {
        guard canCopy, let text = entry?.output?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        remember()
        withAnimation(Motion.selection) { copied = true }
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.hover) { copied = false }
        }
    }

    // MARK: Keys

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window?.identifier?.rawValue == AppModel.lyricsEditorIdentifier, !PopMenuController.isAnyOpen,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: move(by: -1)
        case 125: move(by: 1)
        default: return false
        }
        return true
    }
}

// MARK: - Rows

private extension View {
    func scrollEdgeFade(_ length: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: length)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: length)
            }
        }
    }
}

private extension Theme {
    var exportKept: Color { Color(hex: isDark ? "#5FD08A" : "#2E9D5B") }
    var exportLost: Color { Color(hex: isDark ? "#F0625D" : "#DC3F3A") }
}

private struct ExportFormatRow: View {
    enum Badge: Equatable {
        case complete, losses(Int), blocked
    }

    var title: String
    var recommended: Bool
    var badge: Badge?
    var selected: Bool
    var selection: Namespace.ID
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.onSurface.opacity(selected ? 1 : 0.84))
                    .lineLimit(1)
                if recommended { Tag(text: "推荐", style: .primary, soft: true) }
                Spacer(minLength: 6)
                if let badge {
                    badgeView(badge).transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background { background }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(badge.map(label) ?? "")
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.menu, style: .continuous)
        if selected {
            shape.fill(theme.primary.opacity(theme.isDark ? 0.14 : 0.08))
                .overlay(shape.strokeBorder(theme.primary.opacity(0.08), lineWidth: 1))
                .matchedGeometryEffect(id: "export.selection", in: selection)
        } else if hovering {
            shape.fill(theme.onSurface.opacity(0.05))
        }
    }

    private func badgeView(_ badge: Badge) -> some View {
        let (systemImage, color): (String, Color) = switch badge {
        case .complete: ("checkmark", theme.exportKept)
        case .losses: ("minus", theme.warning)
        case .blocked: ("nosign", theme.exportLost)
        }
        return HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .bold))
            Text(label(badge))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(color)
    }

    private func label(_ badge: Badge) -> String {
        switch badge {
        case .complete: "完整"
        case .losses(let count): "丢 \(count) 项"
        case .blocked: "无法导出"
        }
    }
}

private struct ExportContentRow: View {
    var content: LyricsExportReport.Content
    var status: LyricsExportReport.Status?
    var order: Int
    var appeared: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch status {
        case .kept: theme.exportKept
        case .partial: theme.warning
        case .lost: theme.exportLost
        case nil: theme.onSurfaceVariant
        }
    }

    private var symbol: String {
        switch status {
        case .kept: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .lost: "xmark.circle.fill"
        case nil: "minus.circle"
        }
    }

    private var label: String {
        switch status {
        case .kept: "保留"
        case .partial: "部分保留"
        case .lost: "丢失"
        case nil: "—"
        }
    }

    private var detail: String? {
        switch status {
        case .partial(let note): note
        case .lost: content.lossNote
        default: nil
        }
    }

    private var isLoss: Bool { status != nil && status != .kept }

    private var animation: Animation {
        if reduceMotion { return Motion.hover }
        return Motion.selection.delay(Double(min(order, Motion.staggerLimit)) * Motion.staggerStep)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: content.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(0.9))
                    .frame(minHeight: 18)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(tint)
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(isLoss ? 0.08 : 0), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .animation(animation, value: status)
        .animation(animation, value: appeared)
        .accessibilityElement(children: .combine)
    }
}

private struct ExportNotice: View {
    enum Tone { case warning, error }

    var tone: Tone
    var systemImage: String
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    private var color: Color { tone == .error ? theme.exportLost : theme.warning }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
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
