import Foundation

/// What a file's tags say, before any cleaning: every value as the tag holds it (mojibake and
/// all), multi-values kept, under canonical keys (`TagKey`). Saved with the track, so cleaning it
/// again (another encoding for the folder, other artist separators) needs no file read.
public struct RawTags: Codable, Sendable, Hashable {
    public private(set) var fields: [String: [String]] = [:]

    public init(_ fields: [String: [String]] = [:]) {
        for (key, values) in fields { add(values, for: key) }
    }

    public subscript(key: String) -> [String] { fields[key] ?? [] }

    public func first(_ key: String) -> String? { fields[key]?.first }

    public var isEmpty: Bool { fields.isEmpty }

    public mutating func add(_ values: [String], for key: String) {
        let kept = values.map { $0.trimmingCharacters(in: Self.trimmed) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return }
        fields[key, default: []] += kept
    }

    public mutating func add(_ value: String, for key: String) { add([value], for: key) }

    public mutating func fill(from other: RawTags) {
        for (key, values) in other.fields where fields[key] == nil { fields[key] = values }
    }

    public mutating func remove(_ key: String) { fields[key] = nil }

    private static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}"))
}

public enum TagKey {
    public static let title = "title"
    public static let artist = "artist"
    public static let artists = "artists"
    public static let albumArtist = "albumartist"
    public static let albumArtists = "albumartists"
    public static let album = "album"
    public static let albumVersion = "albumversion"
    public static let track = "track"
    public static let trackTotal = "tracktotal"
    public static let disc = "disc"
    public static let discTotal = "disctotal"
    public static let discSubtitle = "discsubtitle"
    public static let date = "date"
    public static let originalDate = "originaldate"
    public static let genre = "genre"
    public static let compilation = "compilation"
    public static let composer = "composer"
    public static let titleSort = "titlesort"
    public static let artistSort = "artistsort"
    public static let albumArtistSort = "albumartistsort"
    public static let albumSort = "albumsort"
    public static let lyrics = "lyrics"
    public static let syncedLyrics = "syncedlyrics"
    public static let trackGain = "replaygain_track_gain"
    public static let trackPeak = "replaygain_track_peak"
    public static let albumGain = "replaygain_album_gain"
    public static let albumPeak = "replaygain_album_peak"
    public static let r128TrackGain = "r128_track_gain"
    public static let r128AlbumGain = "r128_album_gain"
    public static let musicBrainzTrack = "musicbrainz_trackid"
    public static let musicBrainzAlbum = "musicbrainz_albumid"

    /// Keys whose values are long and read only when wanted (lyrics), not kept with the track.
    static let transient: Set<String> = [lyrics, syncedLyrics]

    /// The canonical key for a Vorbis comment, APEv2 item, ID3 `TXXX` description, MP4 freeform
    /// name or RIFF INFO name; nil for one the library does not use.
    public static func canonical(_ name: String) -> String? {
        let folded = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        if let key = aliases[folded] { return key }
        let lower = name.lowercased().replacingOccurrences(of: " ", with: "_")
        if lower.hasPrefix("replaygain_") || lower.hasPrefix("r128_") { return lower }
        return nil
    }

    private static let aliases: [String: String] = [
        "title": title,
        "artist": artist,
        "artists": artists,
        "albumartist": albumArtist,
        "albumartists": albumArtists,
        "band": albumArtist,
        "ensemble": albumArtist,
        "album": album,
        "albumversion": albumVersion,
        "version": albumVersion,
        "tracknumber": track,
        "track": track,
        "tracktotal": trackTotal,
        "totaltracks": trackTotal,
        "discnumber": disc,
        "disc": disc,
        "disctotal": discTotal,
        "totaldiscs": discTotal,
        "discsubtitle": discSubtitle,
        "setsubtitle": discSubtitle,
        "date": date,
        "year": date,
        "originaldate": originalDate,
        "originalyear": originalDate,
        "genre": genre,
        "compilation": compilation,
        "itunescompilation": compilation,
        "composer": composer,
        "titlesort": titleSort,
        "artistsort": artistSort,
        "albumartistsort": albumArtistSort,
        "albumsort": albumSort,
        "lyrics": lyrics,
        "unsyncedlyrics": lyrics,
        "unsynchronizedlyrics": lyrics,
        "musicbrainztrackid": musicBrainzTrack,
        "musicbrainzalbumid": musicBrainzAlbum,
        // RIFF INFO and CAF info, as AVFoundation names their items.
        "recordeddate": date,
    ]

    static let id3Frames: [String: String] = [
        "TIT2": title, "TT2": title,
        "TPE1": artist, "TP1": artist,
        "TPE2": albumArtist, "TP2": albumArtist,
        "TALB": album, "TAL": album,
        "TRCK": track, "TRK": track,
        "TPOS": disc, "TPA": disc,
        "TDRC": date, "TYER": date, "TYE": date,
        "TDOR": originalDate, "TORY": originalDate, "TOR": originalDate,
        "TCON": genre, "TCO": genre,
        "TCMP": compilation, "TCP": compilation,
        "TCOM": composer, "TCM": composer,
        "TSOT": titleSort, "TST": titleSort,
        "TSOP": artistSort, "TSP": artistSort,
        "TSO2": albumArtistSort, "TS2": albumArtistSort,
        "TSOA": albumSort, "TSA": albumSort,
        "TSST": discSubtitle,
    ]
}

/// A picture inside an audio file: where it is (own readers), or its bytes (AVFoundation).
public struct EmbeddedPicture: Sendable, Hashable {
    public var offset: Int64?
    public var length: Int
    public var data: Data?
    /// ID3/FLAC picture type 3 is the front cover.
    public var type: Int

    public init(offset: Int64? = nil, length: Int, data: Data? = nil, type: Int = 3) {
        self.offset = offset
        self.length = length
        self.data = data
        self.type = type
    }

    public var isFrontCover: Bool { type == 3 }

    public func bytes(in file: URL) -> Data? {
        if let data { return data }
        guard let offset, length > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: length)
    }
}

public struct AudioProperties: Codable, Sendable, Hashable {
    public var codec: String
    public var duration: TimeInterval
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var bitrate: Int?

    public init(codec: String, duration: TimeInterval, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil, bitrate: Int? = nil) {
        self.codec = codec
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.bitrate = bitrate
    }

    public var isLossless: Bool { ["flac", "alac", "pcm", "wavpack", "ape"].contains(codec) }
}

public struct FileTags: Sendable {
    public var tags: RawTags
    public var audio: AudioProperties
    public var picture: EmbeddedPicture?
    /// The system can play it (some Ogg streams it lists are not).
    public var isPlayable: Bool
    /// Which readers the tags came from (`id3v2+ape`, `flac`, `avf`), for finding out where a
    /// wrong value came from.
    public var reader: String

    public init(tags: RawTags, audio: AudioProperties, picture: EmbeddedPicture?, isPlayable: Bool, reader: String) {
        self.tags = tags
        self.audio = audio
        self.picture = picture
        self.isPlayable = isPlayable
        self.reader = reader
    }

    public var hasLyrics: Bool { !tags[TagKey.lyrics].isEmpty || !tags[TagKey.syncedLyrics].isEmpty }
}
