import Foundation

public struct Artwork: Hashable, Sendable, Codable {
    public var url: URL?
    public var seed: String
    /// How to ask the image's host for a smaller copy, from the source that made the artwork:
    /// the address with `{width}` and `{height}` where the pixel size goes. nil when the host
    /// only serves `url`.
    public var sizedTemplate: String?
    /// The only sides the host makes (e.g. 150, 300, 500…), smallest first; a request is
    /// rounded up to the next one (the largest when it is bigger). nil when any size goes.
    public var sizeSteps: [Int]?

    public init(url: URL? = nil, seed: String, sizedTemplate: String? = nil, sizeSteps: [Int]? = nil) {
        self.url = url
        self.seed = seed
        self.sizedTemplate = sizedTemplate
        self.sizeSteps = sizeSteps
    }

    public func sized(_ side: Int) -> URL? { sized(width: side, height: side) }

    public func sized(width: Int, height: Int) -> URL? {
        guard let url else { return nil }
        guard let sizedTemplate else { return url }
        var width = width
        var height = height
        if let sizeSteps, let largest = sizeSteps.last {
            let side = sizeSteps.first { $0 >= max(width, height) } ?? largest
            width = side
            height = side
        }
        let address = sizedTemplate.replacingOccurrences(of: "{width}", with: "\(width)").replacingOccurrences(of: "{height}", with: "\(height)")
        return URL(string: address) ?? url
    }
}

public struct ArtistRef: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var artwork: Artwork?

    public init(id: String, name: String, artwork: Artwork? = nil) {
        self.id = id
        self.name = name
        self.artwork = artwork
    }
}

public enum TrackFee: Int, Sendable, Codable {
    case free = 0
    case vip = 1
    case purchase = 4
    case freeLowQuality = 8
}

/// Where a song is in the AMLL TTML DB: the folder (`%p`, e.g. `am-lyrics`) and the id in it.
public struct TTMLKey: Hashable, Sendable, Codable {
    public var folder: String
    public var id: String

    public init(folder: String, id: String) {
        self.folder = folder
        self.id = id
    }
}

public struct Track: Identifiable, Hashable, Sendable, Codable {
    public var id: TrackRef
    public var title: String
    public var alias: String?
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    public var duration: TimeInterval
    public var artwork: Artwork?
    /// The source's tiers (`QualityTier.id`) the song comes in; empty when the source does not
    /// say.
    public var availableTiers: [String]
    public var fee: TrackFee
    public var hasVideo: Bool
    /// Popularity in 0…1 when the source rates it; nil otherwise.
    public var popularity: Double?
    /// Position on the album: disc (1-based, nil when the source does not say) and track number.
    public var discNumber: Int?
    public var trackNumber: Int?
    public var localPath: String?
    public var cueRange: ClosedRange<TimeInterval>?
    /// The song's entries in the AMLL TTML DB its source knows, asked before any other id; nil
    /// when it gives none.
    public var ttml: [TTMLKey]?

    public init(
        id: TrackRef,
        title: String,
        alias: String? = nil,
        artists: [ArtistRef] = [],
        album: AlbumRef? = nil,
        duration: TimeInterval,
        artwork: Artwork? = nil,
        availableTiers: [String] = [],
        fee: TrackFee = .free,
        hasVideo: Bool = false,
        popularity: Double? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        localPath: String? = nil,
        cueRange: ClosedRange<TimeInterval>? = nil,
        ttml: [TTMLKey]? = nil
    ) {
        self.id = id
        self.title = title
        self.alias = alias
        self.artists = artists
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.availableTiers = availableTiers
        self.fee = fee
        self.hasVideo = hasVideo
        self.popularity = popularity
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.localPath = localPath
        self.cueRange = cueRange
        self.ttml = ttml
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, alias, artists, album, duration, artwork, fee, hasVideo, popularity, discNumber, trackNumber, localPath, cueRange, ttml
        case availableTiers = "availableQualities"
    }

    public var artistText: String { artists.map(\.name).joined(separator: " / ") }
    public var ref: TrackRef { id }
}

public struct Artist: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var source: SourceID
    public var name: String
    public var artwork: Artwork?
    public var albumCount: Int
    public var songCount: Int
    public var description: String?
    public var alias: String?
    public var followerCount: Int?

    public init(id: String, source: SourceID, name: String, artwork: Artwork? = nil, albumCount: Int = 0, songCount: Int = 0, description: String? = nil, alias: String? = nil, followerCount: Int? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.artwork = artwork
        self.albumCount = albumCount
        self.songCount = songCount
        self.description = description
        self.alias = alias
        self.followerCount = followerCount
    }
}

public struct Album: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var source: SourceID
    public var name: String
    public var artists: [ArtistRef]
    public var artwork: Artwork?
    public var releaseDate: Date?
    public var trackCount: Int
    public var description: String?
    public var alias: String?
    public var releaseType: String?
    public var edition: String?
    public var company: String?

    public init(id: String, source: SourceID, name: String, artists: [ArtistRef] = [], artwork: Artwork? = nil, releaseDate: Date? = nil, trackCount: Int = 0, description: String? = nil, alias: String? = nil, releaseType: String? = nil, edition: String? = nil, company: String? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.artists = artists
        self.artwork = artwork
        self.releaseDate = releaseDate
        self.trackCount = trackCount
        self.description = description
        self.alias = alias
        self.releaseType = releaseType
        self.edition = edition
        self.company = company
    }
}

public struct Playlist: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var source: SourceID
    public var name: String
    public var artwork: Artwork?
    /// The creator's user id, for their page; nil when the source does not say.
    public var creatorID: String?
    public var creatorName: String?
    public var creatorAvatar: Artwork?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var trackCount: Int
    public var playCount: Int
    public var tags: [String]
    public var description: String?
    public var isOwned: Bool
    /// Only its owner sees it; nil when the source does not say.
    public var isPrivate: Bool?

    public init(id: String, source: SourceID, name: String, artwork: Artwork? = nil, creatorID: String? = nil, creatorName: String? = nil, creatorAvatar: Artwork? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, trackCount: Int = 0, playCount: Int = 0, tags: [String] = [], description: String? = nil, isOwned: Bool = false, isPrivate: Bool? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.artwork = artwork
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.creatorAvatar = creatorAvatar
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trackCount = trackCount
        self.playCount = playCount
        self.tags = tags
        self.description = description
        self.isOwned = isOwned
        self.isPrivate = isPrivate
    }
}

public struct Page: Hashable, Sendable {
    public var offset: Int
    public var limit: Int

    public init(offset: Int = 0, limit: Int = 30) {
        self.offset = offset
        self.limit = limit
    }

    public static let first = Page()
}
