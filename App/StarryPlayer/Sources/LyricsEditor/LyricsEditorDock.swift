import AppKit
import SwiftUI

struct LyricsEditorDock: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    var tap: () -> Void
    var release: () -> Void
    var manageTracks: () -> Void
    @Environment(\.theme) private var theme
    @State private var viewport = LyricsTimelineViewport()
    @AppStorage(LyricsEditorDock.timelineHeightKey) private var timelineHeight = LyricsEditorDock.defaultTimelineHeight
    @State private var resizeStart: Double?
    @State private var handleHovered = false

    static let timelineHeightKey = "starry.lyricsEditor.timelineHeight"
    static let defaultTimelineHeight = 180.0
    /// The lower bound leaves two lanes room over the tray.
    static let timelineHeights: ClosedRange<Double> = 136...340

    static func height(timeline: Double) -> CGFloat {
        CGFloat(min(max(timeline, timelineHeights.lowerBound), timelineHeights.upperBound)) + 120
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                VStack(spacing: 8) {
                    LyricsEditorOverview(session: session, audio: audio, clock: clock, viewport: viewport)
                    LyricsEditorTimeline(session: session, audio: audio, clock: clock, viewport: viewport, manageTracks: manageTracks)
                        .frame(height: CGFloat(min(max(timelineHeight, Self.timelineHeights.lowerBound), Self.timelineHeights.upperBound)))
                }
                transport
            }
            .frame(maxWidth: .infinity)
            LyricsEditorInspector(session: session)
                .frame(width: 300)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: Self.height(timeline: timelineHeight))
        .background(theme.surfaceAlt.ignoresSafeArea())
        .overlay(alignment: .top) { Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(height: 1) }
        .overlay(alignment: .top) { resizeHandle }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(theme.primary)
            .frame(height: 2)
            .opacity(handleHovered || resizeStart != nil ? 1 : 0)
            .frame(height: 8, alignment: .top)
            .contentShape(Rectangle())
            .onHover { inside in
                handleHovered = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = resizeStart ?? timelineHeight
                    resizeStart = start
                    timelineHeight = min(max(start - Double(value.translation.height), Self.timelineHeights.lowerBound), Self.timelineHeights.upperBound)
                }
                .onEnded { _ in resizeStart = nil })
            .animation(Motion.hover, value: handleHovered)
            .help("拖动调整时间轴高度")
    }

    private var transport: some View {
        HStack(spacing: 10) {
            LyricsEditorPlayButton(audio: audio)
            DockClock(clock: clock, duration: audio.duration)
            HStack(spacing: 6) {
                RateMenu(audio: audio)
                VolumeControl(audio: audio)
            }
            .disabled(!audio.isReady)
            .opacity(audio.isReady ? 1 : 0.45)
            if audio.isReady, !audio.isPrecise {
                Label("流式播放", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .help("这首歌的格式没法预先解码，开始播放和跳转会慢半拍")
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                TimingKey(title: "撤回", key: "⇧⌫", variant: .ghost, help: "撤回上一次打点（⇧⌫）") { session.stepBack() }
                TimingKey(title: "结束", key: "H", variant: .tertiary, help: "在这里结束刚唱的音节，用于停顿和行尾（H、K 或 ↩）", action: release)
                TimingKey(title: "打点", key: "F", variant: .filled, help: "开始当前音节，并结束上一个（F、G 或 J）", action: tap)
            }
            .disabled(session.draft.isEmpty)
            .opacity(session.draft.isEmpty ? 0.45 : 1)
        }
        .frame(height: 34)
    }
}

private struct LyricsEditorPlayButton: View {
    let audio: LyricsEditorAudio
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "gobackward", size: 30, iconSize: 13, help: "后退 3 秒（⇧←）") { audio.seek(by: -3) }
            Button { audio.togglePlayPause() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.onPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(VariantButtonStyle(variant: .filled, isCircle: true))
            .help("播放 / 暂停（空格）")
            IconButton(systemName: "goforward", size: 30, iconSize: 13, help: "前进 3 秒（⇧→）") { audio.seek(by: 3) }
        }
        .disabled(!audio.isReady)
        .opacity(audio.isReady ? 1 : 0.45)
    }
}

private struct RateMenu: View {
    let audio: LyricsEditorAudio
    @Environment(\.theme) private var theme

    var body: some View {
        PopMenu {
            PopMenuItem.header("播放速度")
            for rate in LyricsEditorAudio.rates {
                PopMenuItem.option(LyricsEditorFormat.rate(rate), selected: abs(audio.rate - rate) < 0.001) { audio.setRate(rate) }
            }
        } label: { open in
            Text(LyricsEditorFormat.rate(audio.rate))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(audio.rate == 1 ? theme.onSurface.opacity(0.8) : theme.primary)
                .contentTransition(.numericText(value: audio.rate))
                .frame(minWidth: 44)
                .frame(height: 26)
                .padding(.horizontal, 2)
        }
        .buttonStyle(VariantButtonStyle(variant: audio.rate == 1 ? .ghost : .tertiary, isPill: true))
        .animation(Motion.hover, value: audio.rate)
        .help("播放速度，音高不变（[ 减慢、] 加快、' 复原）")
    }
}

private struct VolumeControl: View {
    let audio: LyricsEditorAudio
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: audio.volume)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.7))
                .frame(width: 20)
            ProgressSlider(value: Binding { audio.volume } set: { audio.setVolume($0) }, trackHeight: 3, thumbSize: 10, tint: theme.onSurface.opacity(0.75))
                .frame(width: 72)
        }
        .help("编辑器的音量")
    }
}

/// The position over the song's length; a leaf, so the clock re-runs only this.
private struct DockClock: View {
    let clock: LyricsEditorClock
    var duration: TimeInterval
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(LyricsEditorFormat.time(clock.time))
                .foregroundStyle(theme.onSurface)
            Text("/ \(LyricsEditorFormat.time(duration))")
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
    }
}

private struct TimingKey: View {
    var title: String
    var key: String
    var variant: ButtonVariant
    var help: String
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(foreground.opacity(0.14)))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
        .buttonStyle(VariantButtonStyle(variant: variant, isPill: true))
        .help(help)
    }

    private var foreground: Color { variant == .filled ? theme.onPrimary : theme.onSurface.opacity(0.85) }
}
