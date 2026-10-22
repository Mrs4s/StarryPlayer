import AppKit
import LyricsCore
import LyricsProviders
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorImport: View {
    let session: LyricsEditorSession
    var close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var text = ""
    @State private var pairsTranslations = true
    @State private var result: Result<LyricsDraft, Error>?
    @State private var shown = false
    @State private var finding = false
    @FocusState private var focused: Bool

    private var kind: LyricsDraftImport.Kind { LyricsDraftImport.kind(of: text) }
    private var draft: LyricsDraft? { if case .success(let draft) = result { draft } else { nil } }

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.4 : 0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            card
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
        }
        .modifier(WindowCancelShortcut(action: dismiss))
        .onAppear {
            withAnimation(Motion.searchOpen) { shown = true }
            focused = true
        }
        .task(id: "\(pairsTranslations)\(text)") {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let parsed: Result<LyricsDraft, Error>? = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Result { try LyricsDraftImport.draft(from: text, pairsTranslations: pairsTranslations) }
            withAnimation(Motion.hover) { result = parsed }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("快速导入").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.onSurface)
                Text("粘贴歌词或打开歌词文件，自动分好音节，接着就能跟着歌逐字打点。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            HStack(spacing: 8) {
                source("粘贴", systemImage: "doc.on.clipboard") {
                    if let pasted = NSPasteboard.general.string(forType: .string) { text = pasted }
                }
                source("打开文件…", systemImage: "folder", action: openFile)
                source(finding ? "正在查找…" : "这首歌的歌词", systemImage: "text.quote", action: findLyrics)
                    .disabled(finding)
                    .help("从歌词来源找这首歌的歌词，已有的时间会保留")
            }
            editor
            summary
            if let draft, !draft.isEmpty { splitPreview(draft) }
            footer
        }
        .padding(22)
        .frame(width: 640)
        .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 30, y: 12)
        .animation(Motion.popover, value: draft?.lines.count)
    }

    private func source(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        PillButton(title: title, systemName: systemImage, variant: .tertiary, height: 28, action: action)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("每行一句歌词，例如：\n\n君の名は\nHel|lo world（用 | 手动分开音节）\n\n也可以直接粘贴 LRC、TTML、YRC、QRC 或 KRC 歌词，已有的时间会保留。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
        }
        .frame(minHeight: 180, maxHeight: 280)
        .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous).strokeBorder(theme.primary.opacity(focused ? 0.35 : 0), lineWidth: 1))
        .animation(Motion.hover, value: focused)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if kind != .empty {
                Tag(text: kindName, style: .primary, soft: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            switch result {
            case .success(let draft):
                Text(stats(of: draft))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .contentTransition(.numericText())
            case .failure:
                Text("读不出歌词，检查一下格式")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A"))
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
            if kind == .lineTimed {
                Text("同一时间的第二行作为翻译").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                SettingsSwitch(isOn: $pairsTranslations)
            }
        }
        .frame(height: 22)
    }

    private var kindName: String {
        switch kind {
        case .empty: ""
        case .plainText: "纯文本"
        case .lineTimed: "LRC · 逐行时间"
        case .syllableTimed(let format): "\(format.rawValue.uppercased()) · 逐字时间"
        }
    }

    private func stats(of draft: LyricsDraft) -> String {
        var parts = ["\(draft.lines.count) 行", "\(draft.syllableCount) 个音节"]
        if draft.timedCount > 0 { parts.append("\(draft.timedCount) 个已有时间") }
        let translated = draft.lines.filter { !$0.translation.isEmpty }.count
        if translated > 0 { parts.append("\(translated) 行带翻译") }
        return parts.joined(separator: " · ")
    }

    private func splitPreview(_ draft: LyricsDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("拆分预览").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.onSurfaceVariant)
            ForEach(Array(draft.lines.prefix(3))) { line in
                LyricsFlowLayout(spacing: 3, lineSpacing: 3) {
                    ForEach(line.syllables) { syllable in
                        Text(syllable.text.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.onSurface.opacity(0.85))
                            .padding(.horizontal, 5)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.primary.opacity(syllable.isTimed ? 0.14 : 0.06)))
                            .padding(.trailing, syllable.text.hasSuffix(" ") ? 5 : 0)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !session.draft.isEmpty {
                Label("会替换现在的 \(session.draft.lines.count) 行，可以撤销", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            PillButton(title: "取消", variant: .ghost, height: 32, action: dismiss)
            PillButton(title: "导入", systemName: "arrow.down.to.line", variant: .filled, height: 32, action: commit)
                .disabled(draft?.isEmpty ?? true)
                .opacity(draft?.isEmpty ?? true ? 0.45 : 1)
                .animation(Motion.hover, value: draft == nil)
                .keyboardShortcut(.return, modifiers: .command)
                .help("导入（⌘↩）")
        }
    }

    private func commit() {
        guard let draft, !draft.isEmpty else { return }
        session.replace(with: draft)
        session.flash(draft.timedCount == draft.syllableCount ? "已导入 \(draft.lines.count) 行" : "已导入 \(draft.lines.count) 行，播放后按 F 开始打点")
        dismiss()
    }

    private func findLyrics() {
        finding = true
        Task {
            let found = await model.findLyricsDraft(for: session.track)
            finding = false
            guard let found else { return session.flash("没找到这首歌的歌词") }
            session.replace(with: found)
            session.flash("已载入这首歌的歌词")
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(Motion.searchClose) { shown = false }
        close()
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = LyricsFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "打开"
        let read: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            if let file = LyricsFile(name: url.lastPathComponent, data: data) {
                text = file.text
            } else {
                session.flash("「\(url.lastPathComponent)」里没有可用的歌词")
            }
        }
        if let window = model.lyricsEditorWindow.window {
            panel.beginSheetModal(for: window, completionHandler: read)
        } else {
            panel.begin(completionHandler: read)
        }
    }
}
