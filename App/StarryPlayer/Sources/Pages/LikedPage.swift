import MusicSources
import StarryCore
import SwiftUI

struct LikedPage: View {
    enum Tab: Int {
        case songs
    }

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The liked playlist's id once loaded (nil for a source without one).
    @State private var state: Loadable<String?> = .idle
    @State private var list: TrackListLoader?
    @State private var tab: Tab = .songs
    @State private var filter = ""
    @State private var query = ""
    @State private var appeared = false
    /// A queue action is waiting for the songs not loaded yet.
    @State private var preparing = false
    /// Bumped by every like and unlike: the heart beats.
    @State private var pulse = 0
    @State private var locator = TrackListLocator()
    @State private var backdrop: PageBackdrop = {
        let backdrop = PageBackdrop()
        backdrop.tint = LikedCover.tint
        return backdrop
    }()

    private static let coverSize: CGFloat = 200

    private var source: SourceID { model.browsingSourceID }
    private var available: Bool { model.hasLibrary && model.signedInUser != nil }
    /// What the list is of; it loads again when this changes (not when the account only signs
    /// in again).
    private var loadKey: String? {
        available ? "\(source.key)|\(model.signedInUser ?? "")" : nil
    }
    private var context: PlaybackContext {
        PlaybackContext(source: source, originType: .liked, originID: state.value ?? nil, originName: "我喜欢的音乐")
    }
    private var count: Int { list?.totalCount ?? 0 }

    var body: some View {
        DetailTablePage(tab: $tab, backdrop: backdrop, model: model, hero: AnyView(hero), bar: AnyView(bar), barBottomPadding: showsList ? TrackListRows.gapAbove : 0, rows: tableRows, bottomInset: model.player.current != nil ? Metrics.playerBarInset : 0)
            .preference(key: PageBackdropKey.self, value: backdrop)
            .task(id: loadKey) {
                list = nil
                state = .idle
                if loadKey != nil { await load() }
            }
            .settled(filter, into: $query)
            .task(id: filter.isEmpty ? nil : list.map(ObjectIdentifier.init)) { await list?.loadRemaining() }
            .onChange(of: model.likeChange) { _, change in follow(change) }
            .onAppear { appeared = true }
    }

    private var bar: some View {
        DetailTabBar(tab: $tab, items: [.init(value: .songs, title: "歌曲", count: count > 0 ? count : nil)]) {
            HStack(spacing: 0) {
                LocatePlayingButton(list: list, locator: locator, context: context, query: query, clearSearch: clearSearch)
                DetailTabSearch(text: available ? $filter : nil, placeholder: "搜索喜欢的歌曲")
            }
        }
        .reveal(appeared, delay: 0.26, distance: 6)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 30) {
            CoverStack(artwork: nil, tracks: list.map { Array($0.tracks.prefix(16)) }, context: context, size: Self.coverSize, glow: LikedCover.tint, appeared: appeared) {
                playAll()
            } cover: { playing in
                LikedCover(size: Self.coverSize, playing: playing, pulse: pulse)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("我的音乐")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .reveal(appeared, delay: 0.06)
                Text("我喜欢的音乐")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.1)
                ownerLine
                    .padding(.top, 14)
                    .reveal(appeared, delay: 0.14)
                metaLine
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

    private var ownerLine: some View {
        HStack(spacing: 6) {
            if let profile = model.profile {
                AvatarView(artwork: profile.avatar ?? Artwork(seed: "avatar-\(profile.nickname)"), size: 22)
                    .padding(.trailing, 2)
                TextLink(text: profile.nickname, color: theme.onSurface, hoverColor: theme.onSurface, action: model.hasUserPages(source) ? { model.openProfile() } : nil)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            if let latest = list?.tracks.first {
                ZStack(alignment: .leading) {
                    Text("\(model.profile == nil ? "" : "·  ")最近喜欢《\(latest.title)》")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .id(latest.id)
                        .transition(.push(from: .bottom))
                }
                .clipped()
            }
        }
        .frame(height: 22, alignment: .leading)
    }

    private var metaLine: some View {
        Text(metaText)
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(theme.onSurfaceVariant)
            .contentTransition(.numericText(value: Double(count)))
            .animation(.easeOut(duration: 0.25), value: metaText)
    }

    private var metaText: String {
        guard let list, count > 0 else { return available || !model.hasLibrary ? " " : "登录后同步你喜欢的歌曲" }
        var parts = ["\(count) 首"]
        // The length only once every song is known, not a partial sum.
        if list.isComplete { parts.append(DetailFormat.durationText(list.tracks.reduce(0) { $0 + $1.duration })) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            ListPlayButton(context: context, busy: false, action: playAll)
                .disabled(list?.tracks.isEmpty != false)
            Button(action: shufflePlay) {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .bold))
                    Text("随机播放")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 16)
                .frame(height: 38)
            }
            .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
            .disabled(list?.tracks.isEmpty != false)
            moreMenu
        }
    }

    private var moreMenu: some View {
        PopMenu {
            PopMenuItem.button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(next: true) }
            PopMenuItem.button("添加到播放队列", systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(next: false) }
        } label: { open in
            ZStack {
                if preparing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    PopMenuEllipsis(isOpen: open)
                        .foregroundStyle(theme.primary)
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isCircle: true))
        .fixedSize()
        .disabled(list?.tracks.isEmpty != false)
    }

    private var tableRows: [DetailTableRow] {
        if !model.hasLibrary {
            return [.hosted("lacks") { SourceLacks(feature: "喜欢的音乐", systemName: "heart") }]
        } else if !available {
            return [.hosted("login") { LoginPrompt().frame(maxWidth: .infinity).padding(.top, 36) }]
        }
        switch state {
        case .idle, .loading:
            return [.hosted("skeleton") { TrackSkeleton(count: 10, artwork: true) }]
        case .failed(let message):
            return [.hosted("failed") {
                VStack(spacing: 14) {
                    StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
                    PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }]
        case .loaded:
            guard let list else { return [] }
            let matches = list.matches(query)
            var rows: [DetailTableRow] = []
            if matches?.isEmpty ?? list.tracks.isEmpty, list.isComplete {
                if list.tracks.isEmpty {
                    rows.append(.hosted("empty") { StateView(systemName: "heart", title: "还没有喜欢的歌曲", detail: "点击歌曲旁的心形图标收藏") })
                } else {
                    rows.append(.hosted("no-matches") { StateView(systemName: "magnifyingglass", title: "没有匹配的歌曲") })
                }
            } else {
                rows.append(DetailTableRow(id: "songs", kind: .songs(SongRowsSpec(list: list, matches: matches, query: query, context: context, locator: locator, animatesEdits: pageActive && !reduceMotion))))
            }
            rows.append(.hosted("end") {
                TrackListEnd(list: list) {
                    if query.isEmpty, !list.tracks.isEmpty { footer(list) }
                }
            })
            return rows
        }
    }

    private var showsList: Bool {
        if model.hasLibrary, available, case .loaded = state, list != nil { return true }
        return false
    }

    private func footer(_ list: TrackListLoader) -> some View {
        Text("\(list.tracks.count) 首歌曲，\(DetailFormat.durationText(list.tracks.reduce(0) { $0 + $1.duration }))")
            .font(.system(size: 12))
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(.top, 22)
            .padding(.leading, 12)
    }

    private func load() async {
        if list == nil { state = .loading }
        let key = loadKey
        let source = source
        let result: Loadable<(id: String?, list: TrackListLoader, liked: [String])> = await Loadable.run {
            let catalog = try model.catalog(source)
            let fetch: @Sendable ([String]) async throws -> [Track] = { try await catalog.songs(ids: $0) }
            let library = try model.library(source)
            if let likedID = try await library.likedPlaylistID() {
                let detail = try await catalog.playlist(id: likedID)
                let liked = detail.tracks.map(\.id.id) + detail.pendingTrackIDs
                return (likedID, TrackListLoader(tracks: detail.tracks, pendingIDs: detail.pendingTrackIDs, fetch: fetch), liked)
            }
            let ids = try await library.likedTrackIDs()
            return (nil, TrackListLoader(tracks: [], pendingIDs: ids, fetch: fetch), ids)
        }
        guard key == loadKey, !Task.isCancelled else { return }
        // Not animated: the page's height changes with it (see `DetailPageScroll`).
        switch result {
        case .loaded(let loaded):
            list = loaded.list
            state = .loaded(loaded.id)
            model.setLikedSongs(loaded.liked, of: source)
        case .failed(let message): state = .failed(message)
        case .idle, .loading: break
        }
    }

    /// Keeps the list in step with a like or unlike of this source's songs made anywhere, and
    /// beats the heart.
    private func follow(_ change: AppModel.LikeChange?) {
        guard let change, change.track.id.source == source, let list, state.value != nil else { return }
        // Animated only where it is seen: a hidden page would render the whole motion.
        let animated = pageActive && !reduceMotion
        withTransaction(Transaction(animation: animated ? Motion.listEdit : nil)) {
            if change.liked {
                list.prepend(change.track)
            } else {
                list.remove(change.track.id)
            }
        }
        pulse += 1
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

    private func shufflePlay() {
        list?.play(shuffled: true, on: model.player, context: context)
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
}
