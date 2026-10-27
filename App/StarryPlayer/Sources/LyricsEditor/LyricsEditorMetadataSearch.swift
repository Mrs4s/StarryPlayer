import AppKit
import LyricsCore
import Observation
import SwiftUI

@MainActor @Observable
final class LyricsEditorMetadataSearchState {
    enum Step { case prompt, result }
    var step: Step = .prompt
    var fields = Set(LyricsMetadataSearch.Field.allCases)
    var instructions = ""
    var response = ""
    var overwrite = false
}

extension LyricsEditorSession {
    func metadataSearchPreview(_ entries: [LyricsMetadataSearch.Entry], overwrite: Bool) -> (metadata: [MetadataEntry], fields: Set<LyricsMetadataSearch.Field>) {
        var next = metadata
        var fields: Set<LyricsMetadataSearch.Field> = []
        for entry in entries where !entry.values.isEmpty {
            let key = entry.field.rawValue
            let existing = next.filter { $0.key == key }
            guard overwrite || existing.allSatisfy({ $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            guard existing.map(\.value) != entry.values else { continue }
            let insertion = next.firstIndex { $0.key == key } ?? next.count
            let replacements = entry.values.enumerated().map { index, value in
                MetadataEntry(id: index < existing.count ? existing[index].id : UUID(), key: key, value: value)
            }
            next.removeAll { $0.key == key }
            next.insert(contentsOf: replacements, at: insertion)
            fields.insert(entry.field)
        }
        return (next, fields)
    }
}

struct LyricsEditorMetadataSearch: View {
    let session: LyricsEditorSession
    var close: () -> Void
    @Bindable private var state: LyricsEditorMetadataSearchState
    @Environment(\.theme) private var theme
    @FocusState private var responseFocused: Bool
    @State private var actionError: String?
    @State private var copied = false

    init(session: LyricsEditorSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        self.state = session.metadataSearch
    }

    private var prompt: Result<String, Error> {
        Result {
            try LyricsMetadataSearch.prompt(fields: state.fields, metadata: session.metadata.map { .init(key: $0.key, value: $0.value) },
                                            title: session.track.title, artists: session.track.artists.map(\.name), album: session.track.album?.name ?? "",
                                            duration: session.track.duration, lyrics: session.draft.lines.map(\.text), instructions: state.instructions)
        }
    }

    private var result: Result<[LyricsMetadataSearch.Entry], Error>? {
        guard !state.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result { try LyricsMetadataSearch.parse(state.response, fields: state.fields) }
    }

    private var entries: [LyricsMetadataSearch.Entry] {
        guard case .success(let entries) = result else { return [] }
        return entries
    }

    private var changedFields: Set<LyricsMetadataSearch.Field> {
        session.metadataSearchPreview(entries, overwrite: state.overwrite).fields
    }

    var body: some View {
        EditorPanel(title: "AI 搜索歌曲信息", subtitle: "复制 Prompt 到支持联网搜索的 AI Chat，再将完整回复粘贴回来。", width: 760, close: close) {
            SegmentSwitch(selection: $state.step, options: [(.prompt, "1 · 复制 Prompt"), (.result, "2 · 粘贴结果")])
            if state.step == .prompt {
                promptSettings
                promptPreview
            } else {
                responseEditor
                responseSummary
                metadataPreview
                HStack(spacing: 8) {
                    SettingsSwitch(isOn: $state.overwrite)
                        .accessibilityLabel("覆盖已有歌曲信息")
                    Text("覆盖已有内容").font(.system(size: 12.5))
                    Text("关闭时只补全空白项目；查不到的项目保持原样")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.onSurface)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要搜索的项目").font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 10) {
                ForEach(LyricsMetadataSearch.Field.allCases, id: \.self) { field in
                    HStack(spacing: 6) {
                        SettingsSwitch(isOn: Binding { state.fields.contains(field) } set: { on in
                            if on { state.fields.insert(field) } else { state.fields.remove(field) }
                        })
                        .accessibilityLabel("搜索\(field.title)")
                        Text(field.title).font(.system(size: 12.5))
                    }
                }
            }
            TextField("补充线索或要求（可选），例如：日版专辑、录音室版本", text: $state.instructions)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("补充搜索线索或要求")
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
        .frame(height: 220)
        .background(theme.onSurface.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.menu))
        .accessibilityLabel("歌曲信息搜索 Prompt 预览")
    }

    private var responseEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(copied ? "Prompt 已复制，请在 AI Chat 中开启联网搜索。" : "粘贴 AI 的完整回复，核对歌曲版本和来源。")
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
                .frame(height: 115)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu))
                .overlay(RoundedRectangle(cornerRadius: Radius.menu).strokeBorder(theme.primary.opacity(responseFocused ? 0.35 : 0), lineWidth: 1))
                .accessibilityLabel("AI 返回的歌曲信息")
        }
    }

    @ViewBuilder
    private var responseSummary: some View {
        switch result {
        case .success(let entries):
            let found = entries.filter { !$0.values.isEmpty }.count
            let count = changedFields.count
            Label("找到 \(found) 项 · \(count == 0 ? "没有需要更新的内容" : "将更新 \(count) 项")", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primary)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("粘贴后可预览各项信息，并打开来源链接核对。")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    private var metadataPreview: some View {
        let changed = changedFields
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.field.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(theme.onSurface)
                            Spacer(minLength: 0)
                            Text(entry.values.isEmpty ? "未找到" : changed.contains(entry.field) ? "将更新" : "保留现有内容")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                        let current = session.metadata.filter { $0.key == entry.field.rawValue && !$0.value.isEmpty }.map(\.value)
                        if !current.isEmpty {
                            Text("当前：" + current.joined(separator: "、")).foregroundStyle(theme.onSurfaceVariant)
                        }
                        if !entry.values.isEmpty {
                            Text("搜索：" + entry.values.joined(separator: "、")).foregroundStyle(theme.onSurface)
                        }
                        if !entry.note.isEmpty {
                            Text(entry.note).foregroundStyle(theme.onSurfaceVariant)
                        }
                        ForEach(entry.sources.indices, id: \.self) { index in
                            let source = entry.sources[index]
                            Link(destination: source.url) {
                                Label(source.title.isEmpty ? source.url.host ?? "来源" : source.title, systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.primary)
                            .help(source.url.absoluteString)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(12)
            .textSelection(.enabled)
        }
        .frame(height: 200)
        .background(theme.onSurface.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.menu))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.step == .prompt ? "Prompt 包含当前歌曲信息和前 8 行非空歌词。" : "确认后回填歌曲信息，可用 ⌘Z 撤销。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 0)
            PillButton(title: "返回歌曲信息", variant: .ghost, height: 32, action: close)
            if state.step == .prompt {
                PillButton(title: "复制 Prompt", systemName: "doc.on.doc", variant: .filled, height: 32, action: copyPrompt)
                    .disabled(promptText == nil)
            } else {
                PillButton(title: "应用", systemName: "checkmark", variant: .filled, height: 32, action: apply)
                    .disabled(changedFields.isEmpty)
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
            let entries = try LyricsMetadataSearch.parse(state.response, fields: state.fields)
            let preview = session.metadataSearchPreview(entries, overwrite: state.overwrite)
            guard !preview.fields.isEmpty else { return }
            session.editMetadata(preview.metadata)
            session.flash("已更新 \(preview.fields.count) 项歌曲信息，可用 ⌘Z 撤销")
            close()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
