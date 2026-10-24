import LyricsCore
import LyricsUI
import SwiftUI

struct LyricsEditorPreview: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    var isFocused: Bool
    var toggleFocus: () -> Void
    var close: () -> Void
    @Environment(AppModel.self) private var model

    private var isLive: Bool { audio.isReady }
    private var tint: Color { ((model.player.current?.id == session.track.id ? model.player.accentColor : nil) ?? Color(hex: "#FE7971")).lightTint }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let document = session.document
                if document.isEmpty {
                    placeholder
                } else {
                    EditorPreviewLyrics(document: document, specs: specs(height: geo.size.height), audio: audio, clock: clock, tint: tint, alignment: model.settings.settings.lyrics.alignment == .center ? .center : .left, timeSource: clockSource)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .id(isFocused)
                    .transition(.opacity)
                }
            }
            // A fill-scaled cover can report a size larger than the viewport. Keep it out
            // of layout so resizing never pushes the lyrics or controls beyond the panel.
            .frame(width: geo.size.width, height: geo.size.height)
            .background { backdrop }
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Button(action: toggleFocus) {
                        Image(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    .help(isFocused ? "回到编辑" : "全幅预览")
                    .accessibilityLabel(isFocused ? "回到编辑" : "全幅预览")
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    .help("隐藏预览")
                    .accessibilityLabel("隐藏预览")
                }
                .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 28))
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        }
        .environment(\.colorScheme, .dark)
    }

    private var clockSource: () -> (time: TimeInterval, rate: Double) {
        if isLive { return { [audio] in audio.clock() } }
        let line = (session.caret ?? session.lastStarted)?.line ?? 0
        let windows = session.lineWindows
        let time = windows.indices.contains(line) ? windows[line].lowerBound + 0.01 : 0
        return { (time, 0) }
    }

    private func specs(height: CGFloat) -> LyricsSpecs {
        var specs = LyricsSpecs.make(from: model.settings.settings.lyrics, fullscreen: isFocused, viewHeight: height)
        specs.selectedLinePosition = .topRelative(percentage: 34)
        specs.horizontalInset = 28
        return specs
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            if session.track.artwork != nil {
                ArtworkView(artwork: session.track.artwork, radius: 0, pixelSize: 200)
                    .scaledToFill()
                    .blur(radius: 60)
                    .scaleEffect(1.5)
                    .opacity(0.75)
            } else {
                LinearGradient(colors: PlaceholderArt.colors(for: session.track.title), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.75)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(clock.isPlaying && isLive ? Color(hex: "#5FD08A") : tint.opacity(0.4))
                .frame(width: 6, height: 6)
                .shadow(color: Color(hex: "#5FD08A").opacity(clock.isPlaying && isLive ? 0.8 : 0), radius: 4)
            Text(isLive ? (clock.isPlaying ? (audio.rate == 1 ? "实时预览" : "实时预览 · \(LyricsEditorFormat.rate(audio.rate))") : "预览 · 已暂停") : "预览 · 停在当前行")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(tint.opacity(0.1)))
        .padding(12)
        .animation(Motion.hover, value: clock.isPlaying)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "quote.bubble").font(.system(size: 30, weight: .light))
            Text("导入歌词后，在这里预览效果").font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(tint.opacity(0.45))
    }
}

/// The scrub position must not invalidate the artwork, blur, controls or preview layout.
private struct EditorPreviewLyrics: View {
    var document: LyricsDocument
    var specs: LyricsSpecs
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    var tint: Color
    var alignment: NSTextAlignment
    var timeSource: () -> (time: TimeInterval, rate: Double)

    var body: some View {
        LyricsHost(document: document, specs: specs, rate: clock.isPlaying ? audio.rate : 0, color: tint, timeOffset: 0, scrubTime: clock.scrubTime, alignment: alignment, clock: timeSource) { time in
            if audio.isReady { audio.seek(to: time) }
        }
    }
}
