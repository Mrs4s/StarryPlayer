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
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuAction.item(model.showsDesktopLyrics ? "隐藏桌面歌词" : "显示桌面歌词", symbol: nil) { model.showsDesktopLyrics.toggle() })
        if model.showsDesktopLyrics {
            menu.addItem(MenuAction.item(model.desktopLyricsLocked ? "解锁桌面歌词" : "锁定桌面歌词", symbol: nil) { model.desktopLyricsLocked.toggle() })
        }
        return menu
    }

    @MainActor
    private func flush() {
        guard let model, !waiting.isEmpty else { return }
        let urls = waiting
        waiting = []
        model.open(urls)
    }
}
