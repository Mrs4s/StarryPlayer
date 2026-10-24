import AppKit
import Library
import LyricsCore
import LyricsUI
import StarryCore
import SwiftUI
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorPreviewLayoutTests {
    @Test(arguments: [false, true], [false, true])
    func resizingKeepsLyricsInsideThePreviewViewport(hasArtwork: Bool, isFocused: Bool) async throws {
        let model = AppModel(launch: LaunchOptions(settings: SettingsStore(inMemory: AppSettings()), sources: []))
        let track = Track(id: TrackRef(source: .local, id: "preview-layout"), title: "Preview", duration: 30, artwork: hasArtwork ? Artwork(seed: "preview-layout") : nil)
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: String(repeating: "歌词预览 ", count: 30), start: 1, end: 4)])])
        let session = LyricsEditorSession(track: track, draft: draft)
        let view = LyricsEditorPreview(session: session, audio: LyricsEditorAudio(), clock: LyricsEditorClock(), isFocused: isFocused, toggleFocus: {}, close: {})
            .environment(model)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for size in [NSSize(width: 520, height: 420), NSSize(width: 384, height: 720), NSSize(width: 520, height: 800), NSSize(width: 1000, height: 480), NSSize(width: 384, height: 500)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let lyrics = try #require(descendants(of: host).first { $0 is LyricsView })
            let frame = host.convert(lyrics.bounds, from: lyrics)
            #expect(abs(frame.minX) < 1)
            #expect(abs(frame.minY) < 1)
            #expect(abs(frame.width - size.width) < 1)
            #expect(abs(frame.height - size.height) < 1)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
