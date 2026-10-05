import Foundation
import StarryCore

public struct LyricCandidate<Payload: Sendable>: Sendable {
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: TimeInterval?
    public var payload: Payload

    public init(title: String, artists: [String], album: String? = nil, duration: TimeInterval? = nil, payload: Payload) {
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.payload = payload
    }
}

public enum LyricCandidateMatcher {
    public static func best<Payload>(_ candidates: [LyricCandidate<Payload>], for query: LyricQuery) -> LyricCandidate<Payload>? {
        var best: (score: Int, candidate: LyricCandidate<Payload>)?
        for candidate in candidates {
            guard let score = score(candidate, for: query) else { continue }
            if score > (best?.score ?? 0) { best = (score, candidate) }
        }
        return best?.candidate
    }

    public static func score<Payload>(_ candidate: LyricCandidate<Payload>, for query: LyricQuery) -> Int? {
        let title = normalize(query.title)
        let candidateTitle = normalize(candidate.title)
        guard !title.isEmpty, !candidateTitle.isEmpty else { return nil }

        let titleEqual = title == candidateTitle
        if !titleEqual {
            guard eitherContains(title, candidateTitle) else { return nil }
            let lengths = (title.count, candidateTitle.count)
            guard Double(min(lengths.0, lengths.1)) / Double(max(lengths.0, lengths.1)) >= 0.34 else { return nil }
        }

        var delta: TimeInterval?
        if let a = query.duration, let b = candidate.duration, a > 0, b > 0 { delta = abs(a - b) }
        if let delta, delta > 20 { return nil }
        let durationClose = delta.map { $0 <= 5 } ?? false

        let queryArtists = query.artists.map(normalize).filter { !$0.isEmpty }
        let candidateArtists = candidate.artists.flatMap(splitArtists)
        let candidateFull = normalize(candidate.artists.joined())
        let artistEqual = queryArtists.contains { artist in artist == candidateFull || candidateArtists.contains(artist) }
        let artistContained = !artistEqual && queryArtists.contains { artist in
            artist.count >= 2 && (eitherContains(candidateFull, artist) || candidateArtists.contains { eitherContains($0, artist) })
        }
        if !queryArtists.isEmpty, !artistEqual, !artistContained { return nil }
        if !titleEqual, !artistEqual, !artistContained, !durationClose { return nil }

        var score = titleEqual ? 10 : 4
        if artistEqual { score += 5 } else if artistContained { score += 2 }
        if let album = query.album.map(normalize), !album.isEmpty, album == candidate.album.map(normalize) { score += 2 }
        if durationClose { score += 3 }
        return score
    }

    public static func searchKeyword(for query: LyricQuery) -> String {
        ([query.title] + query.artists)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cache key for a query's match: title, artists and the duration in 5 s buckets, so the
    /// same recording from sources with slightly different metadata shares one entry.
    public static func fingerprint(for query: LyricQuery) -> String {
        let bucket = query.duration.map { Int(($0 / 5).rounded()) } ?? 0
        return "v1|\(normalize(query.title))|\(query.artists.map(normalize).joined())|\(bucket)"
    }

    public static func normalize(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !dropped.contains($0) }))
    }

    private static func splitArtists(_ text: String) -> [String] {
        text.split { "、&;，,/|·・".contains($0) }.map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    private static func eitherContains(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
    }
}
