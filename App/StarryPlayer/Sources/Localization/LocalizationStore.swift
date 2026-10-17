import Foundation
import Library
import Observation
import SwiftUI

/// Only language changes invalidate consumers such as Commands. Other settings and playback
/// updates never enter this observable object's state.
@MainActor
@Observable
final class LocalizationStore {
    var language: AppSettings.Language {
        didSet {
            guard language != oldValue else { return }
            if settings.settings.language != language { settings.settings.language = language }
            refreshSystemLocale()
        }
    }
    private(set) var locale: Locale
    private(set) var formattingLocale: Locale

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let preferredLanguages: () -> [String]
    @ObservationIgnored private let systemLocale: () -> Locale

    init(settings: SettingsStore, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }, systemLocale: @escaping () -> Locale = { .current }) {
        self.settings = settings
        self.preferredLanguages = preferredLanguages
        self.systemLocale = systemLocale
        let selectedLanguage = settings.settings.language
        let selectedLocale = Locale(identifier: selectedLanguage.resolved(preferredLanguages: preferredLanguages()).rawValue)
        language = selectedLanguage
        locale = selectedLocale
        formattingLocale = selectedLocale
        refreshSystemLocale()
        observeSettings()
    }

    func refreshSystemLocale() {
        let selected = language.resolved(preferredLanguages: preferredLanguages())
        let nextLocale = Locale(identifier: selected.rawValue)
        var components = Locale.Components(identifier: systemLocale().identifier)
        let region = components.languageComponents.region
        components.languageComponents = Locale.Language.Components(identifier: selected.rawValue)
        components.languageComponents.region = region
        let nextFormattingLocale = Locale(components: components)
        if locale != nextLocale { locale = nextLocale }
        if formattingLocale != nextFormattingLocale { formattingLocale = nextFormattingLocale }
    }

    func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    func string(_ text: DisplayText) -> String {
        text.resolved(locale: locale)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings.language
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.language = self.settings.settings.language
                self.observeSettings()
            }
        }
    }
}

/// Apply this at every independently created NSHostingView/NSHostingController root.
struct AppLocalization: ViewModifier {
    let localization: LocalizationStore

    func body(content: Content) -> some View {
        content
            .environment(localization)
            .environment(\.locale, localization.locale)
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                localization.refreshSystemLocale()
            }
    }
}
