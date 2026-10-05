import Foundation

/// What the user set on a source's own page in Settings, by
/// the keys of the settings the source declares (`MusicSources.SourceSetting`). A key that is
/// missing is at the source's default, so only changed values are stored. Saved as a plain JSON
/// object.
public struct SourceSettingValues: Codable, Sendable, Hashable {
    public enum Value: Codable, Sendable, Hashable {
        case bool(Bool)
        case string(String)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let bool): try container.encode(bool)
            case .string(let string): try container.encode(string)
            }
        }
    }

    public private(set) var values: [String: Value]

    public init(_ values: [String: Value] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> Value? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: Value].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
