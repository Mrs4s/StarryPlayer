import AppKit
import MusicSources
import StarryCore
import SwiftUI

struct AlbumPage: View {
    enum Tab: Int {
        case songs, comments, details
    }

    var album: Album
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<AlbumDetail> = .idle
    @State private var tab: Tab = .songs
    @State private var filter = ""
    @State private var subscribed: Bool?
    @State private var subscribedCount: Int?
    @State private var appeared = false
    @State private var backdrop = PageBackdrop()
    @State private var comments: CommentFeed

    private static let coverSize: CGFloat = 200
    static let coverPixels = 400

    init(album: Album) {
        self.album = album
        _comments = State(initialValue: CommentFeed(source: album.source, target: .album(album.id)))
    }

    private var shown: Album { state.value?.album ?? album }
    private var context: PlaybackContext { PlaybackContext(source: album.source, originType: .album, originID: album.id, originName: album.name) }
    private var isCurrentAlbum: Bool { model.player.playState(from: .album, of: album.source, id: album.id) != nil }
    private var hasComments: Bool { model.commentSource(album.source) != nil }

    var body: some View {
        DetailPageScroll(tab: $tab, backdrop: backdrop) {
            hero
        } bar: { tab in
            DetailTabBar(tab: tab, items: tabItems, search: tab.wrappedValue == .songs ? $filter : nil, searchPlaceholder: "搜索专辑内歌曲")
                .reveal(appeared, delay: 0.24, distance: 6)
        } rows: {
            tabRows
        }
        .task(id: album.id) { await load() }
        .task(id: shown.artwork?.sized(Self.coverPixels)) { await backdrop.tint(from: shown.artwork ?? album.artwork, pixels: Self.coverPixels) }
        .onAppear { appeared = true }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 30) {
            AlbumCoverStack(artwork: shown.artwork ?? album.artwork, size: Self.coverSize, glow: backdrop.tint, appeared: appeared, isCurrent: isCurrentAlbum, isPlaying: isCurrentAlbum && model.player.isPlaying) {
                playAll()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .reveal(appeared, delay: 0.06)
                Text(shown.name)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.1)
                if let alias = shown.alias {
                    Text(alias)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                }
                artistLine
                    .padding(.top, 14)
                    .reveal(appeared, delay: 0.14)
                Text(metaText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: metaText)
                    .padding(.top, 6)
                    .reveal(appeared, delay: 0.16)
                actions
                    .padding(.top, 22)
                    .reveal(appeared, delay: 0.2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 22)
        .padding(.bottom, 28)
    }

    private var eyebrow: String {
        [shown.releaseType ?? "专辑", shown.edition].compactMap { $0 }.joined(separator: " · ")
    }

    private var artistLine: some View {
        TruncatingRow {
            ForEach(Array(shown.artists.enumerated()), id: \.offset) { index, artist in
                HStack(spacing: 0) {
                    if index > 0 { Text(" / ").foregroundStyle(theme.onSurfaceVariant).fixedSize() }
                    TextLink(text: artist.name, color: theme.onSurface, hoverColor: theme.onSurface, action: artist.isLinkable ? {
                        model.navigate(.artist(Artist(id: artist.id, source: album.source, name: artist.name)))
                    } : nil)
                }
            }
        }
        .font(.system(size: 15, weight: .medium))
    }

    private var metaText: String {
        var parts: [String] = []
        if let date = shown.releaseDate { parts.append(date.isYearOnly ? "\(date.utcYear)" : date.ymd) }
        if let tracks = state.value?.tracks {
            parts.append("\(tracks.count) 首")
            parts.append(DetailFormat.durationText(tracks.reduce(0) { $0 + $1.duration }))
        } else if shown.trackCount > 0 {
            parts.append("\(shown.trackCount) 首")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            playButton
            if model.collecting(.album, in: album.source) != nil { subscribeButton }
            moreMenu
        }
    }

    private var playButton: some View {
        let playing = isCurrentAlbum && model.player.isPlaying
        return Button(action: playAll) {
            HStack(spacing: 7) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(playing ? "暂停" : (isCurrentAlbum ? "继续播放" : "播放全部"))
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.onPrimary)
            .padding(.horizontal, 20)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
        .disabled(state.value?.tracks.isEmpty != false)
        .animation(Motion.hover, value: playing)
        .animation(Motion.hover, value: isCurrentAlbum)
    }

    private var subscribeButton: some View {
        let isSubscribed = subscribed ?? state.value?.isSubscribed ?? false
        let count = subscribedCount ?? state.value?.subscribedCount
        return Button(action: toggleSubscription) {
            HStack(spacing: 6) {
                Image(systemName: isSubscribed ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(isSubscribed ? "已收藏" : "收藏")
                    .font(.system(size: 14, weight: .semibold))
                if let count, count > 0 {
                    Text(TimeFormatting.compactCount(count))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.7)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .disabled(state.value == nil)
    }

    private var moreMenu: some View {
        Menu {
            Button("下一首播放") { playNext() }
            Button("添加到播放队列") { addToQueue() }
            AddToPlaylistMenu(tracks: state.value?.tracks ?? [])
            if let url = webURL {
                Divider()
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.showToast("已复制专辑链接")
                }
                Button("在浏览器中打开") { NSWorkspace.shared.open(url) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isCircle: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.value?.tracks.isEmpty != false)
    }

    private var webURL: URL? {
        model.webURL(.album(album.id), in: album.source)
    }

    private var tabItems: [PageTabs<Tab>.Item] {
        var items: [PageTabs<Tab>.Item] = [.init(value: .songs, title: "歌曲", count: state.value?.tracks.count ?? (shown.trackCount > 0 ? shown.trackCount : nil))]
        if hasComments { items.append(.init(value: .comments, title: "评论", count: state.value?.commentCount)) }
        items.append(.init(value: .details, title: "专辑详情"))
        return items
    }

    /// The selected tab as rows of the page's lazy stack (several views, not one container).
    @ViewBuilder private var tabRows: some View {
        switch tab {
        case .songs: songRows
        case .comments: CommentThreadView(feed: comments)
        case .details: AlbumInfoView(album: shown, tracks: state.value?.tracks)
        }
    }

    @ViewBuilder private var songRows: some View {
        switch state {
        case .idle, .loading:
            TrackSkeleton(count: min(max(shown.trackCount, 6), 10))
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
                PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded(let detail):
            let tracks = filtered(detail.tracks)
            Color.clear.frame(height: 8)
            if tracks.isEmpty {
                StateView(systemName: "magnifyingglass", title: detail.tracks.isEmpty ? "专辑暂无歌曲" : "没有匹配的歌曲")
            } else {
                AlbumTrackRows(tracks: tracks, queue: detail.tracks, context: context, showPopularity: detail.tracks.contains { $0.popularity != nil })
            }
            if filter.isEmpty, !detail.tracks.isEmpty {
                footer(detail)
            }
        }
    }

    private func footer(_ detail: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = shown.releaseDate { Text(date.isYearOnly ? "\(date.utcYear) 年发行" : "\(DetailFormat.longDate(date)) 发行") }
            Text("\(detail.tracks.count) 首歌曲，\(DetailFormat.durationText(detail.tracks.reduce(0) { $0 + $1.duration }))")
            if let company = shown.company { Text("© \(company)") }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.top, 22)
        .padding(.leading, 12)
    }

    private func filtered(_ tracks: [Track]) -> [Track] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.alias?.localizedCaseInsensitiveContains(query) ?? false) || $0.artistText.localizedCaseInsensitiveContains(query) }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        // Not animated: the page's height changes with it (see `tabBinding`); the pieces that
        // appear bring their own transitions.
        state = await Loadable.run { try await model.catalog(album.source).album(id: album.id) }
        subscribed = nil
        subscribedCount = nil
    }

    private func playAll() {
        if isCurrentAlbum {
            model.player.togglePlayPause()
        } else if let tracks = state.value?.tracks, !tracks.isEmpty {
            model.player.play(tracks, context: context)
        }
    }

    private func playNext() {
        guard let tracks = state.value?.tracks, !tracks.isEmpty else { return }
        model.player.playNext(tracks)
        model.showToast("已添加 \(tracks.count) 首到下一首播放")
    }

    private func addToQueue() {
        guard let tracks = state.value?.tracks, !tracks.isEmpty else { return }
        model.player.addToQueue(tracks)
        model.showToast("已添加 \(tracks.count) 首到播放队列")
    }

    private func toggleSubscription() {
        guard let detail = state.value else { return }
        guard let collecting = model.collecting(.album, in: album.source) else { return }
        guard model.accounts.isLoggedIn(album.source) else {
            model.requestLogin(album.source)
            return
        }
        let was = subscribed ?? detail.isSubscribed ?? false
        let count = subscribedCount ?? detail.subscribedCount
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            subscribed = !was
            subscribedCount = count.map { max($0 + (was ? -1 : 1), 0) }
        }
        Task {
            do {
                try await collecting.setCollected(.album(album.id), collected: !was)
                model.showToast(was ? "已取消收藏" : "已收藏专辑")
            } catch {
                withAnimation {
                    subscribed = was
                    subscribedCount = count
                }
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private struct AlbumCoverStack: View {
    var artwork: Artwork?
    var size: CGFloat
    var glow: Color?
    var appeared: Bool
    var isCurrent: Bool
    var isPlaying: Bool
    var onPlay: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var discSize: CGFloat { size * 0.9 }
    private var peek: CGFloat { size * 0.24 }

    var body: some View {
        ZStack(alignment: .leading) {
            VinylDisc(artwork: artwork, spinning: isPlaying)
                .frame(width: discSize, height: discSize)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 2)
                .offset(x: (size - discSize) + (appeared ? peek : 0))
                .animation(Motion.reveal.delay(0.26), value: appeared)
                .offset(x: hovering ? 10 : (isCurrent ? 5 : 0))
                .animation(Motion.lift, value: hovering)
                .animation(Motion.reveal, value: isCurrent)
                .reveal(appeared, delay: 0.12, distance: 0)
            cover
        }
        .frame(width: size + peek + 12, height: size, alignment: .leading)
    }

    private var cover: some View {
        ArtworkView(artwork: artwork, radius: 10, pixelSize: AlbumPage.coverPixels)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                CoverPlayButton(isPlaying: isPlaying, visible: hovering, action: onPlay)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: theme.coverShadow(glow), radius: hovering ? 26 : 18, y: hovering ? 14 : 9)
            .onHover { hovering = $0 }
            .animation(Motion.lift, value: hovering)
            .reveal(appeared, distance: 0, scale: 0.94)
    }
}

/// The album's rows: no covers, the source's track numbers, a "CD n" line between discs when
/// there is more than one. Rows rise in with a stagger when the list first shows. Its body is
/// the rows themselves, so they become rows of the page's lazy stack.
private struct AlbumTrackRows: View {
    var tracks: [Track]
    var queue: [Track]
    var context: PlaybackContext
    var showPopularity: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var shown = false

    var body: some View {
        let multiDisc = Set(queue.map { $0.discNumber ?? 1 }).count > 1
        ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
            if multiDisc, position == 0 || tracks[position - 1].discNumber != track.discNumber {
                discHeader(track.discNumber ?? 1, first: position == 0)
                    .staggeredReveal(shown, index: position)
            }
            SongRow(track: track, index: track.trackNumber ?? position + 1, showAlbum: false, showPopularity: showPopularity, showArtwork: false) {
                model.player.play(queue, startAt: queue.firstIndex { $0.id == track.id } ?? 0, context: context)
            }
            .staggeredReveal(shown, index: position)
            .onAppear { if !shown { shown = true } }
        }
    }

    private func discHeader(_ number: Int, first: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "opticaldisc").font(.system(size: 12, weight: .medium))
            Text("CD \(number)").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.horizontal, 12)
        .padding(.top, first ? 6 : 22)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlbumInfoView: View {
    var album: Album
    var tracks: [Track]?
    @Environment(\.theme) private var theme
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let description = album.description {
                section("专辑介绍") {
                    Text(description)
                        .font(.system(size: 14))
                        .lineSpacing(7)
                        .foregroundStyle(theme.onSurface.opacity(0.88))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 720, alignment: .leading)
                }
                .staggeredReveal(shown, index: 0)
            }
            section("专辑信息") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 12) {
                    ForEach(rows, id: \.0) { key, value in
                        GridRow {
                            Text(key).foregroundStyle(theme.onSurfaceVariant)
                            Text(value).foregroundStyle(theme.onSurface).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 13))
            }
            .staggeredReveal(shown, index: 1)
        }
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { shown = true }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if !album.artists.isEmpty { rows.append(("艺人", album.artists.map(\.name).joined(separator: " / "))) }
        if let date = album.releaseDate { rows.append(("发行时间", date.isYearOnly ? "\(date.utcYear) 年" : DetailFormat.longDate(date))) }
        if let company = album.company { rows.append(("发行公司", company)) }
        rows.append(("类型", [album.releaseType ?? "专辑", album.edition].compactMap { $0 }.joined(separator: " · ")))
        if let tracks, !tracks.isEmpty {
            rows.append(("歌曲", "\(tracks.count) 首"))
            rows.append(("时长", DetailFormat.durationText(tracks.reduce(0) { $0 + $1.duration })))
        }
        if let alias = album.alias { rows.append(("别名", alias)) }
        return rows
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.onSurface)
            content()
        }
    }
}
