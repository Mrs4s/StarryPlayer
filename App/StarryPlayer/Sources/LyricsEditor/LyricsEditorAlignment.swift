import AudioProcessing
import LyricsCore
import LyricsSync
import SwiftUI

struct LyricsEditorAlignment: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    var close: () -> Void
    @State private var state: LyricsEditorAlignmentState
    @Environment(\.theme) private var theme

    init(session: LyricsEditorSession, audio: LyricsEditorAudio, line: LyricsDraft.Line, close: @escaping () -> Void) {
        self.session = session
        self.audio = audio
        self.close = close
        _state = State(initialValue: LyricsEditorAlignmentState(line: line, revision: session.revision,
                                                               duration: audio.duration, playhead: audio.currentTime))
    }

    var body: some View {
        EditorPanel(title: "当前行自动排字", subtitle: "先设置这一行的搜索范围，再根据人声起字提示生成时间。", width: 660, close: close) {
            VStack(alignment: .leading, spacing: 12) {
                Text(state.original.text).font(.system(size: 15, weight: .medium)).lineLimit(2)
                rangeFields
                HStack {
                    if let range = state.suggestedRange {
                        Button("使用原行范围") {
                            state.start = LyricsEditorFormat.time(range.lowerBound, digits: 3)
                            state.end = LyricsEditorFormat.time(min(range.upperBound, audio.duration), digits: 3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.primary)
                    }
                    Spacer()
                    Button("从起点试听") {
                        if let input = state.input { audio.seek(to: input.range.lowerBound); audio.play() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.primary)
                    .disabled(state.input == nil || !audio.isReady)
                }
                .font(.system(size: 12))
                if state.original.syllables.contains(where: \.isTimed) {
                    SegmentSwitch(selection: $state.mode, options: [(.calibrate, "校准已有时间"), (.arrange, "重新排字")])
                }
                options
                Text(state.mode == .calibrate ? "参考原有节奏调整起字时间；偏差较大时可扩大搜索距离，或改用重新排字。" : "重新计算当前行的逐字时间；缺少起字依据的位置会标为估计。")
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if state.language == .japanese {
                    Text("日语优先参考字块注音；特殊读法可先补全注音或合并字块。")
                        .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                }
                if state.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("准备人声并分析当前行…").font(.system(size: 12.5))
                    }
                }
                if let error = state.error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.input == nil {
                    Text("请输入有效的开始和结束时间，范围须在歌曲时长以内。")
                        .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                }
                if let result = state.result { preview(result) }
                if session.revision != state.revision {
                    Text("歌词已发生变化，请关闭后重新打开自动排字。")
                        .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            HStack(spacing: 8) {
                Text("应用会替换当前行时间，可用 ⌘Z 撤销")
                    .font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 0)
                PillButton(title: "取消", variant: .ghost, height: 32, action: close)
                PillButton(title: state.isWorking ? "停止" : (state.result == nil ? "分析" : "重新分析"), variant: .secondary, height: 32) {
                    if state.isWorking { state.cancel() }
                    else { state.analyze { try await audio.alignmentAnalysis(in: $0.range, voice: $0.voice) } }
                }
                .disabled(!state.isWorking && (state.input == nil || !audio.isPrecise || session.revision != state.revision))
                PillButton(title: "应用", variant: .filled, height: 32) {
                    if state.apply(in: session) { close() }
                }
                .disabled(!state.canApply(in: session))
            }
        }
        .foregroundStyle(theme.onSurface)
        .onChange(of: state.input) { _, _ in state.invalidate() }
        .onDisappear { state.cancel() }
    }

    private var rangeFields: some View {
        HStack(spacing: 18) {
            timeField("范围开始", text: $state.start)
            timeField("范围结束", text: $state.end)
        }
    }

    private func timeField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            TextField("00:00.000", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13).monospacedDigit())
                .padding(8)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button))
                .accessibilityLabel(title)
            IconButton(systemName: "arrow.down.to.line", size: 26, iconSize: 12, help: "将\(title)设为播放位置") {
                text.wrappedValue = LyricsEditorFormat.time(audio.currentTime, digits: 3)
            }
        }
    }

    private var options: some View {
        HStack(spacing: 14) {
            Picker("语言", selection: $state.language) {
                Text("自动").tag(LyricsTimingWeights.Language.automatic)
                Text("中文").tag(LyricsTimingWeights.Language.chinese)
                Text("日语").tag(LyricsTimingWeights.Language.japanese)
            }
            .frame(width: 150)
            if state.mode == .calibrate {
                Picker("搜索距离", selection: $state.maximumAdjustment) {
                    ForEach([0.15, 0.35, 0.6, 1.0], id: \.self) { value in Text("±\(value, specifier: "%.2f") 秒").tag(value) }
                }
                .frame(width: 190)
            }
            if audio.duetStatus == .ready {
                Picker("人声", selection: $state.voice) {
                    ForEach(LyricsEditorAudio.HintVoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 150)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private func preview(_ result: LyricsLineAligner.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(result.matchedCount) 个起点匹配提示 · \(result.estimatedCount) 个起点为估计，请结合试听复核")
                .font(.system(size: 12, weight: .medium))
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(result.line.syllables.indices, id: \.self) { index in
                        let syllable = result.line.syllables[index]
                        HStack(spacing: 10) {
                            Text(syllable.text).lineLimit(1).frame(width: 80, alignment: .leading)
                            Text(times(state.original.syllables[index]))
                                .foregroundStyle(theme.onSurfaceVariant)
                            Image(systemName: "arrow.right").foregroundStyle(theme.onSurfaceVariant)
                            Text(times(syllable))
                            Spacer(minLength: 0)
                            Text(result.matched[index] ? "起字匹配" : "估计")
                                .foregroundStyle(result.matched[index] ? theme.primary : theme.onSurfaceVariant)
                        }
                        .font(.system(size: 11.5).monospacedDigit())
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(height: min(180, CGFloat(result.matched.count) * 27))
        }
    }

    private func times(_ syllable: LyricsDraft.Syllable) -> String {
        guard let start = syllable.start else { return "未打点" }
        return LyricsEditorFormat.time(start, digits: 3) + " – " + (syllable.end.map { LyricsEditorFormat.time($0, digits: 3) } ?? "—")
    }
}
