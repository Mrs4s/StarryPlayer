import Foundation
import StarryCore

public struct UserProfile: Identifiable, Hashable, Sendable, Codable {
    public enum Gender: String, Sendable, Codable {
        case male, female
    }

    public var id: String
    public var source: SourceID
    public var nickname: String
    public var avatar: Artwork?
    public var signature: String?
    /// The source's account level; nil when it has none.
    public var level: Int?
    /// The highest `level` the source has, for showing how far along it is; nil
    /// when the source does not say.
    public var maxLevel: Int?
    public var isVIP: Bool
    public var identity: String?
    public var gender: Gender?
    public var details: [String]
    public var followCount: Int?
    public var followerCount: Int?
    public var eventCount: Int?
    public var listenedSongCount: Int?
    public var createdPlaylistCount: Int?
    public var isFollowed: Bool?
    public var followsYou: Bool
    public var isRankingPublic: Bool
    public var areFollowsPublic: Bool

    public init(
        id: String,
        source: SourceID,
        nickname: String,
        avatar: Artwork? = nil,
        signature: String? = nil,
        level: Int? = nil,
        maxLevel: Int? = nil,
        isVIP: Bool = false,
        identity: String? = nil,
        gender: Gender? = nil,
        details: [String] = [],
        followCount: Int? = nil,
        followerCount: Int? = nil,
        eventCount: Int? = nil,
        listenedSongCount: Int? = nil,
        createdPlaylistCount: Int? = nil,
        isFollowed: Bool? = nil,
        followsYou: Bool = false,
        isRankingPublic: Bool = true,
        areFollowsPublic: Bool = true
    ) {
        self.id = id
        self.source = source
        self.nickname = nickname
        self.avatar = avatar
        self.signature = signature
        self.level = level
        self.maxLevel = maxLevel
        self.isVIP = isVIP
        self.identity = identity
        self.gender = gender
        self.details = details
        self.followCount = followCount
        self.followerCount = followerCount
        self.eventCount = eventCount
        self.listenedSongCount = listenedSongCount
        self.createdPlaylistCount = createdPlaylistCount
        self.isFollowed = isFollowed
        self.followsYou = followsYou
        self.isRankingPublic = isRankingPublic
        self.areFollowsPublic = areFollowsPublic
    }
}

public struct UserPlaylists: Sendable {
    public var created: [Playlist]
    public var subscribed: [Playlist]

    public init(created: [Playlist] = [], subscribed: [Playlist] = []) {
        self.created = created
        self.subscribed = subscribed
    }
}

public struct UserPage: Sendable {
    public var users: [UserProfile]
    public var total: Int?
    /// Where the next page starts; nil at the end.
    public var nextPage: Page?

    public init(users: [UserProfile] = [], total: Int? = nil, nextPage: Page? = nil) {
        self.users = users
        self.total = total
        self.nextPage = nextPage
    }
}

public enum ListeningPeriod: String, Sendable, CaseIterable {
    case week
    case allTime
}

public struct RankedTrack: Identifiable, Hashable, Sendable {
    public var track: Track
    /// 0…100, relative to the most-played song.
    public var score: Int
    public var playCount: Int?

    public var id: TrackRef { track.id }

    public init(track: Track, score: Int, playCount: Int? = nil) {
        self.track = track
        self.score = score
        self.playCount = playCount
    }
}

public protocol UserSource: MusicSource {
    func user(id: String) async throws -> UserProfile
    func playlists(ofUser id: String) async throws -> UserPlaylists
}

public protocol ListeningRankingSource: UserSource {
    func listeningRanking(ofUser id: String, period: ListeningPeriod) async throws -> [RankedTrack]
}

public protocol UserFollowSource: UserSource {
    func setUserFollowed(_ id: String, followed: Bool) async throws
    func follows(ofUser id: String, page: Page) async throws -> UserPage
    func followers(ofUser id: String, page: Page) async throws -> UserPage
}

public enum UserSourceError: Error, Sendable, Equatable {
    /// The user does not show their listening ranking to others.
    case rankingHidden
    /// The user does not show who they follow or who follows them.
    case followsHidden
}
