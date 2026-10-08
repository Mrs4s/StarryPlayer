import AppKit
import MusicSources
import StarryCore
import SwiftUI

struct ProfilePage: View {
    enum Tab: Int {
        case weekRanking, allRanking, created, subscribed, follows, followers

        var section: Section {
            switch self {
            case .weekRanking, .allRanking: .ranking
            case .created: .created
            case .subscribed: .subscribed
            case .follows: .follows
            case .followers: .followers
            }
        }
    }

    enum Section: Hashable {
        case ranking, created, subscribed, follows, followers
    }

    var user: UserProfile
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var state: Loadable<UserProfile> = .idle
    @State private var lists: Loadable<UserPlaylists> = .idle
    @State private var week: Loadable<[RankedTrack]> = .idle
    @State private var allTime: Loadable<[RankedTrack]> = .idle
    /// The source said the ranking is not for others to see.
    @State private var rankingHidden = false
    @State private var follows = PagedFeed<UserProfile>(pageSize: 30)
    @State private var followers = PagedFeed<UserProfile>(pageSize: 30)
    /// The source said the follow lists are not for others to see.
    @State private var followsHidden = false
    @State private var tab: Tab = .allRanking
    @State private var rankingTab: Tab = .allRanking
    /// The user picked a tab, so the page no longer picks one for them.
    @State private var tabTouched = false
    @State private var followed: Bool?
    @State private var columns = 5
    @State private var appeared = false
    @State private var backdrop = PageBackdrop()

    private static let avatarSize: CGFloat = 184
    static let avatarPixels = 368

    private var shown: UserProfile { state.value ?? user }
    private var isSelf: Bool { model.isSelf(user) }
    private var context: PlaybackContext { PlaybackContext(source: user.source, originType: .user, originID: user.id, originName: shown.nickname) }
    private var hasRanking: Bool { model.source(user.source, as: (any ListeningRankingSource).self) != nil }
    private var hasFollowLists: Bool { model.source(user.source, as: (any UserFollowSource).self) != nil }

    var body: some View {
        DetailPageScroll(tab: $tab, backdrop: backdrop, switchingHero: { tab in
            hero(switchTab: tab)
        }, bar: { tab in
            DetailTabBar(tab: sectionBinding(tab), items: tabItems) {
                if tab.wrappedValue.section == .ranking, hasRanking, !isRankingHidden {
                    SegmentSwitch(selection: periodBinding(tab), options: [(.week, "最近一周"), (.allTime, "所有时间")])
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
            .reveal(appeared, delay: 0.26, distance: 6)
        }, rows: { _ in
            tabRows
        })
        .onGeometryChange(for: Int.self) { ProfilePlaylistRows.columns(for: $0.size.width) } action: { columns = $0 }
        .onChange(of: tab) { if tab.section == .ranking { rankingTab = tab } }
        .task(id: user.id) { await load() }
        .task(id: user.id) { await loadPlaylists() }
        .onAppear { if !hasRanking, tab.section == .ranking { tab = .created } }
        .task(id: shown.avatar?.sized(Self.avatarPixels)) { await backdrop.tint(from: shown.avatar, pixels: Self.avatarPixels) }
        .onAppear { appeared = true }
    }

    private func hero(switchTab: Binding<Tab>) -> some View {
        HStack(alignment: .bottom, spacing: 38) {
            ProfileAvatar(artwork: shown.avatar, level: shown.level, maxLevel: shown.maxLevel, size: Self.avatarSize, glow: backdrop.tint, appeared: appeared)
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .reveal(appeared, delay: 0.06)
                nameLine
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.1)
                let info = shown.details.joined(separator: " · ")
                if !info.isEmpty {
                    Text(info)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .padding(.top, 8)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.12)
                } else if isLoading {
                    // Holds the lines the details usually bring, so the header keeps its height
                    // (it is bottom-aligned: a taller text column moves the name and the avatar).
                    SkeletonBar(width: 180, height: 10)
                        .frame(height: 16)
                        .padding(.top, 8)
                        .reveal(appeared, delay: 0.12)
                }
                if let signature = shown.signature {
                    DescriptionPeek(title: "个人介绍", text: signature)
                        .padding(.top, 10)
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                        .reveal(appeared, delay: 0.15)
                } else if isLoading {
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonBar(width: 340, height: 9)
                        SkeletonBar(width: 220, height: 9)
                    }
                    .frame(height: 34)
                    .padding(.top, 10)
                    .reveal(appeared, delay: 0.15)
                }
                ProfileStats(items: statItems(switchTab: switchTab), loaded: !isLoading)
                    .padding(.top, 18)
                    .reveal(appeared, delay: 0.18)
                actions
                    .padding(.top, 22)
                    .reveal(appeared, delay: 0.22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 26)
        .padding(.bottom, 30)
    }

    /// The details have not come yet.
    private var isLoading: Bool {
        switch state {
        case .idle, .loading: true
        case .loaded, .failed: false
        }
    }

    private var eyebrow: String {
        ([isSelf ? "我的主页" : "个人主页"] + [shown.identity].compactMap { $0 }).joined(separator: " · ")
    }

    private var nameLine: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(shown.nickname.isEmpty ? " " : shown.nickname)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .textSelection(.enabled)
            if let gender = shown.gender {
                GenderMark(gender: gender)
                    .transition(.scale(scale: 0.6).combined(with: .opacity).animation(.spring(response: 0.4, dampingFraction: 0.7)))
            }
            if shown.isVIP {
                Tag(text: "VIP", style: .red, soft: true)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
        }
    }

    private func statItems(switchTab: Binding<Tab>) -> [ProfileStats.Item] {
        let open = { (target: Tab, count: Int?) -> (() -> Void)? in
            guard hasFollowLists, !isFollowListHidden, (count ?? 0) > 0 else { return nil }
            return {
                tabTouched = true
                switchTab.wrappedValue = target
            }
        }
        return [
            .init(title: "关注", value: shown.followCount, open: open(.follows, shown.followCount)),
            .init(title: "粉丝", value: followerCount, open: open(.followers, followerCount)),
            .init(title: "动态", value: shown.eventCount),
            .init(title: "累计听歌", value: shown.listenedSongCount),
        ]
    }

    private var followerCount: Int? {
        let changed = (followed ?? state.value?.isFollowed) != state.value?.isFollowed
        let shift = changed ? (followed == true ? 1 : -1) : 0
        return shown.followerCount.map { max($0 + shift, 0) }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if hasRanking, !isRankingHidden {
                RankingPlayButton(user: user, action: playRanking)
                    .disabled(currentRanking.isEmpty)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
            if !isSelf, hasFollowLists {
                followButton
            }
            if !currentRanking.isEmpty || webURL != nil {
                moreMenu
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isRankingHidden)
    }

    private var followButton: some View {
        let isFollowed = followed ?? state.value?.isFollowed ?? false
        let followsYou = state.value?.followsYou == true
        let title = isFollowed ? (followsYou ? "互相关注" : "已关注") : (followsYou ? "回关" : "关注")
        let symbol = isFollowed ? (followsYou ? "arrow.left.arrow.right" : "checkmark") : "plus"
        return Button(action: toggleFollow) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .disabled(state.value == nil)
    }

    private var moreMenu: some View {
        PopMenu {
            if !currentRanking.isEmpty {
                PopMenuItem.button("下一首播放排行", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(next: true) }
                PopMenuItem.button("将排行添加到播放队列", systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(next: false) }
            }
            if let url = webURL {
                PopMenuItem.divider
                PopMenuItem.button("复制主页链接", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.showToast("已复制主页链接")
                }
                PopMenuItem.button("在浏览器中打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        } label: { open in
            PopMenuEllipsis(isOpen: open)
                .foregroundStyle(theme.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isCircle: true))
        .fixedSize()
    }

    private var webURL: URL? {
        model.webURL(.user(user.id), in: user.source)
    }

    private var isRankingHidden: Bool {
        rankingHidden || state.value?.isRankingPublic == false
    }

    private var isFollowListHidden: Bool {
        followsHidden || state.value?.areFollowsPublic == false
    }

    private var tabItems: [PageTabs<Section>.Item] {
        var items: [PageTabs<Section>.Item] = []
        if hasRanking { items.append(.init(value: .ranking, title: "听歌排行")) }
        items += [
            .init(value: .created, title: "创建的歌单", count: lists.value.map(\.created.count) ?? shown.createdPlaylistCount),
            .init(value: .subscribed, title: "收藏的歌单", count: lists.value.map(\.subscribed.count)),
        ]
        if hasFollowLists {
            items += [
                .init(value: .follows, title: "关注", count: shown.followCount),
                .init(value: .followers, title: "粉丝", count: followerCount),
            ]
        }
        return items
    }

    private func sectionBinding(_ tab: Binding<Tab>) -> Binding<Section> {
        Binding {
            tab.wrappedValue.section
        } set: { section in
            tabTouched = true
            switch section {
            case .ranking: tab.wrappedValue = rankingTab
            case .created: tab.wrappedValue = .created
            case .subscribed: tab.wrappedValue = .subscribed
            case .follows: tab.wrappedValue = .follows
            case .followers: tab.wrappedValue = .followers
            }
        }
    }

    /// Last week / all time are tabs of their own, so switching them scrolls and slides like a tab.
    private func periodBinding(_ tab: Binding<Tab>) -> Binding<ListeningPeriod> {
        Binding {
            tab.wrappedValue == .weekRanking ? .week : .allTime
        } set: { period in
            tabTouched = true
            tab.wrappedValue = period == .week ? .weekRanking : .allRanking
        }
    }

    /// The selected tab as rows of the page's lazy stack (several views, not one container).
    @ViewBuilder private var tabRows: some View {
        switch tab {
        case .weekRanking: rankingRows(.week)
        case .allRanking: rankingRows(.allTime)
        case .created: playlistRows(created: true)
        case .subscribed: playlistRows(created: false)
        case .follows: userRows(follows, list: "follows", empty: "还没有关注的人", fetch: followFetcher(followers: false))
        case .followers: userRows(followers, list: "followers", empty: "还没有粉丝", fetch: followFetcher(followers: true))
        }
    }

    @ViewBuilder private func userRows(_ feed: PagedFeed<UserProfile>, list: String, empty: String, fetch: @escaping PagedFeed<UserProfile>.PageFetch) -> some View {
        if isFollowListHidden {
            StateView(systemName: "lock", title: "\(shown.nickname.isEmpty ? "TA" : shown.nickname) 没有公开关注和粉丝")
        } else {
            switch feed.phase {
            case .idle, .loading:
                UserSkeleton(count: 8)
                    .task { await feed.loadIfNeeded(pages: fetch) }
            case .failed(let message):
                failure(message) { Task { await feed.load(pages: fetch) } }
            case .loaded:
                Color.clear.frame(height: 8)
                if feed.items.isEmpty {
                    StateView(systemName: "person.2", title: empty)
                } else {
                    UserRows(users: feed.items, list: list)
                }
                if feed.hasMore {
                    if feed.moreFailed {
                        PillButton(title: "加载失败，重试", systemName: "arrow.clockwise", variant: .tertiary) { feed.retryMore() }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    } else {
                        UserSkeleton(count: 3)
                            .task(id: feed.items.count) { await feed.loadMore(pages: fetch) }
                    }
                }
            }
        }
    }

    private func followFetcher(followers: Bool) -> PagedFeed<UserProfile>.PageFetch {
        let model = model, id = user.id, source = user.source
        return { page in
            do {
                let users = try model.require(source, as: (any UserFollowSource).self, "关注列表")
                let result = followers ? try await users.followers(ofUser: id, page: page) : try await users.follows(ofUser: id, page: page)
                return (result.users, result.nextPage)
            } catch UserSourceError.followsHidden {
                followsHidden = true
                throw UserSourceError.followsHidden
            }
        }
    }

    @ViewBuilder private func rankingRows(_ period: ListeningPeriod) -> some View {
        let ranking = period == .week ? week : allTime
        if isRankingHidden {
            StateView(systemName: "lock", title: "\(shown.nickname.isEmpty ? "TA" : shown.nickname) 没有公开听歌排行")
        } else {
            switch ranking {
            case .idle, .loading:
                TrackSkeleton(count: 10, artwork: true)
                    .task { await loadRanking(period) }
            case .failed(let message):
                failure(message) { Task { await loadRanking(period, again: true) } }
            case .loaded(let ranked):
                Color.clear.frame(height: 8)
                if ranked.isEmpty {
                    StateView(systemName: "music.note", title: period == .week ? "最近一周没有听歌记录" : "还没有听歌记录")
                } else {
                    RankingRows(ranked: ranked, period: period, context: context, tint: barTint)
                    Text(rankingFooter(ranked, period: period))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(theme.onSurfaceVariant)
                        .padding(.top, 22)
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func rankingFooter(_ ranked: [RankedTrack], period: ListeningPeriod) -> String {
        var parts = [period == .week ? "最近一周听得最多的 \(ranked.count) 首" : "听得最多的 \(ranked.count) 首"]
        if let total = shown.listenedSongCount, total > 0 { parts.append("累计听歌 \(ProfileFormat.count(total)) 首") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func playlistRows(created: Bool) -> some View {
        switch lists {
        case .idle, .loading:
            PlaylistGridSkeleton(columns: columns)
        case .failed(let message):
            failure(message) { Task { await loadPlaylists() } }
        case .loaded(let lists):
            let playlists = created ? lists.created : lists.subscribed
            if playlists.isEmpty {
                StateView(systemName: "music.note.list", title: created ? "还没有创建歌单" : "没有公开收藏的歌单")
            } else {
                ProfilePlaylistRows(playlists: playlists, columns: columns, showsCreator: !created)
            }
        }
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            StateView(systemName: "exclamationmark.triangle", title: "加载失败", detail: message).frame(minHeight: 0)
            PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary, action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var barTint: Color {
        guard let glow = backdrop.tint, let hsb = glow.hsb else { return theme.onSurface }
        return theme.isDark
            ? .hsb(hsb.hue, min(hsb.saturation, 0.55), 0.9)
            : .hsb(hsb.hue, min(hsb.saturation, 0.6), 0.55)
    }

    private var currentRanking: [Track] {
        ((rankingTab == .weekRanking ? week : allTime).value ?? []).map(\.track)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        // Not animated: the page's height changes with it (see `DetailPageScroll`); the pieces
        // that appear bring their own transitions.
        state = await Loadable.run { try await model.users(user.source).user(id: user.id) }
        followed = nil
        if state.value?.isRankingPublic == false, !tabTouched, tab.section == .ranking {
            tab = .created
        }
    }

    private func loadPlaylists() async {
        if lists.value == nil { lists = .loading }
        let loaded = await Loadable.run { try await model.users(user.source).playlists(ofUser: user.id) }
        lists = Task.isCancelled && lists.value == nil ? .idle : loaded
    }

    private func loadRanking(_ period: ListeningPeriod, again: Bool = false) async {
        let current = period == .week ? week : allTime
        guard again || current.value == nil, !current.isLoading else { return }
        setRanking(.loading, period)
        do {
            let ranked = try await model.require(user.source, as: (any ListeningRankingSource).self, "听歌排行").listeningRanking(ofUser: user.id, period: period)
            setRanking(.loaded(ranked), period)
        } catch UserSourceError.rankingHidden {
            rankingHidden = true
            setRanking(.loaded([]), period)
        } catch {
            setRanking(Task.isCancelled ? .idle : .failed(ErrorText.describe(error)), period)
        }
    }

    private func setRanking(_ value: Loadable<[RankedTrack]>, _ period: ListeningPeriod) {
        if period == .week { week = value } else { allTime = value }
    }

    private func playRanking() {
        if model.player.playState(from: .user, of: user.source, id: user.id) != nil {
            model.player.togglePlayPause()
        } else if !currentRanking.isEmpty {
            model.player.play(currentRanking, context: context)
        }
    }

    private func enqueue(next: Bool) {
        let tracks = currentRanking
        guard !tracks.isEmpty else { return }
        if next {
            model.player.playNext(tracks)
            model.showToast("已添加 \(tracks.count) 首到下一首播放")
        } else {
            model.player.addToQueue(tracks)
            model.showToast("已添加 \(tracks.count) 首到播放队列")
        }
    }

    private func toggleFollow() {
        guard let profile = state.value, let follow = model.source(user.source, as: (any UserFollowSource).self) else { return }
        guard model.accounts.isLoggedIn(user.source) else {
            model.requestLogin(user.source)
            return
        }
        let was = followed ?? profile.isFollowed ?? false
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { followed = !was }
        Task {
            do {
                try await follow.setUserFollowed(user.id, followed: !was)
                model.showToast(was ? "已取消关注" : "已关注 \(profile.nickname)")
            } catch {
                withAnimation { followed = was }
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private struct ProfileAvatar: View {
    var artwork: Artwork?
    var level: Int?
    var maxLevel: Int?
    var size: CGFloat
    var glow: Color?
    var appeared: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private static let ringGap: CGFloat = 9
    private static let ringWidth: CGFloat = 3

    private var ringDiameter: CGFloat { size + 2 * Self.ringGap }

    var body: some View {
        ZStack {
            if let level {
                LevelRing(level: level, maxLevel: maxLevel, color: ringColor, lineWidth: Self.ringWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
            }
            ArtworkView(artwork: artwork, circle: true, zoom: hovering ? 1.05 : 1, pixelSize: ProfilePage.avatarPixels, neutralPlaceholder: "person.fill")
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: theme.coverShadow(glow), radius: hovering ? 26 : 18, y: hovering ? 14 : 9)
                .scaleEffect(hovering ? 1.02 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.lift, value: hovering)
                .reveal(appeared, distance: 0, scale: 0.92)
            if let level {
                LevelBadge(level: level, color: ringColor)
                    .offset(y: ringDiameter / 2)
                    .offset(y: hovering ? 2 : 0)
                    .animation(Motion.lift, value: hovering)
                    .help("等级 Lv.\(level)")
            }
        }
        .frame(width: ringDiameter + Self.ringWidth, height: ringDiameter + Self.ringWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.map { "头像，等级 \($0)" } ?? "头像")
    }

    private var ringColor: Color {
        guard let glow, let hsb = glow.hsb else { return theme.primary }
        return theme.isDark
            ? .hsb(hsb.hue, min(hsb.saturation, 0.5), 0.9)
            : .hsb(hsb.hue, min(hsb.saturation, 0.62), 0.52)
    }
}

private struct LevelRing: View {
    var level: Int
    var maxLevel: Int?
    var color: Color
    var lineWidth: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false

    private var progress: Double {
        guard let maxLevel, maxLevel > 0 else { return 0 }
        return min(max(Double(level) / Double(maxLevel), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(theme.onSurface.opacity(theme.isDark ? 0.1 : 0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: swept ? progress : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(90))
        }
        .allowsHitTesting(false)
        .animation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.8), value: level)
        .onAppear {
            guard !swept else { return }
            if reduceMotion {
                swept = true
            } else {
                withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 1.3).delay(0.28)) { swept = true }
            }
        }
    }
}

private struct LevelBadge: View {
    var level: Int
    var color: Color
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    var body: some View {
        Text("Lv.\(level)")
            .font(.system(size: 11, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(theme.surface)
            .contentTransition(.numericText(value: Double(level)))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color, in: Capsule())
            .padding(2.5)
            .background(theme.surface, in: Capsule())
            .scaleEffect(popped || reduceMotion ? 1 : 0.4)
            .opacity(popped ? 1 : 0)
            .onAppear {
                guard !popped else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.58).delay(reduceMotion ? 0 : 0.16)) { popped = true }
            }
    }
}

private struct GenderMark: View {
    var gender: UserProfile.Gender
    @Environment(\.theme) private var theme

    var body: some View {
        let color = gender == .male ? Color(hex: theme.isDark ? "#6FA8F5" : "#3E82E0") : Color(hex: theme.isDark ? "#F48FB5" : "#E0588C")
        Text(gender == .male ? "♂" : "♀")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(color.opacity(0.15), in: Circle())
            .help(gender == .male ? "男" : "女")
    }
}

/// Follows · followers · events · songs listened: numbers over their labels, rolling up from zero
/// once the details arrive. A count the source does not show is left out.
private struct ProfileStats: View {
    struct Item {
        var title: String
        var value: Int?
        var open: (() -> Void)? = nil
    }

    var items: [Item]
    var loaded: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var counted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 26) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if loaded, let value = item.value {
                    StatCell(open: item.open) { hovering in
                        VStack(alignment: .leading, spacing: 3) {
                            CountingNumber(value: counted ? Double(value) : 0, final: value)
                                .font(.system(size: 19, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(theme.onSurface)
                                .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(0.05 * Double(index)), value: counted)
                                .animation(.easeOut(duration: 0.35), value: value)
                            HStack(spacing: 2) {
                                Text(item.title)
                                if item.open != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .opacity(hovering ? 1 : 0)
                                        .offset(x: hovering ? 0 : -3)
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(hovering ? theme.onSurface : theme.onSurfaceVariant)
                        }
                    }
                } else if !loaded {
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBar(width: 34, height: 14)
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
            }
        }
        .frame(height: 42, alignment: .bottomLeading)
        // The update that brought the details drew the zeros; the numbers run from them. Set
        // here rather than from a main-actor task: during the route's fade such a task can wait
        // a while for its turn.
        .onChange(of: loaded) {
            if loaded, !counted { counted = true }
        }
    }
}

private struct StatCell<Content: View>: View {
    var open: (() -> Void)?
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        if let open {
            Button(action: open) {
                content(hovering).contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .linkPointer()
        } else {
            content(false)
        }
    }
}

/// A count drawn at an animated value, in the width of its final value, so rolling up moves
/// no layout.
private struct CountingNumber: View, Animatable {
    var value: Double
    var final: Int

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(ProfileFormat.count(final))
            .hidden()
            .overlay(alignment: .leading) {
                Text(ProfileFormat.count(Int(value.rounded())))
                    .fixedSize()
            }
    }
}

private struct RankingPlayButton: View {
    var user: UserProfile
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let state = model.player.playState(from: .user, of: user.source, id: user.id)
        let playing = state == true
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(playing ? "暂停" : (state != nil ? "继续播放" : "播放排行"))
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(theme.onPrimary)
            .padding(.horizontal, 20)
            .frame(height: 38)
        }
        .buttonStyle(VariantButtonStyle(variant: .filled, isPill: true))
        .animation(Motion.hover, value: state)
    }
}

/// The ranking as song rows, each over a bar of its share of the top song's plays, so the list
/// reads as a chart. The rows rise in a stagger when the list first shows and the bars grow
/// behind them from the left. Its body is the rows themselves, so they become rows of the
/// page's lazy stack.
private struct RankingRows: View {
    var ranked: [RankedTrack]
    var period: ListeningPeriod
    var context: PlaybackContext
    var tint: Color
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let tracks = ranked.map(\.track)
        // Keyed by period too: a song in both lists must not be taken for the other list's row
        // by the lazy stack.
        let rows = ranked.enumerated().map { (key: "\(period.rawValue)-\($0.element.track.id.id)", index: $0.offset, item: $0.element) }
        ForEach(rows, id: \.key) { _, index, item in
            SongRow(track: item.track, index: index + 1, trailing: item.playCount.map { AnyView(PlayCount(count: $0)) }) {
                model.player.play(tracks, startAt: index, context: context)
            }
            .background {
                ScoreBar(fraction: shown ? Double(item.score) / 100 : 0)
                    // Fades along the row, so a long bar thins out towards the columns on the right.
                    .fill(LinearGradient(colors: [tint.opacity(theme.isDark ? 0.15 : 0.11), tint.opacity(theme.isDark ? 0.04 : 0.03)], startPoint: .leading, endPoint: .trailing))
                    .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.92).delay(0.12 + Double(min(index, Motion.staggerLimit)) * 0.04), value: shown)
            }
            .staggeredReveal(shown, index: index)
            .onAppear { if !shown { shown = true } }
        }
    }
}

private struct PlayCount: View {
    var count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(count) 次")
            .font(.system(size: 12.5))
            .monospacedDigit()
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(width: 52, alignment: .trailing)
    }
}

/// A rounded bar from the row's leading edge, `fraction` of its width, a little inside the row's
/// height so bars of neighbouring rows stay apart. Animates by fraction, so growing it moves no
/// layout.
private struct ScoreBar: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    private static let inset: CGFloat = 5
    private static let radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let lane = rect.insetBy(dx: 0, dy: Self.inset)
        let width = lane.width * min(max(fraction, 0), 1)
        guard width > 0.5 else { return Path() }
        let bar = CGRect(x: lane.minX, y: lane.minY, width: width, height: lane.height)
        return Path(roundedRect: bar, cornerRadius: min(Self.radius, width / 2), style: .continuous)
    }
}

/// A user's playlists as rows of cover cards (`columns` to a row); the created ones say how many
/// songs and plays, the collected ones who made them. They rise in a stagger when the grid first
/// shows. Its body is the rows, so they become rows of the page's lazy stack.
private struct ProfilePlaylistRows: View {
    var playlists: [Playlist]
    var columns: Int
    var showsCreator: Bool
    @Environment(AppModel.self) private var model
    @State private var shown = false

    static let spacing: CGFloat = 22
    static let minCardWidth: CGFloat = 156

    nonisolated static func columns(for width: CGFloat) -> Int {
        max(2, Int((width - 2 * Metrics.pagePadding + spacing) / (minCardWidth + spacing)))
    }

    var body: some View {
        let columns = max(columns, 1)
        let kind = showsCreator ? "subscribed" : "created"
        let rows = stride(from: 0, to: playlists.count, by: columns).map { (key: "\(kind)-\($0 / columns)", index: $0 / columns, row: Array(playlists[$0..<min($0 + columns, playlists.count)])) }
        ForEach(rows, id: \.key) { _, index, row in
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(row) { playlist in
                    CoverCard(title: playlist.name, subtitle: subtitle(playlist), artwork: playlist.artwork) {
                        model.navigate(.collection(playlist))
                    } onPlay: {
                        play(playlist)
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(row.count..<columns, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .padding(.top, index == 0 ? 22 : 0)
            .padding(.bottom, 24)
            .staggeredReveal(shown, index: index)
            .onAppear { if !shown { shown = true } }
        }
    }

    private func subtitle(_ playlist: Playlist) -> String {
        if showsCreator { return playlist.creatorName ?? "" }
        var parts = ["\(playlist.trackCount) 首"]
        if playlist.playCount > 0 { parts.append("播放 \(TimeFormatting.compactCount(playlist.playCount))") }
        return parts.joined(separator: " · ")
    }

    private func play(_ playlist: Playlist) {
        Task {
            do {
                let detail = try await model.catalog(playlist.source).playlist(id: playlist.id)
                model.player.play(detail.tracks, context: PlaybackContext(source: playlist.source, originType: .playlist, originID: playlist.id, originName: playlist.name))
            } catch {
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private struct PlaylistGridSkeleton: View {
    var columns: Int
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(alignment: .top, spacing: ProfilePlaylistRows.spacing) {
                    ForEach(0..<max(columns, 1), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                                .aspectRatio(1, contentMode: .fit)
                            SkeletonBar(width: [112, 84, 128, 96][index % 4], height: 11)
                            SkeletonBar(width: 64, height: 9)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.top, 22)
        .shimmer()
    }
}

enum ProfileFormat {
    static func count(_ n: Int) -> String {
        guard n >= 100_000 else { return n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
        return TimeFormatting.compactCount(n)
    }
}
