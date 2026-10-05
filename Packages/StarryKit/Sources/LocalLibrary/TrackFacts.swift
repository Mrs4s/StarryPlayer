import CryptoKit
import Foundation

public struct LibraryRules: Sendable, Hashable {
    public var artists = ArtistNames()
    /// Read misread legacy text (GBK and others) again; on unless turned off.
    public var repairsEncoding = true
    public var folderNamesAlbums = false

    public init(artists: ArtistNames = ArtistNames(), repairsEncoding: Bool = true, folderNamesAlbums: Bool = false) {
        self.artists = artists
        self.repairsEncoding = repairsEncoding
        self.folderNamesAlbums = folderNamesAlbums
    }
}

struct TrackFacts: Sendable, Hashable {
    var title: String
    var titleSort: String?
    var artists: [String]
    var album: String?
    var albumArtists: [String]
    /// The album's identity (`AlbumKey`); nil for a song outside any album.
    var albumKey: String?
    var isCompilation: Bool
    var disc: Int?
    var discTotal: Int?
    var track: Int?
    var trackTotal: Int?
    var year: Int?
    var genres: [String]
    var composer: String?
    var trackGain: Double?
    var trackPeak: Double?
    var albumGain: Double?
    var albumPeak: Double?
    var musicBrainzTrack: String?
}

struct FolderMember: Sendable {
    var fileName: String
    var tags: RawTags
}

enum FolderRules {
    static let variousArtists = "群星"

    static func facts(_ members: [FolderMember], albumFolderName: String, discFromFolder: Int?, encoding: LegacyEncoding?, rules: LibraryRules) -> (facts: [TrackFacts], encoding: LegacyEncoding?) {
        let legacy = rules.repairsEncoding ? (encoding ?? TextRepair.vote(members.flatMap { $0.tags.fields.values.flatMap { $0 } })) : nil
        func clean(_ text: String) -> String {
            guard let legacy else { return text }
            return TextRepair.repaired(text, as: legacy) ?? text
        }
        func values(_ tags: RawTags, _ key: String) -> [String] { tags[key].map(clean) }

        var facts = members.map { member -> TrackFacts in
            let tags = member.tags
            let parsed = FileName(member.fileName)
            var artists = rules.artists.split(values(tags, TagKey.artists).isEmpty ? values(tags, TagKey.artist) : values(tags, TagKey.artists))
            if artists.isEmpty, let artist = parsed.artist { artists = [artist] }
            let title = values(tags, TagKey.title).first ?? parsed.title
            var album = values(tags, TagKey.album).first
            if album == nil, rules.folderNamesAlbums { album = albumFolderName }
            let albumArtists = rules.artists.split(values(tags, TagKey.albumArtists).isEmpty ? values(tags, TagKey.albumArtist) : values(tags, TagKey.albumArtists))
            let (track, trackTotal) = numberPair(tags.first(TagKey.track))
            var (disc, discTotal) = numberPair(tags.first(TagKey.disc))
            if disc == nil { disc = discFromFolder }
            return TrackFacts(
                title: title,
                titleSort: values(tags, TagKey.titleSort).first,
                artists: artists,
                album: album,
                albumArtists: albumArtists,
                albumKey: nil,
                isCompilation: isTrue(tags.first(TagKey.compilation)),
                disc: disc,
                discTotal: discTotal ?? tags.first(TagKey.discTotal).flatMap { Int($0) },
                track: track ?? parsed.track,
                trackTotal: trackTotal ?? tags.first(TagKey.trackTotal).flatMap { Int($0) },
                year: year(tags.first(TagKey.date) ?? tags.first(TagKey.originalDate)),
                genres: Array(Set(values(tags, TagKey.genre).flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } })).sorted(),
                composer: values(tags, TagKey.composer).first,
                trackGain: gain(tags.first(TagKey.trackGain)) ?? r128(tags.first(TagKey.r128TrackGain)),
                trackPeak: tags.first(TagKey.trackPeak).flatMap(Double.init),
                albumGain: gain(tags.first(TagKey.albumGain)) ?? r128(tags.first(TagKey.r128AlbumGain)),
                albumPeak: tags.first(TagKey.albumPeak).flatMap(Double.init),
                musicBrainzTrack: tags.first(TagKey.musicBrainzTrack)
            )
        }

        let titles = Set(facts.compactMap { $0.album.map(normalize) })
        let distinctArtists = Set(facts.compactMap { $0.artists.first.map(normalize) })
        let autoCompilation = facts.count > 1 && titles.count == 1 && distinctArtists.count > 2 && facts.allSatisfy { $0.albumArtists.isEmpty }

        for index in facts.indices {
            let tags = members[index].tags
            if facts[index].albumArtists.isEmpty {
                if facts[index].isCompilation || autoCompilation {
                    facts[index].albumArtists = [variousArtists]
                    facts[index].isCompilation = true
                } else if let first = facts[index].artists.first {
                    facts[index].albumArtists = [first]
                }
            }
            if facts[index].albumArtists.count == 1, ["various artists", "va", "群星", "various"].contains(facts[index].albumArtists[0].lowercased()) {
                facts[index].albumArtists = [variousArtists]
                facts[index].isCompilation = true
            }
            guard let album = facts[index].album else { continue }
            if let mbid = tags.first(TagKey.musicBrainzAlbum), !mbid.isEmpty {
                facts[index].albumKey = "mb:" + mbid.lowercased()
            } else {
                let version = tags.first(TagKey.albumVersion).map { clean($0) }.map(normalize) ?? ""
                facts[index].albumKey = [facts[index].albumArtists.map(normalize).joined(separator: "\u{1}"), normalize(album), version].joined(separator: "\u{2}")
            }
        }
        return (facts, legacy)
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func numberPair(_ value: String?) -> (Int?, Int?) {
        guard let value else { return (nil, nil) }
        let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return (numbers.first.flatMap { $0 > 0 ? $0 : nil }, numbers.dropFirst().first.flatMap { $0 > 0 ? $0 : nil })
    }

    static func year(_ value: String?) -> Int? {
        guard let value, let match = value.firstMatch(of: /(1[0-9]{3}|20[0-9]{2})/) else { return nil }
        return Int(match.1)
    }

    static func isTrue(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    /// `-7.50 dB`.
    static func gain(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.lowercased().replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// R128 gains are Q7.8 against −23 LUFS; ReplayGain's reference is 5 dB louder.
    static func r128(_ value: String?) -> Double? {
        guard let value, let raw = Double(value) else { return nil }
        return raw / 256 + 5
    }

    static func discNumber(folderName: String) -> Int? {
        let folded = folderName.lowercased().replacingOccurrences(of: #"[-._()\[\]\s]+"#, with: " ", options: .regularExpression)
        guard let match = folded.firstMatch(of: /^(?:cd|disc|disk|vol|volume|part|dvd)\s?(\d{1,2})(?:\s.*)?$/) else { return nil }
        return Int(match.1)
    }
}

struct FileName {
    var title: String
    var artist: String?
    var track: Int?

    init(_ name: String) {
        var stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        if let match = stem.firstMatch(of: /^(\d{2,3})(?:\s*[-._]\s*|\s+)(.+)$/) ?? stem.firstMatch(of: /^(\d)\s*[-._]\s+(.+)$/) {
            track = Int(match.1)
            stem = String(match.2)
        }
        let parts = stem.components(separatedBy: " - ")
        if parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts[1].trimmingCharacters(in: .whitespaces)
        } else {
            title = stem.isEmpty ? (name as NSString).deletingPathExtension : stem
        }
    }
}

enum StableID {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func artist(_ name: String) -> String { "ar" + hash(FolderRules.normalize(name)) }
    static func album(_ key: String) -> String { "al" + hash(key) }

    /// A new song's id: random, never derived from what may change.
    static func newTrack() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
