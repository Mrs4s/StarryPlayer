import AppKit
import LyricsCore
import Observation
import SwiftUI

/// Kept with the editing session so closing the panel does not lose a pasted response.
@MainActor @Observable
final class LyricsEditorTranslationState {
    enum Step { case prompt, result }
    var step: Step = .prompt
    var language = "简体中文"
    var style: LyricsTranslation.Style = .accurate
    var instructions = ""
    var response = ""
    var overwrite = false
}

extension LyricsEditorSession {
    @discardableResult
    func applyTranslation(_ response: String, overwrite: Bool = false) throws -> Int {
        var next = draft
        let updated = try LyricsTranslation.apply(response, to: &next, overwrite: overwrite)
        edit { $0 = next }
        return updated
    }
}

struct LyricsEditorTranslation: View {
    let session: LyricsEditorSession
    var close: () -> Void
    @Bindable private var state: LyricsEditorTranslationState
    @Environment(\.theme) private var theme
    @FocusState private var responseFocused: Bool
    @State private var actionError: String?
    @State private var copied = false

    init(session: LyricsEditorSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        self.state = session.translation
    }

    private var prompt: Result<String, Error> {
        Result {
            try LyricsTranslation.prompt(for: session.draft, language: state.language, style: state.style,
                                         instructions: state.instructions, title: session.track.title, artist: session.track.artistText)
        }
    }

    private var result: Result<[LyricsTranslation.Entry], Error>? {
        guard !state.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result { try LyricsTranslation.parse(state.response, for: session.draft) }
    }

    private var entries: [LyricsTranslation.Entry] {
        guard case .success(let entries) = result else { return [] }
        return entries
    }

    private var changes: [LyricsTranslation.Entry] {
        let current = Dictionary(session.draft.lines.map { ($0.id, $0.translation) }, uniquingKeysWith: { first, _ in first })
        return entries.filter {
            guard let existing = current[$0.id] else { return false }
            return (state.overwrite || existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && existing != $0.translation
        }
    }

    var body: some View {
        EditorPanel(title: "AI 翻译", subtitle: "复制 Prompt 给你使用的 AI，再将它的完整回复粘贴回来。", width: 720, close: close) {
            SegmentSwitch(selection: $state.step, options: [(.prompt, "1 · 复制 Prompt"), (.result, "2 · 粘贴译文")])
            if state.step == .prompt {
                promptSettings
                promptPreview
            } else {
                responseEditor
                responseSummary
                translationPreview
                HStack(spacing: 8) {
                    SettingsSwitch(isOn: $state.overwrite)
                        .accessibilityLabel("覆盖已有翻译")
                    Text("覆盖已有翻译")
                        .font(.system(size: 12.5))
                    Text("关闭时只补全空白译文")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
            }
            if let actionError {
                Text(actionError).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
            }
            footer
        }
        .onChange(of: state.step) { _, _ in actionError = nil }
        .onChange(of: state.response) { _, _ in actionError = nil }
    }

    private var promptSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("目标语言").font(.system(size: 12, weight: .medium))
                TextField("例如：简体中文、English", text: $state.language)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .frame(width: 190)
                    .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("目标语言")
                Spacer(minLength: 0)
                SegmentSwitch(selection: $state.style, options: LyricsTranslation.Style.allCases.map { ($0, $0.title) })
            }
            Text(state.style.guidance)
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            TextField("补充要求（可选），例如：保留人名原文、用词简洁", text: $state.instructions)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("补充翻译要求")
        }
        .foregroundStyle(theme.onSurface)
    }

    private var promptPreview: some View {
        ScrollView {
            switch prompt {
            case .success(let text):
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            case .failure(let error):
                Text(error.localizedDescription).font(.system(size: 13)).padding(12)
            }
        }
        .foregroundStyle(theme.onSurfaceVariant)
        .frame(height: 240)
        .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.menu))
        .accessibilityLabel("翻译 Prompt 预览")
    }

    private var responseEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(copied ? "Prompt 已复制，交给 AI 翻译后把完整回复粘贴到这里。" : "粘贴 AI 的完整回复，然后核对下方译文。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 0)
                PillButton(title: "从剪贴板粘贴", systemName: "doc.on.clipboard", variant: .tertiary, height: 28) {
                    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                        actionError = "剪贴板里没有文字，请先复制 AI 的回复。"
                        return
                    }
                    state.response = text
                    actionError = nil
                    responseFocused = true
                }
            }
            TextEditor(text: $state.response)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.onSurface)
                .scrollContentBackground(.hidden)
                .focused($responseFocused)
                .padding(8)
                .frame(height: 140)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
                .overlay(RoundedRectangle(cornerRadius: Radius.menu).strokeBorder(theme.primary.opacity(responseFocused ? 0.35 : 0), lineWidth: 1))
                .accessibilityLabel("AI 翻译结果")
        }
    }

    @ViewBuilder
    private var responseSummary: some View {
        switch result {
        case .success(let entries):
            Label("已匹配 \(entries.count) 行 · 将更新 \(changes.count) 行译文", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primary)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("原文会自动逐行匹配，粘贴后可预览译文。")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private var translationPreview: some View {
        let updatedIDs = Set(changes.map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(entry.lineNumber)")
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 26, alignment: .trailing)
                            .foregroundStyle(theme.onSurfaceVariant)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.source).foregroundStyle(theme.onSurfaceVariant)
                            Text(entry.translation).foregroundStyle(theme.onSurface)
                        }
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !updatedIDs.contains(entry.id) {
                            Text("保留现有译文").font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                        }
                    }
                }
            }
            .padding(10)
            .textSelection(.enabled)
        }
        .frame(height: 140)
        .background(theme.onSurface.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.menu))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.step == .prompt ? "Prompt 包含整首歌词的原文与逐行格式。" : "只更新翻译，保留打点、音译和分轨；可撤销。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 0)
            PillButton(title: "关闭", variant: .ghost, height: 32, action: close)
            if state.step == .prompt {
                PillButton(title: "复制 Prompt", systemName: "doc.on.doc", variant: .filled, height: 32, action: copyPrompt)
                    .disabled(promptText == nil)
            } else {
                PillButton(title: "应用翻译", systemName: "checkmark", variant: .filled, height: 32, action: apply)
                    .disabled(changes.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("应用翻译（⌘↩）")
            }
        }
    }

    private var promptText: String? {
        guard case .success(let text) = prompt else { return nil }
        return text
    }

    private func copyPrompt() {
        guard let text = promptText else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            actionError = "未能复制 Prompt，请重试。"
            return
        }
        copied = true
        state.step = .result
    }

    private func apply() {
        do {
            let updated = try session.applyTranslation(state.response, overwrite: state.overwrite)
            session.flash("已应用 \(updated) 行翻译，可用 ⌘Z 撤销")
            close()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
