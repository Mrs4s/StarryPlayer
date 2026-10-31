import Foundation

/// Lossless JSON project, preserving untimed syllables and editor tracks omitted by TTML.
public struct LyricsProject: Sendable, Hashable, Codable {
    public static let fileExtension = "starrylyrics"
    public static let currentVersion = 6
    static let formatName = "starry-lyrics"

    public struct Entry: Sendable, Hashable, Codable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public enum ReadError: Error, Equatable {
        case notAProject
        /// Saved by a later version, which may hold what this one would drop.
        case newerVersion(Int)
    }

    public var format = LyricsProject.formatName
    public var version = LyricsProject.currentVersion
    public var title: String
    public var artists: [String]
    /// `amll:meta` entries in order; a key may repeat (one entry per artist).
    public var metadata: [Entry]
    public var draft: LyricsDraft

    public init(draft: LyricsDraft, metadata: [Entry] = [], title: String = "", artists: [String] = []) {
        self.draft = draft
        self.metadata = metadata
        self.title = title
        self.artists = artists
    }

    public init(data: Data) throws {
        // Reject unrelated or newer formats before decoding draft fields.
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == Self.formatName, let version = header.version else { throw ReadError.notAProject }
        guard version <= Self.currentVersion else { throw ReadError.newerVersion(version) }
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var current = self
        current.version = Self.currentVersion
        return try encoder.encode(current)
    }
}
