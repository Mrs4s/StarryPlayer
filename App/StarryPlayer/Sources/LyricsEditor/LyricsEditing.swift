import AppKit
import LyricsCore
import LyricsProviders
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

extension AppModel {
    func presentLyricsEditor(for track: Track) {
        if lyricsEditorWindow.isOpen, lyricsEditorTrack == track.id {
            lyricsEditorWindow.bringToFront()
            return
        }
        let session = lyricsEditorSessions[track.id] ?? LyricsEditorSession(track: track)
        lyricsEditorSessions[track.id] = session
        let audio = lyricsEditorAudio ?? makeLyricsEditorAudio()
        lyricsEditorTrack = track.id
        // Opening another song closes the window first, which runs its own `onClose`.
        lyricsEditorWindow.show(title: "歌词编辑器", model: self, resizable: true, initialContentSize: LyricsEditorView.defaultContentSize, centerOnScreen: true) { [weak self] in
            guard let self, lyricsEditorTrack == track.id else { return }
            lyricsEditorTrack = nil
            lyricsEditorAudio?.stop()
        } content: {
            LyricsEditorView(session: session, audio: audio)
        }
        audio.load(track)
    }

    private func makeLyricsEditorAudio() -> LyricsEditorAudio {
        let audio = LyricsEditorAudio()
        audio.resolve = { [weak self] track in
            guard let resolve = self?.player.resolveAsset else { throw PlaybackError.sourceUnreachable }
            return try await resolve(track, nil)
        }
        audio.willPlay = { [weak self] in self?.player.pause() }
        audio.setVolume(player.volume)
        audio.vocalModel = vocalModel
        audio.setOutputDevice(player.engine.outputDeviceUID)
        lyricsEditorAudio = audio
        return audio
    }

    func currentLyricsDraft(for track: Track) -> LyricsDraft? {
        guard player.current?.id == track.id, let lyrics = player.lyrics, !lyrics.isEmpty else { return nil }
        let draft = LyricsDraft(document: lyrics)
        return draft.isEmpty ? nil : draft
    }

    func findLyricsDraft(for track: Track) async -> LyricsDraft? {
        if let current = currentLyricsDraft(for: track) { return current }
        guard let stream = player.loadLyrics?(track) else { return nil }
        var best: LyricsDocument?
        for await result in stream where !result.document.isEmpty { best = result.document }
        guard let best else { return nil }
        let draft = LyricsDraft(document: best)
        return draft.isEmpty ? nil : draft
    }

    func exportLyrics(_ session: LyricsEditorSession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ttml") ?? .xml]
        panel.nameFieldStringValue = session.exportFileName
        panel.prompt = "导出"
        panel.message = "导出「\(session.track.title)」的逐字歌词（TTML）"
        let text = session.ttml()
        let write: (NSApplication.ModalResponse) -> Void = { [weak session] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                session?.markSaved()
                session?.flash("已导出「\(url.lastPathComponent)」")
            } catch {
                session?.flash("导出失败：\(error.localizedDescription)")
            }
        }
        if let window = lyricsEditorWindow.window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }

    func copyLyrics(_ session: LyricsEditorSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.ttml(), forType: .string)
        session.flash("TTML 已拷贝")
    }
}
