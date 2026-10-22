import SwiftUI

private struct EditorPanel<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var width: CGFloat
    var close: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.4 : 0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.onSurface)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(theme.onSurfaceVariant)
                        }
                    }
                    Spacer(minLength: 12)
                    IconButton(systemName: "xmark", size: 28, iconSize: 11, help: "关闭（Esc）", action: dismiss)
                }
                content
            }
            .padding(22)
            .frame(width: width)
            .background(theme.surfacePanel, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(theme.onSurface.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 30, y: 12)
            .scaleEffect(shown ? 1 : 0.96)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
        }
        .modifier(WindowCancelShortcut(action: dismiss))
        .onAppear { withAnimation(Motion.searchOpen) { shown = true } }
    }

    private func dismiss() {
        withAnimation(Motion.searchClose) { shown = false }
        close()
    }
}

// MARK: - Shortcuts

struct LyricsEditorShortcuts: View {
    var close: () -> Void
    @Environment(\.theme) private var theme

    private struct Group {
        var title: String
        var keys: [(keys: [String], action: String)]
    }

    private let groups: [Group] = [
        Group(title: "打点", keys: [
            (["F", "G", "J"], "开始当前音节，并结束上一个"),
            (["H", "K", "↩"], "结束刚唱的音节（停顿、行尾）"),
            (["⌫"], "撤回上一次打点"),
            (["⌥←", "⌥→"], "微调当前音节 10 毫秒"),
            (["⌥⇧←", "⌥⇧→"], "微调当前音节 100 毫秒"),
        ]),
        Group(title: "移动", keys: [
            (["A", "D"], "上一个 / 下一个音节"),
            (["W", "S"], "上一行 / 下一行"),
            (["←", "→", "↑", "↓"], "同上"),
            (["R", "Y"], "移到上一个 / 下一个音节并从那里播放"),
            (["Home", "End"], "移到行首 / 行尾并从那里播放"),
        ]),
        Group(title: "播放", keys: [
            (["空格"], "播放 / 暂停，立即生效"),
            (["⇧←", "⇧→"], "后退 / 前进 3 秒"),
            (["Q"], "从当前行稍前一点播放"),
            (["[", "]"], "减慢 / 加快，音高不变"),
            (["'"], "恢复原速"),
        ]),
        Group(title: "文件", keys: [
            (["⌘I"], "导入歌词"),
            (["⌘E"], "导出 TTML"),
            (["⌘S"], "应用到这首歌"),
            (["⌘Z", "⇧⌘Z"], "撤销 / 重做"),
            (["?"], "显示快捷键"),
        ]),
    ]

    var body: some View {
        EditorPanel(title: "快捷键", width: 720, close: close) {
            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    group(groups[0])
                    group(groups[1])
                }
                GridRow {
                    group(groups[2])
                    group(groups[3])
                }
            }
        }
    }

    private func group(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
            ForEach(group.keys, id: \.action) { entry in
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        ForEach(entry.keys, id: \.self) { KeyCap(text: $0) }
                    }
                    .frame(width: 118, alignment: .leading)
                    Text(entry.action)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurface.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyCap: View {
    var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.onSurface.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.onSurface.opacity(0.07)))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.onSurface.opacity(0.12), lineWidth: 1)
            }
    }
}

// MARK: - Metadata

struct LyricsEditorMetadata: View {
    let session: LyricsEditorSession
    var close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        EditorPanel(title: "歌曲信息", subtitle: "导出和应用时写进 TTML，AMLL 歌词库靠这些找到歌曲。", width: 600, close: close) {
            VStack(alignment: .leading, spacing: 6) {
                if session.metadata.isEmpty {
                    Text("还没有信息")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(session.metadata) { entry in
                            MetadataRow(session: session, entry: entry)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Motion.listEdit, value: session.metadata.map(\.id))
                HStack {
                    PopMenu {
                        for key in LyricsEditorSession.metadataKeys {
                            PopMenuItem.button(key.name) { add(key.key) }
                        }
                    } label: { _ in
                        Label("添加", systemImage: "plus")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.onSurface.opacity(0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                    }
                    .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
                    Spacer()
                    PillButton(title: "完成", variant: .filled, height: 32, action: close)
                }
                .padding(.top, 6)
            }
        }
    }

    private func add(_ key: String) {
        let entry = LyricsEditorSession.MetadataEntry(key: key, value: "")
        if let last = session.metadata.lastIndex(where: { $0.key == key }) {
            session.metadata.insert(entry, at: last + 1)
        } else {
            session.metadata.append(entry)
        }
    }
}

private struct MetadataRow: View {
    let session: LyricsEditorSession
    let entry: LyricsEditorSession.MetadataEntry
    @Environment(\.theme) private var theme
    @State private var text = ""
    @FocusState private var focused: Bool

    private var name: String {
        LyricsEditorSession.metadataKeys.first { $0.key == entry.key }?.name ?? entry.key
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
                .help(entry.key)
            TextField(entry.key, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
                .onAppear {
                    text = entry.value
                    if entry.value.isEmpty { focused = true }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(theme.primary.opacity(focused ? 0.5 : 0), lineWidth: 1))
                .animation(Motion.hover, value: focused)
            IconButton(systemName: "minus.circle", size: 26, iconSize: 12, help: "删除") {
                session.metadata.removeAll { $0.id == entry.id }
            }
        }
    }

    private func apply() {
        guard let index = session.metadata.firstIndex(where: { $0.id == entry.id }) else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        if session.metadata[index].value != value { session.metadata[index].value = value }
    }
}
