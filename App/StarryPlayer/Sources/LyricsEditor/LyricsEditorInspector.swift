import AppKit
import LyricsCore
import SwiftUI

struct LyricsEditorInspector: View {
    let session: LyricsEditorSession
    var manageRoles: () -> Void = {}
    var reviewAI: (Bool) -> Void = { _ in }
    @Environment(\.theme) private var theme

    private var position: LyricsDraft.Position? {
        guard let p = session.caret ?? session.lastStarted, session.draft.contains(p) else { return nil }
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.aiReviewNotes.isEmpty { aiReview }
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
                if let run = session.sharedRubyRun(at: position) {
                    let positions = run.map { LyricsDraft.Position(line: position.line, syllable: $0) }
                    LineTextField(placeholder: "\(run.count) 个音节共享的注音，用 | 分段，如 des|ti|ny",
                                  value: session.draft.rubyGroup(at: position) == run ? session.draft.editableRuby(at: position) : "",
                                  id: positions.map { session.draft[$0].id }, focusRequest: session.rubyFocusRequest) { setGroupRuby($0, over: positions) }
                } else {
                    LineTextField(placeholder: "注音，用 | 分段，如 せ|ん", value: LyricsDraft.editableRuby(of: syllable), id: syllable.id, focusRequest: session.rubyFocusRequest) { setRuby($0, at: position) }
                }
                HStack(spacing: 10) {
                    Text("演唱者").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    LyricsEditorRolePicker(session: session, line: line, manage: manageRoles)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Text("位置").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    SegmentSwitch(selection: Binding { line.singer } set: { session.setDisplayPosition($0, ofLines: [line.id]) },
                                  options: [(.primary, "左侧"), (.secondary, "右侧"), (.duet, "居中")])
                        .controlSize(.small)
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

    private var aiReview: some View {
        let id = position.map { session.draft[$0].id }
        let notes = id.flatMap { session.aiReviewNotes[$0] } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Label("AI 待核对 \(session.aiReviewNotes.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.warning)
                Spacer(minLength: 0)
                IconButton(systemName: "chevron.left", size: 22, iconSize: 10, help: "上一处 AI 待核对音节") { reviewAI(true) }
                    .accessibilityLabel("上一处 AI 待核对音节")
                IconButton(systemName: "chevron.right", size: 22, iconSize: 10, help: "下一处 AI 待核对音节") { reviewAI(false) }
                    .accessibilityLabel("下一处 AI 待核对音节")
                Button {
                    if let id { session.markAIReviewed(id); reviewAI(false) }
                } label: {
                    Label("已核对", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(notes.isEmpty ? theme.onSurfaceVariant : theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(notes.isEmpty)
                .help("清除当前音节的复核标记并跳到下一处，可撤销")
                .accessibilityLabel("标记当前音节已核对")
            }
            Text(notes.isEmpty ? "选择琥珀色字块，或跳到下一处" : notes.joined(separator: "；"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(2)
                .help(notes.joined(separator: "\n"))
        }
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

    private func setGroupRuby(_ text: String, over positions: [LyricsDraft.Position]) {
        session.edit { $0.setGroupRuby(text, over: positions) }
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
    var id: AnyHashable
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
