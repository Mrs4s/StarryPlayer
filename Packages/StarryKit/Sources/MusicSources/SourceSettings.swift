import Foundation
import StarryCore

public struct SourceSetting: Sendable, Hashable, Identifiable {
    public enum Control: Sendable, Hashable {
        case toggle(default: Bool)
        case text(placeholder: String, default: String = "", secure: Bool = false)
        case choice([Choice], default: String)
    }

    public struct Choice: Sendable, Hashable {
        public var value: String
        public var title: String

        public init(_ value: String, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    public var key: String
    public var title: String
    public var detail: String?
    public var keywords: String
    public var advanced: Bool
    public var control: Control

    public var id: String { key }

    public init(_ key: String, _ title: String, detail: String? = nil, keywords: String = "", advanced: Bool = false, control: Control) {
        self.key = key
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.advanced = advanced
        self.control = control
    }
}

public struct SourceSettingsSection: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var footer: String?
    public var advanced: Bool
    public var settings: [SourceSetting]

    public init(_ id: String, title: String? = nil, footer: String? = nil, advanced: Bool = false, settings: [SourceSetting]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.advanced = advanced
        self.settings = settings
    }
}

public extension SourceSettingValues {
    func bool(_ setting: SourceSetting) -> Bool {
        if case .bool(let value)? = self[setting.key] { return value }
        if case .toggle(let fallback) = setting.control { return fallback }
        return false
    }

    func string(_ setting: SourceSetting) -> String {
        if case .string(let value)? = self[setting.key] { return value }
        switch setting.control {
        case .text(_, let fallback, _), .choice(_, let fallback): return fallback
        case .toggle: return ""
        }
    }

    mutating func set(_ setting: SourceSetting, to value: Value) {
        let isDefault = switch (setting.control, value) {
        case (.toggle(let fallback), .bool(let bool)): bool == fallback
        case (.text(_, let fallback, _), .string(let string)), (.choice(_, let fallback), .string(let string)): string == fallback
        default: false
        }
        self[setting.key] = isDefault ? nil : value
    }
}

public protocol ConfigurableSource: MusicSource {
    var settingsSymbol: String { get }
    var settingsSummary: String { get }
    var settingsSections: [SourceSettingsSection] { get }
    func applySettings(_ values: SourceSettingValues) async
}
