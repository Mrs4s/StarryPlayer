import AppKit
import LyricsCore
import SwiftUI

struct LyricsEditorInspector: View {
    let session: LyricsEditorSession
    var manageRoles: () -> Void = {}
    @Environment(\.theme) private var theme

    private var position: LyricsDraft.Position? {
        guard let p = session.caret ?? session.lastStarted, session.draft.contains(p) else { return nil }
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let position {
                let syllable = session.draft[position]
                let line = session.draft.lines[position.line]
                HStack(spacing: 8) {
                    Text(syllable.text.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .frame(minWidth: 28, alignment: .leading)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                    TimeField(value: syllable.start, placeholder: "开始") { set(\.start, $0, at: position) }
                    Text("–").foregroundStyle(theme.onSurfaceVariant)
                    TimeField(value: syllable.end, placeholder: "结束") { set(\.end, $0, at: position) }
                }
                .frame(height: 28)
                LineTextField(placeholder: "注音，用 | 分段，如 せ|ん", value: LyricsDraft.editableRuby(of: syllable), id: syllable.id, focusRequest: session.rubyFocusRequest) { setRuby($0, at: position) }
                HStack(spacing: 10) {
                    if session.draft.agents.isEmpty {
                        SegmentSwitch(selection: Binding { line.singer } set: { singer in
                            session.edit { draft in draft.lines[position.line].setSinger(singer, agents: draft.agents) }
                        }, options: [(.primary, "主唱"), (.secondary, "对唱"), (.duet, "合唱")])
                            .controlSize(.small)
                            .transition(.opacity)
                    } else {
                        LyricsEditorRolePicker(session: session, line: line, manage: manageRoles)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    Text("背景").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    SettingsSwitch(isOn: Binding { line.isBackground } set: { setLine(\.isBackground, $0, at: position.line) })
                }
                LineTextField(placeholder: "翻译", value: line.translation, id: line.id) { setLine(\.translation, $0, at: position.line) }
                HStack(spacing: 6) {
                    LineTextField(placeholder: "音译", value: line.romanization, id: line.id) { setLine(\.romanization, $0, at: position.line) }
                    IconButton(systemName: "wand.and.stars", size: 26, iconSize: 12, help: "为这一行生成日语罗马音（替换已有音译，可撤销）") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        Task { await session.generateJapaneseRomanization(for: line.id, overwrite: true) }
                    }
                    .disabled(session.isGeneratingRomanization || !JapaneseRomanization.containsJapaneseScript(line.text))
                    .accessibilityLabel("生成这一行的日语音译")
                }
            } else {
                Text("选中一个音节，在这里细调它的时间、注音和所在行")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Motion.hover, value: position)
        .animation(Motion.popover, value: session.draft.agents.isEmpty)
    }

    private func set(_ key: WritableKeyPath<LyricsDraft.Syllable, TimeInterval?>, _ value: TimeInterval?, at position: LyricsDraft.Position) {
        session.edit { draft in
            guard draft.contains(position) else { return }
            draft[position][keyPath: key] = value
        }
    }

    private func setRuby(_ text: String, at position: LyricsDraft.Position) {
        session.edit { draft in
            guard draft.contains(position) else { return }
            draft.setRuby(text, at: position)
        }
    }

    private func setLine<Value>(_ key: WritableKeyPath<LyricsDraft.Line, Value>, _ value: Value, at line: Int) {
        session.edit { draft in
            guard draft.lines.indices.contains(line) else { return }
            draft.lines[line][keyPath: key] = value
        }
    }
}

private struct TimeField: View {
    var value: TimeInterval?
    var placeholder: String
    var commit: (TimeInterval?) -> Void
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .multilineTextAlignment(.center)
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onChange(of: value) { _, _ in if !focused { sync() } }
            .onAppear(perform: sync)
            .frame(width: 78, height: 26)
            .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(theme.primary.opacity(focused ? 0.5 : 0), lineWidth: 1))
            .animation(Motion.hover, value: focused)
    }

    private func sync() {
        text = value.map { LyricsEditorFormat.time($0, digits: 3) } ?? ""
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if value != nil { commit(nil) }
        } else if let seconds = LyricsEditorFormat.seconds(from: trimmed), seconds != value {
            commit(seconds)
        }
        sync()
    }
}

private struct LineTextField: View {
    var placeholder: String
    var value: String
    var id: UUID
    var focusRequest = 0
    var commit: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onChange(of: id) { _, _ in text = value }
            .onChange(of: focusRequest) { _, _ in focused = true }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onAppear { text = value }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(theme.primary.opacity(focused ? 0.5 : 0), lineWidth: 1))
            .animation(Motion.hover, value: focused)
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}
