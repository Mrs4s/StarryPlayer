import AppKit
import LyricsCore
import StarryCore
import SwiftUI

enum NowPlayingPanel: Int, CaseIterable, Identifiable {
    case lyrics, comments, queue

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lyrics: "歌词"
        case .comments: "评论"
        case .queue: "队列"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "quote.bubble"
        case .comments: "bubble.left.and.bubble.right"
        case .queue: "list.bullet"
        }
    }
}

/// Song details and source pickers. Fixed `height × k` keeps the cover stable between songs.
struct NowPlayingInfoBlock: View {
    nonisolated static let height: CGFloat = 128

    var track: Track
    var tint: Color
    var k: CGFloat
    @Binding var showAudioInfo: Bool
    @Binding var showLyricsSource: Bool
    var lyricsSourceSearches = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(track.title, selectable: true)
                .font(.system(size: 24 * k, weight: .bold))
                .foregroundStyle(tint)
                .frame(height: 31 * k)
            if let alias = track.alias, !alias.isEmpty {
                Text(alias)
                    .font(.system(size: 15 * k, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .frame(height: 20 * k)
                    .padding(.top, 1 * k)
            }
            TruncatingRow {
                ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                    HStack(spacing: 0) {
                        if index > 0 { Text(" / ").fixedSize() }
                        TextLink(text: artist.name, color: tint.opacity(0.68), hoverColor: tint, action: artist.isLinkable ? { model.showArtist(artist, of: track) } : nil)
                    }
                }
                if let album = track.album {
                    HStack(spacing: 0) {
                        Text(" — ").fixedSize()
                        TextLink(text: album.name, color: tint.opacity(0.68), hoverColor: tint, action: album.isLinkable ? { model.showAlbum(of: track) } : nil)
                    }
                }
            }
            .font(.system(size: 16 * k, weight: .medium))
            .foregroundStyle(tint.opacity(0.68))
            .frame(height: 22 * k)
            .padding(.top, 4 * k)
            tags
                .padding(.top, 14 * k)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tags: some View {
        let player = model.player
        return HStack(spacing: 6 * k) {
            if let quality = qualityText {
                Button { showAudioInfo.toggle() } label: {
                    InfoTag(systemName: "waveform", text: quality, tint: tint, k: k, interactive: true, active: showAudioInfo)
                }
                .buttonStyle(NowPlayingPressStyle())
                .fixedSize()
                .help("音源信息与音质")
                .popover(isPresented: $showAudioInfo, arrowEdge: .top) {
                    AudioSourcePanel(track: track)
                        .environment(model)
                        .environment(\.theme, Theme.darkBase)
                }
            }
            // One tag from no lyrics to lyrics, kept while its popover is open, so picking lyrics
            // there does not take the popover away.
            let lyrics = player.lyrics.flatMap { $0.isEmpty ? nil : $0 }
            if lyrics != nil || !player.lyricsLoading || showLyricsSource {
                Button { showLyricsSource.toggle() } label: {
                    InfoTag(systemName: "quote.bubble", text: lyrics.map(lyricsText) ?? "无歌词", tint: tint, k: k, interactive: true, active: showLyricsSource)
                }
                .buttonStyle(NowPlayingPressStyle())
                .help("歌词来源")
                .popover(isPresented: $showLyricsSource, arrowEdge: .top) {
                    LyricsSourcePanel(track: track, startsWithSearch: lyricsSourceSearches) {
                        showLyricsSource = false
                        model.openSettings(.lyrics)
                    }
                    .environment(model)
                    .environment(\.theme, Theme.darkBase)
                }
            }
        }
        .frame(height: 24 * k)
        .animation(Motion.hover, value: player.lyrics?.format)
    }

    private var qualityText: String? {
        if let asset = model.player.currentAsset, model.player.current?.id == track.id {
            let parts = [model.tierName(asset.tier, of: track), asset.container == .hls ? nil : asset.container.rawValue.uppercased(), asset.isTrial ? "试听" : nil]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        return model.availableTiers(of: track).last?.name
    }

    private func lyricsText(_ lyrics: LyricsDocument) -> String {
        var parts = [model.player.lyricsOrigin?.displayName ?? lyrics.format.rawValue.uppercased()]
        parts.append(lyrics.hasSyllables ? "逐字" : "逐行")
        if lyrics.hasTranslation { parts.append("翻译") }
        if lyrics.hasRomanization { parts.append("音译") }
        return parts.joined(separator: " · ")
    }
}

private struct InfoTag: View {
    var systemName: String
    var text: String
    var tint: Color
    var k: CGFloat
    var interactive = false
    var active = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5 * k) {
            Image(systemName: systemName).font(.system(size: 10 * k, weight: .bold))
            Text(text).font(.system(size: 11.5 * k, weight: .semibold)).lineLimit(1)
            if interactive {
                Image(systemName: "chevron.down").font(.system(size: 7.5 * k, weight: .heavy)).opacity(0.7)
            }
        }
        .foregroundStyle(tint.opacity(interactive && (hovering || active) ? 0.95 : 0.72))
        .padding(.horizontal, 9 * k)
        .frame(height: 22 * k)
        .background(Capsule().fill(tint.opacity(interactive && (hovering || active) ? 0.18 : 0.11)))
        .contentShape(Capsule())
        .onHover { if interactive { hovering = $0 } }
        .animation(Motion.hover, value: hovering)
    }
}

struct NowPlayingLikeButton: View {
    var track: Track
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let liked = model.player.isLiked(track)
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { model.toggleLike(track) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 14 * k, weight: .semibold))
                .foregroundStyle(liked ? Color(hex: "#FF6B6B") : tint)
                .symbolEffect(.bounce, value: liked)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(NowPlayingCircleButtonStyle(tint: tint, size: 34 * k))
        .help(liked ? "取消喜欢" : "喜欢")
    }
}

struct NowPlayingMoreMenu: View {
    var track: Track
    var tint: Color
    var k: CGFloat
    var onOpenSettings: () -> Void
    var onSearchLyrics: () -> Void
    var onEqualizer: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Menu {
            if track.album?.isLinkable == true {
                Button("查看专辑", systemImage: "square.stack") { model.showAlbum(of: track) }
            }
            ForEach(track.artists.filter(\.isLinkable)) { artist in
                Button("查看歌手：\(artist.name)", systemImage: "music.mic") { model.showArtist(artist, of: track) }
            }
            AddToPlaylistMenu(tracks: [track], systemImage: "text.badge.plus")
            Divider()
            Button("拷贝歌曲名", systemImage: "doc.on.doc") {
                copy("\(track.title) - \(track.artistText)", toast: "已拷贝歌曲名")
            }
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                Button("拷贝歌词", systemImage: "text.quote") {
                    copy(lyrics.lines.map(\.text).joined(separator: "\n"), toast: "歌词已拷贝")
                }
            }
            Button("搜索歌词…", systemImage: "magnifyingglass", action: onSearchLyrics)
            Button("打开歌词文件…", systemImage: "doc.text") { model.openLyricsFile(for: track) }
            Divider()
            Section("这首歌") {
                Text("来源：\(model.displayName(of: track.id.source))")
                if let tier = model.availableTiers(of: track).last {
                    Text("最高音质：\(tier.name)")
                }
                if let format = player.lyrics?.format {
                    Text("歌词：\([player.lyricsOrigin?.displayName, format.rawValue.uppercased()].compactMap { $0 }.joined(separator: " · "))")
                }
            }
            Divider()
            Button("均衡器…", systemImage: "slider.vertical.3", action: onEqualizer)
            Button("播放页设置…", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14 * k, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34 * k, height: 34 * k)
                .background(Circle().fill(tint.opacity(0.14)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func copy(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.showToast(toast)
    }
}

struct ElasticBar: View {
    var fraction: Double
    var tint: Color
    var restHeight: CGFloat = 6
    var activeHeight: CGFloat = 11
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void = { _ in }
    @State private var hovering = false
    @State private var dragging = false
    /// Points dragged past an end (negative = before the start), shown as a stretch.
    @State private var overshoot: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = hovering || dragging
            let stretch = Self.rubberBand(overshoot)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(active ? 0.24 : 0.18))
                Rectangle()
                    .fill(tint.opacity(dragging ? 0.95 : (active ? 0.88 : 0.72)))
                    .frame(width: width * min(max(fraction, 0), 1))
            }
            .frame(height: active ? activeHeight : restHeight)
            .clipShape(Capsule())
            .scaleEffect(x: 1 + abs(stretch) / width, y: 1 - min(abs(stretch) / 60, 0.2), anchor: stretch < 0 ? .trailing : .leading)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { dragging = true }
                        let x = drag.location.x
                        overshoot = x < 0 ? x : max(x - width, 0)
                        onChanged(Double(min(max(x / width, 0), 1)))
                    }
                    .onEnded { drag in
                        dragging = false
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { overshoot = 0 }
                        onEnded(Double(min(max(drag.location.x / width, 0), 1)))
                    }
            )
        }
        .frame(height: activeHeight + 10)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering || dragging)
    }

    static func rubberBand(_ distance: CGFloat) -> CGFloat {
        let magnitude = 12 * (1 - 1 / (abs(distance) / 40 + 1))
        return distance < 0 ? -magnitude : magnitude
    }
}

/// The scrubber on the playback position. A leaf view: the 4 Hz clock re-runs only this, and
/// not at all while the controls are hidden (`live` false).
struct NowPlayingScrubber: View {
    @Binding var scrubbing: Bool
    @Binding var scrubValue: Double
    var tint: Color
    var k: CGFloat
    var live = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let duration = max(player.duration, 1)
        ElasticBar(fraction: (scrubbing ? scrubValue : (live ? player.currentTime : 0)) / duration, tint: tint, restHeight: 6 * k, activeHeight: 11 * k) { f in
            if !scrubbing {
                scrubbing = true
                player.isSeeking = true
            }
            scrubValue = f * duration
        } onEnded: { f in
            scrubValue = f * duration
            scrubbing = false
            player.isSeeking = false
            player.seek(to: scrubValue)
        }
    }
}

struct NowPlayingClock: View {
    enum Kind { case elapsed, remaining }

    var kind: Kind
    var scrubbing: Bool
    var scrubValue: Double
    var tint: Color
    var k: CGFloat
    var live = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let time = scrubbing ? scrubValue : (live ? player.currentTime : 0)
        Text(kind == .elapsed ? TimeFormatting.clock(time) : "-" + TimeFormatting.clock(max(player.duration - time, 0)))
            .font(.system(size: 11 * k, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint.opacity(scrubbing ? 0.9 : 0.55))
            .animation(Motion.hover, value: scrubbing)
    }
}

struct NowPlayingTransport: View {
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model
    @State private var nextTaps = 0
    @State private var previousTaps = 0

    var body: some View {
        let player = model.player
        HStack(spacing: 0) {
            if player.isEndless {
                toggle(systemName: "hand.thumbsdown", on: false, help: "不喜欢") { model.trashPersonalFMTrack() }
            } else {
                toggle(systemName: "shuffle", on: player.shuffle, help: "随机播放") { player.shuffle.toggle() }
            }
            Spacer(minLength: 0)
            Button {
                previousTaps += 1
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 21 * k))
                    .symbolEffect(.bounce.down, value: previousTaps)
            }
            .buttonStyle(NowPlayingGlyphButtonStyle(tint: tint, diameter: 46 * k))
            .help("上一曲")
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30 * k))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 34 * k)
            }
            .buttonStyle(NowPlayingGlyphButtonStyle(tint: tint, diameter: 52 * k))
            .help(player.isPlaying ? "暂停" : "播放")
            Spacer(minLength: 0)
            Button {
                nextTaps += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 21 * k))
                    .symbolEffect(.bounce.down, value: nextTaps)
            }
            .buttonStyle(NowPlayingGlyphButtonStyle(tint: tint, diameter: 46 * k))
            .help("下一曲")
            Spacer(minLength: 0)
            toggle(systemName: player.activeRepeat == .one ? "repeat.1" : player.isEndless ? "infinity" : "repeat", on: player.activeRepeat != .off,
                   help: player.isEndless ? (player.endlessRepeatsOne ? "单曲循环" : "无限播放") : "循环模式") { player.cycleRepeat() }
        }
    }

    private func toggle(systemName: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14 * k, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.78) : tint.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30 * k, height: 26 * k)
                .background(RoundedRectangle(cornerRadius: 7 * k, style: .continuous).fill(tint.opacity(on ? 0.9 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
        .help(help)
    }
}

struct NowPlayingGlyphButtonStyle: ButtonStyle {
    var tint: Color
    var diameter: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.07 : 0))))
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
            .animation(Motion.hover, value: hovering)
    }
}

struct NowPlayingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct NowPlayingCircleButtonStyle: ButtonStyle {
    var tint: Color
    var size: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(configuration.isPressed ? 0.26 : (hovering ? 0.2 : 0.14))))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(Motion.hover, value: hovering)
    }
}

struct NowPlayingVolume: View {
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 10 * k) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11 * k, weight: .semibold))
                    .frame(width: 16 * k)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(NowPlayingPressStyle())
            .foregroundStyle(tint.opacity(0.6))
            .help(player.isMuted ? "取消静音" : "静音")
            ElasticBar(fraction: player.volume, tint: tint, restHeight: 5 * k, activeHeight: 9 * k) { player.setVolume($0) }
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11 * k, weight: .semibold))
                .foregroundStyle(tint.opacity(0.6))
                .frame(width: 18 * k)
        }
        .onScrollWheel { VolumeWheel.applyScroll($0, to: player) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue(player.isMuted ? "静音" : "\(Int((player.volume * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.stepVolume(up: true)
            case .decrement: player.stepVolume(up: false)
            @unknown default: break
            }
        }
    }
}

struct NowPlayingPanelSwitch: View {
    var selection: NowPlayingPanel
    var panels: [NowPlayingPanel]
    var commentCount: Int?
    var tint: Color
    var k: CGFloat
    var select: (NowPlayingPanel) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2 * k) {
            ForEach(panels) { panel in
                PanelSwitchButton(panel: panel, selected: panel == selection, count: panel == .comments ? commentCount : nil, tint: tint, k: k, namespace: pill) {
                    select(panel)
                }
            }
        }
        .padding(3 * k)
        .background(Capsule().fill(tint.opacity(0.1)))
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selection)
    }
}

private struct PanelSwitchButton: View {
    var panel: NowPlayingPanel
    var selected: Bool
    var count: Int?
    var tint: Color
    var k: CGFloat
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * k) {
                Image(systemName: panel.systemImage)
                    .font(.system(size: 11.5 * k, weight: .semibold))
                Text(panel.title)
                    .font(.system(size: 12.5 * k, weight: .semibold))
                if let count, count > 0 {
                    Text(TimeFormatting.compactCount(count))
                        .font(.system(size: 10.5 * k, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.7)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.8) : tint.opacity(hovering ? 0.95 : 0.7))
            .padding(.horizontal, 12 * k)
            .frame(height: 28 * k)
            .background {
                if selected {
                    Capsule().fill(tint.opacity(0.92))
                        .matchedGeometryEffect(id: "pill", in: namespace)
                } else if hovering {
                    Capsule().fill(tint.opacity(0.08))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(panel.title)
    }
}
