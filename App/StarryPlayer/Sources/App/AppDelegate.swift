import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel? {
        didSet { flush() }
    }

    @MainActor private var waiting: [URL] = []

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        waiting += urls.filter(\.isFileURL)
        flush()
    }

    @MainActor
    private func flush() {
        guard let model, !waiting.isEmpty else { return }
        let urls = waiting
        waiting = []
        model.open(urls)
    }
}
