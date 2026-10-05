import Foundation

public struct TrackSearchIndex: Sendable {
    private var keys: [[UInt8]] = []

    public init() {}

    public init(_ tracks: some Sequence<Track>) {
        keys = tracks.map(Self.key)
    }

    public var count: Int { keys.count }

    public mutating func append(_ other: TrackSearchIndex) {
        keys += other.keys
    }

    public mutating func append(contentsOf tracks: some Sequence<Track>) {
        keys += tracks.map(Self.key)
    }

    public mutating func insert(_ track: Track, at position: Int) {
        keys.insert(Self.key(track), at: position)
    }

    public mutating func remove(at position: Int) {
        keys.remove(at: position)
    }

    /// The positions of the tracks matching `query`, in order; nil when the query is blank
    /// (every track matches, no filter).
    public func matches(_ query: String) -> [Int]? {
        let needle = Array(Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines)).utf8)
        guard !needle.isEmpty else { return nil }
        return needle.withUnsafeBytes { needle in
            keys.indices.filter { position in
                keys[position].withUnsafeBytes { key in
                    key.count >= needle.count && memmem(key.baseAddress, key.count, needle.baseAddress, needle.count) != nil
                }
            }
        }
    }

    private static let separator = "\u{1}"

    static func key(_ track: Track) -> [UInt8] {
        let fields = [track.title, track.alias ?? "", track.artists.map(\.name).joined(separator: " / "), track.album?.name ?? ""]
        return Array(fold(fields.joined(separator: separator)).utf8)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
