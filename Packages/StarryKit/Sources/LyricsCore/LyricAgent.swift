import Foundation

/// Document-local performer identity, mapped to TTML `ttm:agent` / `xml:id`.
public struct LyricAgent: Sendable, Hashable, Identifiable, Codable {
    public static let styleNamespace = "urn:ttml:extensions:vocalist-style:1"

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
    public var color: LyricColor?
    public var memberIDs: [String]

    public init(id: String, kind: Kind = .person, names: [Name] = [], actorID: String? = nil, color: LyricColor? = nil, memberIDs: [String] = []) {
        self.id = id
        self.kind = kind
        self.names = names
        self.actorID = actorID
        self.color = color
        self.memberIDs = memberIDs
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

    static func sanitizingMembers(_ agents: [LyricAgent]) -> [LyricAgent] {
        let performers = Set(agents.filter { $0.kind != .group }.map(\.id))
        return agents.map { agent in
            var agent = agent
            agent.memberIDs = agent.kind == .group ? references(agent.memberIDs).filter(performers.contains) : []
            return agent
        }
    }
}

extension LyricAgent {
    private enum CodingKeys: String, CodingKey { case id, kind, names, actorID, color, memberIDs }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  kind: try values.decode(Kind.self, forKey: .kind),
                  names: try values.decode([Name].self, forKey: .names),
                  actorID: try values.decodeIfPresent(String.self, forKey: .actorID),
                  color: try values.decodeIfPresent(LyricColor.self, forKey: .color),
                  memberIDs: try values.decodeIfPresent([String].self, forKey: .memberIDs) ?? [])
    }
}
