import AppKit
import AudioProcessing
import LyricsCore
import SwiftUI

struct LyricsEditorTimeline: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    let viewport: LyricsTimelineViewport
    var manageTracks: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage(LyricsEditorTimeline.gainKey) private var gain = Double(Spectrogram.defaultGain)
    @AppStorage(LyricsEditorTimeline.vocalsOnlyKey) private var vocalsOnly = false
    @AppStorage("starry.lyricsEditor.onsetHints") private var onsetHints = false
    @AppStorage("starry.lyricsEditor.onsetSensitivity") private var sensitivity = VocalOnsetDetector.Sensitivity.medium

    static let gainKey = "starry.lyricsEditor.spectrogramGain"
    static let vocalsOnlyKey = "starry.lyricsEditor.vocalsOnly"
    static let gains: [Double] = [1, 1.5, 2, 3, 4, 6, 8]
    private var onSpectrogram: Bool { audio.isPrecise }
    private var accent: Color { onSpectrogram ? model.theme(for: .dark).primary : theme.primary }
    private var lineIndex: Int? { (session.caret ?? session.lastStarted)?.line }
    private struct OnsetRequest: Equatable {
        var enabled: Bool
        var precise: Bool
        var vocalsReady: Bool
    }

    private var onsets: [VocalOnset] {
        onsetHints && audio.onsetStatus == .ready ? audio.onsets.filter { $0.strength >= sensitivity.minimumStrength } : []
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035))
            if let lineIndex, let range = viewport.range(caretLine: lineIndex, in: session) {
                if onSpectrogram {
                    TimelineSpectrogram(audio: audio, range: range, gain: Float(gain), vocalsOnly: vocalsOnly && audio.vocals == .ready)
                        .padding(.top, 26)
                        .padding(.bottom, LyricsTimelineView.trayHeight)
                        .allowsHitTesting(false)
                } else if let waveform = audio.waveform {
                    TimelineWaveform(waveform: waveform, range: range, color: theme.onSurface)
                        .padding(.top, 26)
                        .padding(.bottom, LyricsTimelineView.trayHeight + 4)
                        .allowsHitTesting(false)
                }
                LyricsTimelineSurface(session: session, audio: audio, clock: clock, viewport: viewport,
                                      revision: session.revision, caret: session.caret, range: range,
                                      theme: theme, accent: NSColor(accent), onSpectrogram: onSpectrogram,
                                      canPlay: audio.isReady, onsets: onsets)
                HStack(spacing: 6) {
                    tracksMenu
                    if onSpectrogram {
                        onsetSwitch
                        if onsetHints { sensitivityMenu }
                        vocalsSwitch
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 3)
                    .padding(.trailing, 6)
            } else {
                Text("导入歌词并选中一行，这里会显示它的时间轴")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onChange(of: lineIndex) { _, line in
            if viewport.interactionRange == nil, !viewport.keepsSpan(movingTo: line) { viewport.manual = nil }
        }
        .task(id: vocalsOnly && audio.isPrecise) {
            if vocalsOnly, audio.isPrecise { audio.prepareVocals() }
        }
        .task(id: OnsetRequest(enabled: onsetHints, precise: audio.isPrecise, vocalsReady: audio.vocals == .ready)) {
            if onsetHints, audio.isPrecise { audio.prepareOnsets() }
            else {
                audio.cancelOnsets()
                if !vocalsOnly, case .separating = audio.vocals { audio.discardVocals() }
            }
        }
    }

    private var tracksMenu: some View {
        let tracks = session.draft.tracks.count
        let line = lineIndex.flatMap { session.draft.lines.indices.contains($0) ? session.draft.lines[$0] : nil }
        return PopMenu {
            PopMenuItem.header("虚拟轨：把重叠的行分开编辑，不写进 TTML")
            PopMenuItem.button("新建轨道", systemImage: "plus") { session.addTrack() }
            PopMenuItem.button("把当前行移到新轨道", systemImage: "arrow.down.to.line", disabled: line == nil) { session.addTrack(moving: line?.id) }
            if let line, line.track != nil {
                PopMenuItem.button("把当前行移回按演唱分的轨道", systemImage: "arrow.up.to.line") { session.setTrack(nil, ofLine: line.id) }
            }
            PopMenuItem.button("按重叠自动分轨", systemImage: "wand.and.stars", disabled: session.draft.timedCount == 0) { session.separateOverlaps() }
            PopMenuItem.divider
            PopMenuItem.button("管理轨道…", systemImage: "slider.horizontal.3", action: manageTracks)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.1x2")
                Text(tracks == 0 ? "轨道" : "轨道 \(tracks)")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.onSurface.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(theme.surfaceAlt.opacity(0.95)))
            .overlay(Capsule().strokeBorder(theme.onSurface.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("虚拟轨：重叠的主唱、和声各放一条轨道，⌘ 拖动字块可以整行换轨。轨道只存在歌词工程里，导出 TTML 时仍按演唱和背景人声写入")
        .accessibilityLabel("虚拟轨")
    }

    private var onsetSwitch: some View {
        Button { onsetHints.toggle() } label: {
            HStack(spacing: 5) {
                if onsetHints && (audio.onsetStatus == .analyzing || audio.vocals.isSeparating) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "waveform.path")
                }
                Text(onsetLabel)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(onsetHints ? theme.onPrimary : theme.onSurface.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(onsetHints ? theme.primary : theme.surfaceAlt.opacity(0.95)))
            .overlay(Capsule().strokeBorder(theme.onSurface.opacity(onsetHints ? 0 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(onsetHelp)
        .accessibilityLabel("起字提示")
        .accessibilityValue(onsetHints ? onsetLabel : "已关闭")
    }

    private var onsetLabel: String {
        guard onsetHints else { return "起字提示" }
        if case .failed = audio.vocals { return "起字提示不可用" }
        if case .failed = audio.onsetStatus { return "起字提示失败" }
        if audio.vocals.isSeparating { return "准备人声…" }
        if audio.onsetStatus == .analyzing { return "分析起字点…" }
        return "起字提示"
    }

    private var onsetHelp: String {
        if onsetHints {
            if case .failed(let message) = audio.vocals { return message + "；关闭再开启可重试" }
            if case .failed(let message) = audio.onsetStatus { return message + "；关闭再开启可重试" }
            if audio.onsetStatus == .ready, onsets.isEmpty { return "未找到明显的起字点，可提高灵敏度" }
        }
        return "在人声中寻找疑似起字点，以虚线提示；拖动边界可吸附，按住 Option 跳过提示吸附"
    }

    private var sensitivityMenu: some View {
        PopMenu {
            PopMenuItem.header("起字提示灵敏度")
            PopMenuItem.option("低 · 只提示明显起点", selected: sensitivity == .low) { sensitivity = .low }
            PopMenuItem.option("中 · 标准", selected: sensitivity == .medium) { sensitivity = .medium }
            PopMenuItem.option("高 · 更多候选", selected: sensitivity == .high) { sensitivity = .high }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(theme.surfaceAlt.opacity(0.95)))
        }
        .help("起字提示灵敏度")
        .accessibilityLabel("起字提示灵敏度")
    }

    private var vocalsSwitch: some View {
        Button {
            vocalsOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                switch (vocalsOnly, audio.vocals) {
                case (true, .separating(let progress)):
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("分离人声 \(Int(progress * 100))%")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                case (true, .failed):
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("仅人声")
                default:
                    Image(systemName: vocalsOnly ? "person.wave.2.fill" : "person.wave.2")
                    Text("仅人声")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(vocalsOnly ? theme.onPrimary : theme.onSurface.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(vocalsOnly ? theme.primary : theme.surfaceAlt.opacity(0.95)))
            .overlay(Capsule().strokeBorder(theme.onSurface.opacity(vocalsOnly ? 0 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: vocalsOnly)
        .animation(Motion.hover, value: audio.vocals)
        .help(vocalsHelp)
    }

    private var vocalsHelp: String {
        if case .failed(let message) = audio.vocals, vocalsOnly { return message }
        return vocalsOnly ? "频谱只显示分离出的人声，点按显示整首歌" : "用人声分离模型只显示人声的频谱，字的起止更清楚"
    }

}

private extension LyricsEditorAudio.VocalsStatus {
    var isSeparating: Bool {
        if case .separating = self { return true }
        return false
    }
}

private struct TimelineWaveform: View {
    let waveform: WaveformPeaks
    var range: ClosedRange<TimeInterval>
    var color: Color

    var body: some View {
        Canvas { context, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0, size.width > 0 else { return }
            let step: CGFloat = 2
            let secondsPerStep = span / Double(size.width) * Double(step)
            let middle = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let t = range.lowerBound + Double(x) / Double(size.width) * span
                // A square root lifts quiet passages enough to see.
                let level = CGFloat(sqrt(waveform.peak(from: t, to: t + secondsPerStep)))
                let half = max(0.5, level * middle)
                path.addRect(CGRect(x: x, y: middle - half, width: step - 0.6, height: half * 2))
                x += step
            }
            context.fill(path, with: .color(color.opacity(0.32)))
        }
    }
}

/// Keeps the previous image at its original span until the debounced render completes.
private struct TimelineSpectrogram: View {
    let audio: LyricsEditorAudio
    var range: ClosedRange<TimeInterval>
    var gain: Float
    var vocalsOnly: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var picture: (image: CGImage, range: ClosedRange<TimeInterval>)?

    private struct Request: Equatable {
        var range: ClosedRange<TimeInterval>
        var size: CGSize
        var gain: Float
        var scale: CGFloat
        var vocalsOnly: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let scale = span > 0 ? geo.size.width / span : 0
            ZStack(alignment: .topLeading) {
                Color.black
                if let picture {
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: CGFloat(picture.range.upperBound - picture.range.lowerBound) * scale, height: geo.size.height)
                        .offset(x: CGFloat(picture.range.lowerBound - range.lowerBound) * scale)
                }
            }
            .task(id: Request(range: range, size: geo.size, gain: gain, scale: displayScale, vocalsOnly: vocalsOnly)) {
                // Spans change on every frame of a drag: draw once they settle.
                try? await Task.sleep(for: .milliseconds(picture == nil ? 0 : 40))
                guard !Task.isCancelled else { return }
                let width = Int(geo.size.width * displayScale), height = Int(geo.size.height * displayScale)
                guard let image = await audio.spectrogram(of: range, width: width, height: height, gain: gain, vocalsOnly: vocalsOnly), !Task.isCancelled else { return }
                picture = (image, range)
            }
        }
        .clipped()
    }
}
