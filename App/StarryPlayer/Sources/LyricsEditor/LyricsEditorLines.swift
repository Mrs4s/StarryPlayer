import LyricsCore
import SwiftUI

struct LyricsEditorLineList: View {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    var canPlay: Bool
    var appeared: Bool
    var playFrom: (LyricsDraft.Position) -> Void
    @Environment(\.theme) private var theme
    @Namespace private var caretSpace
    /// The line a click just moved the caret to: it is in view already, and scrolling it would
    /// move what the next click lands on.
    @State private var clickedLine: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(session.draft.lines.enumerated()), id: \.element.id) { index, line in
                        LyricsEditorObservedLine(session: session, index: index, line: line, clock: clock, canPlay: canPlay, caretSpace: caretSpace, playFrom: playFrom) {
                            if session.caret?.line != index { clickedLine = index }
                        }
                        .id(line.id)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(Motion.reveal.delay(Double(min(index, Motion.staggerLimit)) * Motion.staggerStep), value: appeared)
                    }
                    if !session.draft.lines.isEmpty { addLineButton }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(Motion.selection, value: session.caret)
                .animation(Motion.listEdit, value: session.draft.lines.map(\.id))
            }
            .scrollIndicators(.automatic)
            .overlay {
                if session.draft.lines.isEmpty {
                    StateView(systemName: "text.badge.plus", title: "还没有歌词", detail: "点「导入」粘贴歌词，或打开歌词文件")
                }
            }
            .onChange(of: session.caret?.line) { _, line in
                defer { clickedLine = nil }
                guard let line, line != clickedLine, session.draft.lines.indices.contains(line) else { return }
                withAnimation(Motion.reveal) { proxy.scrollTo(session.draft.lines[line].id, anchor: UnitPoint(x: 0.5, y: 0.4)) }
            }
            .onChange(of: session.editingLine) { _, id in
                guard let id else { return }
                withAnimation(Motion.reveal) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var addLineButton: some View {
        Button {
            let line = LyricsDraft.Line(syllables: [])
            session.edit { $0.lines.append(line) }
            session.editingLine = line.id
        } label: {
            Label("添加一行", systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
        .padding(.leading, 34)
        .padding(.top, 6)
    }
}

/// Reads shared selection/playback state outside the expensive row subtree. Unchanged rows
/// keep their layout and gesture graph when another line is selected or starts playing.
private struct LyricsEditorObservedLine: View {
    let session: LyricsEditorSession
    let index: Int
    let line: LyricsDraft.Line
    let clock: LyricsEditorClock
    var canPlay: Bool
    var caretSpace: Namespace.ID
    var playFrom: (LyricsDraft.Position) -> Void
    var willSelect: () -> Void

    var body: some View {
        let lastTapped = session.lastTapped
        let tapped = lastTapped.flatMap { id in line.syllables.contains { $0.id == id } ? id : nil }
        LyricsEditorLineRow(session: session, index: index, line: line, clock: clock,
                            isPlaying: canPlay && clock.activeLines.contains(index),
                            caretSyllable: session.caret?.line == index ? session.caret?.syllable : nil,
                            isEditing: session.editingLine == line.id,
                            lastTapped: tapped, tapSerial: tapped == nil ? 0 : session.tapSerial,
                            caretSpace: caretSpace, playFrom: playFrom, willSelect: willSelect)
            .equatable()
    }
}

private struct LyricsEditorLineRow: View, @MainActor Equatable {
    let session: LyricsEditorSession
    let index: Int
    let line: LyricsDraft.Line
    let clock: LyricsEditorClock
    var isPlaying: Bool
    var caretSyllable: Int?
    var isEditing: Bool
    var lastTapped: UUID?
    var tapSerial: Int
    var caretSpace: Namespace.ID
    var playFrom: (LyricsDraft.Position) -> Void
    var willSelect: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var menuOpen = false
    @State private var text = ""
    @FocusState private var focused: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.clock === rhs.clock && lhs.index == rhs.index
            && lhs.line == rhs.line && lhs.isPlaying == rhs.isPlaying
            && lhs.caretSyllable == rhs.caretSyllable && lhs.isEditing == rhs.isEditing
            && lhs.lastTapped == rhs.lastTapped && lhs.tapSerial == rhs.tapSerial
            && lhs.caretSpace == rhs.caretSpace
    }

    private var isCaretLine: Bool { caretSyllable != nil }

    private func playLine() { playFrom(LyricsDraft.Position(line: index, syllable: 0)) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            gutter
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    editor
                } else if line.syllables.isEmpty {
                    Text("空行")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.6))
                        .frame(height: 30)
                } else {
                    LyricsFlowLayout(spacing: 2, lineSpacing: 4) {
                        if let badge {
                            Tag(text: badge, style: line.isBackground ? .neutral : .primary, soft: true)
                                .fixedSize()
                                .padding(.trailing, 4)
                        }
                        ForEach(Array(line.syllables.enumerated()), id: \.element.id) { s, syllable in
                            let position = LyricsDraft.Position(line: index, syllable: s)
                            SyllableChip(syllable: syllable, position: position, isCaret: caretSyllable == s, pulse: lastTapped == syllable.id ? tapSerial : 0, clock: isPlaying ? clock : nil, background: line.isBackground, caretSpace: caretSpace) {
                                willSelect()
                                session.caret = position
                            }
                            .equatable()
                            .contextMenu { syllableItems(syllable, at: position) }
                        }
                    }
                }
                if !line.translation.isEmpty {
                    Text(line.translation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(2)
                }
                if !line.romanization.isEmpty {
                    Text(line.romanization)
                        .font(.system(size: 12).italic())
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .padding(.leading, line.isBackground ? 24 : 0)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isCaretLine ? theme.primary.opacity(theme.isDark ? 0.1 : 0.06) : theme.onSurface.opacity(hovering ? 0.035 : 0))
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(theme.primary)
                .frame(width: 3, height: isPlaying ? 18 : 0)
                .opacity(isPlaying ? 1 : 0)
                .padding(.leading, line.isBackground ? 26 : 2)
                .animation(Motion.lift, value: isPlaying)
        }
        .padding(.top, line.isParagraphStart && index > 0 ? 12 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        // A click anywhere on the row picks the line at once (a chip picks its syllable);
        // the double click that edits the text does not hold the single one back.
        .onTapGesture(count: 2) { if !isEditing { begin() } }
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu { contextItems }
        .onChange(of: isEditing) { _, editing in
            if editing { begin() }
        }
    }

    private var gutter: some View {
        Text("\(index + 1)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(isCaretLine ? theme.primary : theme.onSurfaceVariant.opacity(0.7))
            .frame(width: 26, height: 30, alignment: .trailing)
    }

    private var badge: String? {
        if line.isBackground { return "背景" }
        switch line.singer {
        case .primary: return nil
        case .secondary: return "对唱"
        case .duet: return "合唱"
        }
    }

    private var trailing: some View {
        HStack(spacing: 2) {
            HStack(spacing: 2) {
                IconButton(systemName: "play.fill", size: 26, iconSize: 10, help: "从这一行播放（Q）", action: playLine)
                PopMenu(isPresented: $menuOpen) {
                    menuItems
                } label: { open in
                    PopMenuEllipsis(isOpen: open, size: 12, weight: .semibold)
                        .foregroundStyle(theme.onSurface.opacity(0.8))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true, isActive: menuOpen))
            }
            // Reserve the controls' width: hover while scrolling must not rewrap lyrics
            // and change the lazy stack's row heights underneath the pointer.
            .opacity(hovering || menuOpen || isCaretLine ? 1 : 0)
            .allowsHitTesting(hovering || menuOpen || isCaretLine)
            .accessibilityHidden(!(hovering || menuOpen || isCaretLine))
            Text(LyricsEditorFormat.time(line.timedRange?.lowerBound))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.onSurfaceVariant.opacity(line.timedRange == nil ? 0.4 : 0.8))
                .frame(width: 58, height: 28, alignment: .trailing)
        }
        .animation(Motion.hover, value: hovering || menuOpen || isCaretLine)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("这一行的歌词", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { endEditing() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous).strokeBorder(theme.primary.opacity(0.5), lineWidth: 1))
            Text("用 | 手动分开音节，空格分开单词；回车保存，Esc 取消")
                .font(.system(size: 11))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
        }
        .transition(.opacity)
    }

    private func select() {
        guard session.editingLine != line.id else { return }
        if line.syllables.isEmpty { return begin() }
        willSelect()
        session.selectLine(index)
    }

    private func begin() {
        text = LyricsDraft.editableText(of: line)
        if session.editingLine != line.id { session.editingLine = line.id }
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
    }

    private func commit() {
        guard session.editingLine == line.id else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        if value != LyricsDraft.editableText(of: line) {
            session.edit { draft in
                guard let index = draft.lines.firstIndex(where: { $0.id == line.id }) else { return }
                if value.isEmpty { draft.lines.remove(at: index) } else { draft.setText(value, ofLine: index) }
            }
        }
        endEditing()
    }

    private func endEditing() {
        if session.editingLine == line.id { session.editingLine = nil }
    }

    // MARK: Line actions

    @PopMenuBuilder
    private var menuItems: [PopMenuItem] {
        PopMenuItem.button("编辑文本", systemImage: "pencil") { begin() }
        PopMenuItem.button("从这一行播放", systemImage: "play", action: playLine)
        PopMenuItem.button("在下方插入一行", systemImage: "text.insert") { insertBelow() }
        PopMenuItem.divider
        PopMenuItem.header("演唱")
        PopMenuItem.option("主唱", selected: line.singer == .primary) { set(\.singer, .primary) }
        PopMenuItem.option("对唱", selected: line.singer == .secondary) { set(\.singer, .secondary) }
        PopMenuItem.option("合唱", selected: line.singer == .duet) { set(\.singer, .duet) }
        PopMenuItem.option("背景人声", selected: line.isBackground) { set(\.isBackground, !line.isBackground) }
        PopMenuItem.divider
        PopMenuItem.button("清除这一行的时间", systemImage: "eraser", disabled: line.timedRange == nil) { clearTiming() }
        PopMenuItem.button("删除这一行", systemImage: "trash", role: .destructive) { remove() }
    }

    @ViewBuilder
    private func syllableItems(_ syllable: LyricsDraft.Syllable, at position: LyricsDraft.Position) -> some View {
        Button("从这里播放") {
            session.caret = position
            playFrom(position)
        }
        Divider()
        Button("拆成单字") { session.edit { $0.splitSyllable(at: position) } }
            .disabled(syllable.text.trimmingCharacters(in: .whitespaces).count < 2)
        Button("与后一个合并") { session.edit { $0.mergeWithNext(at: position) } }
            .disabled(position.syllable + 1 >= line.syllables.count)
        Button("清除时间") {
            session.edit { draft in
                guard draft.contains(position) else { return }
                draft[position].start = nil
                draft[position].end = nil
            }
        }
        .disabled(!syllable.isTimed)
        Divider()
        Button("编辑这一行…") { begin() }
    }

    @ViewBuilder
    private var contextItems: some View {
        Button("编辑文本") { begin() }
        Button("从这一行播放", action: playLine)
        Button("在下方插入一行") { insertBelow() }
        Divider()
        Toggle("背景人声", isOn: Binding { line.isBackground } set: { set(\.isBackground, $0) })
        Button("清除这一行的时间") { clearTiming() }
        Button("删除这一行", role: .destructive) { remove() }
    }

    private func set<Value>(_ key: WritableKeyPath<LyricsDraft.Line, Value>, _ value: Value) {
        session.edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == line.id }) else { return }
            draft.lines[index][keyPath: key] = value
        }
    }

    private func insertBelow() {
        let new = LyricsDraft.Line(syllables: [], singer: line.singer)
        session.edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == line.id }) else { return }
            draft.lines.insert(new, at: index + 1)
        }
        session.editingLine = new.id
    }

    private func clearTiming() {
        session.edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == line.id }) else { return }
            draft.clearTiming(ofLine: index)
            draft.lines[index].start = nil
            draft.lines[index].end = nil
        }
        session.caret = session.draft.firstPosition(fromLine: index)
    }

    private func remove() {
        session.edit { draft in draft.lines.removeAll { $0.id == line.id } }
    }
}

private struct SyllableChip: View, @MainActor Equatable {
    let syllable: LyricsDraft.Syllable
    let position: LyricsDraft.Position
    var isCaret: Bool
    /// Changes when this syllable is tapped, to bounce it.
    var pulse: Int
    /// The playback clock, only on the lines being sung.
    var clock: LyricsEditorClock?
    var background: Bool
    var caretSpace: Namespace.ID
    var select: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.syllable == rhs.syllable && lhs.position == rhs.position && lhs.isCaret == rhs.isCaret && lhs.pulse == rhs.pulse
            && lhs.clock === rhs.clock && lhs.background == rhs.background && lhs.caretSpace == rhs.caretSpace
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        let timed = syllable.isTimed
        Text(syllable.text.trimmingCharacters(in: .whitespaces))
            .font(.system(size: background ? 15 : 17, weight: .medium))
            .foregroundStyle(theme.onSurface.opacity(timed ? 0.95 : 0.5))
            .padding(.horizontal, 6)
            .frame(minWidth: 26, minHeight: background ? 26 : 30)
            .background {
                ZStack(alignment: .leading) {
                    shape.fill(timed ? theme.primary.opacity(theme.isDark ? 0.14 : 0.09) : theme.onSurface.opacity(hovering ? 0.05 : 0))
                    if let clock, timed {
                        SyllableSweep(syllable: syllable, clock: clock)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                if !timed {
                    shape.strokeBorder(theme.onSurface.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .overlay {
                if isCaret {
                    shape.strokeBorder(theme.primary, lineWidth: 1.75)
                        .padding(-2)
                        .matchedGeometryEffect(id: "caret", in: caretSpace)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.16, duration: 0.07, spring: .snappy)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
            .padding(.trailing, syllable.text.hasSuffix(" ") ? 8 : 0)
            .contentShape(Rectangle())
            // Alongside the row's double click, so a click takes effect at once.
            .simultaneousGesture(TapGesture().onEnded(select))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .animation(Motion.selection, value: timed)
            .help(timed ? "\(LyricsEditorFormat.time(syllable.start, digits: 3)) – \(LyricsEditorFormat.time(syllable.end, digits: 3))" : "还没有打点")
    }
}

private struct SyllableSweep: View {
    let syllable: LyricsDraft.Syllable
    let clock: LyricsEditorClock
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let fraction = progress
            Rectangle()
                .fill(theme.primary.opacity(theme.isDark ? 0.32 : 0.22))
                .frame(width: geo.size.width * fraction)
                .opacity(fraction > 0 && fraction < 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    private var progress: CGFloat {
        guard let start = syllable.start else { return 0 }
        let end = max(syllable.end ?? start + 0.3, start + 0.01)
        return CGFloat(min(max((clock.time - start) / (end - start), 0), 1))
    }
}
