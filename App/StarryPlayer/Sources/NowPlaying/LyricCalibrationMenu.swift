import LyricsSync
import SwiftUI

struct LyricCalibrationMenu: View {
    var size: CGFloat = 32
    var tint: Color
    @Binding var isOpen: Bool
    @Environment(AppModel.self) private var model
    @AppStorage(LyricsAIModelDownloadState.directoryKey) private var modelPath = ""
    @AppStorage(LyricsEditorAITiming.backendKey) private var backend = LyricsAIBackend.neuralEngine
    @AppStorage(LyricsEditorAITiming.englishSplitKey) private var englishSplit = LyricsAIEnglishSplit.automatic
    @State private var modelStatus = ModelStatus.missing
    @State private var menuOpen = false
    @State private var confirmingRegeneration = false
    private let download = LyricsAIModelDownloadState.shared

    private enum ModelStatus { case missing, checking, ready, invalid }
    private var player: PlayerController { model.player }
    private var running: Bool { player.lyricCalibration.isRunning }
    private var available: Bool { player.lyrics.map { !$0.isEmpty } ?? false }
    private var supported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
    private var regenerationUnavailableReason: String? {
        if !supported { return "本地模型需要 macOS 15 或更新版本" }
        if download.isDownloading { return "模型正在下载，完成后即可使用" }
        switch modelStatus {
        case .missing: return "尚未安装 AI 打轴模型"
        case .checking: return "正在检查本地模型…"
        case .invalid: return "模型不可用，请在设置中重新选择"
        case .ready: break
        }
        if player.lyrics?.hasJapanese != true { return "未检测到日语歌词，逐字生成暂不可用" }
        return player.lyricAnalysisUnavailableReason
    }

    var body: some View {
        PopMenu(isPresented: $menuOpen) {
            items
        } label: { open in
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .symbolEffect(.pulse, isActive: running)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(open ? 0.1 : 0)))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(tint.opacity(0.7))
                        .padding(3)
                }
                .overlay {
                    if player.lyricCalibration.isRegenerating {
                        Circle().trim(from: 0, to: player.lyricRegenerationProgress.fraction)
                            .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1)
                    }
                }
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true, isActive: running))
        .disabled(!available && !running)
        .opacity(available || running ? 1 : 0.4)
        .help(player.lyricCalibration.isRegenerating ? player.lyricRegenerationProgress.message : "歌词校准与逐字生成")
        .accessibilityLabel("歌词校准与逐字生成")
        .task { await download.discover() }
        .task(id: modelPath) { await checkModel() }
        .onChange(of: menuOpen) { _, _ in isOpen = menuOpen || confirmingRegeneration }
        .onChange(of: confirmingRegeneration) { _, _ in isOpen = menuOpen || confirmingRegeneration }
        .onChange(of: player.current?.id) { _, _ in confirmingRegeneration = false }
        .onChange(of: player.lyrics) { _, _ in confirmingRegeneration = false }
        .onDisappear { isOpen = false }
        .confirmationDialog("用本地模型重新生成逐字歌词？", isPresented: $confirmingRegeneration, titleVisibility: .visible) {
            Button("重新生成逐字") {
                guard regenerationUnavailableReason == nil else { return }
                player.regenerateLyrics(modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true), backend: backend, englishSplit: englishSplit)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将为当前日语歌词重新生成逐字时间。和声、合唱、重叠演唱及特殊读音等复杂情况可能不准确，请试听核对。生成后可以从校准菜单恢复原歌词。")
        }
    }

    @PopMenuBuilder
    private var items: [PopMenuItem] {
        if running {
            PopMenuItem.button(player.lyricCalibration.isRegenerating ? "停止生成逐字歌词" : "停止自动校准", systemImage: "stop.fill", action: player.cancelLyricCalibration)
            if player.lyricCalibration.isRegenerating {
                PopMenuItem.info(player.lyricRegenerationProgress.message, "\(Int(player.lyricRegenerationProgress.fraction * 100))%")
            }
            PopMenuItem.divider
        }
        PopMenuItem.button("自动校准整体时间", systemImage: "waveform.badge.magnifyingglass", disabled: running || player.lyricAnalysisUnavailableReason != nil, action: player.calibrateLyrics)
        if let reason = player.lyricAnalysisUnavailableReason { PopMenuItem.header(reason) }
        PopMenuItem.divider
        PopMenuItem.button("用本地模型重新生成逐字…", systemImage: "wand.and.stars", disabled: running || regenerationUnavailableReason != nil) {
            confirmingRegeneration = true
        }
        if let reason = regenerationUnavailableReason {
            PopMenuItem.header(reason)
        } else {
            PopMenuItem.header("和声、重叠演唱等复杂情况可能不准确")
        }
        if supported, modelStatus != .ready {
            PopMenuItem.button("下载或选择 AI 打轴模型…", systemImage: "arrow.down.circle") { model.openSettings(.lyricsEditor) }
        }
        if player.canRestoreLyricsBeforeRegeneration {
            PopMenuItem.divider
            PopMenuItem.button("恢复生成前的歌词", systemImage: "arrow.uturn.backward", disabled: running, action: player.restoreLyricsBeforeRegeneration)
        }
    }

    private func checkModel() async {
        guard !modelPath.isEmpty else { modelStatus = .missing; return }
        modelStatus = .checking
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let ready = await Task.detached(priority: .utility) { (try? LyricsAIModelBundle.load(from: directory)) != nil }.value
        guard !Task.isCancelled else { return }
        modelStatus = ready ? .ready : .invalid
    }
}
