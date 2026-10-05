import AppKit
import MusicSources
import StarryCore
import SwiftUI

struct PlaylistPage: View {
    enum Tab: Int {
        case songs, comments
    }

    var playlist: Playlist
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<PlaylistDetail> = .idle
    @State private var list: TrackListLoader?
    @State private var tab: Tab = .songs
    @State private var filter = ""
    @State private var query = ""
    @State private var subscribed: Bool?
    @State private var subscribedCount: Int?
    @State private var appeared = false
    /// A queue action is waiting for the songs not loaded yet.
    @State private var preparing = false
    @State private var backdrop = PageBackdrop()
    @State private var comments: CommentFeed
    @State private var edited: Playlist?
    @State private var confirmingDelete = false
    @State private var locator = TrackListLocator()

    private static let coverSize: CGFloat = 200
    static let coverPixels = 400

    init(playlist: Playlist) {
        self.playlist = playlist
        _comments = State(initialValue: CommentFeed(source: playlist.source, target: .playlist(playlist.id)))
    }

    private var shown: Playlist { edited ?? state.value?.playlist ?? playlist }
    private var context: PlaybackContext { PlaybackContext(source: playlist.source, originType: .playlist, originID: playlist.id, originName: playlist.name) }
    private var hasComments: Bool { model.commentSource(playlist.source) != nil }

    var body: some View {
        DetailPageScroll(tab: $tab, backdrop: backdrop) {
            hero
        } bar: { tab in
            DetailTabBar(tab: tab, items: tabItems) {
                HStack(spacing: 0) {
                    if tab.wrappedValue == .songs {
                        LocatePlayingButton(list: list, locator: locator, context: context, query: query, clearSearch: clearSearch)
                    }
                    DetailTabSearch(text: tab.wrappedValue == .songs ? $filter : nil, placeholder: "搜索歌单内歌曲")
                }
            }
            .reveal(appeared, delay: 0.26, distance: 6)
            .padding(.bottom, tab.wrappedValue == .songs && showsList ? TrackListRows.gapAbove : 0)
        } rows: {
            tabRows
        }
        .task(id: playlist.id) { await load() }
        .settled(filter, into: $query)
        .task(id: filter.isEmpty ? nil : list.map(ObjectIdentifier.init)) { await list?.loadRemaining() }
        .task(id: shown.artwork?.sized(Self.coverPixels)) { await backdrop.tint(from: shown.artwork ?? playlist.artwork, pixels: Self.coverPixels) }
        .onAppear { appeared = true }
        .onChange(of: model.playlistChange) { _, change in follow(change) }
        .confirmationDialog("删除歌单「\(shown.name)」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await model.deletePlaylist(shown)
                    } catch {
                        model.showToast(ErrorText.describe(error))
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不能恢复，歌单里的歌曲本身不受影响。")
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 30) {
            CoverStack(artwork: shown.artwork ?? playlist.artwork, tracks: list.map { Array($0.tracks.prefix(16)) }, context: context, size: Self.coverSize, glow: backdrop.tint, appeared: appeared) {
                playAll()
            } cover: { _ in
                ArtworkView(artwork: shown.artwork ?? playlist.artwork, radius: 12, pixelSize: Self.coverPixels)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .reveal(appeared, delay: 0.06)
                Text(shown.name)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.3), value: shown.name)
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.1)
                if shown.creatorName?.isEmpty == false || shown.createdAt != nil {
                    creatorLine
                        .padding(.top, 14)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.14)
                }
                if let description = shown.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                    DescriptionPeek(title: "歌单介绍", text: description, tags: shown.tags)
                        .padding(.top, 10)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.16)
                }
                Text(metaText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: metaText)
                    .padding(.top, 10)
                    .reveal(appeared, delay: 0.18)
                actions
                    .padding(.top, 22)
                    .reveal(appeared, delay: 0.22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 22)
        .padding(.bottom, 28)
    }

    private var eyebrow: String {
        let kind = shown.isOwned ? (shown.isPrivate == true ? "我创建的隐私歌单" : "我创建的歌单") : "歌单"
        return ([kind] + shown.tags.prefix(3)).joined(separator: " · ")
    }

    private var creatorLine: some View {
        HStack(spacing: 6) {
            let name = shown.creatorName.flatMap { $0.isEmpty ? nil : $0 }
            if let name {
                AvatarView(artwork: shown.creatorAvatar ?? Artwork(seed: "avatar-\(name)"), size: 22)
                    .padding(.trailing, 2)
                TextLink(text: name, color: theme.onSurface, hoverColor: theme.onSurface, action: canShowCreator ? { model.showCreator(of: shown) } : nil)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            if let created = shown.createdAt {
                Text(name == nil ? "\(DetailFormat.longDate(created))创建" : "·  \(DetailFormat.longDate(created))创建")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
    }

    private var canShowCreator: Bool {
        model.canShowUser(shown.creatorID, in: playlist.source)
    }

    private var metaText: String {
        var parts: [String] = []
        let count = list?.totalCount ?? shown.trackCount
        if count > 0 { parts.append("\(count) 首") }
        // The length only once every track is known, not a partial sum.
        if let list, list.isComplete, !list.tracks.isEmpty {
            parts.append(DetailFormat.durationText(list.tracks.reduce(0) { $0 + $1.duration }))
        }
        if shown.playCount > 0 { parts.append("\(TimeFormatting.compactCount(shown.playCount)) 次播放") }
        if let updated = shown.updatedAt { parts.append("\(DetailFormat.dayText(updated))更新") }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            ListPlayButton(context: context, busy: preparing, action: playAll)
                .disabled(list?.tracks.isEmpty != false)
            if model.canEdit(shown) {
                editButton
            } else if !shown.isOwned, model.collecting(.playlist, in: playlist.source) != nil {
                subscribeButton
            }
            moreMenu
        }
    }

    private var editButton: some View {
        Button(action: edit) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                Text("编辑").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .disabled(state.value == nil)
    }

    private func edit() {
        model.presentPlaylistEditor(PlaylistEditorRequest(source: playlist.source, purpose: .edit(shown)))
    }

    private var subscribeButton: some View {
        let isSubscribed = subscribed ?? state.value?.isSubscribed ?? model.isCollected(playlist)
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
        let empty = list?.tracks.isEmpty != false
        return Menu {
            Button("下一首播放") { enqueue(next: true) }.disabled(empty)
            Button("添加到播放队列") { enqueue(next: false) }.disabled(empty)
            if let list, list.isComplete { AddToPlaylistMenu(tracks: list.tracks, excluding: playlist.id) }
            if model.canEdit(shown) || model.canDelete(shown) {
                Divider()
                if model.canEdit(shown) { Button("编辑歌单…", action: edit) }
                if model.canDelete(shown) { Button("删除歌单…", role: .destructive) { confirmingDelete = true } }
            }
            if let url = webURL {
                Divider()
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.showToast("已复制歌单链接")
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
        .disabled(state.value == nil)
    }

    private var webURL: URL? {
        model.webURL(.playlist(playlist.id), in: playlist.source)
    }

    private var tabItems: [PageTabs<Tab>.Item] {
        let songCount = list?.totalCount ?? shown.trackCount
        var items: [PageTabs<Tab>.Item] = [.init(value: .songs, title: "歌曲", count: songCount > 0 ? songCount : nil)]
        if hasComments { items.append(.init(value: .comments, title: "评论", count: state.value?.commentCount)) }
        return items
    }

    /// The selected tab as rows of the page's lazy stack (several views, not one container).
    @ViewBuilder private var tabRows: some View {
        switch tab {
        case .songs: songRows
        case .comments: CommentThreadView(feed: comments)
        }
    }

    @ViewBuilder private var songRows: some View {
        switch state {
        case .idle, .loading:
            TrackSkeleton(count: min(max(shown.trackCount, 6), 10), artwork: true)
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
                PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary) { Task { await load() } }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded:
            if let list {
                let matches = list.matches(query)
                if matches?.isEmpty ?? list.tracks.isEmpty, list.isComplete {
                    if list.tracks.isEmpty {
                        StateView(systemName: "music.note.list", title: "歌单里还没有歌曲", detail: model.canRemoveSongs(from: shown) || model.canEdit(shown) ? "在歌曲上右键选“加入歌单”，或把歌曲拖到侧栏的这个歌单上" : nil)
                    } else {
                        StateView(systemName: "magnifyingglass", title: "没有匹配的歌曲")
                    }
                } else {
                    TrackListRows(list: list, matches: matches, context: context,
                                  onRemove: model.canRemoveSongs(from: shown) ? { remove($0) } : nil,
                                  onMove: model.canReorder(shown) ? { move(from: $0, to: $1) } : nil,
                                  locator: locator)
                }
                TrackListEnd(list: list) {
                    if query.isEmpty, !list.tracks.isEmpty { footer(list) }
                }
            }
        }
    }

    private var showsList: Bool {
        if case .loaded = state, list != nil { return true }
        return false
    }

    private func footer(_ list: TrackListLoader) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(list.tracks.count) 首歌曲，\(DetailFormat.durationText(list.tracks.reduce(0) { $0 + $1.duration }))")
            if let updated = shown.updatedAt { Text("最后更新于 \(DetailFormat.longDate(updated))") }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.top, 22)
        .padding(.leading, 12)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        let result = await Loadable.run { try await model.catalog(playlist.source).playlist(id: playlist.id) }
        if let detail = result.value, let catalog = try? model.catalog(playlist.source) {
            list = TrackListLoader(tracks: detail.tracks, pendingIDs: detail.pendingTrackIDs) { try await catalog.songs(ids: $0) }
        }
        // Not animated: the page's height changes with it (see `DetailPageScroll`); the pieces
        // that appear bring their own transitions.
        state = result
        subscribed = nil
        subscribedCount = nil
        edited = nil
    }

    private func remove(_ track: Track) {
        guard let list else { return }
        withTransaction(Transaction(animation: Motion.listEdit)) { list.remove(track.id) }
        Task {
            do {
                try await model.removeSongs([track.id], from: shown)
                model.showToast("已从歌单中删除")
            } catch {
                model.showToast(ErrorText.describe(error))
                await load()
            }
        }
    }

    private func move(from: Int, to: Int) {
        guard let list else { return }
        withAnimation(Motion.listEdit) { list.move(from: from, to: to) }
        let order = list.allIDs
        let playlist = shown
        Task {
            do {
                try await model.reorder(playlist, to: order)
            } catch {
                model.showToast(ErrorText.describe(error))
                await load()
            }
        }
    }

    private func follow(_ change: PlaylistChange?) {
        guard let change, change.playlist.source == playlist.source, change.playlist.id == playlist.id else { return }
        switch change.kind {
        case .added:
            Task { await load() }
        case .removed(let refs):
            guard let list else { return }
            withTransaction(Transaction(animation: Motion.listEdit)) {
                for ref in refs { list.remove(ref) }
            }
        case .edited:
            var now = shown
            now.name = change.playlist.name
            now.description = change.playlist.description
            now.isPrivate = change.playlist.isPrivate
            withAnimation(.easeOut(duration: 0.3)) { edited = now }
        case .deleted:
            break
        }
    }

    private func clearSearch() {
        filter = ""
        query = ""
    }

    private func playAll() {
        if model.player.isQueue(from: context) {
            model.player.togglePlayPause()
            return
        }
        list?.play(on: model.player, context: context)
    }

    private func enqueue(next: Bool) {
        guard let list, !preparing else { return }
        Task {
            if !list.isComplete {
                preparing = true
                await list.loadRemaining()
                preparing = false
            }
            let tracks = list.tracks
            guard !tracks.isEmpty else { return }
            if next {
                model.player.playNext(tracks)
                model.showToast("已添加 \(tracks.count) 首到下一首播放")
            } else {
                model.player.addToQueue(tracks)
                model.showToast("已添加 \(tracks.count) 首到播放队列")
            }
        }
    }

    private func toggleSubscription() {
        guard let detail = state.value else { return }
        guard model.accounts.isLoggedIn(playlist.source) else {
            model.requestLogin(playlist.source)
            return
        }
        let was = subscribed ?? detail.isSubscribed ?? model.isCollected(playlist)
        let count = subscribedCount ?? detail.subscribedCount
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            subscribed = !was
            subscribedCount = count.map { max($0 + (was ? -1 : 1), 0) }
        }
        Task {
            do {
                try await model.setCollected(detail.playlist, !was)
                model.showToast(was ? "已取消收藏" : "已收藏歌单")
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
