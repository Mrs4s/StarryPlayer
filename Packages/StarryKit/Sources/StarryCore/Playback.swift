import Foundation

public enum PlaybackOrigin: String, Sendable, Codable {
    case playlist, album, artist, radio, search, dailyRecommendation, liked, local, queue, history
    /// All media: every song the account keeps on the platform (its uploads, a server's library).
    case allMedia
    case user

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let origin = Self(rawValue: raw == "cloud" ? Self.allMedia.rawValue : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a playback origin: \(raw)"))
        }
        self = origin
    }
}

public struct PlaybackContext: Hashable, Sendable, Codable {
    /// The source the origin belongs to (the playlist's, the album's, the account whose daily
    /// recommendations it is); nil for an origin of the app's own (recently played, a hand-built
    /// queue), whose songs may come from several sources.
    public var source: SourceID?
    public var originType: PlaybackOrigin
    public var originID: String?
    public var originName: String?

    public init(source: SourceID?, originType: PlaybackOrigin, originID: String? = nil, originName: String? = nil) {
        self.source = source
        self.originType = originType
        self.originID = originID
        self.originName = originName
    }
}

public enum TransitionMode: Hashable, Sendable, Codable {
    case none
    case gapless
    case crossfade(seconds: Double)

    public static let crossfadeRange: ClosedRange<Double> = 1...12
}

public enum TransitionCancelReason: String, Sendable {
    case seek, skip, error, resolveFailed, tooShort, pastOverlapStart, unsupported
}

public enum BufferState: String, Sendable {
    case idle, buffering, ready, stalled
}

public enum RepeatMode: String, Sendable, Codable, CaseIterable {
    case off, all, one
}

public struct SpectrumFrame: Sendable {
    public var bands: [Float]
    public var hostTime: TimeInterval

    public init(bands: [Float], hostTime: TimeInterval) {
        self.bands = bands
        self.hostTime = hostTime
    }
}

public enum PlaybackError: Error, Sendable, Equatable {
    case vipRequired
    case loginExpired
    case unavailableInRegion
    case sourceUnreachable
    case assetExpired
    case trialOnly
    case decodeFailed(String)
    case notImplemented(String)
    case unknown(String)
}

public enum PlaybackEvent: Sendable {
    case itemWillChange(to: TrackRef?)
    case itemDidChange(TrackRef?)
    case transitionArmed(mode: TransitionMode, overlapStart: TimeInterval)
    case transitionBegan
    case transitionPivoted(TrackRef)
    case transitionEnded
    case transitionCancelled(TransitionCancelReason)
    case rate(Float)
    case time(TimeInterval)
    case duration(TimeInterval)
    case bufferState(BufferState)
    case sourceRecovered(TrackRef)
    case vocalAttenuation(VocalAttenuationStatus)
    case spectrumFrame(SpectrumFrame)
    case playbackEnded(TrackRef)
    case downloadFinished(TrackRef, file: URL)
    case error(PlaybackError)
}

public struct VocalAttenuationStatus: Sendable, Equatable {
    /// Why the vocals cannot be controlled right now (the source, Low Power Mode, heat, or
    /// processing too slow).
    public enum Unavailable: Sendable, Equatable {
        /// This song cannot be processed: no tap (HLS), more than two channels, or no network.
        case unsupportedSource
        case spatialMix
        case lowPowerMode
        case thermal
        /// Processing fell behind real time (5 late blocks within a second).
        case performance
    }

    public var enabled = false
    public var isActive = false
    /// The separation unit is being built.
    public var isPreparing = false
    public var unavailable: Unavailable?
    public var modelName: String?
    public var usesMusicModel = false
    public var latency: TimeInterval = 0

    public init() {}
}

public struct PlaybackReport: Sendable, Hashable {
    public var track: TrackRef
    public var context: PlaybackContext?
    public var playedSeconds: TimeInterval
    public var duration: TimeInterval
    public var startedAt: Date
    public var endedAt: Date

    public init(track: TrackRef, context: PlaybackContext?, playedSeconds: TimeInterval, duration: TimeInterval, startedAt: Date, endedAt: Date) {
        self.track = track
        self.context = context
        self.playedSeconds = playedSeconds
        self.duration = duration
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public static func scrobbleThreshold(duration: TimeInterval) -> TimeInterval {
        min(duration / 2, 240)
    }
}
