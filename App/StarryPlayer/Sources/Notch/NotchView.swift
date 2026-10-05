import AppKit
import StarryCore
import SwiftUI

/// The notch panel's content: the island at the top, centred (the panel is centred on the notch).
struct NotchRoot: View {
    let island: NotchModel
    let actions: NotchActions
    let app: AppModel

    var body: some View {
        NotchIsland(island: island, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .environment(app)
            .environment(\.colorScheme, .dark)
    }
}

/// Black like the notch, in the cover's colour where it has one. The cover and bars are one view
/// each in every phase, so they travel between their places as the island opens and closes.
private struct NotchIsland: View {
    let island: NotchModel
    let actions: NotchActions
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = island.layout
        let player = model.player
        let shape = NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
        let theme = Theme.make(seed: player.accentColor, dark: true, tintSurfaces: false)
        let shown = layout.phase != .hidden && player.current != nil
        ZStack(alignment: .topLeading) {
            if let frame = layout.lyric {
                Text(island.lyric)
                    .font(Font(NotchController.lyricFont as CTFont))
                    .foregroundStyle(.white.opacity(player.isPlaying ? 0.92 : 0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .frame(width: frame.width, height: frame.height, alignment: .leading)
                    .position(x: frame.midX, y: frame.midY)
                    .transition(.opacity)
            }
            if let frame = layout.controls {
                NotchControls(layout: layout, onScrub: actions.scrub, openNowPlaying: actions.openNowPlaying)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .position(x: frame.midX, y: frame.midY)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.08)), removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
            if let track = player.current {
                NotchCover(track: track, radius: layout.coverRadius, open: layout.phase == .expanded, openNowPlaying: actions.openNowPlaying)
                    .frame(width: layout.cover.width, height: layout.cover.height)
                    .position(x: layout.cover.midX, y: layout.cover.midY)
                    .opacity(shown ? 1 : 0)
            }
            NotchWaveform(color: theme.accent, playing: shown && player.isPlaying)
                .frame(width: layout.bars.width, height: layout.bars.height)
                .position(x: layout.bars.midX, y: layout.bars.midY)
                .opacity(shown ? 1 : 0)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .clipShape(shape)
        .background {
            shape.fill(.black)
                .shadow(color: .black.opacity(layout.phase == .expanded ? 0.45 : 0), radius: 16, y: 8)
        }
        // Without a notch to stay in, the hidden island fades away as it shrinks.
        .opacity(shown || island.geometry.hasNotch ? 1 : 0)
        .contentShape(shape)
        .onHover { actions.hover($0) }
        .onTapGesture { actions.tap() }
        .offset(x: layout.offset)
        .environment(\.theme, theme)
    }
}

/// Settles back while paused, like the player bar's; open, a click goes to the Now Playing page.
private struct NotchCover: View {
    var track: Track
    var radius: CGFloat
    var open: Bool
    var openNowPlaying: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let player = model.player
        let awake = player.isPlaying || open
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ArtworkView(artwork: track.artwork ?? track.album?.artwork, radius: 0, pixelSize: 160, fallback: player.coverImage)
            .overlay {
                shape.fill(.black.opacity(open && hovering ? 0.4 : 0))
                    .overlay {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(open && hovering ? 1 : 0)
                    }
            }
            .clipShape(shape)
            .scaleEffect(awake ? 1 : 0.86)
            .opacity(awake ? 1 : 0.7)
            .animation(Motion.pause, value: awake)
            .animation(Motion.hover, value: hovering)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { openNowPlaying() }
            .allowsHitTesting(open)
            .help("打开播放页")
    }
}

/// The open island beside the cover (which floats in the space left for it): title, artist and
/// the line being sung, then the progress and the transport.
private struct NotchControls: View {
    var layout: NotchLayout
    var onScrub: @MainActor (Bool) -> Void
    var openNowPlaying: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private static let gap: CGFloat = 12

    var body: some View {
        let player = model.player
        let track = player.current
        let textWidth = (layout.controls?.width ?? 0) - layout.cover.width - Self.gap - layout.bars.width - 10
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.cover.width + Self.gap)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                    Text(subtitle(track))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                    if player.lyrics != nil {
                        OneLineLyrics(tint: theme.accent, fontSize: 12.5, width: textWidth, showsSongWhenIdle: false)
                            .frame(width: textWidth, height: 18)
                    }
                }
                .lineLimit(1)
                .frame(width: textWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(height: layout.cover.height)
            NotchProgress(onScrub: onScrub)
                .padding(.top, 12)
            NotchTransport(openNowPlaying: openNowPlaying)
                .padding(.top, 4)
        }
    }

    private func subtitle(_ track: Track?) -> String {
        guard let track else { return "" }
        return [track.artistText, track.album?.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Times either side of the bar; dragging it seeks when let go, like the player bar's.
private struct NotchProgress: View {
    var onScrub: @MainActor (Bool) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let player = model.player
        let duration = max(player.duration, 1)
        let time = scrubbing ? scrubValue : player.currentTime
        HStack(spacing: 10) {
            Text(TimeFormatting.clock(time))
                .frame(width: 38, alignment: .leading)
            ProgressSlider(value: Binding { time } set: { scrubValue = $0 }, range: 0...duration, trackHeight: 4, thumbSize: 10,
                           tint: theme.onSurface, trackTint: theme.onSurface.opacity(0.18)) { editing in
                if editing {
                    scrubValue = time
                    scrubbing = true
                    player.isSeeking = true
                } else {
                    scrubbing = false
                    player.isSeeking = false
                    player.seek(to: scrubValue)
                }
                onScrub(editing)
            }
            Text("-" + TimeFormatting.clock(max(duration - time, 0)))
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(theme.onSurfaceVariant)
        .frame(height: 18)
    }
}

/// Like on the left, previous / play / next in the middle, the Now Playing page on the right.
private struct NotchTransport: View {
    var openNowPlaying: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let player = model.player
        HStack(spacing: 0) {
            Group {
                if let track = player.current, model.canLike(track) {
                    HeartButton(track: track, size: 30)
                } else {
                    Color.clear.frame(width: 30, height: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                IconButton(systemName: "backward.fill", size: 34, iconSize: 15, help: "上一曲") { player.previous() }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .offset(x: player.isPlaying ? 0 : 1.5)
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(theme.onSurface))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchPressStyle())
                .help(player.isPlaying ? "暂停" : "播放")
                IconButton(systemName: "forward.fill", size: 34, iconSize: 15, help: "下一曲") { player.next() }
            }
            IconButton(systemName: "arrow.up.forward.app", size: 30, iconSize: 14, help: "打开播放页") { openNowPlaying() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 38)
    }
}

private struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

