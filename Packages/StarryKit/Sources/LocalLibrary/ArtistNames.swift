import Foundation

/// How a single artist tag is cut into artists. Real multi-value tags
/// (ID3v2.4, repeated Vorbis fields, `ARTISTS`) are taken as they are; one string is split on
/// separators that are almost never part of a name — `;`, `、`, ` / `, `feat.` — and on a bare `/`
/// unless the name is a known exception (`AC/DC`). `&` splits only when the listener asks for it.
public struct ArtistNames: Sendable, Hashable {
    public var splitsAmpersand: Bool
    /// Names never split, beside the built-in ones.
    public var exceptions: [String]

    public init(splitsAmpersand: Bool = false, exceptions: [String] = []) {
        self.splitsAmpersand = splitsAmpersand
        self.exceptions = exceptions
    }

    public static let builtInExceptions = [
        "AC/DC", "Au/Ra", "M/A/R/R/S", "Bob & Earl", "Simon & Garfunkel", "Hall & Oates", "Daryl Hall & John Oates",
        "Earth, Wind & Fire", "Crosby, Stills & Nash", "Crosby, Stills, Nash & Young", "Tyler, The Creator",
        "Mumford & Sons", "Above & Beyond", "Iron & Wine", "Kool & the Gang", "Chase & Status", "Brooks & Dunn",
        "Big & Rich", "Sly & the Family Stone", "Bob Marley & the Wailers", "Tom Petty & the Heartbreakers",
        "Huey Lewis & the News", "Hootie & the Blowfish", "Florence + the Machine", "Of Monsters and Men",
        "Prince & the Revolution", "Belle & Sebastian", "Marina & the Diamonds", "Jon & Vangelis", "Ashford & Simpson",
        "Peaches & Herb", "Sam & Dave", "Ike & Tina Turner", "Captain & Tennille", "Angus & Julia Stone",
    ]

    public func split(_ values: [String]) -> [String] {
        let names = values.count > 1 ? values.flatMap(splitFeaturing) : values.flatMap(split)
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public func split(_ value: String) -> [String] {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        if isException(text) { return [text] }
        var parts = splitFeaturing(text)
        for separator in ["；", ";", "、", " / ", " ／ "] {
            parts = parts.flatMap { cut($0, on: separator) }
        }
        parts = parts.flatMap { cutSlash($0) }
        if splitsAmpersand {
            for separator in ["＆", "&"] { parts = parts.flatMap { cut($0, on: separator) } }
        }
        return parts
    }

    private func splitFeaturing(_ text: String) -> [String] {
        let pattern = /(?i)\s*[\(\[（]?\s*(?:feat\.?|ft\.|featuring)\s+/
        guard let match = text.firstMatch(of: pattern) else { return [text] }
        let head = String(text[..<match.range.lowerBound])
        var tail = String(text[match.range.upperBound...])
        if let last = tail.last, ")]）".contains(last) { tail.removeLast() }
        guard !head.trimmingCharacters(in: .whitespaces).isEmpty else { return [text] }
        return [head] + split(tail)
    }

    private func cut(_ text: String, on separator: String) -> [String] {
        guard text.contains(separator), !isException(text) else { return [text] }
        let pieces = text.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
        return pieces.contains(where: \.isEmpty) ? [text] : pieces
    }

    /// A bare `/` or `／` splits when every piece has letters and the whole is not an exception.
    private func cutSlash(_ text: String) -> [String] {
        guard text.contains("/") || text.contains("／"), !isException(text) else { return [text] }
        let pieces = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "／" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count > 1, pieces.allSatisfy({ $0.count > 1 || ($0.first.map { !$0.isASCII } ?? false) }) else { return [text] }
        return pieces
    }

    private func isException(_ text: String) -> Bool {
        let folded = text.lowercased()
        return (Self.builtInExceptions + exceptions).contains { $0.lowercased() == folded }
    }
}
