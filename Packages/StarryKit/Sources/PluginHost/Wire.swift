import Foundation
import LyricsProviders
import MusicSources
import StarryCore

// The JSON a plugin returns and is given. Decoding is lenient where scripts often differ (ids as
// numbers, artwork as a bare URL, dates as numbers or strings) and strict where a wrong value
// would mislead (a track without a title).

extension KeyedDecodingContainer {
    func decodeLenientString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let integer = try? decode(Int64.self, forKey: key) { return String(integer) }
        if let number = try? decode(Double.self, forKey: key), number.isFinite { return String(number) }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "\(key.stringValue) 应为字符串"))
    }

    func decodeLenientStringIfPresent(forKey key: Key) -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        return try? decodeLenientString(forKey: key)
    }

    /// Milliseconds since 1970, or an ISO 8601 date or date-time.
    func decodeDateIfPresent(forKey key: Key) -> Date? {
        if let number = try? decode(Double.self, forKey: key), number.isFinite { return Date(timeIntervalSince1970: number / 1000) }
        guard let text = try? decode(String.self, forKey: key) else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) { return date }
        return nil
    }

    func decodeArtworkIfPresent(forKey key: Key) -> WireArtwork? {
        try? decodeIfPresent(WireArtwork.self, forKey: key)
    }
}

struct WireArtwork: Codable {
    var url: String?
    var sizedTemplate: String?
    var sizeSteps: [Int]?

    private enum CodingKeys: String, CodingKey { case url, sizedTemplate, sizeSteps }

    init(_ artwork: Artwork) {
        url = artwork.url?.absoluteString
        sizedTemplate = artwork.sizedTemplate
        sizeSteps = artwork.sizeSteps
    }

    init(from decoder: any Decoder) throws {
        if let url = try? decoder.singleValueContainer().decode(String.self) {
            self.url = url
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        sizedTemplate = try container.decodeIfPresent(String.self, forKey: .sizedTemplate)
        sizeSteps = try container.decodeIfPresent([Int].self, forKey: .sizeSteps)
    }

    func artwork(seed: String) -> Artwork? {
        guard let url = url.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return Artwork(url: url, seed: seed, sizedTemplate: sizedTemplate, sizeSteps: sizeSteps?.sorted())
    }
}

struct WireArtistRef: Codable {
    var id: String
    var name: String

    private enum CodingKeys: String, CodingKey { case id, name }

    init(_ ref: ArtistRef) {
        id = ref.id
        name = ref.name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLenientStringIfPresent(forKey: .id) ?? ""
        name = try container.decode(String.self, forKey: .name)
    }

    var ref: ArtistRef { ArtistRef(id: id, name: name) }
}

struct WireAlbumRef: Codable {
    var id: String
    var name: String
    var artwork: WireArtwork?

    private enum CodingKeys: String, CodingKey { case id, name, artwork }

    init(_ ref: AlbumRef) {
        id = ref.id
        name = ref.name
        artwork = ref.artwork.map(WireArtwork.init)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLenientStringIfPresent(forKey: .id) ?? ""
        name = try container.decode(String.self, forKey: .name)
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
    }

    func ref(source: SourceID) -> AlbumRef {
        AlbumRef(id: id, name: name, artwork: artwork?.artwork(seed: "\(source.key):album:\(id)"))
    }
}

struct WireTrack: Codable {
    var id: String
    var title: String
    var alias: String?
    var artists: [WireArtistRef]
    var album: WireAlbumRef?
    var duration: TimeInterval
    var artwork: WireArtwork?
    var tiers: [String]
    var fee: String?
    var popularity: Double?
    var discNumber: Int?
    var trackNumber: Int?
    var hasVideo: Bool?
    var ttml: [WireTTMLKey]?

    private enum CodingKeys: String, CodingKey {
        case id, title, alias, artists, album, duration, artwork, tiers, fee, popularity, discNumber, trackNumber, hasVideo, ttml
    }

    init(_ track: Track) {
        id = track.id.id
        title = track.title
        alias = track.alias
        artists = track.artists.map(WireArtistRef.init)
        album = track.album.map(WireAlbumRef.init)
        duration = track.duration
        artwork = track.artwork.map(WireArtwork.init)
        tiers = track.availableTiers
        fee = switch track.fee {
        case .free: "free"
        case .vip: "vip"
        case .purchase: "purchase"
        case .freeLowQuality: "freeLowQuality"
        }
        popularity = track.popularity
        discNumber = track.discNumber
        trackNumber = track.trackNumber
        hasVideo = track.hasVideo
        ttml = track.ttml?.map(WireTTMLKey.init)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        artists = try container.decodeIfPresent([WireArtistRef].self, forKey: .artists) ?? []
        album = try container.decodeIfPresent(WireAlbumRef.self, forKey: .album)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
        tiers = try container.decodeIfPresent([String].self, forKey: .tiers) ?? []
        fee = try container.decodeIfPresent(String.self, forKey: .fee)
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo)
        // A malformed entry is dropped (`WireTTMLKey.key`), not the song.
        ttml = try? container.decodeIfPresent([WireTTMLKey].self, forKey: .ttml)
    }

    func track(source: SourceID) -> Track {
        let album = album?.ref(source: source)
        let fee: TrackFee = switch self.fee {
        case "vip": .vip
        case "purchase": .purchase
        case "freeLowQuality": .freeLowQuality
        default: .free
        }
        return Track(
            id: TrackRef(source: source, id: id),
            title: title,
            alias: alias,
            artists: artists.map(\.ref),
            album: album,
            duration: max(0, duration),
            artwork: artwork?.artwork(seed: "\(source.key):\(id)") ?? album?.artwork,
            availableTiers: tiers,
            fee: fee,
            hasVideo: hasVideo ?? false,
            popularity: popularity.map { min(max($0, 0), 1) },
            discNumber: discNumber,
            trackNumber: trackNumber,
            ttml: ttml.map { $0.compactMap(\.key) }.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// `Track.ttml`: an AMLL TTML DB folder and an id in it (a number is taken as its digits).
struct WireTTMLKey: Codable {
    var folder: String?
    var id: String?

    private enum CodingKeys: String, CodingKey { case folder, id }

    init(_ key: TTMLKey) {
        folder = key.folder
        id = key.id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = (try? container.decodeIfPresent(String.self, forKey: .folder))?.trimmingCharacters(in: .whitespaces)
        id = container.decodeLenientStringIfPresent(forKey: .id)?.trimmingCharacters(in: .whitespaces)
    }

    /// nil when the folder or the id is missing or blank.
    var key: TTMLKey? {
        guard let folder, !folder.isEmpty, let id, !id.isEmpty else { return nil }
        return TTMLKey(folder: folder, id: id)
    }
}

struct WireArtist: Decodable {
    var id: String
    var name: String
    var artwork: WireArtwork?
    var albumCount: Int?
    var songCount: Int?
    var description: String?
    var alias: String?
    var followerCount: Int?

    private enum CodingKeys: String, CodingKey { case id, name, artwork, albumCount, songCount, description, alias, followerCount }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
        albumCount = try container.decodeIfPresent(Int.self, forKey: .albumCount)
        songCount = try container.decodeIfPresent(Int.self, forKey: .songCount)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
    }

    func artist(source: SourceID) -> Artist {
        Artist(id: id, source: source, name: name, artwork: artwork?.artwork(seed: "\(source.key):artist:\(id)"), albumCount: albumCount ?? 0,
               songCount: songCount ?? 0, description: description, alias: alias, followerCount: followerCount)
    }
}

struct WireAlbum: Decodable {
    var id: String
    var name: String
    var artists: [WireArtistRef]
    var artwork: WireArtwork?
    var releaseDate: Date?
    var trackCount: Int?
    var description: String?
    var alias: String?
    var releaseType: String?
    var edition: String?
    var company: String?

    private enum CodingKeys: String, CodingKey { case id, name, artists, artwork, releaseDate, trackCount, description, alias, releaseType, edition, company }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artists = try container.decodeIfPresent([WireArtistRef].self, forKey: .artists) ?? []
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
        releaseDate = container.decodeDateIfPresent(forKey: .releaseDate)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        releaseType = try container.decodeIfPresent(String.self, forKey: .releaseType)
        edition = try container.decodeIfPresent(String.self, forKey: .edition)
        company = try container.decodeIfPresent(String.self, forKey: .company)
    }

    func album(source: SourceID) -> Album {
        Album(id: id, source: source, name: name, artists: artists.map(\.ref), artwork: artwork?.artwork(seed: "\(source.key):album:\(id)"), releaseDate: releaseDate,
              trackCount: trackCount ?? 0, description: description, alias: alias, releaseType: releaseType, edition: edition, company: company)
    }
}

struct WirePlaylist: Decodable {
    var id: String
    var name: String
    var artwork: WireArtwork?
    var creatorID: String?
    var creatorName: String?
    var creatorAvatar: WireArtwork?
    var createdAt: Date?
    var updatedAt: Date?
    var trackCount: Int?
    var playCount: Int?
    var tags: [String]?
    var description: String?
    var isOwned: Bool?
    var isPrivate: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, artwork, creatorID, creatorName, creatorAvatar, createdAt, updatedAt, trackCount, playCount, tags, description, isOwned, isPrivate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
        creatorID = container.decodeLenientStringIfPresent(forKey: .creatorID)
        creatorName = try container.decodeIfPresent(String.self, forKey: .creatorName)
        creatorAvatar = container.decodeArtworkIfPresent(forKey: .creatorAvatar)
        createdAt = container.decodeDateIfPresent(forKey: .createdAt)
        updatedAt = container.decodeDateIfPresent(forKey: .updatedAt)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isOwned = try container.decodeIfPresent(Bool.self, forKey: .isOwned)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
    }

    func playlist(source: SourceID) -> Playlist {
        Playlist(id: id, source: source, name: name, artwork: artwork?.artwork(seed: "\(source.key):playlist:\(id)"), creatorID: creatorID, creatorName: creatorName,
                 creatorAvatar: creatorAvatar?.artwork(seed: "\(source.key):user:\(creatorID ?? id)"), createdAt: createdAt, updatedAt: updatedAt,
                 trackCount: trackCount ?? 0, playCount: playCount ?? 0, tags: tags ?? [], description: description, isOwned: isOwned ?? false,
                 isPrivate: isPrivate)
    }
}

struct WirePlaylistDraft: Encodable, Sendable {
    var name: String?
    var description: String?
    var isPrivate: Bool?

    init(_ draft: PlaylistDraft) {
        name = draft.name
        description = draft.description
        isPrivate = draft.isPrivate
    }

    init(_ changes: PlaylistChanges) {
        name = changes.name
        description = changes.description
        isPrivate = changes.isPrivate
    }
}

struct WirePage: Encodable {
    var offset: Int
    var limit: Int

    init(_ page: Page) {
        offset = page.offset
        limit = page.limit
    }
}

struct WireSearchPage: Decodable {
    var songs: [WireTrack]?
    var albums: [WireAlbum]?
    var artists: [WireArtist]?
    var playlists: [WirePlaylist]?
    var users: [WireUser]?
    var hasMore: Bool?
    var nextOffset: Int?
    var total: Int?

    func page(source: SourceID, requested: Page) -> SearchPage {
        var page = SearchPage(
            songs: (songs ?? []).map { $0.track(source: source) },
            albums: (albums ?? []).map { $0.album(source: source) },
            artists: (artists ?? []).map { $0.artist(source: source) },
            playlists: (playlists ?? []).map { $0.playlist(source: source) },
            users: (users ?? []).map { $0.user(source: source) },
            total: total
        )
        let more = hasMore ?? (nextOffset != nil)
        page.hasMore = more && page.count > 0
        if page.hasMore { page.nextPage = Page(offset: nextOffset ?? requested.offset + page.count, limit: requested.limit) }
        return page
    }
}

struct WireSearchOverview: Decodable {
    struct TopResult: Decodable {
        var song: WireTrack?
        var artist: WireArtist?
        var album: WireAlbum?
        var playlist: WirePlaylist?

        func result(source: SourceID) -> SearchOverview.TopResult? {
            if let song { return .song(song.track(source: source)) }
            if let artist { return .artist(artist.artist(source: source)) }
            if let album { return .album(album.album(source: source)) }
            return playlist.map { .playlist($0.playlist(source: source)) }
        }
    }

    var topResult: TopResult?
    var songs: [WireTrack]?
    var artists: [WireArtist]?
    var albums: [WireAlbum]?
    var playlists: [WirePlaylist]?

    func overview(source: SourceID, query: String) -> SearchOverview {
        var overview = SearchOverview(
            topResult: topResult?.result(source: source),
            songs: (songs ?? []).map { $0.track(source: source) },
            artists: (artists ?? []).map { $0.artist(source: source) },
            albums: (albums ?? []).map { $0.album(source: source) },
            playlists: (playlists ?? []).map { $0.playlist(source: source) }
        )
        if overview.topResult == nil { overview.topResult = SearchOverview.guessTopResult(for: query, in: overview) }
        return overview
    }
}

struct WireAlbumDetail: Decodable {
    var album: WireAlbum
    var tracks: [WireTrack]?
    var subscribedCount: Int?
    var commentCount: Int?
    var isSubscribed: Bool?

    func detail(source: SourceID) -> AlbumDetail {
        AlbumDetail(album: album.album(source: source), tracks: (tracks ?? []).map { $0.track(source: source) }, subscribedCount: subscribedCount,
                    commentCount: commentCount, isSubscribed: isSubscribed)
    }
}

struct WireArtistDetail: Decodable {
    struct Section: Decodable {
        var title: String
        var text: String
    }

    var artist: WireArtist
    var topTracks: [WireTrack]?
    var photo: WireArtwork?
    var videoCount: Int?
    var isFollowed: Bool?
    var introduction: [Section]?

    func detail(source: SourceID) -> ArtistDetail {
        ArtistDetail(artist: artist.artist(source: source), topTracks: (topTracks ?? []).map { $0.track(source: source) },
                     photo: photo?.artwork(seed: "\(source.key):artist-photo:\(artist.id)"), videoCount: videoCount, isFollowed: isFollowed,
                     introduction: (introduction ?? []).map { ArtistDetail.Section(title: $0.title, text: $0.text) })
    }
}

struct WirePlaylistDetail: Decodable {
    var playlist: WirePlaylist
    var tracks: [WireTrack]?
    var pendingTrackIDs: [String]?
    var subscribedCount: Int?
    var commentCount: Int?
    var isSubscribed: Bool?

    func detail(source: SourceID) -> PlaylistDetail {
        PlaylistDetail(playlist: playlist.playlist(source: source), tracks: (tracks ?? []).map { $0.track(source: source) },
                       pendingTrackIDs: pendingTrackIDs ?? [], subscribedCount: subscribedCount, commentCount: commentCount, isSubscribed: isSubscribed)
    }
}

struct WireTier: Codable {
    var id: String
    var name: String
    var detail: String?
    var level: String
    var spatial: Bool?
    var badge: String?

    init(_ tier: QualityTier) {
        id = tier.id
        name = tier.name
        detail = tier.detail
        level = tier.level.rawValue
        spatial = tier.isSpatial
        badge = tier.badge
    }

    var tier: QualityTier? {
        guard let level = AudioQuality(rawValue: level) else { return nil }
        return QualityTier(id: id, name: name, detail: detail, level: level, isSpatial: spatial ?? false, badge: badge)
    }
}

struct WireAsset: Decodable {
    struct Info: Decodable {
        var bitrate: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var channels: Int?
        var fileSize: Int64?
    }

    /// Volume normalization: dB to -18 LUFS for the song and its album (ReplayGain 2.0), peaks when known.
    struct Gain: Decodable {
        var trackGain: Double?
        var trackPeak: Double?
        var albumGain: Double?
        var albumPeak: Double?

        var replayGain: ReplayGain? {
            ReplayGain(trackGain: trackGain, trackPeak: trackPeak, albumGain: albumGain, albumPeak: albumPeak).nonEmpty
        }
    }

    var url: String
    var headers: [String: String]?
    var container: String?
    var tier: String?
    var expiresIn: TimeInterval?
    var trial: Bool?
    var info: Info?
    var supportsOverlap: Bool?
    var decrypt: JSONValue?
    /// The server makes the file while sending it: no length, no ranges.
    var transcoded: Bool?
    var gain: Gain?

    func asset(requested: QualityTier, tiers: [QualityTier], pluginID: String, decryption: (JSONValue) throws -> StreamDecryption) throws -> PlayableAsset {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SourceError.invalidResponse("播放地址不是 http(s)：\(self.url)")
        }
        let tier = tier.flatMap { id in tiers.first { $0.id == id } } ?? requested
        let container = container.flatMap { AudioContainer(rawValue: $0.lowercased()) } ?? Self.container(guessedFrom: url)
        return PlayableAsset(
            url: url,
            headers: headers ?? [:],
            container: container,
            tier: tier,
            expiresAt: Date().addingTimeInterval(max(expiresIn ?? 1200, 30)),
            isTrial: trial ?? false,
            supportsTap: container != .hls && !tier.isSpatial,
            supportsOverlap: supportsOverlap ?? true,
            provider: trial == true ? .trial : .source,
            pluginID: pluginID,
            info: info.map { AudioStreamInfo(bitrate: $0.bitrate, sampleRate: $0.sampleRate, bitDepth: $0.bitDepth, channels: $0.channels, fileSize: $0.fileSize) },
            decryption: try decrypt.map(decryption),
            isTranscode: transcoded ?? false,
            gain: gain?.replayGain
        )
    }

    static func container(guessedFrom url: URL) -> AudioContainer {
        switch url.pathExtension.lowercased() {
        case "flac": .flac
        case "m4a", "aac": .aac
        case "mp4": .mp4
        case "wav": .wav
        case "ogg", "oga", "opus": .ogg
        case "ape": .ape
        case "m3u8": .hls
        default: .mp3
        }
    }
}

struct WireTrend: Decodable {
    var query: String
    var badge: String?

    init(from decoder: any Decoder) throws {
        if let query = try? decoder.singleValueContainer().decode(String.self) {
            self.query = query
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        badge = try container.decodeIfPresent(String.self, forKey: .badge)
    }

    private enum CodingKeys: String, CodingKey { case query, badge }

    var trend: SearchTrend { SearchTrend(query: query, badge: badge.flatMap(SearchTrend.Badge.init(rawValue:))) }
}

struct WireHint: Decodable {
    var display: String
    var query: String

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            display = text
            query = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        display = try container.decodeIfPresent(String.self, forKey: .display) ?? query
    }

    private enum CodingKeys: String, CodingKey { case display, query }

    var hint: SearchHint { SearchHint(display: display, query: query) }
}

struct WireSettingsSection: Decodable {
    struct Setting: Decodable {
        struct Choice: Decodable {
            var value: String
            var title: String
        }

        var key: String
        var title: String
        var detail: String?
        var keywords: String?
        var advanced: Bool?
        var type: String
        var `default`: SourceSettingValues.Value?
        var placeholder: String?
        var secure: Bool?
        var choices: [Choice]?

        var setting: SourceSetting? {
            let control: SourceSetting.Control
            switch type {
            case "toggle":
                guard case .bool(let fallback)? = `default` ?? .bool(false) else { return nil }
                control = .toggle(default: fallback)
            case "text":
                guard case .string(let fallback)? = `default` ?? .string("") else { return nil }
                control = .text(placeholder: placeholder ?? "", default: fallback, secure: secure ?? false)
            case "choice":
                guard let choices, !choices.isEmpty else { return nil }
                let fallback = if case .string(let value)? = `default` { value } else { choices[0].value }
                control = .choice(choices.map { SourceSetting.Choice($0.value, $0.title) }, default: fallback)
            default:
                return nil
            }
            return SourceSetting(key, title, detail: detail, keywords: keywords ?? "", advanced: advanced ?? false, control: control)
        }
    }

    var id: String
    var title: String?
    var footer: String?
    var advanced: Bool?
    var settings: [Setting]

    var section: SourceSettingsSection {
        SourceSettingsSection(id, title: title, footer: footer, advanced: advanced ?? false, settings: settings.compactMap(\.setting))
    }
}

struct WireLyricsHit: Decodable {
    var id: String
    var mid: String?
    var title: String
    var artists: [String]
    var album: String?
    var duration: TimeInterval?

    private enum CodingKeys: String, CodingKey { case id, mid, title, artists, album, duration }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        mid = container.decodeLenientStringIfPresent(forKey: .mid)
        title = try container.decode(String.self, forKey: .title)
        if let list = try? container.decode([String].self, forKey: .artists) {
            artists = list
        } else {
            artists = (try container.decodeIfPresent(String.self, forKey: .artists)).map { [$0] } ?? []
        }
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
    }

    var hit: ExternalLyricsProvider.Hit {
        ExternalLyricsProvider.Hit(song: LyricsSongRef(id: id, mid: mid, title: title, duration: duration), title: title, artists: artists, album: album, duration: duration)
    }
}

struct WireLyricsSong: Encodable {
    var id: String
    var mid: String?
    var title: String?
    var duration: TimeInterval?

    init(_ song: LyricsSongRef) {
        id = song.id
        mid = song.mid
        title = song.title
        duration = song.duration
    }
}

struct WireLyrics: Decodable {
    var format: String
    var body: String
    var translation: String?
    var romanization: String?

    func raw(providerName: String) throws -> RawLyrics {
        guard let format = RawLyrics.Format(rawValue: format.lowercased()) else {
            throw SourceError.invalidResponse("不认识的歌词格式：\(format)")
        }
        return RawLyrics(format: format, body: body, translation: translation, romanization: romanization, providerName: providerName)
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    var isNull: Bool { self == .null }
}

struct WireProfile: Decodable {
    var userID: String
    var nickname: String
    var avatar: WireArtwork?
    var isVIP: Bool?
    var detail: String?

    private enum CodingKeys: String, CodingKey { case userID, nickname, avatar, isVIP, detail }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decodeLenientString(forKey: .userID)
        nickname = try container.decode(String.self, forKey: .nickname)
        avatar = container.decodeArtworkIfPresent(forKey: .avatar)
        isVIP = try container.decodeIfPresent(Bool.self, forKey: .isVIP)
        detail = try container.decodeIfPresent(String.self, forKey: .detail).flatMap { $0.isEmpty ? nil : $0 }
    }

    func profile(source: SourceID) -> AccountProfile {
        AccountProfile(userID: userID, nickname: nickname, avatar: avatar?.artwork(seed: "\(source.key):user:\(userID)"), isVIP: isVIP ?? false, detail: detail)
    }
}

struct WireHomeShelf: Decodable {
    var id: String?
    var title: String
    var songs: [WireTrack]?
    var albums: [WireAlbum]?
    var artists: [WireArtist]?
    var playlists: [WirePlaylist]?

    func shelf(source: SourceID, position: Int) -> HomeShelf? {
        let items: HomeShelf.Items
        if let songs {
            items = .songs(songs.map { $0.track(source: source) })
        } else if let albums {
            items = .albums(albums.map { $0.album(source: source) })
        } else if let artists {
            items = .artists(artists.map { $0.artist(source: source) })
        } else if let playlists {
            items = .playlists(playlists.map { $0.playlist(source: source) })
        } else {
            return nil
        }
        guard !items.isEmpty else { return nil }
        return HomeShelf(id: id ?? "\(position)", title: title, items: items)
    }
}

/// `source.allMedia`: the songs, or `{ songs, total?, hasMore?, nextOffset? }`. Without `hasMore`
/// another page follows when the total says so, else when the page came full.
struct WireTrackPage: Decodable {
    var songs: [WireTrack]
    var total: Int?
    var hasMore: Bool?
    var nextOffset: Int?

    private enum CodingKeys: String, CodingKey { case songs, total, hasMore, nextOffset }

    init(from decoder: any Decoder) throws {
        if let songs = try? decoder.singleValueContainer().decode([WireTrack].self) {
            self.songs = songs
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = try container.decodeIfPresent([WireTrack].self, forKey: .songs) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
    }

    func page(source: SourceID, asked: Page) -> TrackPage {
        let next = nextOffset ?? asked.offset + songs.count
        let more = hasMore ?? total.map { next < $0 } ?? (songs.count >= asked.limit)
        return TrackPage(tracks: songs.map { $0.track(source: source) }, total: total, hasMore: more, nextOffset: nextOffset)
    }
}

private func libraryHasMore(_ hasMore: Bool?, total: Int?, count: Int, asked: Page) -> Bool {
    hasMore ?? total.map { asked.offset + count < $0 } ?? (count >= asked.limit)
}

struct WireAlbumPage: Decodable {
    var albums: [WireAlbum]
    var total: Int?
    var hasMore: Bool?

    private enum CodingKeys: String, CodingKey { case albums, total, hasMore }

    init(from decoder: any Decoder) throws {
        if let albums = try? decoder.singleValueContainer().decode([WireAlbum].self) {
            self.albums = albums
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = try container.decodeIfPresent([WireAlbum].self, forKey: .albums) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    func page(source: SourceID, asked: Page) -> LibraryPage<Album> {
        LibraryPage(items: albums.map { $0.album(source: source) }, total: total, hasMore: libraryHasMore(hasMore, total: total, count: albums.count, asked: asked))
    }
}

struct WireArtistPage: Decodable {
    var artists: [WireArtist]
    var total: Int?
    var hasMore: Bool?

    private enum CodingKeys: String, CodingKey { case artists, total, hasMore }

    init(from decoder: any Decoder) throws {
        if let artists = try? decoder.singleValueContainer().decode([WireArtist].self) {
            self.artists = artists
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artists = try container.decodeIfPresent([WireArtist].self, forKey: .artists) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    func page(source: SourceID, asked: Page) -> LibraryPage<Artist> {
        LibraryPage(items: artists.map { $0.artist(source: source) }, total: total, hasMore: libraryHasMore(hasMore, total: total, count: artists.count, asked: asked))
    }
}

struct WireGenre: Decodable {
    var name: String
    var albumCount: Int?
    var artwork: WireArtwork?

    private enum CodingKeys: String, CodingKey { case name, albumCount, artwork }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        albumCount = try container.decodeIfPresent(Int.self, forKey: .albumCount)
        artwork = container.decodeArtworkIfPresent(forKey: .artwork)
    }

    func genre(source: SourceID) -> LibraryGenre {
        LibraryGenre(name: name, albumCount: albumCount ?? 0, artwork: artwork?.artwork(seed: "\(source.key):genre:\(name)"))
    }
}

/// `account.connect`: the server reached.
struct WireServerInfo: Decodable {
    var address: String
    var name: String?
    var version: String?
    var methods: [String]?

    var info: ServerInfo {
        ServerInfo(address: address, name: name.flatMap { $0.isEmpty ? nil : $0 }, version: version, methods: methods.map { $0.compactMap(LoginMethod.init(rawValue:)) })
    }
}

struct WireCodeSession: Decodable {
    var key: String
    var code: String

    private enum CodingKeys: String, CodingKey { case key, code }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeLenientString(forKey: .key)
        code = try container.decodeLenientString(forKey: .code)
    }
}

struct WireQRSession: Decodable {
    var key: String
    var url: String?
    var image: String?
    var kind: String?

    private enum CodingKeys: String, CodingKey { case key, url, image, kind }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeLenientString(forKey: .key)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }
}

struct WireQRPoll: Decodable {
    var status: String
    var profile: WireProfile?

    private enum CodingKeys: String, CodingKey { case status, profile }

    init(from decoder: any Decoder) throws {
        if let status = try? decoder.singleValueContainer().decode(String.self) {
            self.status = status
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        profile = try container.decodeIfPresent(WireProfile.self, forKey: .profile)
    }
}

struct WireQRSessionRef: Encodable {
    var key: String
    var kind: String?
}

struct WireCommentTarget: Encodable {
    var kind: String
    var id: String

    init(_ target: CommentTarget) {
        switch target {
        case .song(let id): (kind, self.id) = ("song", id)
        case .album(let id): (kind, self.id) = ("album", id)
        case .playlist(let id): (kind, self.id) = ("playlist", id)
        }
    }
}

struct WireComment: Decodable {
    struct Quote: Decodable {
        var commentID: String?
        var userID: String?
        var userName: String
        var content: String

        private enum CodingKeys: String, CodingKey { case commentID, userID, userName, content }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commentID = container.decodeLenientStringIfPresent(forKey: .commentID)
            userID = container.decodeLenientStringIfPresent(forKey: .userID)
            userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
            content = try container.decode(String.self, forKey: .content)
        }
    }

    var id: String
    var userID: String?
    var userName: String
    var avatar: WireArtwork?
    var content: String
    var time: Date?
    var likedCount: Int?
    var isLiked: Bool?
    var location: String?
    var replyTo: Quote?
    var replyCount: Int?

    private enum CodingKeys: String, CodingKey { case id, userID, userName, avatar, content, time, likedCount, isLiked, location, replyTo, replyCount }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        userID = container.decodeLenientStringIfPresent(forKey: .userID)
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
        avatar = container.decodeArtworkIfPresent(forKey: .avatar)
        content = try container.decode(String.self, forKey: .content)
        time = container.decodeDateIfPresent(forKey: .time)
        likedCount = try container.decodeIfPresent(Int.self, forKey: .likedCount)
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        replyTo = try container.decodeIfPresent(Quote.self, forKey: .replyTo)
        replyCount = try container.decodeIfPresent(Int.self, forKey: .replyCount)
    }

    func comment(source: SourceID) -> Comment {
        Comment(id: id, userID: userID, userName: userName, avatar: avatar?.artwork(seed: "\(source.key):user:\(userID ?? id)"), content: content,
                time: time ?? Date(timeIntervalSince1970: 0), likedCount: likedCount ?? 0, isLiked: isLiked ?? false, location: location,
                replyTo: replyTo.map { Comment.Quote(commentID: $0.commentID, userID: $0.userID, userName: $0.userName, content: $0.content) },
                replyCount: replyCount ?? 0)
    }
}

struct WireCommentPage: Decodable {
    var hot: [WireComment]?
    var latest: [WireComment]?
    var total: Int?
    var hasMore: Bool?

    func page(source: SourceID) -> CommentPage {
        CommentPage(hot: (hot ?? []).map { $0.comment(source: source) }, latest: (latest ?? []).map { $0.comment(source: source) }, total: total ?? 0, hasMore: hasMore ?? false)
    }
}

struct WireCommentSlice: Decodable {
    var comments: [WireComment]?
    var total: Int?
    var next: String?

    func slice(source: SourceID) -> CommentSlice {
        CommentSlice(comments: (comments ?? []).map { $0.comment(source: source) }, total: total ?? 0, next: next)
    }
}

struct WireUser: Decodable {
    var id: String
    var nickname: String
    var avatar: WireArtwork?
    var signature: String?
    var level: Int?
    var maxLevel: Int?
    var isVIP: Bool?
    var identity: String?
    var gender: String?
    var details: [String]?
    var followCount: Int?
    var followerCount: Int?
    var eventCount: Int?
    var listenedSongCount: Int?
    var createdPlaylistCount: Int?
    var isFollowed: Bool?
    var followsYou: Bool?
    var isRankingPublic: Bool?
    var areFollowsPublic: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, nickname, avatar, signature, level, maxLevel, isVIP, identity, gender, details, followCount, followerCount, eventCount
        case listenedSongCount, createdPlaylistCount, isFollowed, followsYou, isRankingPublic, areFollowsPublic
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLenientString(forKey: .id)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = container.decodeArtworkIfPresent(forKey: .avatar)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        maxLevel = try container.decodeIfPresent(Int.self, forKey: .maxLevel)
        isVIP = try container.decodeIfPresent(Bool.self, forKey: .isVIP)
        identity = try container.decodeIfPresent(String.self, forKey: .identity)
        gender = try container.decodeIfPresent(String.self, forKey: .gender)
        details = try container.decodeIfPresent([String].self, forKey: .details)
        followCount = try container.decodeIfPresent(Int.self, forKey: .followCount)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        listenedSongCount = try container.decodeIfPresent(Int.self, forKey: .listenedSongCount)
        createdPlaylistCount = try container.decodeIfPresent(Int.self, forKey: .createdPlaylistCount)
        isFollowed = try container.decodeIfPresent(Bool.self, forKey: .isFollowed)
        followsYou = try container.decodeIfPresent(Bool.self, forKey: .followsYou)
        isRankingPublic = try container.decodeIfPresent(Bool.self, forKey: .isRankingPublic)
        areFollowsPublic = try container.decodeIfPresent(Bool.self, forKey: .areFollowsPublic)
    }

    func user(source: SourceID) -> UserProfile {
        UserProfile(
            id: id, source: source, nickname: nickname, avatar: avatar?.artwork(seed: "\(source.key):user:\(id)"), signature: signature, level: level,
            maxLevel: maxLevel, isVIP: isVIP ?? false, identity: identity, gender: gender.flatMap(UserProfile.Gender.init(rawValue:)),
            details: (details ?? []).filter { !$0.isEmpty }, followCount: followCount, followerCount: followerCount, eventCount: eventCount, listenedSongCount: listenedSongCount,
            createdPlaylistCount: createdPlaylistCount, isFollowed: isFollowed, followsYou: followsYou ?? false,
            isRankingPublic: isRankingPublic ?? true, areFollowsPublic: areFollowsPublic ?? true
        )
    }
}

struct WireUserPlaylists: Decodable {
    var created: [WirePlaylist]?
    var subscribed: [WirePlaylist]?

    func playlists(source: SourceID) -> UserPlaylists {
        UserPlaylists(created: (created ?? []).map { $0.playlist(source: source) }, subscribed: (subscribed ?? []).map { $0.playlist(source: source) })
    }
}

struct WireUserPage: Decodable {
    var users: [WireUser]?
    var total: Int?
    var nextOffset: Int?

    func page(source: SourceID, requested: Page) -> UserPage {
        let users = (users ?? []).map { $0.user(source: source) }
        return UserPage(users: users, total: total, nextPage: nextOffset.map { Page(offset: $0, limit: requested.limit) })
    }
}

struct WireRankedTrack: Decodable {
    var track: WireTrack
    var score: Double?
    var playCount: Int?

    func ranked(source: SourceID) -> RankedTrack {
        RankedTrack(track: track.track(source: source), score: Int(min(max(score ?? 0, 0), 100).rounded()), playCount: playCount)
    }
}

/// `source.reportPlayback`: a play that ended; times in milliseconds since 1970.
struct WirePlaybackReport: Encodable {
    struct Context: Encodable {
        var type: String
        var id: String?
        var name: String?
    }

    var trackID: String
    var context: Context?
    var playedSeconds: Double
    var duration: Double
    var startedAt: Double
    var endedAt: Double

    init(_ report: PlaybackReport) {
        trackID = report.track.id
        context = report.context.map { Context(type: $0.originType.rawValue, id: $0.originID, name: $0.originName) }
        playedSeconds = report.playedSeconds
        duration = report.duration
        startedAt = (report.startedAt.timeIntervalSince1970 * 1000).rounded()
        endedAt = (report.endedAt.timeIntervalSince1970 * 1000).rounded()
    }
}
