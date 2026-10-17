import Foundation
import Library

extension AppSettings.Language {
    /// Match supported languages, keeping Simplified and Traditional Chinese distinct.
    func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            switch language.languageCode?.identifier {
            case "en": return .english
            case "zh" where language.script?.identifier != "Hant": return .simplifiedChinese
            default: continue
            }
        }
        return .english
    }

    var nativeName: String? {
        switch self {
        case .system: nil
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}
