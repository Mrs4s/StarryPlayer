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
    @State private var previewLayout = PreviewLayout.split
    @State private var confirmingApply = false
    @State private var appeared = false
    @State private var keyMonitor: Any?
    @State private var findingLyrics = false
    @State private var autoAlignment = LyricsEditorAutoAlignment()
    @State private var quickAlignment: LyricsEditorAlignmentState?
    @State private var aiTiming = LyricsEditorAITimingState()
    @AppStorage("starry.lyricsEditor.autoAlignAfterTiming") private var autoAlignAfterTiming = false
    @AppStorage("starry.lyricsEditor.splitOnsetHints") private var splitOnsetHints = false
    @AppStorage("starry.lyricsEditor.hintVoice") private var hintVoice = LyricsEditorAudio.HintVoice.all
    @AppStorage(LyricsEditorTimeline.gainKey) private var spectrogramGain = 3.0
    @AppStorage(LyricsEditorDock.timelineHeightKey) private var timelineHeight = LyricsEditorDock.defaultTimelineHeight

    private enum PreviewLayout: String, CaseIterable {
        case editor, split, preview

        var title: String {
            switch self {
            case .editor: "仅编辑"
            case .split: "分栏预览"
            case .preview: "全幅预览"
            }
        }

        var systemImage: String {
            switch self {
            case .editor: "text.alignleft"
            case .split: "sidebar.right"
            case .preview: "rectangle.inset.filled"
            }
        }
    }

    private var showPreview: Bool { previewLayout != .editor }
    private var focusPreview: Bool { previewLayout == .preview }

    enum Panel: Equatable {
        case importer, metadata, tracks, roles, shortcuts, translation, aiTiming, export
        case alignment(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if audio.status != .ready { audioBanner.transition(.move(edge: .top).combined(with: .opacity)) }
            GeometryReader { geo in
                let previewWidth = showPreview ? (focusPreview ? geo.size.width - 24 : max(min(geo.size.width * 0.4, 520), 320)) : 0
                HStack(spacing: 0) {
                    LyricsEditorLineList(session: session, clock: clock, canPlay: audio.isReady, appeared: appeared) { position in
                        play(from: position, preroll: 1)
                    } manageRoles: {
                        show(.roles)
                    }
                    .frame(width: max(geo.size.width - previewWidth - (showPreview ? 12 : 0), 0))
                    .opacity(focusPreview ? 0 : 1)
                    .offset(x: focusPreview && !reduceMotion ? -40 : 0)
                    .allowsHitTesting(!focusPreview)
                    if showPreview {
                        LyricsEditorPreview(session: session, audio: audio, clock: clock, isFocused: focusPreview, toggleFocus: togglePreviewFocus, close: togglePreview)
                            .frame(width: previewWidth)
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                            .transition(.opacity)
                    }
                }
            }
            LyricsEditorDock(session: session, audio: audio, clock: clock, tap: { tap() }, release: { release() }, manageTracks: { show(.tracks) }, alignLine: alignCurrentLine, manageRoles: { show(.roles) })
        }
        .disabled(panel != nil)
        .accessibilityHidden(panel != nil)
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
        .confirmationDialog(untimedTitle, isPresented: $confirmingApply) {
            Button("仍然应用") { apply() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("没打点的音节会按前后已打点的时间平均分配。")
        }
        .background {
            LyricsEditorClockDriver(session: session, audio: audio, clock: clock, ready: audio.isReady, playing: audio.isPlaying)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // The player started: the editor stops, so two songs never play at once.
        .onChange(of: model.player.isPlaying) { _, playing in
            if playing { audio.pause() }
        }
        .onAppear {
            installKeys()
            if session.draft.isEmpty { panel = .importer }
            withAnimation(Motion.reveal) { appeared = true }
        }
        .onChange(of: autoAlignAfterTiming) { _, enabled in
            if enabled, audio.isPrecise { audio.prepareVocals() }
            else { autoAlignment.cancelAll() }
        }
        .onAppear {
            if autoAlignAfterTiming, audio.isPrecise { audio.prepareVocals() }
        }
        .onChange(of: audio.isPrecise) { _, precise in
            if precise, autoAlignAfterTiming { audio.prepareVocals() }
        }
        .onDisappear {
            removeKeys()
            autoAlignment.cancelAll()
            quickAlignment?.cancel()
            aiTiming.dispose()
        }
    }

    @ViewBuilder
    private var panelView: some View {
        let close = { withAnimation(Motion.popover) { panel = nil } }
        switch panel {
        case .importer:
            LyricsEditorImport(session: session, close: close).transition(.opacity).zIndex(3)
        case .metadata:
            LyricsEditorMetadata(session: session, close: close).transition(.opacity).zIndex(3)
        case .tracks:
            LyricsEditorTracks(session: session, close: close).transition(.opacity).zIndex(3)
        case .roles:
            LyricsEditorRoles(session: session, clock: clock, play: { line in
                play(from: LyricsDraft.Position(line: line, syllable: 0), preroll: 1)
            }, close: close)
            .transition(.opacity).zIndex(3)
        case .shortcuts:
            LyricsEditorShortcuts(close: close).transition(.opacity).zIndex(3)
        case .translation:
            LyricsEditorTranslation(session: session, close: close).transition(.opacity).zIndex(3)
        case .aiTiming:
            LyricsEditorAITiming(session: session, audio: audio, state: aiTiming, close: close)
                .transition(.opacity).zIndex(3)
        case .export:
            LyricsEditorExport(session: session, close: close).transition(.opacity).zIndex(3)
        case .alignment(let id):
            if let line = session.draft.lines.first(where: { $0.id == id }) {
                LyricsEditorAlignment(session: session, audio: audio, line: line, close: close)
                    .id(id).transition(.opacity).zIndex(3)
            }
        case nil:
            EmptyView()
        }
    }

    private func show(_ panel: Panel) {
        quickAlignment?.cancel()
        if panel == .aiTiming { autoAlignment.cancelAll() }
        withAnimation(Motion.popover) { self.panel = panel }
    }

    private func alignCurrentLine() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let position = session.caret ?? session.lastStarted, session.draft.contains(position) else { return }
        show(.alignment(session.draft.lines[position.line].id))
    }

    private func quickAlignCurrentLine() {
        guard audio.isPrecise else { return session.flash("本曲暂时无法自动排字") }
        guard let position = session.caret ?? session.lastStarted, session.draft.contains(position) else { return }
        guard quickAlignment?.isWorking != true else { return session.flash("正在自动排字，请稍候") }
        let state = LyricsEditorAlignmentState(line: session.draft.lines[position.line], revision: session.revision,
                                               duration: audio.duration, playhead: audio.currentTime)
        quickAlignment = state
        state.analyze(applyingTo: session) { try await audio.alignmentAnalysis(in: $0.range, voice: $0.voice) }
    }

    private func setPreviewLayout(_ layout: PreviewLayout) {
        withAnimation(Motion.shelf) { previewLayout = layout }
    }

    private func togglePreview() {
        setPreviewLayout(showPreview ? .editor : .split)
    }

    private func togglePreviewFocus() {
        setPreviewLayout(focusPreview ? .split : .preview)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            documentHeader
            editorToolbar
        }
        .overlay(alignment: .bottom) { headerRule }
    }

    private var documentHeader: some View {
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
            .frame(maxWidth: 320, alignment: .leading)
            LyricsEditorProgress(timed: session.draft.timedCount, total: session.draft.syllableCount)
            Spacer(minLength: 12)
            exportButton
            PillButton(title: "应用到这首歌", systemName: "checkmark", variant: .filled, height: 30, action: requestApply)
                .disabled(session.draft.isEmpty)
                .opacity(session.draft.isEmpty ? 0.45 : 1)
                .help("播放这首歌时就显示编辑好的歌词（⌘S）")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background {
            Color.clear.contentShape(Rectangle()).modifier(WindowDrag())
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 12) {
            importMenu
            toolbarDivider
            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward", size: 30, iconSize: 13, help: "撤销（⌘Z）") { session.undo() }
                    .disabled(!session.canUndo)
                    .opacity(session.canUndo ? 1 : 0.4)
                    .accessibilityLabel("撤销")
                IconButton(systemName: "arrow.uturn.forward", size: 30, iconSize: 13, help: "重做（⇧⌘Z）") { session.redo() }
                    .disabled(!session.canRedo)
                    .opacity(session.canRedo ? 1 : 0.4)
                    .accessibilityLabel("重做")
            }
            PillButton(title: "AI 打轴", systemName: "wand.and.stars", variant: .tertiary, height: 30) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                show(.aiTiming)
            }
            .disabled(session.draft.isEmpty)
            .help("使用外置本地模型生成整首逐字时间")
            toolsMenu
            Spacer(minLength: 12)
            previewPicker
            toolbarDivider
            IconButton(systemName: "keyboard", size: 30, iconSize: 13, help: "快捷键（?）") { show(.shortcuts) }
                .accessibilityLabel("快捷键")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(theme.onSurface.opacity(0.025))
        .overlay(alignment: .top) { headerRule }
    }

    private var headerRule: some View {
        Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(height: 1)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(width: 1, height: 18)
            .accessibilityHidden(true)
    }

    private var previewPicker: some View {
        HStack(spacing: 2) {
            ForEach(PreviewLayout.allCases, id: \.self) { layout in
                Button { setPreviewLayout(layout) } label: {
                    Label(layout.title, systemImage: layout.systemImage)
                        .font(.system(size: 12, weight: previewLayout == layout ? .semibold : .medium))
                        .foregroundStyle(previewLayout == layout ? theme.primary : theme.onSurfaceVariant)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                }
                .buttonStyle(VariantButtonStyle(variant: .ghost, isActive: previewLayout == layout))
                .accessibilityAddTraits(previewLayout == layout ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(theme.onSurface.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.button + 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("预览布局")
    }

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(theme.primary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var importMenu: some View {
        PopMenu {
            PopMenuItem.button("导入歌词…", systemImage: "square.and.arrow.down") { show(.importer) }
            PopMenuItem.button(findingLyrics ? "正在查找歌词…" : "载入这首歌的歌词", systemImage: "text.quote", disabled: findingLyrics) { loadSongLyrics() }
            PopMenuItem.divider
            PopMenuItem.button("打开歌词工程…", systemImage: "folder") { model.openLyricsProject(into: session) }
        } label: {
            menuLabel("导入", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .help("导入歌词（⌘I）、载入歌曲歌词或打开工程（⌘O）")
    }

    private var exportButton: some View {
        PillButton(title: "导出…", systemName: "square.and.arrow.up", variant: .secondary, height: 30, action: showExport)
            .disabled(session.draft.isEmpty)
            .opacity(session.draft.isEmpty ? 0.45 : 1)
            .help("选择格式导出或拷贝歌词，导出前列出会丢失的内容（⌘E）；也可以保存歌词工程（⇧⌘S）")
    }

    private var subtitle: String {
        let artist = session.track.artistText
        if session.hasUnsavedChanges { return artist.isEmpty ? "有未保存的修改" : "\(artist) · 有未保存的修改" }
        return artist
    }

    private var toolsMenu: some View {
        PopMenu {
            PopMenuItem.button("歌曲信息…", systemImage: "info.circle") { show(.metadata) }
            PopMenuItem.button("虚拟轨…", systemImage: "rectangle.split.1x2") { show(.tracks) }
            PopMenuItem.button("演唱角色…", systemImage: "person.2") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                show(.roles)
            }
            PopMenuItem.button("AI 翻译与注音…", systemImage: "character.bubble", disabled: !session.draft.lines.contains(where: LyricsTranslation.isTranslatable)) {
                NSApp.keyWindow?.makeFirstResponder(nil)
                show(.translation)
            }
            PopMenuItem.submenu("日语音译", systemImage: "character.phonetic") {
                PopMenuItem.button(session.isGeneratingRomanization ? "正在生成音译…" : "补全整首日语音译", systemImage: "wand.and.stars", disabled: session.draft.isEmpty || session.isGeneratingRomanization) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { await session.generateJapaneseRomanization() }
                }
                PopMenuItem.button("重新生成整首音译（覆盖已有）", systemImage: "arrow.clockwise", disabled: session.draft.isEmpty || session.isGeneratingRomanization) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task { await session.generateJapaneseRomanization(overwrite: true) }
                }
                PopMenuItem.divider
                PopMenuItem.header("离线生成罗马音，特殊读法可手动校对")
            }
            PopMenuItem.divider
            PopMenuItem.submenu("打点设置", systemImage: "timer") {
                PopMenuItem.button("整体提前 0.1 秒", systemImage: "backward", disabled: session.draft.timedCount == 0) { session.edit { $0.shift(by: -0.1) } }
                PopMenuItem.button("整体延后 0.1 秒", systemImage: "forward", disabled: session.draft.timedCount == 0) { session.edit { $0.shift(by: 0.1) } }
                PopMenuItem.divider
                PopMenuItem.option("打完一行后自动排字", selected: autoAlignAfterTiming) {
                    autoAlignAfterTiming.toggle()
                    if !autoAlignAfterTiming { autoAlignment.cancelAll() }
                }
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
            }
            PopMenuItem.divider
            PopMenuItem.button("清除全部时间", systemImage: "eraser", role: .destructive, disabled: session.draft.timedCount == 0) {
                session.edit { draft in
                    for index in draft.lines.indices { draft.clearTiming(ofLine: index) }
                }
                session.caret = session.draft.firstPosition(fromLine: 0)
            }
        } label: {
            menuLabel("工具", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
        .help("歌曲信息、虚拟轨、演唱角色、翻译注音与打点设置")
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

    private func showExport() {
        guard !session.draft.isEmpty else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        show(.export)
    }

    private func requestApply() {
        guard !session.draft.isEmpty else { return }
        if session.draft.timedCount < session.draft.syllableCount {
            confirmingApply = true
        } else {
            apply()
        }
    }

    private func apply() {
        guard session.validateForExport() else { return }
        if model.applyEditedLyrics(session) {
            if session.draft.hasAuthoringTiming {
                session.flash("已应用播放歌词；多拍、休止及未完成时间请另存歌词工程")
            } else {
                session.flash(model.player.current?.id == session.track.id ? "已应用，播放页正在显示编辑好的歌词" : "已应用，播放这首歌时会显示编辑好的歌词")
            }
        } else {
            session.flash("没能应用这份歌词")
        }
    }

    private func saveProject() {
        guard !session.draft.isEmpty else { return }
        model.saveLyricsProject(session)
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
        if let line = session.tap(at: time(of: event), rate: audio.rate) { alignCompletedLine(line, endedByNextLine: true) }
    }

    private func release(_ event: NSEvent? = nil) {
        guard audio.isReady else { return session.flash("音频载入后才能跟着打点") }
        if let line = session.release(at: time(of: event), rate: audio.rate) { alignCompletedLine(line) }
    }

    private func alignCompletedLine(_ line: UUID, endedByNextLine: Bool = false) {
        guard autoAlignAfterTiming else { return }
        guard audio.isPrecise else { return session.flash("本曲暂时无法自动排字，已保留人工打点") }
        let voice = splitOnsetHints ? hintVoice : .all
        let editorAudio = audio
        autoAlignment.schedule(lineID: line, in: session, duration: audio.duration, endedByNextLine: endedByNextLine) {
            try await editorAudio.alignmentAnalysis(in: $0, voice: voice)
        }
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

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window?.identifier?.rawValue == AppModel.lyricsEditorIdentifier, !PopMenuController.isAnyOpen else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if panel != nil {
            if panel == .roles, flags.contains(.command), key == "z" {
                flags.contains(.shift) ? session.redo() : session.undo()
                return true
            }
            guard panel != .importer, event.keyCode == 53 else { return false }
            withAnimation(Motion.popover) { panel = nil }
            return true
        }
        if flags.contains(.command) {
            switch event.keyCode {
            case 36, 76: session.moveToNewLine(); return true                // ⌘↩
            case 126: session.moveToLine(by: -1); return true                // ⌘↑
            case 125: session.moveToLine(by: 1); return true                 // ⌘↓
            case 51: session.delete(); return true                           // ⌘⌫, as ⌫
            default: break
            }
            switch key {
            case "a": session.selectAll()
            case "z": flags.contains(.shift) ? session.redo() : session.undo()
            case "s": flags.contains(.shift) ? saveProject() : requestApply()
            case "e": showExport()
            case "i": show(.importer)
            case "o": model.openLyricsProject(into: session)
            default: return false
            }
            return true
        }
        guard !flags.contains(.control) else { return false }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let repeated = event.isARepeat
        switch event.keyCode {
        case 53 where !session.selection.isEmpty: session.clearSelection() // Esc
        case 49: if !repeated { audio.togglePlayPause() }                // Space
        case 36, 76: if !repeated { release(event) }                     // Return, Enter
        case 51 where shift: session.stepBack()                          // ⇧⌫
        case 51: session.delete()                                        // ⌫
        case 123 where option: session.nudge(by: shift ? -0.1 : -0.01)   // ⌥←
        case 124 where option: session.nudge(by: shift ? 0.1 : 0.01)     // ⌥→
        case 123 where shift: audio.seek(by: -3)                         // ⇧←
        case 124 where shift: audio.seek(by: 3)                          // ⇧→
        case 123: session.moveCaret(by: -1)                              // ←
        case 124: session.moveCaret(by: 1)                               // →
        case 126 where option: session.moveLine(by: -1)                  // ⌥↑
        case 125 where option: session.moveLine(by: 1)                   // ⌥↓
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
            case "l" where !shift && !option: if !repeated { quickAlignCurrentLine() }
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
