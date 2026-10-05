import AppKit
import LyricsUI
import SwiftUI

/// The line being sung, lit syllable by syllable (`MenuBarLyricsView`): the comments' way back to
/// the lyrics, the open notch player.
struct OneLineLyrics: NSViewRepresentable {
    var tint: Color
    var fontSize: CGFloat
    var width: CGFloat
    /// The song's title and artist between lines; off shows nothing there (the title is already
    /// beside it).
    var showsSongWhenIdle = true
    @Environment(AppModel.self) private var model

    @MainActor final class Coordinator: NSObject {
        weak var view: MenuBarLyricsView?
        var timer: Timer?

        @objc func tick() { view?.sync() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuBarLyricsView {
        let view = MenuBarLyricsView(frame: .zero)
        let player = model.player
        view.timeSource = { [player] in player.preciseClock() }
        context.coordinator.view = view
        context.coordinator.timer = Timer.scheduledTimer(timeInterval: 2, target: context.coordinator, selector: #selector(Coordinator.tick), userInfo: nil, repeats: true)
        return view
    }

    func updateNSView(_ view: MenuBarLyricsView, context: Context) {
        let player = model.player
        let track = player.current
        view.font = .systemFont(ofSize: fontSize, weight: .semibold)
        view.textColor = NSColor(tint)
        view.maxTextWidth = max(width - 4, 60)
        view.timeOffset = -player.lyricOffset
        let song = showsSongWhenIdle ? track : nil
        view.content = MenuBarLyricsView.Content(document: player.lyrics, duration: player.duration, title: song?.title ?? "", artist: song?.artistText ?? "")
        _ = player.isPlaying
        _ = player.seekSerial
        view.sync()
    }

    static func dismantleNSView(_ view: MenuBarLyricsView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }
}
