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

    func saveExportedLyrics(_ output: LyricsExport.Output, format: LyricsExportFormat, from session: LyricsEditorSession, completion: @escaping (Bool) -> Void = { _ in }) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension, conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = session.exportFileName(for: format)
        panel.prompt = "导出"
        panel.message = "导出「\(session.track.title)」（\(format.title)）"
        runLyricsEditorPanel(panel) { [weak session] response in
            guard response == .OK, let url = panel.url else { return completion(false) }
            do {
                try output.text.write(to: url, atomically: true, encoding: .utf8)
                if format == .ttml || format == .ttml2, output.losses.isEmpty { session?.markSaved() }
                session?.flash("已导出「\(url.lastPathComponent)」")
                completion(true)
            } catch {
                session?.flash("导出失败：\(error.localizedDescription)")
                completion(false)
            }
        }
    }

    // MARK: Projects

    // Declared with its extension in project.yml so file URLs and panels resolve the same type.
    static let lyricsProjectType = UTType(exportedAs: "moe.mrs4s.starry-player.lyrics-project", conformingTo: .json)
    static let lyricsImportTypes = LyricsFile.extensions.compactMap { UTType(filenameExtension: $0) } + [lyricsProjectType]

    func saveLyricsProject(_ session: LyricsEditorSession, completion: @escaping (Bool) -> Void = { _ in }) {
        let data: Data
        do { data = try session.project.data() } catch {
            session.flash("保存失败：\(error.localizedDescription)")
            return completion(false)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.lyricsProjectType]
        panel.nameFieldStringValue = session.projectFileName
        panel.prompt = "保存"
        panel.message = "保存「\(session.track.title)」的歌词工程：没打点的音节和虚拟轨都会留着，之后打开接着编辑"
        runLyricsEditorPanel(panel) { [weak session] response in
            guard response == .OK, let url = panel.url else { return completion(false) }
            do {
                try data.write(to: url, options: .atomic)
                session?.markSaved()
                session?.flash("已保存「\(url.lastPathComponent)」")
                completion(true)
            } catch {
                session?.flash("保存失败：\(error.localizedDescription)")
                completion(false)
            }
        }
    }

    func openLyricsProject(into session: LyricsEditorSession, onOpen: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.lyricsProjectType]
        panel.prompt = "打开"
        panel.message = "打开歌词工程，会替换现在的歌词，可以撤销"
        runLyricsEditorPanel(panel) { [weak self, weak session] response in
            guard response == .OK, let url = panel.url, let session else { return }
            if self?.readLyricsProject(at: url, into: session) == true { onOpen() }
        }
    }

    @discardableResult
    func readLyricsProject(at url: URL, into session: LyricsEditorSession) -> Bool {
        let name = url.lastPathComponent
        do {
            let project = try LyricsProject(data: Data(contentsOf: url))
            session.open(project)
            let other = project.title.isEmpty || project.title == session.track.title ? "" : "，它原本是「\(project.title)」的工程"
            session.flash("已打开「\(name)」\(other)")
            return true
        } catch LyricsProject.ReadError.newerVersion {
            session.flash("「\(name)」由更新的版本保存，更新后才能打开")
        } catch {
            session.flash("「\(name)」不是可用的歌词工程")
        }
        return false
    }

    private func runLyricsEditorPanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = lyricsEditorWindow.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
