import Foundation

/// Document-local performer identity, mapped to TTML `ttm:agent` / `xml:id`.
public struct LyricAgent: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case person, character, group, organization, other
    }

    public struct Name: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Codable {
            case full, family, given, alias, other
        }

        public var text: String
        public var kind: Kind
        public var language: String?

        public init(_ text: String, kind: Kind = .full, language: String? = nil) {
            self.text = text
            self.kind = kind
            self.language = language
        }
    }

    public var id: String
    public var kind: Kind
    public var names: [Name]
    /// The performer portraying this character (`ttm:actor`).
    public var actorID: String?

    public init(id: String, kind: Kind = .person, names: [Name] = [], actorID: String? = nil) {
        self.id = id
        self.kind = kind
        self.names = names
        self.actorID = actorID
    }

    public var displayName: String {
        names.first { $0.kind == .full && !$0.text.isEmpty }?.text
            ?? names.first { !$0.text.isEmpty }?.text ?? id
    }

    static func singer(for ids: [String], in agents: [LyricAgent]) -> LyricSinger {
        let ids = references(ids)
        if ids.count > 1 || agents.contains(where: { ids.contains($0.id) && $0.kind == .group }) { return .duet }
        guard let id = ids.first, let index = agents.firstIndex(where: { $0.id == id }) else { return .primary }
        return index == agents.firstIndex(where: { $0.kind != .group }) ? .primary : .secondary
    }

    /// Foreign-format IDs can contain spaces; only TTML IDREFS are split on whitespace.
    static func references(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
