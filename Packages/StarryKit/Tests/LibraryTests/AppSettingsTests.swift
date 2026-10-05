import Foundation
import StarryCore
import Testing
@testable import Library

struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func roundTrips() throws {
        for mode in AppSettings.SidebarMode.allCases {
            var settings = AppSettings()
            settings.sidebarMode = mode
            settings.playerBarStyle = .glass
            settings.showAdvancedSettings = true
            settings.restorePlayback = false
            settings.outputDevice = .init(uid: "AppleUSBAudioEngine:1", name: "USB DAC")
            settings.menuBarLyrics.enabled = true
            settings.menuBarLyrics.perSyllable = false
            settings.menuBarLyrics.maxWidth = 220
            settings.checksForUpdates = false
            #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test func olderSettingsGetDefaults() throws {
        let saved = try decode(#"{"sidebarCollapsed": true}"#)
        #expect(saved.sidebarCollapsed)
        #expect(saved.playerBarStyle == .systemDefault)
        #expect(saved.sidebarMode == .floating)
        #expect(saved.showAdvancedSettings == false)
        #expect(saved.restorePlayback)
        #expect(saved.outputDevice == nil)
        #expect(saved.menuBarLyrics == AppSettings.MenuBarLyrics())
        #expect(saved.menuBarLyrics.enabled == false)
        #expect(saved.checksForUpdates)
        let partial = try decode(#"{"menuBarLyrics": {"enabled": true}}"#)
        #expect(partial.menuBarLyrics.enabled)
        #expect(partial.menuBarLyrics.perSyllable)
        #expect(partial.menuBarLyrics.maxWidth == 300)
    }

    /// Song transitions: both switches off by default, and the `mode` older builds saved (never
    /// user-settable) is dropped. Crossfade takes over from gapless, except between songs of one album.
    @Test func transitionSwitches() throws {
        let old = try decode(#"{"transition": {"mode": {"none": {}}, "crossfadeSeconds": 5}}"#)
        #expect(old.transition == AppSettings.Transition())
        #expect(old.transition.mode() == .none)

        var transition = AppSettings.Transition()
        transition.gapless = true
        #expect(transition.mode() == .gapless)
        transition.crossfade = true
        transition.crossfadeSeconds = 30
        #expect(transition.mode() == .crossfade(seconds: 12))
        #expect(transition.mode(sameAlbum: true) == .gapless)
        transition.gapless = false
        #expect(transition.mode(sameAlbum: true) == .gapless)
        transition.albumsWithoutFade = false
        #expect(transition.mode(sameAlbum: true) == .crossfade(seconds: 12))

        var settings = AppSettings()
        settings.transition = transition
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    /// A value this build cannot read (a newer build's style or mode, a damaged entry) falls
    /// back to that option's default, not the whole settings.
    @Test func unreadableValuesFallBackOneByOne() throws {
        let saved = try decode(#"{"playerBarStyle": "neon", "sidebarMode": "drawer", "outputDevice": {"uid": 3}, "menuBarLyrics": 3, "sidebarCollapsed": true}"#)
        #expect(saved.playerBarStyle == .systemDefault)
        #expect(saved.sidebarMode == .floating)
        #expect(saved.outputDevice == nil)
        #expect(saved.menuBarLyrics.enabled == false)
        #expect(saved.sidebarCollapsed)
    }

    @Test func qualityPicks() throws {
        var settings = AppSettings()
        settings.sourceQualities["plugin:example"] = "dolby"
        let json = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: json).sourceQualities == ["plugin:example": "dolby"])
        let saved = try decode(#"{"preferredQuality": "dolby", "sidebarCollapsed": true}"#)
        #expect(saved.preferredQuality == .default)
        #expect(saved.sidebarCollapsed)
    }
}
