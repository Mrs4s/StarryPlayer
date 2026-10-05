import AudioProcessing
import Library
import LocalLibrary
import LyricsCore
import LyricsProviders
import MusicSources
import Observation
import PlaybackEngine
import PluginHost
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Home page needs, loaded in one go. Equatable, so a kept-alive Home whose
/// content did not change is not rendered again.
struct HomeContent: Equatable {
    var recommended: [Playlist] = []
    var dailyPlaylists: [Playlist] = []
    var daily: [Track] = []
    var newSongs: [Track] = []
    var newAlbums: [Album] = []
    var topArtists: [Artist] = []
    var shelves: [HomeShelf] = []
}

struct LaunchOptions {
    var settings: SettingsStore?
    var sources: [any MusicSource]?
    var localLibrary = DataDirectory()
    var keepsPlayback = true
    var prepare: (@MainActor (AppModel) -> Void)?
}

@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let registry = SourceRegistry()
    let library = LibraryDatabase()
    let player: PlayerController
    let keepsData: Bool
    @ObservationIgnored private let keepsPlayback: Bool

    private var history = NavigationHistory()
    var route: Route { history.current.route }
    var currentEntry: HistoryEntry { history.current }
    /// Entries whose pages stay mounted (hidden when not current): the current one and up to 8
    /// back.
    var livePages: [HistoryEntry] { history.live }
    var canGoBack: Bool { history.canGoBack }

    var sidebarCollapsed = false
    private(set) var sidebarMode: AppSettings.SidebarMode = .floating
    var sidebarPeeking = false
    private(set) var showSettings = false
    var settingsPage: SettingsPage = .app(.general)
    private(set) var loginRequest: LoginRequest?
    private let loginWindow = AuxiliaryWindowController(identifier: AppModel.loginWindowIdentifier)
    static let loginWindowIdentifier = "starry.login"
    let search = SearchModel()
    var toast: String?
    private var toastTask: Task<Void, Never>?

    let accounts: AccountCenter
    private(set) var plugins: PluginManager = .empty
    private(set) var playlistsBySource: [SourceID: [Playlist]] = [:]
    @ObservationIgnored private var libraryLoadedAt: [SourceID: Date] = [:]
    /// The playlist holding each source's liked songs, when it keeps them as one: songs go in
    /// by the heart, not by adding to a playlist, and it is not edited (PlaylistEditing.swift).
    private(set) var likedPlaylistIDs: [SourceID: String] = [:]
    var playlistChange: PlaylistChange?
    var playlistPulse: PlaylistPulse?
    let playlistEditorWindow = AuxiliaryWindowController(identifier: AppModel.playlistEditorIdentifier)
    static let playlistEditorIdentifier = "starry.playlist-editor"
    @ObservationIgnored var draggedTracks: [Track] = []
    /// Local music: built in, there with or without plugins; nil without `keepsData`.
    @ObservationIgnored private(set) var localSource: LocalSource?
    @ObservationIgnored private var followsFirstAccount = true
    /// Goes up when the local library's songs change (a scan), so pages showing them load again.
    private(set) var localRevision = 0
    private(set) var localStatus = LibraryStatus()

    init(launch: LaunchOptions = LaunchOptions()) {
        settings = launch.settings ?? SettingsStore()
        keepsData = launch.sources == nil
        keepsPlayback = keepsData && launch.keepsPlayback
        player = PlayerController()
        accounts = AccountCenter(directory: keepsData ? DataDirectory() : nil)
        if keepsData { plugins = SourceCatalog.plugins(settings: settings.settings) }
        appliedPluginPreferences = settings.settings.plugins
        for source in launch.sources ?? SourceCatalog.pluginSources(settings: settings.settings, plugins: plugins) {
            registry.register(source)
        }
        localSource = keepsData ? SourceCatalog.localSource(settings: settings.settings, directory: launch.localLibrary) : nil
        if let localSource {
            registry.register(localSource)
            registry.currentSourceID = localSource.id
        }
        appliedSourceSettings = settings.settings.sources
        sidebarCollapsed = settings.settings.sidebarCollapsed
        sidebarMode = settings.settings.sidebarMode
        adoptLyricPlugins()
        wirePlayer()
        // Core Audio's device list is read after the first frame, not in front of it; so is
        // the menu bar item put up.
        Task { watchOutputDevices() }
        Task { applyMenuBarLyrics() }
        launch.prepare?(self)
        updatePreferredColorScheme()
        updatePlayerBarStyle()
        search.attach(self)
        Task { await bootstrapAccounts() }
        Task { await search.prepare() }
        restorePlayback()
        startLocalLibrary()
    }

    var browsingSourceID: SourceID { registry.currentSourceID }
    var currentSource: (any MusicSource)? { registry.current }
    var currentSourceName: String { currentSource?.displayName ?? "未选择来源" }

    func selectBrowsingSource(_ id: SourceID) {
        followsFirstAccount = false
        guard id != browsingSourceID, registry.source(for: id) != nil else { return }
        registry.currentSourceID = id
        Task { await search.sourceChanged() }
    }

    func displayName(of id: SourceID) -> String {
        registry.source(for: id)?.displayName ?? "未知来源"
    }

    var accountSwitcherOpen = false
    var pendingIdentity: AccountIdentity?

    func qualityTiers(for track: Track) -> [QualityTier] {
        registry.source(for: track.id.source)?.tiers ?? []
    }

    func availableTiers(of track: Track) -> [QualityTier] {
        let ids = Set(track.availableTiers)
        return qualityTiers(for: track).filter { ids.contains($0.id) }
    }

    func requestedTier(for track: Track) -> QualityTier {
        let preferred = settings.settings.preferredQuality
        guard let source = registry.source(for: track.id.source) else { return QualityTier(preferred) }
        return source.requestedTier(preferred: preferred, override: settings.settings.sourceQualities[source.id.key])
    }

    func tierName(_ tier: QualityTier, of track: Track) -> String {
        qualityTiers(for: track).first { $0.id == tier.id }?.name ?? tier.name
    }

    func webURL(_ page: WebPage, in id: SourceID) -> URL? {
        registry.source(for: id)?.webURL(for: page)
    }

    /// `id`'s source when it has the ability `T` (a sub-protocol such as `any CatalogSource`);
    /// nil when it is not registered or cannot do it. The UI hides what this finds nothing for.
    func source<T>(_ id: SourceID, as type: T.Type) -> T? {
        registry.source(for: id)?.capability(type)
    }

    func require<T>(_ id: SourceID, as type: T.Type, _ ability: String) throws -> T {
        guard let source = registry.source(for: id) else { throw SourceError.notRegistered(id) }
        guard let typed = source.capability(type) else { throw SourceError.capabilityMissing(ability) }
        return typed
    }

    func catalog(_ id: SourceID) throws -> any CatalogSource {
        try require(id, as: (any CatalogSource).self, "目录浏览")
    }

    func library(_ id: SourceID) throws -> any UserLibrarySource {
        try require(id, as: (any UserLibrarySource).self, "用户曲库")
    }

    func users(_ id: SourceID) throws -> any UserSource {
        try require(id, as: (any UserSource).self, "用户主页")
    }

    func searchable() throws -> any SearchableSource {
        try require(browsingSourceID, as: (any SearchableSource).self, "搜索")
    }

    var searchSource: (any SearchableSource)? { source(browsingSourceID, as: (any SearchableSource).self) }

    func hasUserPages(_ id: SourceID?) -> Bool {
        id.map { source($0, as: (any UserSource).self) != nil } ?? false
    }

    func commentSource(_ id: SourceID) -> (any CommentSource)? {
        source(id, as: (any CommentSource).self)
    }

    func collecting(_ kind: CollectionItem.Kind, in id: SourceID) -> (any CollectionSource)? {
        source(id, as: (any CollectionSource).self).flatMap { $0.collectableKinds.contains(kind) ? $0 : nil }
    }

    var hasDailyRecommendations: Bool { source(browsingSourceID, as: (any DailyRecommendationSource).self) != nil }
    var hasPersonalFM: Bool { source(browsingSourceID, as: (any RadioSource).self) != nil }
    var hasAllMedia: Bool { source(browsingSourceID, as: (any AllMediaSource).self) != nil }
    var hasLibrary: Bool { source(browsingSourceID, as: (any UserLibrarySource).self) != nil }
    var librarySections: [LibrarySection] { source(browsingSourceID, as: (any LibraryBrowsingSource).self)?.librarySections ?? [] }

    var configurableSources: [any ConfigurableSource] {
        registry.sources.compactMap { $0.capability((any ConfigurableSource).self) }
    }

    @ObservationIgnored private var appliedSourceSettings: [String: SourceSettingValues] = [:]
    @ObservationIgnored private var sourceSettingsHandOvers: [String: Task<Void, Never>] = [:]

    private func applySourceSettings() {
        let saved = settings.settings.sources
        guard saved != appliedSourceSettings else { return }
        for source in configurableSources where saved[source.id.key] != appliedSourceSettings[source.id.key] {
            let values = settings.settings.sourceSettings(source.id)
            let previous = sourceSettingsHandOvers[source.id.key]
            sourceSettingsHandOvers[source.id.key] = Task {
                await previous?.value
                await source.applySettings(values)
            }
        }
        for plugin in plugins.enabledPlugins where !plugin.isSource && saved[plugin.settingsID.key] != appliedSourceSettings[plugin.settingsID.key] {
            plugin.applySettings(settings.settings.sourceSettings(plugin.settingsID), notify: true)
        }
        appliedSourceSettings = saved
    }

    private(set) var nowPlayingPanel: NowPlayingPanel = .lyrics
    /// +1 enters from the right; −1 from the left.
    private(set) var nowPlayingPanelDirection = 1
    /// The player bar's cover in window coordinates, reported by the bar as it lays out: where
    /// the Now Playing cover flies from and back to. Not observed; read when the page opens or
    /// closes.
    @ObservationIgnored var playerBarCoverFrame: CGRect?
    @ObservationIgnored private var songThreads: [(track: TrackRef, thread: SongCommentThread)] = []
    @ObservationIgnored private var songThreadsAccount: String?

    /// The song's comment thread, kept while the song is among the last few asked for, so the
    /// panel comes back as it was left. Nil when the song's source has no comments.
    func commentThread(for track: Track) -> SongCommentThread? {
        guard let source = commentSource(track.id.source) else { return nil }
        let account = accounts.profile(of: track.id.source)?.userID
        if songThreadsAccount != account {
            songThreadsAccount = account
            songThreads.removeAll()
        }
        if let entry = songThreads.first(where: { $0.track == track.id }) { return entry.thread }
        let thread = SongCommentThread(source: track.id.source, target: .song(track.id.id), sort: source.commentSorts.first ?? .latest)
        songThreads.insert((track.id, thread), at: 0)
        if songThreads.count > 4 { songThreads.removeLast() }
        return thread
    }

    func selectNowPlayingPanel(_ panel: NowPlayingPanel) {
        guard panel != nowPlayingPanel else { return }
        nowPlayingPanelDirection = panel.rawValue > nowPlayingPanel.rawValue ? 1 : -1
        withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) { nowPlayingPanel = panel }
    }

    func showNowPlaying(_ panel: NowPlayingPanel) {
        guard let track = player.current, panel != .comments || commentSource(track.id.source) != nil else { return }
        if player.showNowPlaying {
            selectNowPlayingPanel(panel)
        } else {
            nowPlayingPanelDirection = 1
            nowPlayingPanel = panel
            player.showNowPlaying = true
        }
    }

    var account: AccountState { accounts.state(of: browsingSourceID) }
    var isLoggedIn: Bool { isLibraryOpen(browsingSourceID) }
    var profile: AccountProfile? { accounts.profile(of: browsingSourceID) }

    func isLibraryOpen(_ id: SourceID) -> Bool {
        guard registry.source(for: id) != nil else { return false }
        return accountSource(id) == nil || accounts.isLoggedIn(id)
    }

    var userPlaylists: [Playlist] { (playlistsBySource[browsingSourceID] ?? []).filter(\.isOwned) }
    var subscribedPlaylists: [Playlist] { (playlistsBySource[browsingSourceID] ?? []).filter { !$0.isOwned } }

    func accountSource(_ id: SourceID) -> (any AccountSource)? {
        source(id, as: (any AccountSource).self)
    }

    var accountSources: [any AccountSource] {
        registry.sources.compactMap { $0.capability((any AccountSource).self) }
    }

    func canLogIn(_ id: SourceID) -> Bool { accountSource(id) != nil }

    func requestLogin(_ id: SourceID? = nil) {
        presentLogin(LoginRequest(source: id ?? browsingSourceID))
    }

    func presentLogin(_ request: LoginRequest) {
        guard canLogIn(request.source) else { return }
        if request == loginRequest, let window = loginWindow.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let name = displayName(of: request.source)
        loginWindow.show(title: request.adding ? "添加\(name)账号" : "登录\(name)", model: self, onClose: { [weak self] in
            guard let self else { return }
            if loginRequest == request { loginRequest = nil }
            Task { await self.loginDialogClosed(request.source) }
        }) {
            LoginView(request: request)
        }
        loginRequest = request
    }

    func closeLogin() {
        loginWindow.close()
    }

    private func bootstrapAccounts() async {
        accounts.onChange = { [weak self] id, previous, state in self?.accountChanged(id, from: previous, to: state) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStaleLibraries() }
        }
        for source in accountSources {
            do {
                try await accounts.watch(source)
            } catch {
                showToast(ErrorText.describe(error))
            }
        }
        followsFirstAccount = false
        for source in registry.sources where accountSource(source.id) == nil && source.supports((any UserLibrarySource).self) {
            await refreshUserLibrary(source.id)
        }
    }

    private func accountChanged(_ id: SourceID, from previous: String?, to state: AccountState) {
        if followsFirstAccount, localSource != nil, browsingSourceID == .local, state == .loggingIn || accounts.isLoggedIn(id) {
            selectBrowsingSource(id)
        }
        switch state {
        case .loggedIn(let profile):
            guard profile.userID != previous else { return }
            if previous != nil { clearUserLibrary(id) }
            Task { await refreshUserLibrary(id) }
        case .anonymous, .expired:
            clearUserLibrary(id)
        case .loggingIn:
            break
        }
    }

    private func clearUserLibrary(_ id: SourceID) {
        playlistsBySource[id] = nil
        likedPlaylistIDs[id] = nil
        libraryLoadedAt[id] = nil
        setLikedSongs([], of: id)
    }

    func refreshAccount(_ id: SourceID? = nil) async {
        guard let source = accountSource(id ?? browsingSourceID) else { return }
        try? await source.account.refresh()
    }

    func refreshUserLibrary(_ id: SourceID? = nil) async {
        let id = id ?? browsingSourceID
        guard isLibraryOpen(id), let source = self.source(id, as: (any UserLibrarySource).self) else { return }
        async let playlists = source.userPlaylists()
        async let liked = source.likedTrackIDs()
        async let likedList = source.likedPlaylistID()
        var loaded = true
        if let playlists = try? await playlists {
            playlistsBySource[id] = playlists
        } else {
            loaded = false
        }
        if let likedList = try? await likedList { likedPlaylistIDs[id] = likedList }
        if let liked = try? await liked {
            setLikedSongs(liked, of: id)
        } else {
            loaded = false
        }
        libraryLoadedAt[id] = loaded ? Date() : .distantPast
    }

    func updatePlaylists(of id: SourceID, _ change: (inout [Playlist]) -> Void) {
        guard var playlists = playlistsBySource[id] else { return }
        change(&playlists)
        playlistsBySource[id] = playlists
    }

    /// The songs `id`'s account likes, as its source just listed them (also by the liked songs page, so
    /// songs liked on another device or client get their hearts).
    func setLikedSongs(_ ids: [String], of id: SourceID) {
        player.liked = player.liked.filter { $0.source != id }.union(ids.map { TrackRef(source: id, id: $0) })
    }

    /// Back in the app: the playlists and liked songs loaded more than ten minutes ago, or whose
    /// load failed (a server out of reach at launch), load again, as they change on other
    /// devices and clients.
    private func refreshStaleLibraries() {
        for source in accountSources where accounts.isLoggedIn(source.id) {
            guard let loaded = libraryLoadedAt[source.id], Date().timeIntervalSince(loaded) >= 10 * 60 else { continue }
            libraryLoadedAt[source.id] = Date()
            Task { await refreshUserLibrary(source.id) }
        }
    }

    func logout(_ id: SourceID? = nil) async {
        guard let source = accountSource(id ?? browsingSourceID) else { return }
        try? await source.account.logout()
        showToast("已退出登录")
    }

    func switchAccount(_ id: SourceID, to userID: String) async {
        guard let source = accountSource(id) else { return }
        do {
            try await accounts.switchAccount(source, to: userID)
            if let profile = accounts.profile(of: id), profile.userID == userID { showToast("已切换到「\(profile.nickname)」") }
        } catch {
            showToast(ErrorText.describe(error))
        }
    }

    /// Adding an account: keeps the signed-in account of `id` aside for another to sign in. False when the
    /// login dialog should not open (the account could not be kept; the toast says why).
    func addAccount(_ id: SourceID) async -> Bool {
        guard let source = accountSource(id) else { return false }
        do {
            return try await accounts.beginAdding(source)
        } catch {
            showToast(ErrorText.describe(error))
            return false
        }
    }

    /// A login dialog for `id` closed: after adding an account without a new login, the account kept aside
    /// signs in again (nothing happens otherwise).
    func loginDialogClosed(_ id: SourceID) async {
        guard let source = accountSource(id) else { return }
        do {
            try await accounts.endAdding(source)
        } catch {
            showToast(ErrorText.describe(error))
        }
    }

    func isCollected(_ playlist: Playlist) -> Bool {
        playlistsBySource[playlist.source]?.contains { $0.id == playlist.id && !$0.isOwned } == true
    }

    func setCollected(_ playlist: Playlist, _ collected: Bool) async throws {
        let id = playlist.source
        let before = playlistsBySource[id]
        if var list = before {
            if collected {
                if !list.contains(where: { $0.id == playlist.id }) {
                    var added = playlist
                    added.isOwned = false
                    list.insert(added, at: 0)
                }
            } else {
                list.removeAll { $0.id == playlist.id && !$0.isOwned }
            }
            playlistsBySource[id] = list
        }
        do {
            try await require(id, as: (any CollectionSource).self, "收藏").setCollected(.playlist(playlist.id), collected: collected)
            await refreshUserLibrary(id)
        } catch {
            playlistsBySource[id] = before
            throw error
        }
    }

    func loginBenefits(of id: SourceID) -> String {
        var items: [String] = []
        if source(id, as: (any UserLibrarySource).self) != nil { items += ["歌单", "红心"] }
        if source(id, as: (any DailyRecommendationSource).self) != nil { items.append("每日推荐") }
        guard let last = items.popLast() else { return "登录后使用账号的全部功能" }
        return "同步你的" + (items.isEmpty ? last : items.joined(separator: "、") + "与" + last)
    }

    func canLike(_ track: Track) -> Bool {
        source(track.id.source, as: (any UserLibrarySource).self) != nil
    }

    /// A song liked or unliked in this session, so the liked songs page can follow without reloading.
    struct LikeChange: Equatable {
        var track: Track
        var liked: Bool
        var serial: Int
    }

    /// The latest like or unlike (also the undoing of one the source refused).
    private(set) var likeChange: LikeChange?

    func toggleLike(_ track: Track) {
        let id = track.id.source
        guard let source = self.source(id, as: (any UserLibrarySource).self) else { return }
        guard isLibraryOpen(id) else { requestLogin(id); return }
        let liked = !player.isLiked(track)
        setLiked(track, liked)
        Task {
            do {
                try await source.setLiked(track.id, liked: liked)
            } catch {
                setLiked(track, !liked)
                showToast(ErrorText.describe(error))
            }
        }
    }

    private func setLiked(_ track: Track, _ liked: Bool) {
        player.setLiked(track, liked)
        likeChange = LikeChange(track: track, liked: liked, serial: (likeChange?.serial ?? 0) + 1)
    }

    struct HomeKey: Hashable {
        var source: SourceID
        var userID: String?
        var revision = 0
    }

    var homeKey: HomeKey { HomeKey(source: browsingSourceID, userID: signedInUser, revision: browsingSourceID == .local ? localRevision : 0) }

    /// The browsing source's user, kept while the account signs in again (a token refresh does
    /// not reload what follows the account); `""` for a source without accounts, whose library
    /// is always open.
    var signedInUser: String? {
        accountSource(browsingSourceID) == nil && registry.current != nil ? "" : accounts.currentUser(of: browsingSourceID)
    }

    /// The last Home content, so a new visit to Home (each visit is its own page) shows it at
    /// once instead of a skeleton, and does not ask the source again for a few minutes.
    @ObservationIgnored private var homeCache: (content: HomeContent, key: HomeKey, date: Date)?

    func cachedHome(maxAge: TimeInterval = 300) -> HomeContent? {
        guard let homeCache, homeCache.key == homeKey, Date().timeIntervalSince(homeCache.date) < maxAge else { return nil }
        return homeCache.content
    }

    func loadHome() async throws -> HomeContent {
        let key = homeKey
        let content = try await fetchHome(key)
        homeCache = (content, key, Date())
        return content
    }

    private func fetchHome(_ key: HomeKey) async throws -> HomeContent {
        var content = HomeContent()
        if let source = self.source(key.source, as: (any RecommendationSource).self) {
            async let recommended = source.recommendedPlaylists()
            async let newSongs = source.newSongs()
            async let newAlbums = source.newAlbums(page: Page(offset: 0, limit: 12))
            async let topArtists = source.topArtists(page: Page(offset: 0, limit: 12))
            content.recommended = try await recommended
            content.newSongs = (try? await newSongs) ?? []
            content.newAlbums = (try? await newAlbums) ?? []
            content.topArtists = (try? await topArtists) ?? []
        }
        if let source = self.source(key.source, as: (any HomeShelfSource).self) {
            do {
                content.shelves = try await source.homeShelves()
            } catch {
                if content == HomeContent() { throw error }
            }
        }
        if key.userID != nil, let source = self.source(key.source, as: (any DailyRecommendationSource).self) {
            async let daily = source.dailyRecommendations()
            async let dailyPlaylists = source.dailyPlaylists()
            content.daily = (try? await daily) ?? []
            content.dailyPlaylists = (try? await dailyPlaylists) ?? []
        }
        return content
    }

    private func wirePlayer() {
        let songCache = keepsData ? SongCache(limit: Self.songCacheLimit(settings.settings.cache)) : nil
        self.songCache = songCache
        let resolver = PlayURLResolver(steps: [
            CacheStep { track, tier in await songCache?.asset(for: track, tier: tier) },
            SourceStep { [weak self] id in await self?.registry.source(for: id) },
        ])
        player.resolveAsset = { [weak self] track, tier in
            guard let self else { throw PlaybackError.sourceUnreachable }
            return try await resolver.resolve(track, options: ResolveOptions(allowTrialPlay: settings.settings.allowTrialPlay, tier: tier ?? requestedTier(for: track)))
        }
        // Lyrics: the plugins' lyric providers, the AMLL TTML DB
        // and an optional local TTML folder, chosen by the lyric source settings.
        let cache = LyricsCache(directory: keepsData ? LyricsCache.defaultDirectory : nil)
        lyricsCache = cache
        rebuildLyricsResolver()
        lyricPins = LyricSourcePins(directory: keepsData ? DataDirectory() : nil)
        player.loadLyrics = { [weak self] track in
            guard let self, let lyrics = lyricsResolver else { return AsyncStream { $0.finish() } }
            let options = lyricOptions()
            guard let pin = lyricPins.pin(for: track.id) else { return lyrics.resolve(track, options: options) }
            return AsyncStream { continuation in
                let task = Task {
                    if let found = await lyrics.lyrics(for: track, pinnedTo: pin, options: options) {
                        continuation.yield(found)
                    } else {
                        for await result in lyrics.resolve(track, options: options) { continuation.yield(result) }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        player.prefetchLyrics = { [weak self] track in
            guard let options = self?.lyricOptions(), let lyrics = self?.lyricsResolver else { return }
            _ = await lyrics.bestLyrics(for: track, options: options)
        }
        appliedLyricOptions = lyricOptions()
        observeSettings()
        player.lyricOffsets = LyricOffsetStore(directory: keepsData ? DataDirectory() : nil)
        reloadVocalModel()
        player.preloadsNext = settings.settings.preloadNextTrack
        player.transitions = settings.settings.transition
        player.engine.loudness = settings.settings.loudness
        applySongCacheSettings()
        player.keepDownload = { [weak self] track, asset, file in self?.keepInSongCache(track, asset: asset, file: file) }
        player.onTrackStarted = { [weak self] track in
            self?.library.recordPlay(track)
            self?.savePlaybackSnapshot()
        }
        player.onMessage = { [weak self] message in self?.showToast(message) }
        player.reportPlayback = { [weak self] report in
            guard let self, settings.settings.scrobble.enabled else { return }
            guard let source = registry.source(for: report.track.source)?.capability((any ScrobblingSource).self) else { return }
            Task { await source.reportPlayback(report) }
        }
        wirePersonalFM()
    }

    private func startLocalLibrary() {
        guard let localSource else { return }
        NotificationCenter.default.addObserver(forName: LocalSource.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localLibraryChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { await localSource.volumesDidChange() }
            }
        }
        Task {
            for await status in localSource.statusUpdates where status != localStatus {
                localStatus = status
            }
        }
        Task { await localSource.start() }
    }

    /// The local library's songs changed: Home and the lists showing them load again, and so
    /// do its liked songs and playlists.
    private func localLibraryChanged() {
        localRevision += 1
        Task { await refreshUserLibrary(.local) }
    }

    func chooseLocalFolders() {
        guard let localSource else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择存放音乐的文件夹，里面的歌会加入本地音乐"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { await self?.addLocalFolder(url, using: localSource) }
            }
        }
    }

    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        guard let localSource else { return false }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) && TagReader.isAudio($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !folders.isEmpty || !files.isEmpty else { return false }
        Task {
            for folder in folders { await addLocalFolder(folder, using: localSource) }
            guard !files.isEmpty else { return }
            let tracks = await localSource.songs(forFiles: files)
            guard !tracks.isEmpty else {
                showToast("没有能播放的音频文件")
                return
            }
            let name = tracks.count == 1 ? tracks[0].title : "打开的 \(tracks.count) 首歌"
            player.play(tracks, context: PlaybackContext(source: .local, originType: .queue, originName: name))
            NSApp.activate()
        }
        return true
    }

    func addLocalFolder(_ url: URL, using localSource: LocalSource) async {
        do {
            try await localSource.addFolder(url)
            showToast("正在扫描「\(url.lastPathComponent)」")
        } catch {
            showToast(ErrorText.describe(error))
        }
    }

    private(set) var vocalModel: VocalSeparationModel = .systemVoice

    var vocalModelFolder: URL {
        settings.settings.vocalModelDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VocalSeparationModelLocator.defaultDirectory(in: DataDirectory.defaultURL)
    }

    /// The model in use is one the app comes with (in its `Resources/Models`), not a side-loaded one.
    var vocalModelIsBuiltIn: Bool {
        guard let directory = vocalModel.directory, let models = Bundle.main.resourceURL?.appending(path: "Models") else { return false }
        return directory.standardizedFileURL.path.hasPrefix(models.standardizedFileURL.path + "/")
    }

    func reloadVocalModel() {
        let model = VocalSeparationModelLocator.locate(in: [vocalModelFolder], bundle: .main)
        vocalModel = model
        player.engine.vocalModel = model
    }

    /// nil restores the default folder.
    func setVocalModelFolder(_ url: URL?) {
        settings.settings.vocalModelDirectory = url?.path
        reloadVocalModel()
    }

    @ObservationIgnored private var appliedPluginPreferences = AppSettings.Plugins()

    func reloadPlugins() {
        guard keepsData else { return }
        appliedPluginPreferences = settings.settings.plugins
        let browsing = browsingSourceID
        let old = registry.sources.compactMap { $0 as? PluginSource }.map(\.id)
        for id in old {
            registry.unregister(id)
            accounts.unwatch(id)
        }
        plugins = SourceCatalog.plugins(settings: settings.settings)
        let sources = SourceCatalog.pluginSources(settings: settings.settings, plugins: plugins)
        for source in sources { registry.register(source) }
        if let localSource { registry.register(localSource) }
        if registry.source(for: browsing) != nil { registry.currentSourceID = browsing }
        for id in old where registry.source(for: id) == nil { clearUserLibrary(id) }
        appliedSourceSettings = settings.settings.sources
        adoptLyricPlugins()
        rebuildLyricsResolver()
        player.reloadLyrics()
        Task {
            for source in sources.compactMap({ $0.capability((any AccountSource).self) }) {
                try? await accounts.watch(source)
            }
            if browsing != browsingSourceID { await search.sourceChanged() }
        }
    }

    private func applyPluginPreferences() {
        let saved = settings.settings.plugins
        let applied = appliedPluginPreferences
        guard Set(saved.disabled) != Set(applied.disabled) || saved.inspectable != applied.inspectable
            || saved.developmentFolders != applied.developmentFolders || saved.logsCalls != applied.logsCalls else {
            appliedPluginPreferences = saved
            return
        }
        reloadPlugins()
    }

    /// The plugins' lyric providers, the AMLL TTML DB and an optional local TTML folder.
    private func rebuildLyricsResolver() {
        guard let cache = lyricsCache else { return }
        let pluginLyrics = plugins.lyricsProviders(cache: cache) { self.settings.settings.sourceSettings($0) }
        lyricsResolver = LyricsResolver.standard(cache: cache, providers: pluginLyrics) { [weak self] id in
            await self?.registry.source(for: id)
        }
    }

    private(set) var lyricsCache: LyricsCache?
    @ObservationIgnored private var lyricsResolver: LyricsResolver?
    @ObservationIgnored private(set) var lyricPins = LyricSourcePins(directory: nil)
    private var appliedLyricOptions = LyricsResolverOptions()

    func lyricCandidateSources(for track: Track) -> [LyricsCandidateSource] {
        lyricsResolver?.candidateSources(for: track, options: lyricOptions()) ?? []
    }

    func lyricCandidates(for track: Track) -> AsyncStream<LyricsCandidate> {
        guard let lyricsResolver else { return AsyncStream { $0.finish() } }
        return lyricsResolver.candidates(for: track, options: lyricOptions())
    }

    func pinLyrics(_ lyrics: ResolvedLyrics, to pin: LyricsPin, for track: Track) {
        lyricPins.set(pin, for: track.id)
        if player.current?.id == track.id { player.useLyrics(lyrics) }
    }

    func unpinLyrics(for track: Track) {
        lyricPins.set(nil, for: track.id)
        if player.current?.id == track.id { player.reloadLyrics() }
    }

    func searchLyrics(_ keyword: String) -> AsyncStream<LyricsSearchAnswer> {
        guard let lyricsResolver else { return AsyncStream { $0.finish() } }
        return lyricsResolver.searchSongs(keyword, options: lyricOptions())
    }

    var lyricProviderIDs: [LyricsProviderID] {
        lyricsResolver?.providerIDs ?? LyricsProviderID.known
    }

    func lyricProviderDetail(_ id: LyricsProviderID) -> String? {
        lyricsResolver?.detail(of: id) ?? id.detail
    }

    /// Whether a lyric platform comes from a plugin the app does not come with.
    func isAddedLyricPlugin(_ id: LyricsProviderID) -> Bool {
        plugins.plugins.contains { $0.isLyricsProvider && $0.lyricsProviderID == id && plugins.origin(of: $0) != .builtIn }
    }

    private func adoptLyricPlugins() {
        let fresh = plugins.plugins.filter(\.isLyricsProvider).map(\.lyricsProviderID)
            .filter { !LyricsProviderID.known.contains($0) }.map(\.rawValue)
            .filter { !settings.settings.knownLyricPlugins.contains($0) }
        guard !fresh.isEmpty else { return }
        settings.settings.knownLyricPlugins += fresh
        settings.settings.lyricSourceOrder += fresh.filter { !settings.settings.lyricSourceOrder.contains($0) }
    }

    var lyricSearchProviders: [LyricsProviderID] {
        lyricsResolver?.searchProviders(options: lyricOptions()) ?? []
    }

    /// The lyrics of a song from lyric search, or nil when it has none.
    func lyrics(of result: LyricsSearchResult, for track: Track) async throws -> ResolvedLyrics? {
        try await lyricsResolver?.lyrics(of: result, for: track, options: lyricOptions())
    }

    func openLyricsFile(for track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = LyricsFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "载入"
        panel.message = "为「\(track.title)」选择歌词文件（LRC、TTML、YRC、QRC、KRC）"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadLyricsFile(at: url, for: track)
        }
    }

    /// Reads a lyric file (opened or dropped) for `track` and pins the song to it; says so in
    /// a toast either way.
    @discardableResult
    func loadLyricsFile(at url: URL, for track: Track) -> Bool {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), let file = LyricsFile(name: name, data: data),
              let lyrics = lyricsResolver?.lyrics(from: file, for: track, options: lyricOptions()) else {
            showToast("「\(name)」里没有可用的歌词")
            return false
        }
        pinLyrics(lyrics, to: .file(file), for: track)
        showToast("已载入歌词「\(name)」")
        return true
    }

    func switchTier(to tier: QualityTier, for track: Track) {
        guard let source = registry.source(for: track.id.source) else { return }
        let follows = source.tier(for: settings.settings.preferredQuality).id == tier.id
        settings.settings.sourceQualities[source.id.key] = follows ? nil : tier.id
        guard player.current?.id == track.id, player.currentAsset?.tier.id != tier.id else { return }
        player.reloadCurrent(tier: tier)
    }

    func lyricOptions() -> LyricsResolverOptions {
        let s = settings.settings
        var options = LyricsResolverOptions()
        options.preferTrackPlatform = s.lyricPreferTrackPlatform
        options.providerOrder = s.lyricSourceOrder.compactMap(LyricsProviderID.init(rawValue:))
        options.raceProviders = s.lyricRaceProviders
        let server = s.amllDbServer.trimmingCharacters(in: .whitespaces)
        options.ttmlDatabase = s.amllDbEnabled && !server.isEmpty ? server : nil
        options.localRepository = s.localLyricRepository.map { URL(fileURLWithPath: $0, isDirectory: true) }
        options.stripCredits = s.stripLyricCredits
        return options
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let options = self.lyricOptions()
                if options != self.appliedLyricOptions {
                    self.appliedLyricOptions = options
                    self.player.reloadLyrics()
                }
                self.updatePreferredColorScheme()
                self.updatePlayerBarStyle()
                self.updateSidebarMode()
                self.player.preloadsNext = self.settings.settings.preloadNextTrack
                self.player.transitions = self.settings.settings.transition
                self.player.engine.loudness = self.settings.settings.loudness
                self.applyOutputDevice()
                self.applySongCacheSettings()
                self.applyMenuBarLyrics()
                self.applySourceSettings()
                self.applyPluginPreferences()
                self.observeSettings()
            }
        }
    }

    func clearLyricsCache() async {
        await lyricsCache?.clear()
        player.reloadLyrics()
    }

    @ObservationIgnored private lazy var menuBarLyrics = MenuBarLyricsController(model: self)

    var showsMenuBarLyrics: Bool {
        get { settings.settings.menuBarLyrics.enabled }
        set {
            settings.settings.menuBarLyrics.enabled = newValue
            applyMenuBarLyrics()
        }
    }

    private func applyMenuBarLyrics() {
        menuBarLyrics.apply(enabled: showsMenuBarLyrics, options: settings.settings.menuBarLyrics)
    }

    /// Songs kept after they were heard; nil without `keepsData`.
    @ObservationIgnored private(set) var songCache: SongCache?
    @ObservationIgnored private var appliedSongCacheLimit: Int64?

    static func songCacheLimit(_ cache: AppSettings.Cache) -> Int64? {
        cache.sizeLimitGB > 0 ? Int64(cache.sizeLimitGB * 1_000_000_000) : nil
    }

    private func applySongCacheSettings() {
        let cache = settings.settings.cache
        player.engine.keepsDownloads = songCache != nil && cache.enabled
        let limit = Self.songCacheLimit(cache)
        guard limit != appliedSongCacheLimit else { return }
        appliedSongCacheLimit = limit
        Task { [songCache] in await songCache?.setLimit(limit) }
    }

    private func keepInSongCache(_ track: Track, asset: PlayableAsset, file: URL) {
        guard let songCache, settings.settings.cache.enabled else { return }
        let requested = requestedTier(for: track)
        Task {
            let kept = await songCache.add(file, for: track, container: asset.container, tier: asset.tier, requested: requested, gain: asset.gain)
            if kept { NSLog("[cache] kept %@ (%@, %@)", track.title, asset.container.rawValue, asset.tier.id) }
        }
    }

    /// Opens `route`; a page already in the history moves to the top as it was left (see
    /// `NavigationHistory.open`). The history is left untouched when nothing changes (the
    /// current page clicked again, back at the first page), so no view reading it updates.
    func navigate(_ route: Route) {
        guard !route.isSamePage(as: self.route) else { return }
        history.open(route)
    }

    func showAlbum(of track: Track) {
        guard let album = track.album, album.isLinkable else { return }
        player.showNowPlaying = false
        navigate(.album(Album(id: album.id, source: track.id.source, name: album.name, artists: track.artists, artwork: album.artwork)))
    }

    func showArtist(_ artist: ArtistRef, of track: Track) {
        guard artist.isLinkable else { return }
        player.showNowPlaying = false
        navigate(.artist(Artist(id: artist.id, source: track.id.source, name: artist.name)))
    }

    /// Whether the playing queue's origin is a page to go to (personal FM, a local folder or a
    /// hand-built queue are not).
    func canOpenPlaybackOrigin(_ context: PlaybackContext) -> Bool {
        context.originType == .user ? context.originID != nil && hasUserPages(context.source) : route(for: context) != nil
    }

    func openPlaybackOrigin(_ context: PlaybackContext) {
        let name = context.originName ?? ""
        if context.originType == .user {
            if let id = context.originID, let source = context.source { showUser(id: id, name: name, avatar: nil, in: source) }
            return
        }
        guard let route = route(for: context) else { return }
        player.showNowPlaying = false
        navigate(route)
    }

    private func route(for context: PlaybackContext) -> Route? {
        let name = context.originName ?? ""
        switch context.originType {
        case .playlist, .album, .artist:
            guard let id = context.originID, let source = context.source else { return nil }
            return switch context.originType {
            case .playlist: .collection(Playlist(id: id, source: source, name: name))
            case .album: .album(Album(id: id, source: source, name: name))
            default: .artist(Artist(id: id, source: source, name: name))
            }
        case .search: return name.isEmpty ? nil : .search(name)
        case .dailyRecommendation: return .daily
        case .liked: return .liked
        case .allMedia: return .allMedia
        case .history: return .history
        case .local: return context.originID.map { .libraryFolder($0) }
        case .user, .radio, .queue: return nil
        }
    }

    func openProfile(_ id: SourceID? = nil) {
        let id = id ?? browsingSourceID
        guard hasUserPages(id), let profile = accounts.profile(of: id) else { return }
        player.showNowPlaying = false
        navigate(.user(UserProfile(id: profile.userID, source: id, nickname: profile.nickname, avatar: profile.avatar, isVIP: profile.isVIP)))
    }

    func showCreator(of playlist: Playlist) {
        guard let id = playlist.creatorID else { return }
        showUser(id: id, name: playlist.creatorName ?? "", avatar: playlist.creatorAvatar, in: playlist.source)
    }

    func canShowUser(_ id: String?, in source: SourceID) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return hasUserPages(source)
    }

    func showUser(id: String, name: String, avatar: Artwork?, in source: SourceID) {
        guard canShowUser(id, in: source) else { return }
        player.showNowPlaying = false
        navigate(.user(UserProfile(id: id, source: source, nickname: name, avatar: avatar)))
    }

    func isSelf(_ user: UserProfile) -> Bool { accounts.profile(of: user.source)?.userID == user.id }

    func goBack() {
        guard canGoBack else { return }
        history.goBack()
    }

    func back() {
        if player.showNowPlaying {
            player.showNowPlaying = false
        } else if search.isActive {
            search.deactivate()
        } else {
            goBack()
        }
    }

    private(set) var locateRequest = 0

    func locatePlaying() {
        guard player.current != nil else { return }
        SettingsWindowController.shared.yieldToMainWindow()
        guard player.showNowPlaying else {
            locateRequest += 1
            return
        }
        player.showNowPlaying = false
        Task {
            try? await Task.sleep(for: .seconds(Motion.nowPlayingDuration + 0.05))
            locateRequest += 1
        }
    }

    func openSearch() {
        SettingsWindowController.shared.yieldToMainWindow()
        if player.showNowPlaying { player.showNowPlaying = false }
        search.focus()
    }

    func toggleSidebar() {
        switch sidebarMode {
        case .docked:
            withAnimation(Motion.sidebar) { sidebarCollapsed.toggle() }
            settings.settings.sidebarCollapsed = sidebarCollapsed
        case .floating: setSidebarMode(.autoHide)
        case .autoHide: setSidebarMode(.floating)
        }
    }

    func setSidebarMode(_ mode: AppSettings.SidebarMode) {
        settings.settings.sidebarMode = mode
        applySidebarMode(mode)
    }

    var sidebarInset: CGFloat {
        switch sidebarMode {
        case .docked: sidebarCollapsed ? Metrics.sidebarCollapsedWidth : Metrics.sidebarWidth
        case .floating: Metrics.floatingSidebarInset + Metrics.sidebarWidth
        case .autoHide: 0
        }
    }

    private func updateSidebarMode() {
        applySidebarMode(settings.settings.sidebarMode)
    }

    private func applySidebarMode(_ mode: AppSettings.SidebarMode) {
        guard mode != sidebarMode else { return }
        withAnimation(Motion.sidebar) {
            sidebarMode = mode
            sidebarPeeking = false
        }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(Motion.popover) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.popover) { toast = nil }
        }
    }

    func openSettings(_ category: SettingsCategory? = nil) {
        openSettings(page: category.map(SettingsPage.app))
    }

    func openSettings(page: SettingsPage?) {
        if let page { settingsPage = page }
        showSettings = true
        SettingsWindowController.shared.show(model: self)
    }

    func closeSettings() {
        SettingsWindowController.shared.close()
    }

    func settingsDidClose() {
        showSettings = false
    }

    var showsAdvancedSettings: Bool {
        get { settings.settings.showAdvancedSettings }
        set { settings.settings.showAdvancedSettings = newValue }
    }

    func resetSettings() {
        settings.settings = AppSettings()
        settingsPage = .app(.general)
        showToast("已恢复默认设置")
    }

    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var systemOutput: AudioOutputDevice?
    @ObservationIgnored private var outputWatch: AnyObject?

    private func watchOutputDevices() {
        refreshOutputDevices()
        outputWatch = AudioOutputDevices.watch { [weak self] in self?.refreshOutputDevices() }
    }

    private func refreshOutputDevices() {
        let devices = AudioOutputDevices.all()
        if devices != outputDevices { outputDevices = devices }
        let system = AudioOutputDevices.systemOutput()
        if system != systemOutput { systemOutput = system }
        applyOutputDevice()
    }

    /// The picked device while it is connected; otherwise the system output, until it is back.
    private func applyOutputDevice() {
        let picked = settings.settings.outputDevice?.uid
        player.engine.outputDeviceUID = picked.flatMap { uid in outputDevices.contains { $0.uid == uid } ? uid : nil }
    }

    @ObservationIgnored private let snapshotQueue = DispatchQueue(label: "moe.mrs4s.starry-player.playback-state", qos: .utility)

    /// Opens the queue left at the last quit (paused), and saves it again at this one (unless
    /// the launch said otherwise: `LaunchOptions.keepsPlayback`).
    private func restorePlayback() {
        guard keepsPlayback else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePlaybackSnapshot(waiting: true) }
        }
        guard settings.settings.restorePlayback else { return }
        Task {
            let directory = DataDirectory()
            // A queue of thousands of songs takes a moment to decode: not on the main thread.
            let snapshot = await Task.detached(priority: .userInitiated) { PlaybackSnapshot.load(from: directory) }.value
            if let snapshot { player.restore(snapshot) }
        }
    }

    func savePlaybackSnapshot(waiting: Bool = false) {
        guard keepsPlayback else { return }
        let directory = DataDirectory()
        let snapshot = settings.settings.restorePlayback ? player.snapshot() : nil
        let write: @Sendable () -> Void = {
            if let snapshot { snapshot.save(to: directory) } else { PlaybackSnapshot.delete(from: directory) }
        }
        if waiting { snapshotQueue.sync(execute: write) } else { snapshotQueue.async(execute: write) }
    }

    /// Cache appearance separately so unrelated settings changes do not update the entire scene.
    private(set) var preferredColorScheme: ColorScheme?

    private func updatePreferredColorScheme() {
        let scheme: ColorScheme? = switch settings.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
        if scheme != preferredColorScheme { preferredColorScheme = scheme }
    }

    /// Whether the player bar uses Liquid Glass: the saved style, on
    /// macOS 26 and later — before that the system has no Liquid Glass and the bar stays
    /// classic. Stored and written only on change, like `preferredColorScheme`.
    private(set) var playerBarUsesGlass = false

    private func updatePlayerBarStyle() {
        var glass = false
        if #available(macOS 26, *) {
            glass = settings.settings.playerBarStyle == .glass
        }
        if glass != playerBarUsesGlass { playerBarUsesGlass = glass }
    }

    func theme(for scheme: ColorScheme) -> Theme {
        let dark = scheme == .dark
        switch settings.settings.themeColorMode {
        case .default:
            return Theme.make(seed: Color(hex: "#FE7971"), dark: dark, tintSurfaces: false)
        case .custom:
            return Theme.make(seed: Color(hex: settings.settings.customThemeColorHex), dark: dark, tintSurfaces: false)
        case .cover:
            return Theme.make(seed: player.accentColor ?? Color(hex: "#FE7971"), dark: dark, tintSurfaces: player.accentColor != nil)
        }
    }
}
