import AppKit
import LyricsCore
import SwiftUI

struct LyricsEditorLineList: View {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    var canPlay: Bool
    var appeared: Bool
    var playFrom: (LyricsDraft.Position) -> Void
    var manageRoles: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(LocalizationStore.self) private var localization

    var body: some View {
        LyricsEditorLinesHost(session: session, clock: clock, localization: localization, revision: session.revision,
                              caret: session.caret, selection: session.selection, editingLine: session.editingLine,
                              lastTapped: session.lastTapped, tapSerial: session.tapSerial,
                              canPlay: canPlay, theme: theme, playFrom: playFrom, manageRoles: manageRoles)
            .opacity(appeared ? 1 : 0)
            .overlay {
                if session.draft.lines.isEmpty {
                    StateView(systemName: "text.badge.plus", title: "还没有歌词", detail: "点「导入」粘贴歌词，或打开歌词文件")
                }
            }
    }
}

private struct LyricsEditorLinesHost: NSViewRepresentable {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    let localization: LocalizationStore
    var revision: Int
    var caret: LyricsDraft.Position?
    var selection: Set<UUID>
    var editingLine: UUID?
    var lastTapped: UUID?
    var tapSerial: Int
    var canPlay: Bool
    var theme: Theme
    var playFrom: (LyricsDraft.Position) -> Void
    var manageRoles: () -> Void

    func makeNSView(context: Context) -> LyricsEditorListView { LyricsEditorListView() }

    func updateNSView(_ view: LyricsEditorListView, context: Context) {
        view.configure(session: session, clock: clock, localization: localization, theme: theme, canPlay: canPlay, playFrom: playFrom, manageRoles: manageRoles)
    }

    static func dismantleNSView(_ view: LyricsEditorListView, coordinator: ()) { view.disconnect() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LyricsEditorListView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Timing/selection changes retain text layout; scrolling only reuses visible native rows.
final class LyricsEditorListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let selection = LyricsEditorCaret()
    private let popMenu = PopMenuController()
    private var localization: LocalizationStore?
    private var session: LyricsEditorSession?
    private var clock: LyricsEditorClock?
    private var clockToken: UUID?
    private var lines: [LyricsDraft.Line] = []
    private var agents: [LyricAgent] = []
    private var layouts: [UUID: LyricsEditorLineLayout] = [:]
    private var revision = -1
    private var caret: LyricsDraft.Position?
    private var editingLine: UUID?
    private var clickedLine: UUID?
    private var measuredWidth: CGFloat = 0
    private var theme = Theme.darkBase
    private var canPlay = false
    private var playFrom: ((LyricsDraft.Position) -> Void)?
    private var manageRoles: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.wantsLayer = true
        table.layer?.addSublayer(selection.layer)
        let column = NSTableColumn(identifier: .init("lyrics"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 1
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 14, y: 0, width: max(1, bounds.width - 28), height: bounds.height)
        let width = max(1, scroll.contentSize.width)
        guard abs(width - measuredWidth) > 0.5 else { return }
        measuredWidth = width
        table.tableColumns.first?.width = width
        updateLayouts()
        refreshVisible()
        updateSelection(animated: false)
    }

    func configure(session: LyricsEditorSession, clock: LyricsEditorClock, localization: LocalizationStore, theme: Theme, canPlay: Bool,
                   playFrom: @escaping (LyricsDraft.Position) -> Void, manageRoles: @escaping () -> Void = {}) {
        self.localization = localization
        let replaced = self.session !== session
        if replaced { selection.reset() }
        if self.clock !== clock {
            disconnect()
            self.clock = clock
            connect()
        }
        self.session = session
        self.theme = theme
        self.canPlay = canPlay
        self.playFrom = playFrom
        self.manageRoles = manageRoles
        let oldCaret = caret
        let oldEditing = editingLine
        caret = session.caret
        editingLine = session.editingLine
        if replaced || revision != session.revision {
            let oldLines = lines
            let oldIDs = lines.map(\.id)
            revision = session.revision
            lines = session.draft.lines
            let agentsChanged = agents != session.draft.agents
            agents = session.draft.agents
            let ids = lines.map(\.id)
            let live = Set(ids)
            layouts = layouts.filter { live.contains($0.key) }
            let changed = oldIDs == ids && !agentsChanged ? IndexSet(lines.indices.filter {
                oldLines[$0] != lines[$0] || lines[$0].id == oldEditing || lines[$0].id == editingLine
            }) : nil
            updateLayouts(rows: changed, notify: oldIDs == ids)
            if oldIDs != ids { table.reloadData() }
        } else if oldEditing != editingLine {
            updateLayouts(rows: IndexSet(lines.indices.filter { lines[$0].id == oldEditing || lines[$0].id == editingLine }))
        }
        refreshVisible()
        if oldEditing != editingLine, let editingLine,
           let row = lines.firstIndex(where: { $0.id == editingLine }) {
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { [weak self] in self?.focusEditor(id: editingLine) }
        } else if oldCaret?.line != caret?.line, let row = caret?.line, lines.indices.contains(row) {
            if clickedLine != lines[row].id { table.scrollRowToVisible(row) }
        }
        updateSelection(animated: oldCaret != caret)
        clickedLine = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() } else {
            connect()
            updateSelection(animated: false)
        }
    }

    private func connect() {
        guard window != nil, clockToken == nil, let clock else { return }
        clockToken = clock.observeFrames { [weak self] in self?.updatePlayback() }
    }

    func disconnect() {
        if let clockToken { clock?.removeFrameObserver(clockToken) }
        clockToken = nil
        selection.reset()
        popMenu.close()
    }

    private func updateSelection(animated: Bool) {
        var target: NSRect?
        if let caret, lines.indices.contains(caret.line),
           let layout = layouts[lines[caret.line].id], !layout.input.editing,
           layout.chips.indices.contains(caret.syllable) {
            let cell = table.frameOfCell(atColumn: 0, row: caret.line)
            target = layout.chips[caret.syllable].offsetBy(dx: cell.minX, dy: cell.minY).insetBy(dx: -2, dy: -2)
        }
        // Jump to distant selections instead of animating across the whole document.
        let visible = table.visibleRect
        let from = selection.layer.presentation()?.frame ?? selection.frame
        let movesOnScreen = from?.intersects(visible) == true && target?.intersects(visible) == true
        selection.update(frame: target, color: NSColor(theme.primary),
                         animated: animated && movesOnScreen && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func updateLayouts(rows: IndexSet? = nil, notify: Bool = true) {
        var changed = IndexSet()
        for index in rows ?? IndexSet(lines.indices) {
            let line = lines[index]
            let input = LyricsEditorLineLayout.Input(line: line, width: measuredWidth,
                                                     paragraph: index > 0 && line.isParagraphStart,
                                                     editing: line.id == editingLine, agents: agents)
            if layouts[line.id]?.input != input {
                layouts[line.id] = LyricsEditorLineLayout(input: input)
                changed.insert(index)
            }
        }
        if notify, !changed.isEmpty {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            table.noteHeightOfRows(withIndexesChanged: changed)
            NSAnimationContext.endGrouping()
        }
    }

    private func refreshVisible() {
        table.enumerateAvailableRowViews { [self] _, row in
            guard lines.indices.contains(row),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LyricsEditorRowView else { return }
            configure(cell, row: row)
        }
    }

    private func updatePlayback() {
        guard let clock else { return }
        table.enumerateAvailableRowViews { [self] _, row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LyricsEditorRowView else { return }
            cell.updatePlayback(time: clock.time, active: canPlay && clock.activeLines.contains(row))
        }
    }

    private func configure(_ cell: LyricsEditorRowView, row: Int) {
        guard let session, let layout = layouts[lines[row].id] else { return }
        let line = lines[row]
        let selection = session.selection
        cell.configure(line: line, index: row, layout: layout, theme: theme,
                       caret: caret?.line == row ? caret?.syllable : nil,
                       selected: selection.isEmpty ? [] : IndexSet(line.syllables.indices.filter { selection.contains(line.syllables[$0].id) }),
                       pulse: line.syllables.contains(where: { $0.id == session.lastTapped }) ? session.tapSerial : 0,
                       lastTapped: session.lastTapped, agents: agents)
        cell.select = { [weak self] syllable in self?.select(id: line.id, syllable: syllable) }
        cell.toggle = { [weak self] syllable in self?.pick(id: line.id, syllable: syllable, extending: false) }
        cell.extend = { [weak self] syllable in self?.pick(id: line.id, syllable: syllable, extending: true) }
        cell.drag = { [weak self] event in self?.drag(event) }
        cell.edit = { [weak session] in session?.editingLine = line.id }
        cell.commit = { [weak self] text in self?.commit(text, id: line.id) }
        cell.cancel = { [weak session] in session?.editingLine = nil }
        cell.play = { [weak self] in self?.play(id: line.id) }
        cell.showMenu = { [weak self, weak cell] syllable, rect in
            guard let cell else { return }
            self?.showMenu(id: line.id, syllable: syllable, rect: rect, in: cell)
        }
        cell.updatePlayback(time: clock?.time ?? 0, active: canPlay && (clock?.activeLines.contains(row) ?? false))
    }

    private func focusEditor(id: UUID) {
        guard session?.editingLine == id, let row = lines.firstIndex(where: { $0.id == id }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LyricsEditorRowView else { return }
        cell.focusEditor()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.isEmpty ? 0 : lines.count + 1 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        lines.indices.contains(row) ? layouts[lines[row].id]?.height ?? 44 : 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == lines.count {
            let button = NSButton(title: "＋ 添加一行", target: self, action: #selector(addLine))
            button.isBordered = false
            button.font = .systemFont(ofSize: 12.5, weight: .medium)
            button.contentTintColor = NSColor(theme.onSurfaceVariant)
            return button
        }
        guard lines.indices.contains(row) else { return nil }
        let cell = table.makeView(withIdentifier: LyricsEditorRowView.reuseID, owner: nil) as? LyricsEditorRowView ?? LyricsEditorRowView()
        configure(cell, row: row)
        return cell
    }

    @objc private func addLine() {
        guard let session else { return }
        let line = LyricsDraft.Line(syllables: [])
        session.edit { $0.lines.append(line) }
        session.editingLine = line.id
    }

    private func select(id: UUID, syllable: Int?) {
        guard let session, let index = session.draft.lines.firstIndex(where: { $0.id == id }) else { return }
        clickedLine = id
        if session.draft.lines[index].syllables.isEmpty { session.editingLine = id; return }
        if let syllable { session.select(.init(line: index, syllable: syllable)) }
        else {
            session.clearSelection()
            session.selectLine(index)
        }
    }

    private func pick(id: UUID, syllable: Int, extending: Bool) {
        guard let session, let index = session.draft.lines.firstIndex(where: { $0.id == id }) else { return }
        clickedLine = id
        let position = LyricsDraft.Position(line: index, syllable: syllable)
        if extending { session.extendSelection(to: position) } else { session.toggleSelection(position) }
    }

    private func drag(_ event: NSEvent) {
        guard let session else { return }
        table.autoscroll(with: event)
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard lines.indices.contains(row), let layout = layouts[lines[row].id], !layout.input.editing else { return }
        let cell = table.frameOfCell(atColumn: 0, row: row)
        guard let syllable = layout.syllable(at: NSPoint(x: point.x - cell.minX, y: point.y - cell.minY)) else { return }
        let position = LyricsDraft.Position(line: row, syllable: syllable)
        guard session.draft.contains(position) else { return }
        clickedLine = lines[row].id
        session.extendSelection(to: position)
    }

    private func play(id: UUID, syllable: Int = 0) {
        guard let index = session?.draft.lines.firstIndex(where: { $0.id == id }) else { return }
        playFrom?(.init(line: index, syllable: syllable))
    }

    private func commit(_ text: String, id: UUID) {
        guard let session, session.editingLine == id else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        session.editingLine = nil
        session.edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == id }),
                  value != LyricsDraft.editableText(of: draft.lines[index]) else { return }
            if value.isEmpty { draft.lines.remove(at: index) }
            else { draft.setText(value, ofLine: index) }
        }
    }

    private func showMenu(id: UUID, syllable: Int?, rect: NSRect, in cell: NSView) {
        guard let session, let index = session.draft.lines.firstIndex(where: { $0.id == id }) else { return }
        let line = session.draft.lines[index]
        // Menu shortcuts must target the syllable under the pointer.
        if let syllable, line.syllables.indices.contains(syllable), !session.selection.contains(line.syllables[syllable].id) {
            clickedLine = id
            session.select(.init(line: index, syllable: syllable))
        }
        let items: [PopMenuItem]
        if let syllable, line.syllables.indices.contains(syllable) {
            items = session.selection.count > 1 ? selectionItems(session) : syllableItems(session, line: index, syllable: syllable)
        } else {
            items = lineItems(session, id: id)
        }
        guard let localization else { return }
        popMenu.popUp(items: items, theme: theme, localization: localization, from: rect, in: cell)
    }

    private func selectionItems(_ session: LyricsEditorSession) -> [PopMenuItem] {
        let selected = session.selectedPositions
        return PopMenuItem.tidy([
            .header("已选中 \(selected.count) 个音节"),
            .button("移到新的一行", systemImage: "return") { session.moveToNewLine() }.shortcut("⌘↩"),
            .button("移到上一行末尾", systemImage: "arrow.up.to.line", disabled: (selected.first?.line ?? 0) == 0) { session.moveToLine(by: -1) }.shortcut("⌘↑"),
            .button("移到下一行开头", systemImage: "arrow.down.to.line", disabled: (selected.last?.line ?? lines.count) >= lines.count - 1) { session.moveToLine(by: 1) }.shortcut("⌘↓"),
            .button("合并成一个音节", systemImage: "link", disabled: !session.canMergeSelection) { session.mergeSelection() },
            .button("共享注音…", systemImage: "character.textbox", disabled: !session.canShareRuby) { session.focusRuby() },
            LyricsEditorRoleMenu.syllableItem(session, positions: selected),
            .divider,
            .button("清除时间", systemImage: "eraser", disabled: !selected.contains { session.draft[$0].isTimed }) { session.clearTiming() },
            .button("清除注音", systemImage: "xmark.circle", disabled: !selected.contains { session.draft.hasRuby(at: $0) }) { session.clearRuby() },
            .button("删除", systemImage: "trash", role: .destructive) { session.delete() }.shortcut("⌫"),
            .divider,
            .button("取消选择", systemImage: "xmark") { session.clearSelection() }.shortcut("Esc"),
        ])
    }

    private func syllableItems(_ session: LyricsEditorSession, line index: Int, syllable: Int) -> [PopMenuItem] {
        let line = session.draft.lines[index]
        let id = line.id
        let position = LyricsDraft.Position(line: index, syllable: syllable)
        let text = line.syllables[syllable].text.trimmingCharacters(in: .whitespaces)
        return PopMenuItem.tidy([
            .header("「\(text)」"),
            .button("从这里播放", systemImage: "play") { [weak self] in
                session.caret = position
                self?.play(id: id, syllable: syllable)
            },
            .divider,
            .button("拆成单字", systemImage: "scissors", disabled: text.count <= 1) { session.edit { $0.splitSyllable(at: position) } },
            .button("与后一个合并", systemImage: "link",
                    disabled: !session.draft.canMergeSyllables([position, LyricsDraft.Position(line: index, syllable: syllable + 1)])) { session.edit { $0.mergeWithNext(at: position) } },
            .button("编辑注音…", systemImage: "character.textbox") {
                session.select(position)
                session.focusRuby()
            },
            .button("清除注音", systemImage: "xmark.circle", disabled: !session.draft.hasRuby(at: position)) { session.clearRuby([position]) },
            LyricsEditorRoleMenu.syllableItem(session, positions: [position]),
            .button("从这里断成新的一行", systemImage: "return", disabled: syllable == 0) { session.moveToNewLine() }.shortcut("⌘↩"),
            .button("移到上一行末尾", systemImage: "arrow.up.to.line", disabled: index == 0) { session.moveToLine(by: -1, [position]) }.shortcut("⌘↑"),
            .button("移到下一行开头", systemImage: "arrow.down.to.line", disabled: index + 1 >= lines.count) { session.moveToLine(by: 1, [position]) }.shortcut("⌘↓"),
            .divider,
            .button("清除时间", systemImage: "eraser", disabled: !line.syllables[syllable].isTimed) { session.clearTiming([position]) },
            .button("删除这个音节", systemImage: "trash", role: .destructive) { session.delete([position]) }.shortcut("⌫"),
            .divider,
            .submenu("这一行", systemImage: "text.alignleft") { lineItems(session, id: id) },
        ])
    }

    private func lineItems(_ session: LyricsEditorSession, id: UUID) -> [PopMenuItem] {
        guard let index = session.draft.lines.firstIndex(where: { $0.id == id }) else { return [] }
        let line = session.draft.lines[index]
        func editLine(_ change: @escaping (inout LyricsDraft.Line) -> Void) {
            session.edit { draft in
                guard let i = draft.lines.firstIndex(where: { $0.id == id }) else { return }
                change(&draft.lines[i])
            }
        }
        let singers: [(String, LyricSinger)] = [("主唱", .primary), ("对唱", .secondary), ("合唱", .duet)]
        let manageRoles = { [weak self] in
            self?.window?.makeFirstResponder(nil)
            self?.manageRoles?()
        }
        let performers: PopMenuItem = session.draft.agents.isEmpty
            ? .submenu("演唱", systemImage: "person.2", detail: singers.first(where: { $0.1 == line.singer })?.0) {
                for (title, singer) in singers {
                    PopMenuItem.option(title, selected: line.singer == singer) { editLine { $0.setSinger(singer, agents: session.draft.agents) } }
                }
                PopMenuItem.divider
                PopMenuItem.button("设置演唱角色…", systemImage: "person.crop.rectangle.stack", action: manageRoles)
            }
            : .submenu("演唱", systemImage: "person.2", detail: LyricsEditorRoleStyle.names(line.agentIDs, in: session) ?? "未分配") {
                LyricsEditorRoleMenu.lineItems(session, line: id, manage: manageRoles)
            }
        return PopMenuItem.tidy([
            .button("编辑文本", systemImage: "pencil") { session.editingLine = id },
            .button("生成日语音译（替换已有）", systemImage: "wand.and.stars", disabled: session.isGeneratingRomanization || !JapaneseRomanization.containsJapaneseScript(line.text)) { [weak self] in
                self?.window?.makeFirstResponder(nil)
                Task { await session.generateJapaneseRomanization(for: id, overwrite: true) }
            },
            .button("选中这一行的音节", systemImage: "checklist", disabled: line.syllables.isEmpty) { session.selectSyllables(ofLine: index) },
            .button("从这一行播放", systemImage: "play.circle") { [weak self] in self?.play(id: id) },
            .button("在下方插入一行", systemImage: "plus") {
                let new = LyricsDraft.Line(syllables: [], singer: line.singer, track: line.track, agentIDs: line.agentIDs)
                session.edit { draft in
                    guard let i = draft.lines.firstIndex(where: { $0.id == id }) else { return }
                    draft.lines.insert(new, at: i + 1)
                }
                session.editingLine = new.id
            },
            .button("上移这一行", systemImage: "arrow.up", disabled: index == 0) { session.moveLine(by: -1, id: id) }
                .shortcut(session.caret?.line == index ? "⌥↑" : ""),
            .button("下移这一行", systemImage: "arrow.down", disabled: session.draft.lineGroup(at: index).upperBound >= session.draft.lines.count) { session.moveLine(by: 1, id: id) }
                .shortcut(session.caret?.line == index ? "⌥↓" : ""),
            .button("与下一行合并", systemImage: "arrow.triangle.merge", disabled: index + 1 >= session.draft.lines.count) {
                session.edit { draft in
                    guard let i = draft.lines.firstIndex(where: { $0.id == id }) else { return }
                    draft.mergeLineWithNext(i)
                }
            },
            .divider,
            performers,
            .option("背景人声", selected: line.isBackground) { editLine { $0.isBackground.toggle() } },
            .submenu("虚拟轨", systemImage: "rectangle.split.1x2", detail: session.draft.tracks.first { $0.id == line.track }.map { LyricsEditorSession.name(of: $0) }) {
                PopMenuItem.option("不放在轨道上（按演唱）", selected: !session.draft.isOnTrack(line)) { session.setTrack(nil, ofLine: id) }
                for track in session.draft.tracks {
                    PopMenuItem.option(LyricsEditorSession.name(of: track), selected: line.track == track.id) { session.setTrack(track.id, ofLine: id) }
                }
                PopMenuItem.divider
                PopMenuItem.button("新建轨道并移过去", systemImage: "plus") { session.addTrack(moving: id) }
            },
            .button("移到暂存区", systemImage: "tray.and.arrow.down", disabled: !line.syllables.contains(where: \.isTimed)) {
                if let i = session.draft.lines.firstIndex(where: { $0.id == id }) { session.stageLine(i) }
            },
            .divider,
            .button("清除这一行的时间", systemImage: "eraser", disabled: line.timedRange == nil) {
                session.edit { draft in
                    guard let i = draft.lines.firstIndex(where: { $0.id == id }) else { return }
                    draft.clearTiming(ofLine: i)
                    draft.lines[i].start = nil
                    draft.lines[i].end = nil
                }
                session.caret = session.draft.firstPosition(fromLine: index)
            },
            .button("删除这一行", systemImage: "trash", role: .destructive) { session.edit { $0.lines.removeAll { $0.id == id } } },
        ])
    }
}

private extension PopMenuItem {
    func shortcut(_ keys: String) -> PopMenuItem {
        var item = self
        item.detail = keys.isEmpty ? nil : keys
        return item
    }
}
