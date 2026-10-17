import Foundation
import Library
import MusicSources
import Observation
import os
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LocalizationTests {
    private func localization(_ language: AppSettings.Language, preferred: [String] = ["en-US"], region: String = "en_GB") -> LocalizationStore {
        var settings = AppSettings()
        settings.language = language
        return LocalizationStore(settings: SettingsStore(inMemory: settings), preferredLanguages: { preferred }, systemLocale: { Locale(identifier: region) })
    }

    @Test func systemLanguageMatchesRegionsAndScripts() {
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["zh-CN"]) == .simplifiedChinese)
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["zh-Hans-SG"]) == .simplifiedChinese)
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["zh-TW", "en-US"]) == .english)
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["de-DE", "zh-Hans"]) == .simplifiedChinese)
        #expect(AppSettings.Language.system.resolved(preferredLanguages: ["ja-JP"]) == .english)
        #expect(AppSettings.Language.simplifiedChinese.resolved(preferredLanguages: ["en-US"]) == .simplifiedChinese)
    }

    @Test func resourcesUseTheSelectedLanguageAndContentStaysVerbatim() {
        let localization = localization(.english)
        let resource = SettingsCategory.general.title
        #expect(localization.string(resource) == "General")
        localization.language = .simplifiedChinese
        #expect(localization.string(resource) == "通用")
        #expect(localization.string(.verbatim("category.general")) == "category.general")
        #expect(localization.string(.verbatim("林晚风 & Alice")) == "林晚风 & Alice")
    }

    @Test func settingsSearchCountUsesEnglishPlurals() {
        let localization = localization(.english)
        for count in [0, 1, 2] {
            let resource = LocalizedStringResource("search.count", defaultValue: "\(count) 项", table: "Settings")
            #expect(localization.string(resource) == "\(count) \(count == 1 ? "result" : "results")")
            localization.language = .simplifiedChinese
            #expect(localization.string(resource) == "\(count) 项")
            localization.language = .english
        }
    }

    @Test func storedFailureChangesLanguageWithoutReloading() async {
        let localization = localization(.english)
        var calls = 0
        let state: Loadable<Int> = await Loadable.run {
            calls += 1
            throw SourceError.network("HTTP 503")
        }
        guard case .failed(let message) = state else {
            Issue.record("Expected a failed load")
            return
        }
        #expect(localization.string(message) == "Network error: HTTP 503")
        localization.language = .simplifiedChinese
        #expect(localization.string(message) == "网络错误：HTTP 503")
        #expect(calls == 1)
    }

    @Test func unknownErrorsAndMissingResourcesKeepTheirFallback() {
        let localization = localization(.english)
        #expect(localization.string(ErrorText.message(PlaybackError.unknown("Provider diagnostic"))) == "Provider diagnostic")
        #expect(localization.string(LocalizedStringResource("test.missing.resource", defaultValue: "Fallback copy")) == "Fallback copy")
        #expect(localization.string(ErrorText.message(PlaybackError.loginExpired)) == "Your session has expired. Please sign in again.")
    }

    @Test func formattingKeepsTheRegionWhileChangingLanguage() {
        let localization = localization(.simplifiedChinese, region: "en_GB")
        #expect(localization.formattingLocale.region?.identifier == "GB")
        #expect(localization.formattingLocale.language.languageCode?.identifier == "zh")
        localization.language = .english
        #expect(localization.formattingLocale.region?.identifier == "GB")
        #expect(localization.formattingLocale.language.languageCode?.identifier == "en")
    }

    @Test func unrelatedSettingsDoNotInvalidateLanguageConsumersAndResetIsObserved() async {
        var initial = AppSettings()
        initial.language = .english
        let settings = SettingsStore(inMemory: initial)
        let localization = LocalizationStore(settings: settings, preferredLanguages: { ["zh-Hans"] })
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = localization.locale
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        settings.settings.appearance = .dark
        for _ in 0..<5 { await Task.yield() }
        #expect(changes.withLock { $0 } == 0)
        settings.settings = AppSettings()
        for _ in 0..<5 { await Task.yield() }
        #expect(localization.language == .system)
        #expect(localization.locale.language.languageCode?.identifier == "zh")
        #expect(changes.withLock { $0 } == 1)
    }

    @Test func languageSelectionIsPersisted() throws {
        let name = "starry.localization.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let localization = LocalizationStore(settings: store)
        localization.language = .simplifiedChinese
        #expect(SettingsStore(defaults: defaults).settings.language == .simplifiedChinese)
    }
}
