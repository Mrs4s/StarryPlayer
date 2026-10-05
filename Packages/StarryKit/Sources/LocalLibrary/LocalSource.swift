import Foundation
import MusicSources
import StarryCore

public struct LibraryStatus: Sendable, Equatable {
    public var folders: [LibraryFolder] = []
    public var progress: ScanProgress?
    public var isBusy = false
    public var trackCount = 0

    public init() {}
}

public enum LocalLibraryError: LocalizedError, Equatable {
    /// The song's file is not where it was (and was not found elsewhere).
    case fileMissing(String)
    /// Its folder's volume is not mounted.
    case folderOffline(String)
    /// The system cannot play the file.
    case unsupported(String)
    case alreadyAdded(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let name): "找不到文件「\(name)」"
        case .folderOffline(let name): "「\(name)」所在的磁盘没有连接"
        case .unsupported(let name): "系统无法播放「\(name)」"
        case .alreadyAdded(let path): "「\((path as NSString).lastPathComponent)」已在本地音乐里"
        case .notFound: "本地音乐里没有这项内容"
        }
    }
}

public final class LocalSource: MusicSource, SearchableSource, CatalogSource, AllMediaSource, HomeShelfSource, UserLibrarySource,
    PlaylistEditingSource, LyricsSource, ScrobblingSource, ConfigurableSource, LibraryBrowsingSource, @unchecked Sendable {
    public let id: SourceID = .local
    public let displayName = "本地音乐"

    public static let didChange = Notification.Name("LocalSource.didChange")

    let store: LibraryStore
    private let engine: LibraryEngine
    private let artworkDirectory: URL

    /// `directory` nil: a library in memory (tests).
    public init(directory: DataDirectory? = DataDirectory(), artworkDirectory: URL = ArtworkStore.defaultDirectory, settings: SourceSettingValues = SourceSettingValues()) {
        let file = directory.map { $0.url.appending(path: LibraryStore.fileName) }
        let store: LibraryStore
        if let opened = try? LibraryStore(url: file) {
            store = opened
        } else {
            // A database that cannot be opened (damaged): this run keeps its library in memory.
            print("[local] cannot open \(file?.path ?? "memory"); using memory")
            store = try! LibraryStore(url: nil)
        }
        self.store = store
        self.artworkDirectory = artworkDirectory
        let rules = Self.rules(from: settings)
        engine = LibraryEngine(store: store, artworkDirectory: artworkDirectory, rules: rules, watches: Self.watches(settings))
    }

    public func start() async {
        await engine.start()
    }

    public var statusUpdates: AsyncStream<LibraryStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await engine.subscribe(id, continuation) }
            continuation.onTermination = { _ in Task { await self.engine.unsubscribe(id) } }
        }
    }

    public func status() async -> LibraryStatus { await engine.status }

    public func idle() async { await engine.idle() }

    public func addFolder(_ url: URL) async throws {
        try await engine.addFolder(url)
    }

    public func removeFolder(_ id: Int64) async throws {
        try await engine.removeFolder(id)
    }

    public func rescan(_ id: Int64? = nil, rereadTags: Bool = false) async {
        await engine.rescan(id, rereadTags: rereadTags)
    }

    public func setExcluded(_ paths: [String], of id: Int64) async throws {
        try await store.setExcluded(paths, of: id)
        await engine.rescan(id)
    }

    /// The encoding of a folder's old tags; nil votes again.
    public func setEncoding(_ encoding: LegacyEncoding?, of id: Int64) async throws {
        try await store.setEncoding(encoding, of: id)
        await engine.rederive(id)
    }

    public func purgeMissing() async throws -> Int {
        let count = try await store.purgeMissing()
        try await store.rebuildAggregates()
        await engine.changed()
        return count
    }

    public func volumesDidChange() async {
        await engine.volumesDidChange()
    }

    /// Songs of files opened on their own (dropped, or opened with the app): ones in the library are found, others
    /// are kept as songs outside it, so they can be liked or put in playlists.
    public func songs(forFiles urls: [URL]) async -> [Track] {
        var tracks: [Track] = []
        for url in urls where TagReader.isAudio(url) {
            if let id = try? await engine.songID(forFile: url), let row = try? await store.tracks(ids: [id]).first {
                tracks.append(track(row))
            }
        }
        return tracks
    }

    func artwork(_ coverID: String?, seed: String) -> Artwork {
        Artwork(url: coverID.flatMap { ArtworkStore.url(for: $0, directory: artworkDirectory) }, seed: seed)
    }

    func track(_ row: TrackRow) -> Track {
        let artists = zip(row.artistIDs, row.artistNames).map { ArtistRef(id: $0.0, name: $0.1) }
        let album = row.albumID.map { AlbumRef(id: $0, name: row.albumTitle ?? "", artwork: artwork(row.albumCoverID ?? row.coverID, seed: $0)) }
        return Track(
            id: TrackRef(source: .local, id: row.id),
            title: row.title.isEmpty ? (row.path as NSString).lastPathComponent : row.title,
            artists: artists,
            album: album,
            duration: row.duration,
            artwork: artwork(row.coverID ?? row.albumCoverID, seed: row.albumID ?? row.id),
            availableTiers: [Self.tier(row).id],
            discNumber: row.disc,
            trackNumber: row.track,
            localPath: row.path
        )
    }

    func album(_ row: AlbumRow) -> Album {
        Album(
            id: row.id, source: .local, name: row.title,
            artists: zip(row.artistIDs, row.artistNames).map { ArtistRef(id: $0.0, name: $0.1) },
            artwork: artwork(row.coverID, seed: row.id),
            // Year-only dates use January 1 at 00:00 UTC.
            releaseDate: row.year.flatMap { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: $0, month: 1, day: 1).date },
            trackCount: row.trackCount,
            releaseType: row.isCompilation ? "合辑" : nil
        )
    }

    func artist(_ row: ArtistRow) -> Artist {
        Artist(id: row.id, source: .local, name: row.name, artwork: artwork(row.coverID, seed: row.id), albumCount: row.albumCount, songCount: row.trackCount)
    }

    func playlist(_ row: PlaylistRow) -> Playlist {
        Playlist(id: row.id, source: .local, name: row.name, artwork: artwork(row.coverID, seed: row.id), createdAt: row.createdAt,
                 updatedAt: row.updatedAt, trackCount: row.trackCount, description: row.description, isOwned: true)
    }

    static func tier(_ row: TrackRow) -> QualityTier {
        let level: AudioQuality
        if ["flac", "alac", "pcm"].contains(row.codec) {
            level = (row.bitDepth ?? 16) > 16 || (row.sampleRate ?? 44100) > 48000 ? .hiRes : .lossless
        } else {
            let rate = row.bitrate ?? 0
            level = rate >= 256_000 ? .hq : rate >= 160_000 ? .sq : .lq
        }
        return QualityTier(level, detail: detail(row))
    }

    /// `320 kbps · MP3`, `24 bit · 96 kHz · FLAC`.
    static func detail(_ row: TrackRow) -> String {
        let codec = row.codec == "pcm" ? "PCM" : row.codec.uppercased()
        if ["flac", "alac", "pcm"].contains(row.codec) {
            let rate = row.sampleRate.map { $0 % 1000 == 0 ? "\($0 / 1000) kHz" : String(format: "%.1f kHz", Double($0) / 1000) }
            return [row.bitDepth.map { "\($0) bit" }, rate, codec].compactMap { $0 }.joined(separator: " · ")
        }
        return [row.bitrate.map { "\(($0 + 500) / 1000) kbps" }, codec].compactMap { $0 }.joined(separator: " · ")
    }

    public var offersQualityChoice: Bool { false }

    public func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset {
        guard let row = try await store.tracks(ids: [track.id.id]).first else { throw LocalLibraryError.notFound }
        let name = (row.path as NSString).lastPathComponent
        guard row.isPlayable else { throw LocalLibraryError.unsupported(name) }
        guard row.isAvailable else { throw LocalLibraryError.fileMissing(name) }
        let url = URL(fileURLWithPath: row.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            await engine.fileWentMissing(url)
            throw LocalLibraryError.fileMissing(name)
        }
        let container: AudioContainer = switch row.codec {
        case "flac": url.pathExtension.lowercased() == "flac" ? .flac : .mp4
        case "alac": .alac
        case "aac": .aac
        case "pcm": .wav
        case "vorbis", "opus": .ogg
        case "mp3", "mp2": .mp3
        default: .mp4
        }
        return PlayableAsset(
            url: url, container: container, tier: Self.tier(row), supportsTap: true, supportsOverlap: true, provider: .local,
            info: AudioStreamInfo(bitrate: row.bitrate, sampleRate: row.sampleRate, bitDepth: row.bitDepth, channels: row.channels, fileSize: row.size),
            gain: ReplayGain(trackGain: row.trackGain, trackPeak: row.trackPeak, albumGain: row.albumGain, albumPeak: row.albumPeak).nonEmpty
        )
    }

    public let searchKinds: [SearchKind] = [.song, .album, .artist, .playlist]

    public func search(_ query: String, kind: SearchKind, page: Page) async throws -> SearchPage {
        switch kind {
        case .song:
            let (rows, total) = try await store.searchTracks(query, offset: page.offset, limit: page.limit)
            return SearchPage(songs: rows.map(track), hasMore: page.offset + rows.count < total, nextPage: Page(offset: page.offset + rows.count, limit: page.limit), total: total)
        case .album:
            let rows = try await store.searchAlbums(query, offset: page.offset, limit: page.limit)
            return SearchPage(albums: rows.map(album), hasMore: rows.count == page.limit, nextPage: Page(offset: page.offset + rows.count, limit: page.limit))
        case .artist:
            let rows = try await store.searchArtists(query, offset: page.offset, limit: page.limit)
            return SearchPage(artists: rows.map(artist), hasMore: rows.count == page.limit, nextPage: Page(offset: page.offset + rows.count, limit: page.limit))
        case .playlist:
            guard page.offset == 0 else { return SearchPage() }
            let folded = SearchKey.fold(query)
            let rows = try await store.playlists().filter { SearchKey.fold($0.name).contains(folded) }
            return SearchPage(playlists: rows.map(playlist), total: rows.count)
        case .user:
            return SearchPage()
        }
    }

    public func searchSuggestions(_ prefix: String) async throws -> [String] {
        let text = prefix.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        return try await store.suggestions(text, limit: 8)
    }

    public let artistSongOrders: [ArtistSongOrder] = [.hot, .time]

    public func songs(ids: [String]) async throws -> [Track] {
        try await store.tracks(ids: ids).map(track)
    }

    public func album(id: String) async throws -> AlbumDetail {
        guard let row = try await store.album(id) else { throw LocalLibraryError.notFound }
        var album = album(row)
        if !row.genres.isEmpty { album.description = row.genres.joined(separator: " · ") }
        return AlbumDetail(album: album, tracks: try await store.albumTracks(id).map(track))
    }

    public func artist(id: String) async throws -> ArtistDetail {
        guard let row = try await store.artist(id) else { throw LocalLibraryError.notFound }
        let top = try await store.artistTracks(id, byPlays: true, offset: 0, limit: 50)
        return ArtistDetail(artist: artist(row), topTracks: top.map(track))
    }

    public func artistSongs(id: String, order: ArtistSongOrder, page: Page) async throws -> [Track] {
        try await store.artistTracks(id, byPlays: order == .hot, offset: page.offset, limit: page.limit).map(track)
    }

    public func artistAlbums(id: String, page: Page) async throws -> [Album] {
        try await store.artistAlbums(id, offset: page.offset, limit: page.limit).map(album)
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        guard let row = try await store.playlists().first(where: { $0.id == id }) else { throw LocalLibraryError.notFound }
        let tracks = try await store.tracks(ids: store.playlistTrackIDs(id)).map(track)
        return PlaylistDetail(playlist: playlist(row), tracks: tracks)
    }

    public func allMedia(page: Page) async throws -> TrackPage {
        let rows = try await store.tracks(order: .shelf, offset: page.offset, limit: page.limit)
        let total = try await store.trackCount()
        return TrackPage(tracks: rows.map(track), total: total, hasMore: page.offset + rows.count < total)
    }

    public func homeShelves() async throws -> [HomeShelf] {
        let recent = try await store.albums(order: .recentlyAdded, offset: 0, limit: 12)
        let played = try await store.tracks(order: .mostPlayed, offset: 0, limit: 12)
        let random = try await store.tracks(order: .random, offset: 0, limit: 12)
        let artists = try await store.artists(order: .trackCount, offset: 0, limit: 12)
        return [
            HomeShelf(id: "local.recent", title: "最近添加", items: .albums(recent.map(album))),
            HomeShelf(id: "local.played", title: "最常播放", items: .songs(played.map(track))),
            HomeShelf(id: "local.random", title: "随便听听", items: .songs(random.map(track))),
            HomeShelf(id: "local.artists", title: "歌手", items: .artists(artists.map(artist))),
        ].filter { !$0.items.isEmpty }
    }

    public func likedTrackIDs() async throws -> [String] {
        try await store.likedIDs()
    }

    public func setLiked(_ track: TrackRef, liked: Bool) async throws {
        try await store.setLiked(track.id, liked)
    }

    public func userPlaylists() async throws -> [Playlist] {
        try await store.playlists().map(playlist)
    }

    public var playlistEditing: PlaylistEditing {
        var editing = PlaylistEditing()
        editing.canCreate = true
        editing.canEdit = true
        editing.canDelete = true
        editing.canAdd = true
        editing.canRemove = true
        editing.canReorder = true
        editing.keepsDescription = true
        editing.nameLimit = 100
        return editing
    }

    public func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        let id = try await store.createPlaylist(name: draft.name, description: draft.description)
        guard let row = try await store.playlists().first(where: { $0.id == id }) else { throw LocalLibraryError.notFound }
        return playlist(row)
    }

    public func editPlaylist(_ id: String, changes: PlaylistChanges) async throws {
        try await store.editPlaylist(id, name: changes.name, description: changes.description)
    }

    public func deletePlaylist(_ id: String) async throws {
        try await store.deletePlaylist(id)
    }

    public func addTracks(_ trackIDs: [String], toPlaylist id: String) async throws -> Int {
        try await store.addToPlaylist(id, trackIDs: trackIDs)
    }

    public func removeTracks(_ trackIDs: [String], fromPlaylist id: String) async throws {
        try await store.removeFromPlaylist(id, trackIDs: trackIDs)
    }

    public func reorderPlaylist(_ id: String, trackIDs: [String]) async throws {
        try await store.reorderPlaylist(id, trackIDs: trackIDs)
    }

    public func lyrics(for track: TrackRef) async throws -> RawLyrics? {
        guard let row = try await store.tracks(ids: [track.id]).first else { return nil }
        return await LocalLyrics.find(for: URL(fileURLWithPath: row.path), providerName: displayName)
    }

    public func lyrics(matching query: LyricQuery) async throws -> RawLyrics? { nil }

    public func reportPlayback(_ report: PlaybackReport) async {
        try? await store.recordPlay(report.track.id, at: report.endedAt)
    }

    public let librarySections: [LibrarySection] = [.albums, .artists, .genres, .folders]
    public let albumSorts: [LibraryAlbumSort] = [.title, .artist, .year, .recentlyAdded]

    public func libraryAlbums(sort: LibraryAlbumSort, genre: String?, page: Page) async throws -> LibraryPage<Album> {
        let order: LibraryStore.AlbumOrder = switch sort {
        case .title: .title
        case .artist: .artist
        case .year: .year
        case .recentlyAdded: .recentlyAdded
        }
        let rows = try await store.albums(order: order, genre: genre, offset: page.offset, limit: page.limit)
        let total = genre == nil ? try await store.albumCount() : nil
        return LibraryPage(items: rows.map(album), total: total, hasMore: rows.count == page.limit)
    }

    public func libraryArtists(page: Page) async throws -> LibraryPage<Artist> {
        let rows = try await store.artists(order: .name, offset: page.offset, limit: page.limit)
        return LibraryPage(items: rows.map(artist), total: try await store.artistCount(), hasMore: rows.count == page.limit)
    }

    public func libraryGenres() async throws -> [LibraryGenre] {
        var genres: [LibraryGenre] = []
        for (name, count) in try await store.genres() {
            let cover = try await store.albums(order: .recentlyAdded, genre: name, offset: 0, limit: 1).first?.coverID
            genres.append(LibraryGenre(name: name, albumCount: count, artwork: cover.map { artwork($0, seed: name) }))
        }
        return genres
    }

    public func libraryFolder(_ path: String?) async throws -> LibraryFolderPage {
        let roots = try await store.roots()
        guard let path, let (root, relative) = Self.folderPath(path, in: roots) else {
            let entries = roots.map { LibraryFolderPage.Entry(path: "\($0.id):", name: ($0.path as NSString).lastPathComponent, songCount: $0.trackCount, isOffline: $0.isOffline) }
            return LibraryFolderPage(path: nil, title: "文件夹", folders: entries, songCount: entries.reduce(0) { $0 + $1.songCount })
        }
        let folders = try await store.subfolders(root: root.id, relativePath: relative).map { name, count in
            LibraryFolderPage.Entry(path: "\(root.id):" + (relative.isEmpty ? name : relative + "/" + name), name: name, songCount: count, isOffline: root.isOffline)
        }
        let tracks = try await store.folderTracks(root: root.id, relativePath: relative, below: false).map(track)
        let rootName = (root.path as NSString).lastPathComponent
        var trail = [LibraryFolderPage.Entry(path: "\(root.id):", name: rootName, songCount: root.trackCount)]
        let parts = relative.split(separator: "/").map(String.init)
        for depth in parts.indices.dropLast() {
            trail.append(LibraryFolderPage.Entry(path: "\(root.id):" + parts[...depth].joined(separator: "/"), name: parts[depth], songCount: 0))
        }
        if relative.isEmpty { trail = [] }
        let songCount = relative.isEmpty ? root.trackCount : tracks.count + folders.reduce(0) { $0 + $1.songCount }
        return LibraryFolderPage(path: path, title: parts.last ?? rootName, trail: trail, folders: folders, tracks: tracks, songCount: songCount,
                                 location: URL(fileURLWithPath: relative.isEmpty ? root.path : root.path + "/" + relative, isDirectory: true))
    }

    public func libraryFolderSongs(_ path: String) async throws -> [Track] {
        guard let (root, relative) = Self.folderPath(path, in: try await store.roots()) else { return [] }
        return try await store.folderTracks(root: root.id, relativePath: relative, below: true).map(track)
    }

    private static func folderPath(_ path: String, in roots: [LibraryFolder]) -> (LibraryFolder, String)? {
        guard let colon = path.firstIndex(of: ":"), let id = Int64(path[..<colon]), let root = roots.first(where: { $0.id == id }) else { return nil }
        return (root, String(path[path.index(after: colon)...]))
    }

    public let settingsSymbol = "internaldrive"
    public let settingsSummary = "文件夹、整理规则"

    static let splitAmpersand = SourceSetting("splitAmpersand", "按 & 拆分歌手", detail: "把「A & B」当作两位歌手；乐队名里的 & 会被拆开", keywords: "分隔符 合唱 艺人", control: .toggle(default: false))
    static let exceptions = SourceSetting("artistExceptions", "不拆分的歌手", detail: "这些名字整体算一位歌手，用分号隔开", keywords: "分隔符 例外 AC/DC", control: .text(placeholder: "Simon & Garfunkel; AC/DC"))
    static let repairEncoding = SourceSetting("repairEncoding", "修复乱码标签", detail: "旧文件里按 GBK、Big5 等编码写的标签，按文件夹重新识别", keywords: "乱码 编码 GBK 繁体 日文", control: .toggle(default: true))
    static let folderAlbum = SourceSetting("folderAlbum", "用文件夹名作专辑", detail: "没有专辑信息的歌，归入以所在文件夹命名的专辑", keywords: "专辑 分组 未知专辑", control: .toggle(default: false))
    static let watch = SourceSetting("watchFolders", "自动发现变化", detail: "文件夹里的歌有增删改时，随即更新曲库", keywords: "监听 扫描 刷新", control: .toggle(default: true))

    public var settingsSections: [SourceSettingsSection] {
        [
            SourceSettingsSection("organize", title: "整理", footer: "改动只重新整理已读到的信息，不会重新读取文件。", settings: [Self.splitAmpersand, Self.exceptions, Self.folderAlbum, Self.repairEncoding]),
            SourceSettingsSection("scan", title: "扫描", settings: [Self.watch]),
        ]
    }

    public func applySettings(_ values: SourceSettingValues) async {
        await engine.apply(rules: Self.rules(from: values), watches: Self.watches(values))
    }

    static func rules(from values: SourceSettingValues) -> LibraryRules {
        let exceptions = values.string(Self.exceptions).split(whereSeparator: { $0 == ";" || $0 == "；" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return LibraryRules(artists: ArtistNames(splitsAmpersand: values.bool(Self.splitAmpersand), exceptions: exceptions),
                            repairsEncoding: values.bool(Self.repairEncoding), folderNamesAlbums: values.bool(Self.folderAlbum))
    }

    static func watches(_ values: SourceSettingValues) -> Bool { values.bool(Self.watch) }
}
