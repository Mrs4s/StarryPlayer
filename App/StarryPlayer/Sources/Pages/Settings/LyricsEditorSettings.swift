import AppKit
import AudioProcessing
import LyricsCore
import LyricsSync
import SwiftUI

@MainActor
private enum LyricsEditorPreferences {
    static let keys = [
        LyricsEditorAITiming.backendKey, LyricsEditorAITiming.englishSplitKey,
        LyricsEditorTranslationState.languageKey, LyricsEditorTranslationState.styleKey, LyricsEditorTranslationState.rubyScriptKey,
        LyricsEditorView.tapLeadKey, LyricsEditorView.autoAlignAfterTimingKey, LyricsEditorTimeline.gainKey,
        LyricsEditorTimeline.onsetHintsKey, LyricsEditorTimeline.onsetSensitivityKey, LyricsEditorTimeline.splitOnsetHintsKey,
    ]

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}

extension SettingsCatalog {
    var lyricsEditor: [SettingsGroup] {
        [
            SettingsGroup("lyricsEditorAI", title: "AI 打轴", footer: "模型在这台 Mac 上离线运行。改了推理设备或英文切分后，需要在打轴面板中重新打轴。", entries: [
                SettingsEntry("lyricsEditorAIModel", "AI 打轴模型", keywords: "ai 打轴 模型 下载 删除 文件夹 core ml 离线 model 歌词编辑器", layout: .custom) {
                    LyricsAIModelSettings()
                },
                SettingsEntry("lyricsEditorAIBackend", "推理设备", detail: "默认使用 Neural Engine，也可以改用 GPU 或 CPU", keywords: "ai 打轴 neural engine gpu cpu 神经网络引擎 硬件 加速 歌词编辑器") {
                    StoredSegment(LyricsEditorAITiming.backendKey, default: LyricsAIBackend.neuralEngine, options: LyricsAIBackend.allCases.map { ($0, $0.title) })
                },
                SettingsEntry("lyricsEditorAIEnglishSplit", "英文切分", detail: "自动：按音节拆词，合并过短的片段；按音节：保留所有可对齐的音节；按词：保留当前字块", keywords: "ai 打轴 英文 英语 音节 单词 拆分 切分 歌词编辑器") {
                    StoredSegment(LyricsEditorAITiming.englishSplitKey, default: LyricsAIEnglishSplit.automatic, options: LyricsAIEnglishSplit.allCases.map { ($0, $0.title) })
                },
            ]),
            SettingsGroup("lyricsEditorTranslation", title: "AI 翻译与注音", footer: "打开歌词编辑器时，「AI 翻译与注音」面板从这些选项开始；在面板里修改只影响当前这首歌。", entries: [
                SettingsEntry("lyricsEditorTranslationLanguage", "翻译目标语言", detail: "留空时翻译成\(LyricsEditorTranslationState.defaultLanguage)", keywords: "ai 翻译 语言 译文 english prompt 歌词编辑器") {
                    StoredTextField(LyricsEditorTranslationState.languageKey, placeholder: LyricsEditorTranslationState.defaultLanguage)
                },
                SettingsEntry("lyricsEditorTranslationStyle", "翻译风格", detail: "准确：忠实原意；自然：表达流畅；抒情：注重情感与节奏", keywords: "ai 翻译 风格 准确 自然 抒情 直译 意译 prompt 歌词编辑器") {
                    StoredSegment(LyricsEditorTranslationState.styleKey, default: LyricsTranslation.Style.accurate, options: LyricsTranslation.Style.allCases.map { ($0, $0.title) })
                },
                SettingsEntry("lyricsEditorRubyScript", "注音用字", detail: "留空时使用\(LyricsEditorTranslationState.defaultRubyScript)，也可以填写带声调拼音等", keywords: "ai 注音 假名 平假名 片假名 拼音 ruby 振假名 读音 prompt 歌词编辑器") {
                    StoredTextField(LyricsEditorTranslationState.rubyScriptKey, placeholder: LyricsEditorTranslationState.defaultRubyScript)
                },
            ]),
            SettingsGroup("lyricsEditorTiming", title: "打点", entries: [
                SettingsEntry("lyricsEditorTapLead", "打点补偿", detail: "用打点键或按钮记录时间时提前一点，抵消按键的反应时间；拖动时间轴字块不受影响", keywords: "打点 补偿 提前 延迟 反应 tap 歌词编辑器") {
                    StoredMenu(LyricsEditorView.tapLeadKey, default: 0, options: LyricsEditorView.tapLeads.map { ($0, LyricsEditorFormat.lead($0)) })
                },
                SettingsEntry("lyricsEditorAutoAlign", "打完一行后自动排字", detail: "打点打完一行后，按人声自动排好这一行的逐字时间", keywords: "打点 自动排字 对齐 逐字 校准 歌词编辑器") {
                    StoredSwitch(LyricsEditorView.autoAlignAfterTimingKey)
                },
                SettingsEntry("lyricsEditorSpectrogramGain", "频谱亮度", detail: "时间轴频谱的显示亮度，不改变歌词时间", keywords: "频谱 亮度 增益 时间轴 波形 歌词编辑器") {
                    StoredMenu(LyricsEditorTimeline.gainKey, default: Double(Spectrogram.defaultGain), options: LyricsEditorTimeline.gains.map { ($0, LyricsEditorFormat.gain($0)) })
                },
            ]),
            SettingsGroup("lyricsEditorOnsets", title: "起字提示", footer: "提示来自本机对分离人声的自动分析，只作拖动对齐的参考，不会改动歌词时间。", entries: [
                SettingsEntry("lyricsEditorOnsetHints", "起字提示", detail: "在时间轴频谱上用虚线标出疑似开口的时间，拖动字块时可以吸附", keywords: "起字 提示 开口 人声 吸附 onset 歌词编辑器") {
                    StoredSwitch(LyricsEditorTimeline.onsetHintsKey)
                },
                SettingsEntry("lyricsEditorOnsetSensitivity", "灵敏度", detail: "低：只提示明显起点；中：标准；高：显示更多候选", keywords: "起字 提示 灵敏度 onset 歌词编辑器") {
                    StoredSegment(LyricsEditorTimeline.onsetSensitivityKey, default: VocalOnsetDetector.Sensitivity.medium, options: [(.low, "低"), (.medium, "中"), (.high, "高")])
                },
                SettingsEntry("lyricsEditorSplitOnsetHints", "分轨起字提示", detail: "两条人声重叠时，先在本机分成人声 A、B 再分别分析，需要更长时间", keywords: "起字 提示 分轨 对唱 合唱 人声 a b 分离 歌词编辑器", advanced: true) {
                    StoredSwitch(LyricsEditorTimeline.splitOnsetHintsKey)
                },
            ]),
            SettingsGroup("lyricsEditorReset", advanced: true, entries: [
                SettingsEntry("lyricsEditorReset", "恢复歌词编辑器默认设置", detail: "这一页的选项回到初始值；选用的 AI 模型和已下载的模型文件会保留", keywords: "重置 reset 歌词编辑器", advanced: true) {
                    SettingsButton(title: "恢复默认", systemName: "arrow.counterclockwise") {
                        withAnimation(Motion.reveal) { LyricsEditorPreferences.reset() }
                    }
                },
            ]),
        ]
    }
}

private struct LyricsAIModelSettings: View {
    @Environment(\.theme) private var theme
    @AppStorage(LyricsAIModelDownloadState.directoryKey) private var modelPath = ""
    @State private var info: LyricsEditorAITimingState.ModelInfo?
    @State private var failure: String?
    @State private var checking = false
    @State private var confirmingRemoval = false
    private let download = LyricsAIModelDownloadState.shared

    private var directory: URL? { modelPath.isEmpty ? nil : URL(fileURLWithPath: modelPath, isDirectory: true) }
    private var usesInstalled: Bool { download.installedDirectory?.path == modelPath }
    private var supported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
    private var danger: Color { Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accent.opacity(0.12))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "wand.and.stars").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.accent))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(info?.name ?? "AI 打轴模型")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                        if let info, !info.hasEnglishReadings {
                            Tag(text: "无英文词典", style: .amber, soft: true)
                                .help("模型目录中没有英文读音词典，英文段落建议补充假名注音")
                        }
                    }
                    status
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 12)
                primaryButton
            }
            if download.isDownloading {
                downloadProgress.transition(.opacity.combined(with: .offset(y: -4)))
            } else if let text = download.error ?? download.notice {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: download.error == nil ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(download.error == nil ? theme.onSurfaceVariant : danger)
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                SettingsButton(title: "选择文件夹…", systemName: "folder", action: chooseModel)
                    .disabled(download.isDownloading)
                if let directory {
                    SettingsButton(title: "在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if download.installedDirectory != nil {
                    SettingsButton(title: "删除已下载的模型", systemName: "trash", role: .destructive) { confirmingRemoval = true }
                        .disabled(download.isDownloading)
                }
            }
            .padding(.leading, 62)
        }
        .padding(16)
        .animation(Motion.reveal, value: download.isDownloading)
        .animation(Motion.reveal, value: download.installedDirectory)
        .animation(Motion.reveal, value: info?.name)
        .task { await download.discover() }
        .task(id: [modelPath, download.installedDirectory?.path ?? ""]) { await check() }
        .confirmationDialog("删除已下载的 AI 打轴模型？", isPresented: $confirmingRemoval) {
            Button("删除", role: .destructive) { download.removeInstalled() }
        } message: {
            Text("模型文件会从这台 Mac 上删除，之后需要时可以重新下载。")
        }
    }

    @ViewBuilder
    private var status: some View {
        if checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检查模型…")
            }
        } else if let failure {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(danger)
                Text(failure).lineLimit(2)
            }
            .help(failure)
        } else if info != nil, let directory {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary)
                Text(usesInstalled ? "已就绪 · 推荐模型" : "已就绪 ·")
                if !usesInstalled {
                    Text((directory.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(directory.path)
        } else if !supported {
            Text("AI 打轴需要 macOS 15 或更新版本")
        } else {
            Text("下载推荐模型（\(download.downloadSize)）后可离线使用，也可以选择已有的模型文件夹")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if download.isDownloading {
            EmptyView()
        } else if download.installedDirectory != nil {
            if !usesInstalled {
                SettingsButton(title: "使用推荐模型", systemName: "checkmark.circle", role: info == nil ? .prominent : .normal) { download.useInstalled() }
            }
        } else if supported {
            SettingsButton(title: download.error == nil ? "下载 \(download.downloadSize)" : "重试下载", systemName: "arrow.down.circle", role: info == nil ? .prominent : .normal) {
                download.start()
            }
            .disabled(download.isChecking)
        }
    }

    private var downloadProgress: some View {
        let downloading = download.progress.stage == .downloading
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(download.progressText)
                Spacer(minLength: 8)
                if downloading, download.progress.receivedBytes > 0 {
                    Text(verbatim: "\(Int(download.fraction * 100))%").monospacedDigit()
                }
                IconButton(systemName: "xmark", size: 22, iconSize: 9, help: download.isCancelling ? "正在停止…" : "取消下载") {
                    download.cancel()
                }
                .disabled(download.isCancelling)
            }
            AIProgressBar(fraction: downloading ? download.fraction : 1, active: !download.isCancelling)
            Text("关闭设置后会继续下载，完成后自动选用模型。")
                .font(.system(size: 11))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.leading, 62)
    }

    private func check() async {
        info = nil; failure = nil
        guard let directory else { checking = false; return }
        checking = true
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { () throws -> LyricsEditorAITimingState.ModelInfo in
                let bundle = try LyricsAIModelBundle.load(from: directory)
                return .init(name: bundle.name, hasEnglishReadings: !bundle.englishReadings.isEmpty)
            }
        }.value
        guard !Task.isCancelled else { return }
        checking = false
        switch outcome {
        case .success(let found): info = found
        case .failure(let error): failure = error.localizedDescription
        }
    }

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

private struct StoredSwitch: View {
    @AppStorage private var isOn: Bool

    init(_ key: String, default value: Bool = false) {
        _isOn = AppStorage(wrappedValue: value, key)
    }

    var body: some View { SettingsSwitch(isOn: $isOn) }
}

private struct StoredSegment<Value: RawRepresentable & Hashable>: View where Value.RawValue == String {
    @AppStorage private var value: Value
    var options: [(value: Value, title: String)]

    init(_ key: String, default value: Value, options: [(value: Value, title: String)]) {
        _value = AppStorage(wrappedValue: value, key)
        self.options = options
    }

    var body: some View { SegmentSwitch(selection: $value, options: options) }
}

private struct StoredMenu: View {
    @AppStorage private var value: Double
    var options: [(Double, String)]

    init(_ key: String, default value: Double, options: [(Double, String)]) {
        _value = AppStorage(wrappedValue: value, key)
        self.options = options
    }

    var body: some View {
        let nearest = options.min { abs($0.0 - value) < abs($1.0 - value) }?.0 ?? value
        SettingsMenu(selection: Binding { nearest } set: { value = $0 }, options: options)
    }
}

private struct StoredTextField: View {
    @AppStorage private var text: String
    var placeholder: String

    init(_ key: String, placeholder: String) {
        _text = AppStorage(wrappedValue: "", key)
        self.placeholder = placeholder
    }

    var body: some View { SettingsTextField(text: $text, placeholder: placeholder, width: 180) }
}
