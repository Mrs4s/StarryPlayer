import Foundation
import MusicSources
import StarryCore

/// A plugin as a music source. It conforms to every sub-protocol a plugin can fill and answers
/// `capability(_:)` only for the ones the plugin exports, so the UI shows what the plugin does and
/// nothing else.
public final class PluginSource: MusicSource, SearchableSource, CatalogSource, RecommendationSource, ConfigurableSource, AccountSource,
    UserLibrarySource, CollectionSource, DailyRecommendationSource, RadioSource, CommentSource, ScrobblingSource, AllMediaSource,
    UserSource, ListeningRankingSource, UserFollowSource, HomeShelfSource, PlaylistEditingSource, LibraryBrowsingSource {
    enum Capability {
        case search, catalog, recommendation, settings, account, library, collection, daily, radio, comments, scrobbling, allMedia
        case users, ranking, follows, homeShelves, playlistEditing, libraryBrowsing
    }

    private static let gates: [ObjectIdentifier: Capability] = [
        ObjectIdentifier((any SearchableSource).self): .search,
        ObjectIdentifier((any CatalogSource).self): .catalog,
        ObjectIdentifier((any RecommendationSource).self): .recommendation,
        ObjectIdentifier((any ConfigurableSource).self): .settings,
        ObjectIdentifier((any AccountSource).self): .account,
        ObjectIdentifier((any UserLibrarySource).self): .library,
        ObjectIdentifier((any CollectionSource).self): .collection,
        ObjectIdentifier((any DailyRecommendationSource).self): .daily,
        ObjectIdentifier((any RadioSource).self): .radio,
        ObjectIdentifier((any CommentSource).self): .comments,
        ObjectIdentifier((any ScrobblingSource).self): .scrobbling,
        ObjectIdentifier((any AllMediaSource).self): .allMedia,
        ObjectIdentifier((any UserSource).self): .users,
        ObjectIdentifier((any ListeningRankingSource).self): .ranking,
        ObjectIdentifier((any UserFollowSource).self): .follows,
        ObjectIdentifier((any HomeShelfSource).self): .homeShelves,
        ObjectIdentifier((any PlaylistEditingSource).self): .playlistEditing,
        ObjectIdentifier((any LibraryBrowsingSource).self): .libraryBrowsing,
    ]

    private static let catalogFunctions = ["songs", "album", "artist", "artistSongs", "artistAlbums", "similarArtists", "playlist"]
    private static let recommendationFunctions = ["recommendedPlaylists", "newSongs", "newAlbums", "topArtists"]
    private static let libraryFunctions = ["userPlaylists", "likedTrackIDs", "setLiked"]
    private static let playlistEditingFunctions = ["createPlaylist", "editPlaylist", "deletePlaylist", "addToPlaylist", "removeFromPlaylist", "reorderPlaylist"]

    public let plugin: Plugin
    public let id: SourceID
    public let displayName: String
    public let qualityTiers: [QualityTier]
    public let searchKinds: [SearchKind]
    public let artistSongOrders: [ArtistSongOrder]
    public let settingsSections: [SourceSettingsSection]
    public let collectableKinds: Set<CollectionItem.Kind>
    public let commentSorts: [CommentSort]
    public let canLikeComments: Bool
    public let playlistEditing: PlaylistEditing
    public let librarySections: [LibrarySection]
    public let albumSorts: [LibraryAlbumSort]
    private let webPages: [String: String]
    private let capabilities: Set<Capability>
    private let accountAdapter: PluginAccount?

    /// `plugin`, which must be a source (`Plugin.isSource`), with the values saved for it.
    public init(plugin: Plugin, settings: SourceSettingValues) {
        self.plugin = plugin
        let group = plugin.description.source
        id = plugin.manifest.sourceID
        displayName = plugin.manifest.name
        qualityTiers = (group?.qualityTiers ?? []).compactMap(\.tier)
        let kinds = (group?.searchKinds ?? ["song"]).compactMap(SearchKind.init(rawValue:)).filter { $0 != .user || plugin.has("source.user") }
        searchKinds = kinds.contains(.song) ? [.song] + kinds.filter { $0 != .song } : kinds
        let orders = (group?.artistSongOrders ?? []).compactMap(ArtistSongOrder.init(rawValue:))
        artistSongOrders = orders.isEmpty ? [.hot] : orders
        settingsSections = plugin.settingsSections
        webPages = group?.webPages ?? [:]
        collectableKinds = Set((group?.collectableKinds ?? []).compactMap { kind -> CollectionItem.Kind? in
            switch kind {
            case "playlist": .playlist
            case "album": .album
            case "artist": .artist
            default: nil
            }
        })
        let sorts = (group?.commentSorts ?? []).compactMap(CommentSort.init(rawValue:))
        commentSorts = sorts.isEmpty ? [.latest] : sorts
        canLikeComments = (group?.canLikeComments ?? false) && plugin.has("source.setCommentLiked")
        var editing = PlaylistEditing()
        editing.canCreate = plugin.has("source.createPlaylist")
        editing.canEdit = plugin.has("source.editPlaylist")
        editing.canDelete = plugin.has("source.deletePlaylist")
        editing.canAdd = plugin.has("source.addToPlaylist")
        editing.canRemove = plugin.has("source.removeFromPlaylist")
        editing.canReorder = plugin.has("source.reorderPlaylist")
        editing.keepsDescription = group?.playlistOptions?.description ?? false
        editing.keepsPrivacy = group?.playlistOptions?.privacy ?? false
        editing.privateByDefault = group?.playlistOptions?.privateByDefault ?? false
        editing.publicIsFinal = group?.playlistOptions?.publicIsFinal ?? false
        editing.nameLimit = group?.playlistOptions?.nameLimit.flatMap { $0 > 0 ? $0 : nil }
        playlistEditing = editing
        // Library: a genre opens its albums, so genres come with albums only.
        let hasAlbums = plugin.has("source.libraryAlbums")
        librarySections = [
            hasAlbums ? LibrarySection.albums : nil,
            plugin.has("source.libraryArtists") ? .artists : nil,
            hasAlbums && plugin.has("source.libraryGenres") ? .genres : nil,
        ].compactMap { $0 }
        let albumOrders = (group?.albumSorts ?? []).compactMap(LibraryAlbumSort.init(rawValue:))
        albumSorts = albumOrders.isEmpty ? [.title] : albumOrders
        accountAdapter = plugin.hasAccount ? PluginAccount(plugin: plugin) : nil
        var capabilities: Set<Capability> = []
        if plugin.has("source.search"), !searchKinds.isEmpty { capabilities.insert(.search) }
        if Self.catalogFunctions.contains(where: { plugin.has("source.\($0)") }) { capabilities.insert(.catalog) }
        if Self.recommendationFunctions.contains(where: { plugin.has("source.\($0)") }) { capabilities.insert(.recommendation) }
        if !settingsSections.isEmpty { capabilities.insert(.settings) }
        if accountAdapter != nil { capabilities.insert(.account) }
        if Self.libraryFunctions.contains(where: { plugin.has("source.\($0)") }) { capabilities.insert(.library) }
        if plugin.has("source.setCollected"), !collectableKinds.isEmpty { capabilities.insert(.collection) }
        if plugin.has("source.dailyRecommendations") { capabilities.insert(.daily) }
        if plugin.has("source.personalFM") { capabilities.insert(.radio) }
        if plugin.has("source.comments") || plugin.has("source.commentThread") { capabilities.insert(.comments) }
        if plugin.has("source.reportPlayback") { capabilities.insert(.scrobbling) }
        if plugin.has("source.allMedia") { capabilities.insert(.allMedia) }
        if Self.playlistEditingFunctions.contains(where: { plugin.has("source.\($0)") }) { capabilities.insert(.playlistEditing) }
        if plugin.has("source.homeShelves") { capabilities.insert(.homeShelves) }
        if !librarySections.isEmpty { capabilities.insert(.libraryBrowsing) }
        if plugin.has("source.user") {
            capabilities.insert(.users)
            if plugin.has("source.listeningRanking") { capabilities.insert(.ranking) }
            if plugin.has("source.follows"), plugin.has("source.followers") { capabilities.insert(.follows) }
        }
        self.capabilities = capabilities
        plugin.applySettings(settings, notify: false)
    }

    public func capability<T>(_ type: T.Type) -> T? {
        if let gate = Self.gates[ObjectIdentifier(type)], !capabilities.contains(gate) { return nil }
        return self as? T
    }

    public func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset {
        let asset: WireAsset = try await plugin.call("source.resolve", WireTrack(track), WireTier(tier))
        return try asset.asset(requested: tier, tiers: tiers, pluginID: plugin.manifest.id, decryption: plugin.decryption)
    }

    public func webURL(for page: WebPage) -> URL? {
        let (key, id): (String, String) = switch page {
        case .song(let id): ("song", id)
        case .playlist(let id): ("playlist", id)
        case .album(let id): ("album", id)
        case .artist(let id): ("artist", id)
        case .user(let id): ("user", id)
        }
        guard let template = (plugin.webPagesOverride ?? webPages)[key], let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{id}", with: encoded))
    }

    public func search(_ query: String, kind: SearchKind, page: Page) async throws -> SearchPage {
        let result: WireSearchPage = try await plugin.call("source.search", query, kind.rawValue, WirePage(page))
        return result.page(source: id, requested: page)
    }

    public func searchOverview(_ query: String) async throws -> SearchOverview {
        guard plugin.has("source.searchOverview") else { return try await composedOverview(query) }
        let overview: WireSearchOverview = try await plugin.call("source.searchOverview", query)
        return overview.overview(source: id, query: query)
    }

    public func searchSuggestions(_ prefix: String) async throws -> [String] {
        guard plugin.has("source.searchSuggestions") else { return [] }
        return try await plugin.call("source.searchSuggestions", prefix)
    }

    public func trendingSearches() async throws -> [SearchTrend] {
        guard plugin.has("source.trendingSearches") else { return [] }
        let trends: [WireTrend] = try await plugin.call("source.trendingSearches")
        return trends.map(\.trend)
    }

    public func searchHints() async throws -> [SearchHint] {
        guard plugin.has("source.searchHints") else { return [] }
        let hints: [WireHint] = try await plugin.call("source.searchHints")
        return hints.map(\.hint)
    }

    public func songs(ids: [String]) async throws -> [Track] {
        try require("songs", "按 id 取歌曲")
        let tracks: [WireTrack] = try await plugin.call("source.songs", ids)
        return tracks.map { $0.track(source: id) }
    }

    public func album(id albumID: String) async throws -> AlbumDetail {
        try require("album", "专辑")
        let detail: WireAlbumDetail = try await plugin.call("source.album", albumID)
        return detail.detail(source: id)
    }

    public func artist(id artistID: String) async throws -> ArtistDetail {
        try require("artist", "歌手")
        let detail: WireArtistDetail = try await plugin.call("source.artist", artistID)
        return detail.detail(source: id)
    }

    public func artistSongs(id artistID: String, order: ArtistSongOrder, page: Page) async throws -> [Track] {
        try require("artistSongs", "歌手的歌曲")
        let tracks: [WireTrack] = try await plugin.call("source.artistSongs", artistID, order.rawValue, WirePage(page))
        return tracks.map { $0.track(source: id) }
    }

    public func artistAlbums(id artistID: String, page: Page) async throws -> [Album] {
        try require("artistAlbums", "歌手的专辑")
        let albums: [WireAlbum] = try await plugin.call("source.artistAlbums", artistID, WirePage(page))
        return albums.map { $0.album(source: id) }
    }

    public func similarArtists(id artistID: String) async throws -> [Artist] {
        guard plugin.has("source.similarArtists") else { return [] }
        let artists: [WireArtist] = try await plugin.call("source.similarArtists", artistID)
        return artists.map { $0.artist(source: id) }
    }

    public func playlist(id playlistID: String) async throws -> PlaylistDetail {
        try require("playlist", "歌单")
        let detail: WirePlaylistDetail = try await plugin.call("source.playlist", playlistID)
        return detail.detail(source: id)
    }

    private func require(_ function: String, _ ability: String) throws {
        guard plugin.has("source.\(function)") else { throw SourceError.notImplemented("\(displayName)的\(ability)") }
    }

    public func recommendedPlaylists() async throws -> [Playlist] {
        guard plugin.has("source.recommendedPlaylists") else { return [] }
        let playlists: [WirePlaylist] = try await plugin.call("source.recommendedPlaylists")
        return playlists.map { $0.playlist(source: id) }
    }

    public func newSongs() async throws -> [Track] {
        guard plugin.has("source.newSongs") else { return [] }
        let tracks: [WireTrack] = try await plugin.call("source.newSongs")
        return tracks.map { $0.track(source: id) }
    }

    public func newAlbums(page: Page) async throws -> [Album] {
        guard plugin.has("source.newAlbums") else { return [] }
        let albums: [WireAlbum] = try await plugin.call("source.newAlbums", WirePage(page))
        return albums.map { $0.album(source: id) }
    }

    public func topArtists(page: Page) async throws -> [Artist] {
        guard plugin.has("source.topArtists") else { return [] }
        let artists: [WireArtist] = try await plugin.call("source.topArtists", WirePage(page))
        return artists.map { $0.artist(source: id) }
    }

    public func homeShelves() async throws -> [HomeShelf] {
        try require("homeShelves", "首页")
        let shelves: [WireHomeShelf] = try await plugin.call("source.homeShelves")
        return shelves.enumerated().compactMap { $1.shelf(source: id, position: $0) }
    }

    public var settingsSymbol: String { plugin.manifest.icon ?? "puzzlepiece.extension" }

    public var settingsSummary: String {
        let titles = settingsSections.compactMap(\.title)
        return titles.isEmpty ? plugin.manifest.description ?? "插件 · \(plugin.manifest.version)" : titles.joined(separator: "、")
    }

    public func applySettings(_ values: SourceSettingValues) async {
        plugin.applySettings(values, notify: true)
    }

    public var account: AccountAdapter { accountAdapter ?? PluginAccount(plugin: plugin) }

    public func likedTrackIDs() async throws -> [String] {
        guard plugin.has("source.likedTrackIDs") else { return [] }
        let ids: [JSONValue] = try await plugin.call("source.likedTrackIDs")
        return ids.compactMap { value in
            switch value {
            case .string(let id): id
            case .number(let number): String(Int64(number))
            default: nil
            }
        }
    }

    public func setLiked(_ track: TrackRef, liked: Bool) async throws {
        try require("setLiked", "收藏歌曲")
        let _: JSONValue = try await plugin.call("source.setLiked", track.id, liked)
    }

    public func userPlaylists() async throws -> [Playlist] {
        guard plugin.has("source.userPlaylists") else { return [] }
        let playlists: [WirePlaylist] = try await plugin.call("source.userPlaylists")
        return playlists.map { $0.playlist(source: id) }
    }

    public func likedPlaylistID() async throws -> String? {
        guard plugin.has("source.likedPlaylistID") else { return nil }
        let value: JSONValue = try await plugin.call("source.likedPlaylistID")
        switch value {
        case .string(let id): return id
        case .number(let number): return String(Int64(number))
        default: return nil
        }
    }

    public func setCollected(_ item: CollectionItem, collected: Bool) async throws {
        try require("setCollected", "收藏")
        let (kind, itemID): (String, String) = switch item {
        case .playlist(let id): ("playlist", id)
        case .album(let id): ("album", id)
        case .artist(let id): ("artist", id)
        }
        let _: JSONValue = try await plugin.call("source.setCollected", kind, itemID, collected)
    }

    public func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        try require("createPlaylist", "新建歌单")
        let playlist: WirePlaylist = try await plugin.call("source.createPlaylist", WirePlaylistDraft(draft))
        var created = playlist.playlist(source: id)
        created.isOwned = true
        return created
    }

    public func editPlaylist(_ playlistID: String, changes: PlaylistChanges) async throws {
        try require("editPlaylist", "编辑歌单")
        let _: JSONValue = try await plugin.call("source.editPlaylist", playlistID, WirePlaylistDraft(changes))
    }

    public func deletePlaylist(_ playlistID: String) async throws {
        try require("deletePlaylist", "删除歌单")
        let _: JSONValue = try await plugin.call("source.deletePlaylist", playlistID)
    }

    public func addTracks(_ trackIDs: [String], toPlaylist playlistID: String) async throws -> Int {
        try require("addToPlaylist", "加入歌单")
        let added: JSONValue = try await plugin.call("source.addToPlaylist", playlistID, trackIDs)
        if case .number(let count) = added { return Int(count) }
        return trackIDs.count
    }

    public func removeTracks(_ trackIDs: [String], fromPlaylist playlistID: String) async throws {
        try require("removeFromPlaylist", "从歌单删除歌曲")
        let _: JSONValue = try await plugin.call("source.removeFromPlaylist", playlistID, trackIDs)
    }

    public func reorderPlaylist(_ playlistID: String, trackIDs: [String]) async throws {
        try require("reorderPlaylist", "调整歌单顺序")
        let _: JSONValue = try await plugin.call("source.reorderPlaylist", playlistID, trackIDs)
    }

    public func dailyRecommendations() async throws -> [Track] {
        try require("dailyRecommendations", "每日推荐")
        let tracks: [WireTrack] = try await plugin.call("source.dailyRecommendations")
        return tracks.map { $0.track(source: id) }
    }

    public func dailyPlaylists() async throws -> [Playlist] {
        guard plugin.has("source.dailyPlaylists") else { return [] }
        let playlists: [WirePlaylist] = try await plugin.call("source.dailyPlaylists")
        return playlists.map { $0.playlist(source: id) }
    }

    public func personalFM(mode: RadioMode, firstFetch: Bool) async throws -> [Track] {
        try require("personalFM", "私人 FM")
        let tracks: [WireTrack] = try await plugin.call("source.personalFM", "\(mode)", firstFetch)
        return tracks.map { $0.track(source: id) }
    }

    public func skipFM(_ track: TrackRef, playedSeconds: TimeInterval) async throws {
        guard plugin.has("source.skipFM") else { return }
        let _: JSONValue = try await plugin.call("source.skipFM", track.id, playedSeconds)
    }

    public func trashFM(_ track: TrackRef, playedSeconds: TimeInterval) async throws {
        try require("trashFM", "不喜欢")
        let _: JSONValue = try await plugin.call("source.trashFM", track.id, playedSeconds)
    }

    public func comments(on target: CommentTarget, page: Page) async throws -> CommentPage {
        try require("comments", "评论")
        let result: WireCommentPage = try await plugin.call("source.comments", WireCommentTarget(target), WirePage(page))
        return result.page(source: id)
    }

    public func comments(on target: CommentTarget, sort: CommentSort, cursor: String?, limit: Int) async throws -> CommentSlice {
        try require("commentThread", "评论")
        let result: WireCommentSlice = try await plugin.call("source.commentThread", WireCommentTarget(target), sort.rawValue, cursor, limit)
        return result.slice(source: id)
    }

    public func replies(to commentID: String, on target: CommentTarget, cursor: String?, limit: Int) async throws -> CommentSlice {
        guard plugin.has("source.replies") else { return CommentSlice() }
        let result: WireCommentSlice = try await plugin.call("source.replies", commentID, WireCommentTarget(target), cursor, limit)
        return result.slice(source: id)
    }

    public func setCommentLiked(_ commentID: String, on target: CommentTarget, liked: Bool) async throws {
        try require("setCommentLiked", "评论点赞")
        let _: JSONValue = try await plugin.call("source.setCommentLiked", commentID, WireCommentTarget(target), liked)
    }

    public func allMedia(page: Page) async throws -> TrackPage {
        try require("allMedia", "所有媒体")
        let result: WireTrackPage = try await plugin.call("source.allMedia", WirePage(page))
        return result.page(source: id, asked: page)
    }

    public func libraryAlbums(sort: LibraryAlbumSort, genre: String?, page: Page) async throws -> LibraryPage<Album> {
        try require("libraryAlbums", "专辑列表")
        let result: WireAlbumPage = try await plugin.call("source.libraryAlbums", sort.rawValue, genre, WirePage(page))
        return result.page(source: id, asked: page)
    }

    public func libraryArtists(page: Page) async throws -> LibraryPage<Artist> {
        try require("libraryArtists", "歌手列表")
        let result: WireArtistPage = try await plugin.call("source.libraryArtists", WirePage(page))
        return result.page(source: id, asked: page)
    }

    public func libraryGenres() async throws -> [LibraryGenre] {
        guard plugin.has("source.libraryGenres") else { return [] }
        let genres: [WireGenre] = try await plugin.call("source.libraryGenres")
        return genres.map { $0.genre(source: id) }
    }

    public func user(id userID: String) async throws -> UserProfile {
        try require("user", "用户主页")
        let user: WireUser = try await plugin.call("source.user", userID)
        return user.user(source: id)
    }

    public func playlists(ofUser userID: String) async throws -> UserPlaylists {
        guard plugin.has("source.playlistsOfUser") else { return UserPlaylists() }
        let playlists: WireUserPlaylists = try await plugin.call("source.playlistsOfUser", userID)
        return playlists.playlists(source: id)
    }

    public func listeningRanking(ofUser userID: String, period: ListeningPeriod) async throws -> [RankedTrack] {
        try require("listeningRanking", "听歌排行")
        let ranking: [WireRankedTrack] = try await plugin.call("source.listeningRanking", userID, period.rawValue)
        return ranking.map { $0.ranked(source: id) }
    }

    public func follows(ofUser userID: String, page: Page) async throws -> UserPage {
        try require("follows", "关注列表")
        let users: WireUserPage = try await plugin.call("source.follows", userID, WirePage(page))
        return users.page(source: id, requested: page)
    }

    public func followers(ofUser userID: String, page: Page) async throws -> UserPage {
        try require("followers", "粉丝列表")
        let users: WireUserPage = try await plugin.call("source.followers", userID, WirePage(page))
        return users.page(source: id, requested: page)
    }

    public func setUserFollowed(_ userID: String, followed: Bool) async throws {
        try require("setUserFollowed", "关注用户")
        let _: JSONValue = try await plugin.call("source.setUserFollowed", userID, followed)
    }

    public func reportPlayback(_ report: PlaybackReport) async {
        guard plugin.has("source.reportPlayback") else { return }
        let _: JSONValue? = try? await plugin.call("source.reportPlayback", WirePlaybackReport(report))
    }
}
