import MusicSources
import StarryCore
import SwiftUI

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(DisplayText)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    @MainActor
    static func run(_ operation: @MainActor () async throws -> Value) async -> Loadable<Value> {
        do {
            return .loaded(try await operation())
        } catch {
            return .failed(ErrorText.message(error))
        }
    }
}

struct AsyncContent<Value, Content: View>: View {
    var state: Loadable<Value>
    var retry: (() -> Void)? = nil
    @ViewBuilder var content: (Value) -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                DisplayTextView(text: .localized(LocalizedStringResource("common.loading", defaultValue: "加载中…"))).font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", localizedTitle: LocalizedStringResource("common.loadFailed", defaultValue: "加载失败"), detail: message)
                    .frame(minHeight: 0)
                if let retry {
                    PillButton(localizedTitle: LocalizedStringResource("common.retry", defaultValue: "重试"), systemName: "arrow.clockwise", variant: .tertiary, action: retry)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded(let value):
            content(value)
        }
    }
}
