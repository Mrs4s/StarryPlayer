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

    func exportLyrics(_ session: LyricsEditorSession, format: LyricsExportFormat = .ttml) {
        let output: LyricsExport.Output
        do {
            guard let exported = try session.exportLyrics(format: format) else { return }
            output = exported
        } catch {
            session.flash("导出失败：\(error.localizedDescription)")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension, conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = session.exportFileName(for: format)
        panel.prompt = "导出"
        panel.message = "导出「\(session.track.title)」（\(format.title)）" + (output.losses.isEmpty ? "" : "\n此格式不保存：\(output.losses.map(\.title).joined(separator: "、"))。完整内容可保存为歌词工程。")
        let write: (NSApplication.ModalResponse) -> Void = { [weak session] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try output.text.write(to: url, atomically: true, encoding: .utf8)
                if format == .ttml || format == .ttml2, output.losses.isEmpty { session?.markSaved() }
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
        guard let text = session.exportTTML() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.flash("AMLL TTML 已拷贝")
    }

    // MARK: Projects

    // Declared with its extension in project.yml so file URLs and panels resolve the same type.
    static let lyricsProjectType = UTType(exportedAs: "moe.mrs4s.starry-player.lyrics-project", conformingTo: .json)
    static let lyricsImportTypes = LyricsFile.extensions.compactMap { UTType(filenameExtension: $0) } + [lyricsProjectType]

    func saveLyricsProject(_ session: LyricsEditorSession) {
        let data: Data
        do { data = try session.project.data() } catch {
            return session.flash("保存失败：\(error.localizedDescription)")
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.lyricsProjectType]
        panel.nameFieldStringValue = session.projectFileName
        panel.prompt = "保存"
        panel.message = "保存「\(session.track.title)」的歌词工程：没打点的音节和虚拟轨都会留着，之后打开接着编辑"
        runLyricsEditorPanel(panel) { [weak session] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                session?.markSaved()
                session?.flash("已保存「\(url.lastPathComponent)」")
            } catch {
                session?.flash("保存失败：\(error.localizedDescription)")
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

extension LyricsExportFormat {
    var title: String {
        switch self {
        case .ttml: "AMLL TTML"
        case .ttml2: "TTML2"
        case .lrcLine: "LRC · 逐行"
        case .lrcEnhanced: "LRC · 增强型"
        case .lrcWord: "LRC · 逐字"
        case .kra: "KRA"
        case .txt: "纯文本"
        case .txt2ass: "txt2ass"
        case .srt: "SRT"
        case .ass: "ASS · 卡拉 OK"
        case .nicokara: "Nicokara"
        case .nicokaraRuby: "Nicokara · 带注音"
        case .rl: "RL 编辑模式"
        case .kasugamuki: "春日向注音"
        case .krl: "Kirakara（KRL）"
        }
    }
}

private extension LyricsExport.Loss {
    var title: String {
        switch self {
        case .timing: "歌词时间"
        case .syllableTiming: "逐字时间"
        case .lineEndTiming: "重叠歌词的独立结束时间"
        case .translation: "翻译"
        case .romanization: "音译"
        case .ruby: "注音"
        case .sharedRuby: "跨音节的共享注音"
        case .agents: "角色信息"
        case .backgroundGrouping: "背景人声分组（会单独输出为歌词行）"
        case .metadata: "部分歌曲元数据"
        case .agentDetails: "角色 ID、类型、别名和扮演者关系（保留演唱名称）"
        case .editingState: "多拍、休止及未完成的时间编辑状态"
        }
    }
}
