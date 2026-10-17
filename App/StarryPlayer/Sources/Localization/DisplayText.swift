import Foundation
import SwiftUI

/// Interface copy stays localizable until display; names and other user/source content stay
/// verbatim. Deliberately has no implicit String conversion or localization-by-content.
enum DisplayText: Sendable, Equatable {
    case localized(LocalizedStringResource)
    case verbatim(String)

    func resolved(locale: Locale) -> String {
        switch self {
        case .localized(var resource):
            resource.locale = locale
            return String(localized: resource)
        case .verbatim(let value): return value
        }
    }
}

struct DisplayTextView: View {
    var text: DisplayText
    @Environment(\.locale) private var locale

    var body: some View {
        Text(verbatim: text.resolved(locale: locale))
    }
}
