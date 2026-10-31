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
        #expect(saved.language == .system)
        let partial = try decode(#"{"menuBarLyrics": {"enabled": true}}"#)
        #expect(partial.menuBarLyrics.enabled)
        #expect(partial.menuBarLyrics.perSyllable)
        #expect(partial.menuBarLyrics.maxWidth == 300)
    }

    @Test func lyricsSettingsSavedBeforeRubyKeepTheirValues() throws {
        var settings = AppSettings()
        settings.lyrics.showRomanization = true
        settings.lyrics.alignment = .center
        settings.lyrics.fontSize = 40
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var lyrics = try #require(object["lyrics"] as? [String: Any])
        lyrics["showRuby"] = nil
        object["lyrics"] = lyrics
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(saved.lyrics.showRomanization && saved.lyrics.alignment == .center && saved.lyrics.fontSize == 40)
        #expect(saved.lyrics.showRuby)
        settings.lyrics.showRuby = false
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func languagePreferencesRoundTripAndTolerateUnknownValues() throws {
        for language in AppSettings.Language.allCases {
            var settings = AppSettings()
            settings.language = language
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        }
        for value in ["\"future-language\"", "null", "42"] {
            let saved = try decode("{\"language\":\(value),\"sidebarCollapsed\":true}")
            #expect(saved.language == .system)
            #expect(saved.sidebarCollapsed)
        }
    }

    @Test func rubyOverlapPreferenceDefaultsOffAndPersistsIndependentlyOfNames() throws {
        let saved = try decode(#"{"lyrics":{"performerNames":false,"showRuby":true}}"#)
        #expect(!saved.lyrics.hideRubyUnderPerformerNames)
        #expect(!saved.lyrics.performerNames)
        #expect(saved.lyrics.showRuby)

        var settings = saved
        settings.lyrics.hideRubyUnderPerformerNames = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func desktopLyricsRoundTripAndFillGaps() throws {
        var settings = AppSettings()
        settings.desktopLyrics.enabled = true
        settings.desktopLyrics.locked = true
        settings.desktopLyrics.palette = .gold
        settings.desktopLyrics.background = .card
        settings.desktopLyrics.fontSize = 42
        settings.desktopLyrics.hidesFromCapture = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)

        let old = try decode(#"{"sidebarCollapsed": true}"#)
        #expect(old.desktopLyrics == AppSettings.DesktopLyrics())
        let partial = try decode(#"{"desktopLyrics": {"enabled": true, "palette": "neon"}}"#)
        var expected = AppSettings.DesktopLyrics()
        expected.enabled = true
        #expect(partial.desktopLyrics == expected)
        #expect(try decode(#"{"desktopLyrics": 3}"#).desktopLyrics == AppSettings.DesktopLyrics())
    }

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
