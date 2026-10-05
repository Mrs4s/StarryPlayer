import Foundation
import StarryCore
import Testing
@testable import MusicSources

struct SourceSettingsTests {
    private let toggle = SourceSetting("realIP", "海外模式", control: .toggle(default: true))
    private let text = SourceSetting("proxy", "代理", control: .text(placeholder: "未设置"))
    private let choice = SourceSetting("server", "节点", control: .choice([.init("a", "A"), .init("b", "B")], default: "a"))

    /// Missing values read as the setting's default; setting a default drops it, so only
    /// changes are stored.
    @Test func onlyChangesAreKept() {
        var values = SourceSettingValues()
        #expect(values.bool(toggle))
        #expect(values.string(text) == "")
        #expect(values.string(choice) == "a")

        values.set(toggle, to: .bool(false))
        values.set(choice, to: .string("b"))
        #expect(!values.bool(toggle))
        #expect(values.string(choice) == "b")

        values.set(toggle, to: .bool(true))
        values.set(choice, to: .string("a"))
        values.set(text, to: .string(""))
        #expect(values.isEmpty)
    }

    /// Saved as a plain JSON object, so the file reads as what was set.
    @Test func savedAsAPlainObject() throws {
        let values = SourceSettingValues(["realIP": .bool(false), "proxy": .string("http://a")])
        let json = try #require(String(data: JSONEncoder().encode(values), encoding: .utf8))
        #expect(json.contains(#""realIP":false"#))
        #expect(json.contains(#""proxy":"http:\/\/a""#))
        #expect(try JSONDecoder().decode(SourceSettingValues.self, from: Data(json.utf8)) == values)
    }
}
