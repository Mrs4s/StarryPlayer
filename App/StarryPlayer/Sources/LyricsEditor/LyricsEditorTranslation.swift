import AppKit
import LyricsCore
import Observation
import SwiftUI

/// Kept with the editing session so closing the panel does not lose a pasted response.
@MainActor @Observable
final class LyricsEditorTranslationState {
    enum Step { case prompt, result }
    static let languageKey = "starry.lyricsEditor.translation.language"
    static let styleKey = "starry.lyricsEditor.translation.style"
    static let rubyScriptKey = "starry.lyricsEditor.translation.rubyScript"
    static let defaultLanguage = "简体中文"
    static let defaultRubyScript = "平假名"

    var step: Step = .prompt
    var fields: LyricsTranslation.Fields = .translation
    var language: String
    var style: LyricsTranslation.Style
    var rubyScript: String
    var instructions = ""
    var response = ""
    var overwrite = false

    init(defaults: UserDefaults = .standard) {
        language = Self.stored(Self.languageKey, in: defaults) ?? Self.defaultLanguage
        style = defaults.string(forKey: Self.styleKey).flatMap(LyricsTranslation.Style.init(rawValue:)) ?? .accurate
        rubyScript = Self.stored(Self.rubyScriptKey, in: defaults) ?? Self.defaultRubyScript
    }

    private static func stored(_ key: String, in defaults: UserDefaults) -> String? {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

extension LyricsEditorSession {
    @discardableResult
    func applyTranslation(_ response: String, fields: LyricsTranslation.Fields = .translation, overwrite: Bool = false) throws -> LyricsTranslation.Changes {
        var next = draft
        let changes = try LyricsTranslation.apply(response, to: &next, fields: fields, overwrite: overwrite)
        edit { $0 = next }
        return changes
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
            try LyricsTranslation.prompt(for: session.draft, fields: state.fields, language: state.language, style: state.style, rubyScript: state.rubyScript,
                                         instructions: state.instructions, title: session.track.title, artist: session.track.artistText)
        }
    }

    private var result: Result<[LyricsTranslation.Entry], Error>? {
        guard !state.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result { try LyricsTranslation.parse(state.response, for: session.draft, fields: state.fields) }
    }

    private var entries: [LyricsTranslation.Entry] {
        guard case .success(let entries) = result else { return [] }
        return entries
    }

    private var changes: LyricsTranslation.Changes {
        var preview = session.draft
        return LyricsTranslation.apply(entries, to: &preview, overwrite: state.overwrite)
    }

    var body: some View {
        EditorPanel(title: "AI 翻译与注音", subtitle: "复制 Prompt 给你使用的 AI，再将它的完整回复粘贴回来。", width: 720, close: close) {
            SegmentSwitch(selection: $state.step, options: [(.prompt, "1 · 复制 Prompt"), (.result, "2 · 粘贴结果")])
            if state.step == .prompt {
                promptSettings
                promptPreview
            } else {
                responseEditor
                responseSummary
                translationPreview
                HStack(spacing: 8) {
                    SettingsSwitch(isOn: $state.overwrite)
                        .accessibilityLabel("覆盖已有内容")
                    Text("覆盖已有内容")
                        .font(.system(size: 12.5))
                    Text("关闭时只补全空白的翻译、音译和注音")
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
            HStack(spacing: 16) {
                Text("生成").font(.system(size: 12, weight: .medium))
                fieldToggle(.translation, "翻译")
                fieldToggle(.romanization, "音译")
                fieldToggle(.ruby, "注音")
                Spacer(minLength: 0)
            }
            if state.fields.contains(.translation) {
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
            }
            if state.fields.contains(.ruby) {
                HStack(spacing: 14) {
                    Text("注音用字").font(.system(size: 12, weight: .medium))
                    TextField("例如：平假名、带声调拼音", text: $state.rubyScript)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(8)
                        .frame(width: 190)
                        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("注音用字")
                    Text("为汉字和日式英语生成注音；跨音节的读音会共享注音")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
            }
            TextField("补充要求（可选），例如：保留人名原文、用词简洁", text: $state.instructions)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("补充翻译要求")
        }
        .foregroundStyle(theme.onSurface)
    }

    private func fieldToggle(_ field: LyricsTranslation.Fields, _ title: String) -> some View {
        HStack(spacing: 6) {
            SettingsSwitch(isOn: Binding { state.fields.contains(field) } set: { on in
                if on { state.fields.insert(field) } else { state.fields.remove(field) }
            })
            .accessibilityLabel("生成\(title)")
            Text(title).font(.system(size: 12.5))
        }
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
                Text(copied ? "Prompt 已复制，交给 AI 处理后把完整回复粘贴到这里。" : "粘贴 AI 的完整回复，然后核对下方结果。")
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
                .accessibilityLabel("AI 返回的结果")
        }
    }

    @ViewBuilder
    private var responseSummary: some View {
        switch result {
        case .success(let entries):
            let changes = changes
            Label("已匹配 \(entries.count) 行 · \(changes.isEmpty ? "没有需要更新的内容" : "将更新 \(changes.summary)")", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primary)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("原文会自动逐行匹配，粘贴后可预览结果。")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private var translationPreview: some View {
        let updatedIDs = changes.lines
        let lines = Dictionary(session.draft.lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                            if let translation = entry.translation { Text(translation).foregroundStyle(theme.onSurface) }
                            if let romanization = entry.romanization, !romanization.isEmpty {
                                Text(romanization).italic().foregroundStyle(theme.onSurface.opacity(0.8))
                            }
                            if let ruby = rubyText(entry, line: lines[entry.id]) { Text(ruby).foregroundStyle(theme.onSurface.opacity(0.8)) }
                        }
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !updatedIDs.contains(entry.id) {
                            Text("保留现有内容").font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
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

    private func rubyText(_ entry: LyricsTranslation.Entry, line: LyricsDraft.Line?) -> String? {
        guard let ruby = entry.ruby, let line, ruby.count == line.syllables.count else { return nil }
        let joins = entry.rubyJoins ?? []
        var pairs: [String] = []
        var s = 0
        while s < ruby.count {
            var end = s
            while end + 1 < min(ruby.count, joins.count), joins[end + 1] { end += 1 }
            if !ruby[s].isEmpty {
                pairs.append("\(line.syllables[s...end].map { $0.text.trimmingCharacters(in: .whitespaces) }.joined())(\(ruby[s]))")
            }
            s = end + 1
        }
        return pairs.isEmpty ? nil : "注音：" + pairs.joined(separator: "  ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.step == .prompt ? "Prompt 包含整首歌词的原文与逐行格式。" : "只更新勾选的内容，保留打点和分轨；可撤销。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 0)
            PillButton(title: "关闭", variant: .ghost, height: 32, action: close)
            if state.step == .prompt {
                PillButton(title: "复制 Prompt", systemName: "doc.on.doc", variant: .filled, height: 32, action: copyPrompt)
                    .disabled(promptText == nil)
            } else {
                PillButton(title: "应用", systemName: "checkmark", variant: .filled, height: 32, action: apply)
                    .disabled(changes.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("应用（⌘↩）")
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
            let changes = try session.applyTranslation(state.response, fields: state.fields, overwrite: state.overwrite)
            session.flash("已应用 \(changes.summary)，可用 ⌘Z 撤销")
            close()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
