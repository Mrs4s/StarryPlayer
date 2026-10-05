import Foundation

public enum SourceID: Hashable, Sendable, Codable {
    case netease
    case qqMusic
    case kugou
    case subsonic(serverID: String)
    case jellyfin(serverID: String)
    case local
    case plugin(id: String)

    public var key: String {
        switch self {
        case .netease: "netease"
        case .qqMusic: "qqmusic"
        case .kugou: "kugou"
        case .subsonic(let serverID): "subsonic:\(serverID)"
        case .jellyfin(let serverID): "jellyfin:\(serverID)"
        case .local: "local"
        case .plugin(let id): "plugin:\(id)"
        }
    }

    /// The source `key` stands for; nil for a string that is not a key.
    public init?(key: String) {
        switch key {
        case "netease": self = .netease
        case "qqmusic": self = .qqMusic
        case "kugou": self = .kugou
        case "local": self = .local
        default:
            guard let colon = key.firstIndex(of: ":") else { return nil }
            let value = String(key[key.index(after: colon)...])
            guard !value.isEmpty else { return nil }
            switch key[..<colon] {
            case "subsonic": self = .subsonic(serverID: value)
            case "jellyfin": self = .jellyfin(serverID: value)
            case "plugin": self = .plugin(id: value)
            default: return nil
            }
        }
    }
}

public struct TrackRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let source: SourceID
    public let id: String

    public init(source: SourceID, id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source.key):\(id)" }
}
