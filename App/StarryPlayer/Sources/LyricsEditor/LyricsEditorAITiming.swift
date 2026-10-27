import AppKit
import LyricsCore
import LyricsSync
import SwiftUI

struct LyricsEditorAITiming: View {
    static let directoryKey = LyricsAIModelDownloadState.directoryKey
    static let backendKey = "starry.lyricsEditor.aiTiming.backend"

    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let state: LyricsEditorAITimingState
    var close: () -> Void
    var modelDownload = LyricsAIModelDownloadState.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Self.directoryKey) private var modelPath = ""
    @AppStorage(Self.backendKey) private var backend = LyricsAIBackend.neuralEngine

    private enum Stage: Hashable { case setup, working, result }

    // Exclude progress ticks so they do not restart the layout animation.
    private struct Layout: Hashable {
        var stage: Stage
        var messages: [String?]
        var flags: [Bool]
    }

    private enum Tone { case info, warning, error }

    private var directory: URL? { modelPath.isEmpty ? nil : URL(fileURLWithPath: modelPath, isDirectory: true) }
    private var configuration: LyricsEditorAITimingState.Configuration? {
        directory.map { .init(directory: $0, backend: backend) }
    }
    private var supported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
    private var modelReady: Bool { state.isModelReady(at: directory) }
    private var canStart: Bool {
        supported && !modelDownload.isDownloading && audio.isPrecise && !session.draft.isEmpty && modelReady
    }
    private var canApply: Bool {
        state.canApply(in: session, configuration: configuration, audioIdentity: audio.aiAlignmentIdentity)
    }
    private var selectedCount: Int { state.selection.intersection(state.retimedLines).count }
    private var canApplySelection: Bool { canApply && selectedCount > 0 }
    private var stage: Stage { state.isWorking ? .working : state.result == nil ? .setup : .result }
    private var layout: Layout {
        Layout(stage: stage,
               messages: [state.error, state.notice, state.modelError, state.modelInfo?.name,
                          modelDownload.error, modelDownload.notice, modelPath],
               flags: [state.isCheckingModel, modelDownload.isDownloading, canApply, canStart])
    }

    var body: some View {
        EditorPanel(title: "AI 一键打轴", subtitle: "在本机根据人声和歌词读音，为整首主歌词生成逐字时间。", width: 720, close: dismiss) {
            settings
            switch stage {
            case .setup:
                EmptyView()
            case .working:
                progress.transition(stageTransition)
            case .result:
                if let result = state.result {
                    AITimingResultPreview(result: result, state: state, audio: audio).transition(stageTransition)
                }
            }
            if let error = state.error { banner(error, tone: .error) }
            if let notice = state.notice { banner(notice, tone: .info) }
            if stage == .result, !canApply { banner("歌词或音频已改变，请重新打轴后应用。", tone: .warning) }
            footer
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.fold, value: layout)
        .foregroundStyle(theme.onSurface)
        .onAppear {
            state.validate(directory)
        }
        .task { await modelDownload.discover() }
        .onChange(of: modelPath) { _, _ in state.validate(directory) }
        .onChange(of: backend) { _, _ in state.invalidate() }
        .onDisappear { state.cancel() }
    }

    private var stageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                           removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 0) {
            modelRow
            if modelDownload.isDownloading {
                downloadProgress.transition(.opacity.combined(with: .offset(y: -4)))
            } else if let text = modelDownload.error ?? (modelReady ? nil : modelDownload.notice) {
                statusLabel(text, systemName: modelDownload.error == nil ? "info.circle" : "exclamationmark.triangle.fill",
                            color: modelDownload.error == nil ? theme.onSurfaceVariant : danger)
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 56).padding(.trailing, 14).padding(.bottom, 12)
                    .transition(.opacity)
            }
            Rectangle().fill(theme.onSurface.opacity(0.06)).frame(height: 1).padding(.leading, 56)
            settingRow("cpu") {
                Text("推理设备")
            } detail: {
                Text("切换后需要重新打轴")
            } trailing: {
                SegmentSwitch(selection: $backend, options: LyricsAIBackend.allCases.map { ($0, $0.title) })
                    .disabled(state.isWorking)
                    .opacity(state.isWorking ? 0.5 : 1)
            }
        }
        .aiCard(theme)
    }

    private var modelRow: some View {
        settingRow("shippingbox") {
            HStack(spacing: 6) {
                Text(state.modelInfo?.name ?? "AI 打轴模型").lineLimit(1)
                if let info = state.modelInfo, !info.hasEnglishReadings {
                    Tag(text: "无英文词典", style: .amber, soft: true)
                        .help("模型目录中没有英文读音词典，英文段落建议补充假名注音")
                }
            }
        } detail: {
            modelStatus
        } trailing: {
            HStack(spacing: 8) {
                if showsModelInstall {
                    installButton.transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                IconButton(systemName: "folder", size: 30, iconSize: 13, variant: .tertiary, help: "选择模型文件夹…", action: chooseModel)
                    .disabled(state.isWorking || modelDownload.isDownloading)
                    .opacity(state.isWorking || modelDownload.isDownloading ? 0.45 : 1)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if state.isCheckingModel {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检查模型…")
            }
        } else if let error = state.modelError {
            statusLabel(error, systemName: "exclamationmark.triangle.fill", color: danger)
                .lineLimit(2)
                .help(error)
        } else if state.modelInfo != nil, let directory {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary)
                Text("已就绪 ·")
                Text(directory.path).lineLimit(1).truncationMode(.middle)
            }
            .help(directory.path)
        } else {
            Text("下载推荐模型后可离线使用，也可以选择已有的模型文件夹").lineLimit(1)
        }
    }

    private var showsModelInstall: Bool {
        supported && !state.isWorking && !modelDownload.isDownloading && !state.isCheckingModel && !modelReady
    }

    @ViewBuilder
    private var installButton: some View {
        if modelDownload.installedDirectory != nil {
            PillButton(title: "使用已下载模型", systemName: "checkmark.circle", variant: .secondary, height: 30) {
                modelDownload.useInstalled()
            }
        } else {
            PillButton(title: modelDownload.error == nil ? "下载 \(modelDownload.downloadSize)" : "重试下载", systemName: "arrow.down.circle",
                       variant: .secondary, height: 30) { modelDownload.start() }
                .disabled(modelDownload.isChecking)
                .opacity(modelDownload.isChecking ? 0.45 : 1)
        }
    }

    private var downloadProgress: some View {
        let downloading = modelDownload.progress.stage == .downloading
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(modelDownload.progressText)
                Spacer(minLength: 8)
                if downloading, modelDownload.progress.receivedBytes > 0 {
                    Text(verbatim: "\(Int(modelDownload.fraction * 100))%").monospacedDigit()
                }
                IconButton(systemName: "xmark", size: 22, iconSize: 9, help: modelDownload.isCancelling ? "正在停止…" : "取消下载") {
                    modelDownload.cancel()
                }
                .disabled(modelDownload.isCancelling)
            }
            AIProgressBar(fraction: downloading ? modelDownload.fraction : 1, active: !modelDownload.isCancelling)
            Text("关闭面板后会继续下载，完成后自动选用模型。")
                .font(.system(size: 11))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.leading, 56).padding(.trailing, 14).padding(.bottom, 12)
    }

    private func settingRow<Title: View, Detail: View, Trailing: View>(
        _ icon: String, @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.primary)
                .frame(width: 30, height: 30)
                .background(theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                title().font(.system(size: 13, weight: .medium))
                detail().font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Stages

    private var progress: some View {
        let percent = Int(state.progress.fraction * 100)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.primary)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: !state.isCancelling && !reduceMotion)
                    .frame(width: 30, height: 30)
                    .background(theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.progress.message.isEmpty ? "准备中…" : state.progress.message)
                        .font(.system(size: 13, weight: .medium))
                        .contentTransition(.opacity)
                    Text(state.isCancelling ? "正在停止，歌词不会改变" : "在本机运行，可随时停止")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 12)
                Text(verbatim: "\(percent)%")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(percent)))
            }
            AIProgressBar(fraction: state.progress.fraction, active: !state.isCancelling)
        }
        .padding(14)
        .aiCard(theme)
        .animation(.easeOut(duration: 0.25), value: percent)
        .animation(.easeOut(duration: 0.2), value: state.progress.message)
    }

    // MARK: Messages & footer

    private func banner(_ text: String, tone: Tone) -> some View {
        let color: Color = switch tone {
        case .info: theme.onSurfaceVariant
        case .warning: amber
        case .error: danger
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(theme.onSurface.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(theme.isDark ? 0.12 : 0.09), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func statusLabel(_ text: String, systemName: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemName).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var amber: Color { Color(hex: theme.isDark ? "#F5B94E" : "#B7791F") }
    private var danger: Color { Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A") }

    private var hint: String? {
        switch stage {
        case .working: return nil
        case .result:
            guard canApply else { return nil }
            if selectedCount == 0 { return "至少选择一行才能应用" }
            return selectedCount < state.retimedLines.count ? "未选中的行保留原有时间 · 应用后可用 ⌘Z 撤销" : "应用后可用 ⌘Z 撤销"
        case .setup:
            if !supported { return "AI 打轴需要 macOS 15 或更新版本" }
            if session.draft.isEmpty { return "请先导入歌词" }
            if modelDownload.isDownloading { return "模型下载完成后即可开始" }
            if state.isCheckingModel { return nil }
            if !modelReady { return "请先下载或选择模型" }
            if !audio.isPrecise { return "音频完成本地解码后才能开始打轴" }
            return nil
        }
    }

    private var footer: some View {
        let buttonTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.94))
        return HStack(spacing: 8) {
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .id(hint)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            switch stage {
            case .setup:
                PillButton(title: "开始打轴", systemName: "wand.and.stars", variant: .filled, height: 32, action: start)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.45)
                    .transition(buttonTransition)
            case .working:
                PillButton(title: state.isCancelling ? "停止中…" : "停止", systemName: "stop.fill", variant: .secondary, height: 32) {
                    state.cancel()
                }
                .disabled(state.isCancelling)
                .transition(buttonTransition)
            case .result:
                PillButton(title: "重新打轴", systemName: "arrow.clockwise", variant: .tertiary, height: 32, action: start)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.45)
                    .transition(buttonTransition)
                PillButton(title: selectedCount == state.retimedLines.count ? "应用到歌词" : "应用 \(selectedCount) 行",
                           systemName: "checkmark", variant: .filled, height: 32) {
                    if state.apply(in: session, configuration: configuration, audioIdentity: audio.aiAlignmentIdentity) { close() }
                }
                .disabled(!canApplySelection)
                .opacity(canApplySelection ? 1 : 0.45)
                .transition(buttonTransition)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Actions

    private func start() {
        guard let configuration else { return }
        state.start(configuration: configuration, in: session, prepareAudio: { try await audio.aiAlignmentSource() },
                    currentAudioIdentity: { audio.aiAlignmentIdentity })
    }
    private func dismiss() { state.cancel(); close() }
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "选择模型"
        panel.message = "选择包含 Core ML 模型和 metadata 文件夹的目录"
        if let directory { panel.directoryURL = directory }
        if panel.runModal() == .OK, let url = panel.url { modelPath = url.path }
    }
}

// MARK: - Result preview

private struct AITimingResultPreview: View {
    let result: LyricsAIAlignmentResult
    let state: LyricsEditorAITimingState
    let audio: LyricsEditorAudio
    @Environment(\.theme) private var theme
    @State private var expanded: Set<UUID> = []
    @State private var shown = false

    private struct Entry: Identifiable {
        var number: Int
        var line: LyricsDraft.Line
        var id: UUID { line.id }
    }

    private var entries: [Entry] {
        result.draft.lines.enumerated().filter { !$0.element.isBackground }.map { Entry(number: $0.offset + 1, line: $0.element) }
    }

    var body: some View {
        let retimed = Set(state.retimedLines)
        let selected = state.selection.intersection(retimed).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(theme.primary)
                    .symbolEffect(.bounce, value: shown)
                Text("已生成 \(result.alignedLines) 行 · \(result.alignedSyllables) 个字块")
                    .font(.system(size: 13, weight: .semibold))
                if result.estimatedReadings > 0 {
                    Tag(text: "\(result.estimatedReadings) 个读音为估计", style: .amber, soft: true)
                }
                if result.skippedBackgroundLines > 0 {
                    Tag(text: "\(result.skippedBackgroundLines) 行背景未修改", soft: true)
                }
                Spacer(minLength: 0)
            }
            if result.estimatedReadings > 0 {
                Text("估计的读音或词内边界建议重点试听；特殊读法可补充注音后重新打轴。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AICheckbox(value: selected == 0 ? .off : selected == retimed.count ? .on : .mixed, title: "全选") {
                        state.selection = selected == retimed.count ? [] : retimed
                    }
                    .disabled(retimed.isEmpty)
                    Spacer(minLength: 8)
                    Text("已选 \(selected) / \(retimed.count) 行")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.numericText(value: Double(selected)))
                        .animation(Motion.hover, value: selected)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                Rectangle().fill(theme.onSurface.opacity(0.06)).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            AITimingLineRow(number: entry.number, line: entry.line, audio: audio,
                                            isSelectable: retimed.contains(entry.id), isSelected: state.selection.contains(entry.id),
                                            isExpanded: expanded.contains(entry.id)) {
                                if state.selection.remove(entry.id) == nil { state.selection.insert(entry.id) }
                            } toggleExpanded: {
                                withAnimation(Motion.fold) {
                                    if expanded.remove(entry.id) == nil { expanded.insert(entry.id) }
                                }
                            }
                            .staggeredReveal(shown, index: index, distance: 6)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 220)
            }
            .aiCard(theme)
        }
        .onAppear { shown = true }
    }
}

private struct AITimingLineRow: View {
    let number: Int
    let line: LyricsDraft.Line
    let audio: LyricsEditorAudio
    var isSelectable: Bool
    var isSelected: Bool
    var isExpanded: Bool
    var toggleSelected: () -> Void
    var toggleExpanded: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var dimmed: Bool { isSelectable && !isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AICheckbox(value: isSelectable && isSelected ? .on : .off, label: "应用这一行", action: toggleSelected)
                    .disabled(!isSelectable)
                    .opacity(isSelectable ? 1 : 0.35)
                    .help(isSelectable ? "" : "这一行没有新的时间")
                Group {
                    Text("\(number)")
                        .monospacedDigit()
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 24, alignment: .trailing)
                    Text(line.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(range).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(theme.onSurfaceVariant)
                }
                .opacity(dimmed ? 0.45 : 1)
                IconButton(systemName: "play.fill", size: 24, iconSize: 9, help: "试听这一行", action: play)
                    .disabled(!audio.isReady || line.timedRange == nil)
                    .opacity(hovering || isExpanded ? 1 : 0.55)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .font(.system(size: 12.5))
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)
            .accessibilityAddTraits(.isButton)
            if isExpanded {
                LyricsFlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(line.syllables) { syllable in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(syllable.text).font(.system(size: 12.5)).foregroundStyle(theme.onSurface)
                            Text(LyricsEditorFormat.time(syllable.start))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .help(time(syllable.start) + " – " + time(syllable.end))
                    }
                }
                .opacity(dimmed ? 0.45 : 1)
                .padding(.leading, 70)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(theme.onSurface.opacity(isExpanded ? 0.045 : hovering ? 0.03 : 0),
                    in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: dimmed)
    }

    private var range: String {
        guard let range = line.timedRange else { return "未打轴" }
        return time(range.lowerBound) + " – " + time(range.upperBound)
    }
    private func time(_ value: Double?) -> String { value.map { LyricsEditorFormat.time($0, digits: 3) } ?? "—" }
    private func play() {
        guard let start = line.timedRange?.lowerBound else { return }
        audio.seek(to: max(0, start - 0.3))
        audio.play()
    }
}

// MARK: - Pieces

private struct AICheckbox: View {
    enum Value { case off, on, mixed }
    var value: Value
    var title: String? = nil
    var label: String? = nil
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                box
                if let title {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.onSurface)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title ?? "")
        .accessibilityValue(value == .on ? "已选中" : value == .mixed ? "部分选中" : "未选中")
    }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        return ZStack {
            shape.fill(value == .off ? theme.onSurface.opacity(0.04) : theme.primary)
            shape.strokeBorder(theme.onSurface.opacity(value == .off ? 0.28 : 0), lineWidth: 1.2)
            if value != .off {
                Image(systemName: value == .on ? "checkmark" : "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(theme.onPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
        .animation(Motion.lift, value: value)
    }
}

private struct AIProgressBar: View {
    var fraction: Double
    var active = true
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.height, geo.size.width * min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(theme.onSurface.opacity(theme.isDark ? 0.08 : 0.07))
                Capsule().fill(theme.primary)
                    .overlay(alignment: .leading) {
                        if active && !reduceMotion {
                            LinearGradient(colors: [.clear, theme.onPrimary.opacity(theme.isDark ? 0.22 : 0.4), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 72)
                                .offset(x: -72 + sweep * (width + 72))
                        }
                    }
                    .clipShape(Capsule())
                    .frame(width: width)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.35), value: fraction)
        .task(id: active && !reduceMotion) {
            guard active, !reduceMotion else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.2)) { sweep = 1 }
                try? await Task.sleep(for: .seconds(1.2))
                withTransaction(Transaction(animation: nil)) { sweep = 0 }
                try? await Task.sleep(for: .seconds(0.35))
            }
        }
    }
}

private extension View {
    func aiCard(_ theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return background(theme.onSurface.opacity(theme.isDark ? 0.04 : 0.025), in: shape)
            .overlay(shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.06), lineWidth: 1))
    }
}
