import AppKit
import LyricsCore
import StarryCore
import SwiftUI

struct LyricsEditorView: View {
    static let defaultContentSize = NSSize(width: 1440, height: 960)

    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = LyricsEditorClock()
    @State private var panel: Panel?
    @State private var focusPreview = false
    @State private var pendingAction: PendingAction?
    @State private var appeared = false
    @State private var keyMonitor: Any?
    @State private var findingLyrics = false
    @AppStorage(LyricsEditorTimeline.gainKey) private var spectrogramGain = 3.0
    @AppStorage(LyricsEditorDock.timelineHeightKey) private var timelineHeight = LyricsEditorDock.defaultTimelineHeight

    private enum PendingAction: Identifiable {
        case export, apply
        var id: Self { self }
    }

    enum Panel {
        case importer, metadata, shortcuts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if audio.status != .ready { audioBanner.transition(.move(edge: .top).combined(with: .opacity)) }
            GeometryReader { geo in
                let previewWidth = focusPreview ? geo.size.width - 24 : max(min(geo.size.width * 0.4, 520), 320)
                HStack(spacing: 0) {
                    LyricsEditorLineList(session: session, clock: clock, canPlay: audio.isReady, appeared: appeared) { position in
                        play(from: position, preroll: 1)
                    }
                    .frame(width: max(geo.size.width - previewWidth - 12, 0))
                    .opacity(focusPreview ? 0 : 1)
                    .offset(x: focusPreview && !reduceMotion ? -40 : 0)
                    .allowsHitTesting(!focusPreview)
                    LyricsEditorPreview(session: session, audio: audio, clock: clock, isFocused: focusPreview) {
                        withAnimation(Motion.shelf) { focusPreview.toggle() }
                    }
                    .frame(width: previewWidth)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                }
            }
            LyricsEditorDock(session: session, audio: audio, clock: clock, tap: { tap() }, release: { release() })
        }
        .frame(minWidth: 960, idealWidth: Self.defaultContentSize.width, maxWidth: .infinity, minHeight: 680, idealHeight: Self.defaultContentSize.height, maxHeight: .infinity)
        .background(theme.surface.ignoresSafeArea())
        .overlay { panelView }
        .overlay(alignment: .bottom) {
            if let text = session.flashText {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .glassPanel(radius: 19)
                    .padding(.bottom, LyricsEditorDock.height(timeline: timelineHeight) + 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.popover, value: audio.status)
        .confirmationDialog(untimedTitle, isPresented: Binding { pendingAction != nil } set: { if !$0 { pendingAction = nil } }, presenting: pendingAction) { action in
            Button(action == .export ? "仍然导出" : "仍然应用") { perform(action) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("没打点的音节会按前后已打点的时间平均分配。")
        }
        .task(id: audio.isReady) { await runClock() }
        // The player started: the editor stops, so two songs never play at once.
        .onChange(of: model.player.isPlaying) { _, playing in
            if playing { audio.pause() }
        }
        .onAppear {
            installKeys()
            if session.draft.isEmpty { panel = .importer }
            withAnimation(Motion.reveal) { appeared = true }
        }
        .onDisappear(perform: removeKeys)
    }

    @ViewBuilder
    private var panelView: some View {
        let close = { withAnimation(Motion.popover) { panel = nil } }
        switch panel {
        case .importer:
            LyricsEditorImport(session: session, close: close).transition(.opacity).zIndex(3)
        case .metadata:
            LyricsEditorMetadata(session: session, close: close).transition(.opacity).zIndex(3)
        case .shortcuts:
            LyricsEditorShortcuts(close: close).transition(.opacity).zIndex(3)
        case nil:
            EmptyView()
        }
    }

    private func show(_ panel: Panel) {
        withAnimation(Motion.popover) { self.panel = panel }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: session.track.artwork, radius: 6, pixelSize: 96)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: 240, alignment: .leading)
            LyricsEditorProgress(timed: session.draft.timedCount, total: session.draft.syllableCount)
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward", size: 30, iconSize: 13, help: "撤销（⌘Z）") { session.undo() }
                    .disabled(!session.canUndo)
                    .opacity(session.canUndo ? 1 : 0.4)
                IconButton(systemName: "arrow.uturn.forward", size: 30, iconSize: 13, help: "重做（⇧⌘Z）") { session.redo() }
                    .disabled(!session.canRedo)
                    .opacity(session.canRedo ? 1 : 0.4)
                IconButton(systemName: "keyboard", size: 30, iconSize: 13, help: "快捷键（?）") { show(.shortcuts) }
            }
            PillButton(title: "导入", systemName: "square.and.arrow.down", variant: .tertiary, height: 30) { show(.importer) }
                .help("粘贴或打开歌词，快速分好音节")
            moreMenu
            IconButton(systemName: focusPreview ? "rectangle.split.2x1" : "rectangle.inset.filled", size: 30, iconSize: 13, isActive: focusPreview, help: focusPreview ? "回到编辑" : "全幅预览") {
                withAnimation(Motion.shelf) { focusPreview.toggle() }
            }
            PillButton(title: "导出 TTML…", systemName: "square.and.arrow.up", variant: .secondary, height: 30) { request(.export) }
                .disabled(session.draft.isEmpty)
                .opacity(session.draft.isEmpty ? 0.45 : 1)
                .help("导出为 TTML 文件（⌘E）")
            PillButton(title: "应用到这首歌", systemName: "checkmark", variant: .filled, height: 30) { request(.apply) }
                .disabled(session.draft.isEmpty)
                .opacity(session.draft.isEmpty ? 0.45 : 1)
                .help("播放这首歌时就显示编辑好的歌词（⌘S）")
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 56)
        .background {
            Color.clear.contentShape(Rectangle()).modifier(WindowDrag())
        }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(height: 1) }
    }

    private var subtitle: String {
        let artist = session.track.artistText
        if session.hasUnsavedChanges { return artist.isEmpty ? "有未应用的修改" : "\(artist) · 有未应用的修改" }
        return artist
    }

    private var moreMenu: some View {
        PopMenu {
            PopMenuItem.button(findingLyrics ? "正在查找歌词…" : "载入这首歌的歌词", systemImage: "text.quote", disabled: findingLyrics) { loadSongLyrics() }
            PopMenuItem.button("歌曲信息…", systemImage: "info.circle") { show(.metadata) }
            PopMenuItem.divider
            PopMenuItem.button("整体提前 0.1 秒", systemImage: "backward") { session.edit { $0.shift(by: -0.1) } }
            PopMenuItem.button("整体延后 0.1 秒", systemImage: "forward") { session.edit { $0.shift(by: 0.1) } }
            PopMenuItem.submenu("打点补偿", systemImage: "timer", detail: LyricsEditorFormat.lead(session.tapLead)) {
                for lead in [0, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2] {
                    PopMenuItem.option(LyricsEditorFormat.lead(lead), selected: abs(session.tapLead - lead) < 0.001) { session.tapLead = lead }
                }
            }
            PopMenuItem.submenu("频谱亮度", systemImage: "sun.max", detail: LyricsEditorFormat.gain(spectrogramGain)) {
                for gain in LyricsEditorTimeline.gains {
                    PopMenuItem.option(LyricsEditorFormat.gain(gain), selected: abs(spectrogramGain - gain) < 0.001) { spectrogramGain = gain }
                }
            }
            PopMenuItem.divider
            PopMenuItem.button("拷贝 TTML", systemImage: "doc.on.doc", disabled: session.draft.isEmpty) { model.copyLyrics(session) }
            PopMenuItem.button("清除全部时间", systemImage: "eraser", role: .destructive, disabled: session.draft.timedCount == 0) {
                session.edit { draft in
                    for index in draft.lines.indices { draft.clearTiming(ofLine: index) }
                }
                session.caret = session.draft.firstPosition(fromLine: 0)
            }
        } label: { open in
            PopMenuEllipsis(isOpen: open, size: 13, weight: .semibold)
                .foregroundStyle(theme.onSurface.opacity(0.85))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true))
        .help("更多")
    }

    private var audioBanner: some View {
        HStack(spacing: 10) {
            switch audio.status {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#E5A23A"))
                Text("\(message)。歌词仍可编辑和导出，只是没法跟着打点。")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                PillButton(title: "重试", systemName: "arrow.clockwise", variant: .secondary, height: 26) { audio.retry() }
            case .loading(let message):
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
            default:
                Spacer(minLength: 8)
            }
        }
        .foregroundStyle(theme.onSurface.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.primary.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(height: 1) }
    }

    // MARK: Actions

    private var untimedTitle: String {
        "还有 \(session.draft.syllableCount - session.draft.timedCount) 个音节没有打点"
    }

    private func request(_ action: PendingAction) {
        guard !session.draft.isEmpty else { return }
        if session.draft.timedCount < session.draft.syllableCount {
            pendingAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .export:
            model.exportLyrics(session)
        case .apply:
            if model.applyEditedLyrics(session) {
                session.flash(model.player.current?.id == session.track.id ? "已应用，播放页正在显示编辑好的歌词" : "已应用，播放这首歌时会显示编辑好的歌词")
            } else {
                session.flash("没能应用这份歌词")
            }
        }
    }

    private func loadSongLyrics() {
        findingLyrics = true
        Task {
            let draft = await model.findLyricsDraft(for: session.track)
            findingLyrics = false
            if let draft {
                session.replace(with: draft)
                session.flash("已载入这首歌的歌词")
            } else {
                session.flash("没找到这首歌的歌词")
            }
        }
    }

    /// The song's position when `event` happened: the key was pressed a moment before it is
    /// handled, more so while the main thread is busy.
    private func time(of event: NSEvent?) -> TimeInterval {
        let (time, rate) = audio.clock()
        guard let event, rate > 0 else { return time }
        let lag = min(max(ProcessInfo.processInfo.systemUptime - event.timestamp, 0), 0.25)
        return max(0, time - lag * rate)
    }

    private func tap(_ event: NSEvent? = nil) {
        guard audio.isReady else { return session.flash("音频载入后才能跟着打点") }
        session.tap(at: time(of: event), rate: audio.rate)
    }

    private func release(_ event: NSEvent? = nil) {
        guard audio.isReady else { return session.flash("音频载入后才能跟着打点") }
        session.release(at: time(of: event), rate: audio.rate)
    }

    private func play(from position: LyricsDraft.Position, preroll: TimeInterval = 0) {
        guard audio.isReady else { return session.flash("音频载入后才能试听") }
        guard let start = session.playbackStart(of: position) else { return }
        audio.play(from: max(0, start - preroll))
    }

    private func moveAndPlay(by step: Int) {
        session.moveCaret(by: step)
        if let caret = session.caret { play(from: caret) }
    }

    private func moveInLineAndPlay(last: Bool) {
        guard let line = (session.caret ?? session.lastStarted)?.line, session.draft.lines.indices.contains(line) else { return }
        let count = session.draft.lines[line].syllables.count
        guard count > 0 else { return }
        let position = LyricsDraft.Position(line: line, syllable: last ? count - 1 : 0)
        session.caret = position
        play(from: position)
    }

    private func runClock() async {
        guard audio.isReady else {
            clock.cancelScrubbing()
            clock.sample(time: 0, playing: false, ranges: [])
            return
        }
        var revision = -1
        var ranges: [ClosedRange<TimeInterval>?] = []
        while !Task.isCancelled {
            let sample = audio.clock()
            let playing = sample.rate > 0
            if revision != session.revision {
                revision = session.revision
                ranges = session.timedRanges
            }
            clock.sample(time: sample.time, playing: playing, ranges: ranges)
            try? await Task.sleep(for: .milliseconds(playing ? 16 : 100))
        }
    }

    // MARK: Keys

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the editor consumes the key; ignores keys while text is being edited.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window?.identifier?.rawValue == AppModel.lyricsEditorIdentifier, !PopMenuController.isAnyOpen else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if panel != nil {
            guard panel != .importer, event.keyCode == 53 else { return false }
            withAnimation(Motion.popover) { panel = nil }
            return true
        }
        if flags.contains(.command) {
            switch key {
            case "z": flags.contains(.shift) ? session.redo() : session.undo()
            case "s": request(.apply)
            case "e": request(.export)
            case "i": show(.importer)
            default: return false
            }
            return true
        }
        guard !flags.contains(.control) else { return false }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let repeated = event.isARepeat
        switch event.keyCode {
        case 49: if !repeated { audio.togglePlayPause() }                // Space
        case 36, 76: if !repeated { release(event) }                     // Return, Enter
        case 51: session.stepBack()                                      // ⌫
        case 123 where option: session.nudge(by: shift ? -0.1 : -0.01)   // ⌥←
        case 124 where option: session.nudge(by: shift ? 0.1 : 0.01)     // ⌥→
        case 123 where shift: audio.seek(by: -3)                         // ⇧←
        case 124 where shift: audio.seek(by: 3)                          // ⇧→
        case 123: session.moveCaret(by: -1)                              // ←
        case 124: session.moveCaret(by: 1)                               // →
        case 126: session.moveCaretLine(by: -1)                          // ↑
        case 125: session.moveCaretLine(by: 1)                           // ↓
        case 115: moveInLineAndPlay(last: false)                         // Home
        case 119: moveInLineAndPlay(last: true)                          // End
        default:
            switch key {
            case "f", "g", "j": if !repeated { tap(event) }
            case "h", "k": if !repeated { release(event) }
            case "a": session.moveCaret(by: -1)
            case "d": session.moveCaret(by: 1)
            case "w": session.moveCaretLine(by: -1)
            case "s": session.moveCaretLine(by: 1)
            case "r": moveAndPlay(by: -1)
            case "y": moveAndPlay(by: 1)
            case "q": if let caret = session.caret ?? session.lastStarted { play(from: LyricsDraft.Position(line: caret.line, syllable: 0), preroll: 1) }
            case "p": audio.togglePlayPause()
            case "[": audio.stepRate(-1)
            case "]": audio.stepRate(1)
            case "'": audio.setRate(1)
            case "/", "?": show(.shortcuts)
            default: return false
            }
        }
        return true
    }
}

private struct LyricsEditorProgress: View {
    var timed: Int
    var total: Int
    @Environment(\.theme) private var theme

    var body: some View {
        if total > 0 {
            let fraction = Double(timed) / Double(total)
            HStack(spacing: 8) {
                Capsule()
                    .fill(theme.onSurface.opacity(0.1))
                    .frame(width: 72, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(timed == total ? Color(hex: theme.isDark ? "#5FD08A" : "#2E9D5B") : theme.primary)
                            .frame(width: max(5, 72 * fraction), height: 5)
                    }
                Text("\(timed)/\(total)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.numericText(value: Double(timed)))
            }
            .animation(Motion.selection, value: timed)
            .help("已打点的音节")
            .transition(.opacity)
        }
    }
}
