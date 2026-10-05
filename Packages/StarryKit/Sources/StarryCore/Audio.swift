import Foundation

public enum AudioQuality: String, CaseIterable, Sendable, Codable, Comparable {
    case lq
    case sq
    case hq
    case lossless
    case hiRes = "hi-res"

    public static let `default`: AudioQuality = .hq

    private var rank: Int {
        switch self {
        case .lq: 0
        case .sq: 1
        case .hq: 2
        case .lossless: 3
        case .hiRes: 4
        }
    }

    public static func < (lhs: AudioQuality, rhs: AudioQuality) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .lq: "标准"
        case .sq: "较高"
        case .hq: "极高"
        case .lossless: "无损"
        case .hiRes: "Hi-Res"
        }
    }

    /// Tag text in lists and the player bar (nil for lossy levels).
    public var badge: String? {
        switch self {
        case .lossless: "无损"
        case .hiRes: "Hi-Res"
        default: nil
        }
    }
}

/// One quality a source streams, as the platform names it (`MusicSource.qualityTiers`): what a
/// song comes in, what is asked for and what plays. A tier that is one of the generic levels
/// takes the level's raw value as its id (so a saved generic level reads as that tier).
public struct QualityTier: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The format behind it (`320 kbps · MP3`), when the source says.
    public var detail: String?
    public var level: AudioQuality
    /// A spatial mix (Dolby Atmos) the system renders: the global preference never picks it,
    /// nothing of ours (equalizer, spectrum, vocal attenuation) goes between, and a stereo file never stands
    /// in for it or the other way round.
    public var isSpatial: Bool
    /// Tag text in lists and the player bar (`无损`, `Hi-Res`, `杜比`); nil for lossy tiers.
    public var badge: String?

    public init(id: String, name: String, detail: String? = nil, level: AudioQuality, isSpatial: Bool = false, badge: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.level = level
        self.isSpatial = isSpatial
        self.badge = badge ?? (isSpatial ? nil : level.badge)
    }

    public init(_ level: AudioQuality, detail: String? = nil) {
        self.init(id: level.rawValue, name: level.displayName, detail: detail, level: level)
    }
}

public enum AudioContainer: String, Sendable, Codable {
    case mp3, aac, flac, alac, wav, ogg, ape, hls
    /// An MPEG-4 file that is not AAC music (a Dolby Atmos mix).
    case mp4
}

/// Gapless metadata a source may supply so the engine can compensate encoder delay / padding.
public struct GaplessInfo: Hashable, Sendable, Codable {
    public var encoderDelayFrames: Int
    public var endPaddingFrames: Int
    public var sampleRate: Double?

    public init(encoderDelayFrames: Int, endPaddingFrames: Int, sampleRate: Double? = nil) {
        self.encoderDelayFrames = encoderDelayFrames
        self.endPaddingFrames = endPaddingFrames
        self.sampleRate = sampleRate
    }
}

public enum AssetProvider: String, Sendable, Codable {
    case local, cache, source, trial
}

public struct AudioStreamInfo: Sendable, Hashable, Codable {
    public var bitrate: Int?
    /// Hz.
    public var sampleRate: Int?
    /// Bits per sample of a lossless source; nil for lossy formats.
    public var bitDepth: Int?
    public var channels: Int?
    public var fileSize: Int64?

    public init(bitrate: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil, fileSize: Int64? = nil) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.fileSize = fileSize
    }

    public func filled(from other: AudioStreamInfo?) -> AudioStreamInfo {
        guard let other else { return self }
        return AudioStreamInfo(bitrate: bitrate ?? other.bitrate, sampleRate: sampleRate ?? other.sampleRate, bitDepth: bitDepth ?? other.bitDepth, channels: channels ?? other.channels, fileSize: fileSize ?? other.fileSize)
    }
}

/// A file's loudness tags (ReplayGain, or R128 turned into it): how many dB to move each song
/// or album to the same loudness, and its peak (1.0 = full scale) so the move does not clip.
public struct ReplayGain: Sendable, Hashable, Codable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, trackPeak: Double? = nil, albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    /// nil when no gain is known.
    public var nonEmpty: ReplayGain? { trackGain == nil && albumGain == nil ? nil : self }

    /// The linear volume factor for `mode` with `preamp` dB on top, no louder than the peak
    /// allows; 1 when the file has no gain for it.
    public func factor(album: Bool, preamp: Double) -> Float {
        let gain = album ? (albumGain ?? trackGain) : (trackGain ?? albumGain)
        guard let gain else { return 1 }
        let peak = album ? (albumPeak ?? trackPeak) : (trackPeak ?? albumPeak)
        var decibels = gain + preamp
        if let peak, peak > 0 { decibels = min(decibels, -20 * log10(peak)) }
        return Float(pow(10, decibels / 20))
    }
}

public struct Loudness: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        case off
        case track
        case album
    }

    public var mode: Mode
    /// dB added to the tags' gain (ReplayGain aims at 89 dB SPL, quieter than most recent masters).
    public var preamp: Double

    public init(mode: Mode = .off, preamp: Double = 0) {
        self.mode = mode
        self.preamp = preamp
    }

    public func factor(for gain: ReplayGain?) -> Float {
        guard mode != .off, let gain else { return 1 }
        return gain.factor(album: mode == .album, preamp: preamp)
    }
}

/// Unscrambles a file a platform serves scrambled, byte by byte according to where each byte
/// sits in the file, so any range can be read on its own.
public protocol StreamDecryptor: Sendable {
    func decrypt(_ bytes: UnsafeMutableRawBufferPointer, at offset: Int64)
}

/// A `StreamDecryptor` with an identity, so that assets stay comparable.
public struct StreamDecryption: Sendable, Hashable {
    public var id: String
    public var decryptor: any StreamDecryptor

    public init(id: String, decryptor: any StreamDecryptor) {
        self.id = id
        self.decryptor = decryptor
    }

    public static func == (lhs: StreamDecryption, rhs: StreamDecryption) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct PlayableAsset: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    public var container: AudioContainer
    public var tier: QualityTier
    public var expiresAt: Date?
    public var isTrial: Bool
    public var gapless: GaplessInfo?
    public var supportsTap: Bool
    public var supportsOverlap: Bool
    public var provider: AssetProvider
    public var pluginID: String?
    /// Playback window inside the file (CUE sheets); nil = whole file.
    public var range: ClosedRange<TimeInterval>?
    public var info: AudioStreamInfo?
    public var decryption: StreamDecryption?
    /// The server makes the file while it sends it (a transcode): no length, no byte ranges. The
    /// engine downloads it through its own download and plays it once it is all in.
    public var isTranscode: Bool
    public var gain: ReplayGain?

    public init(
        url: URL,
        headers: [String: String] = [:],
        container: AudioContainer,
        tier: QualityTier,
        expiresAt: Date? = nil,
        isTrial: Bool = false,
        gapless: GaplessInfo? = nil,
        supportsTap: Bool = true,
        supportsOverlap: Bool = true,
        provider: AssetProvider = .source,
        pluginID: String? = nil,
        range: ClosedRange<TimeInterval>? = nil,
        info: AudioStreamInfo? = nil,
        decryption: StreamDecryption? = nil,
        isTranscode: Bool = false,
        gain: ReplayGain? = nil
    ) {
        self.url = url
        self.headers = headers
        self.container = container
        self.tier = tier
        self.expiresAt = expiresAt
        self.isTrial = isTrial
        self.gapless = gapless
        self.supportsTap = supportsTap
        self.supportsOverlap = supportsOverlap
        self.provider = provider
        self.pluginID = pluginID
        self.info = info
        self.range = range
        self.decryption = decryption
        self.isTranscode = isTranscode
        self.gain = gain
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}
