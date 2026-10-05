import AppKit
import LocalLibrary
import StarryCore
import SwiftUI

struct LocalLibrarySummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let status = model.localStatus
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.accent.opacity(0.12))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "internaldrive").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(status.folders.isEmpty ? "还没有添加文件夹" : "\(status.trackCount) 首歌 · \(status.folders.count) 个文件夹")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(status.trackCount)))
                Text(Self.statusLine(status))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !status.folders.isEmpty {
                SettingsButton(title: "重新扫描", systemName: "arrow.clockwise") {
                    Task { await model.localSource?.rescan() }
                }
                .disabled(status.isBusy)
            }
            SettingsButton(title: "添加文件夹…", systemName: "plus", role: status.folders.isEmpty ? .prominent : .normal) { model.chooseLocalFolders() }
        }
        .animation(Motion.reveal, value: status)
        .padding(16)
    }

    static func statusLine(_ status: LibraryStatus) -> String {
        if let progress = status.progress {
            return progress.total > 0 ? "正在扫描「\(progress.folder)」\(progress.done) / \(progress.total)" : "正在查看「\(progress.folder)」里的变化…"
        }
        if status.isBusy { return "准备扫描…" }
        if status.folders.isEmpty { return "添加存放音乐的文件夹，里面的歌会出现在本地音乐里" }
        guard let last = status.folders.compactMap(\.lastScan).max() else { return "等待扫描" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateTimeStyle = .named
        let when = Date().timeIntervalSince(last) < 60 ? "刚刚" : formatter.localizedString(for: last, relativeTo: Date())
        return "上次扫描：\(when)"
    }
}

struct LocalFolderRow: View {
    var folder: LibraryFolder
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isOffline ? "externaldrive.badge.xmark" : "folder.fill")
                .font(.system(size: 17))
                .foregroundStyle(folder.isOffline ? theme.onSurfaceVariant : theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(folder.isOffline ? Color(hex: theme.isDark ? "#F5B94E" : "#C47F12") : theme.onSurfaceVariant)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Menu {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                    .disabled(folder.isOffline)
                Button("重新扫描") { Task { await model.localSource?.rescan(folder.id) } }
                Button("重新读取所有文件") { Task { await model.localSource?.rescan(folder.id, rereadTags: true) } }
                Menu("旧标签的编码") {
                    Picker("旧标签的编码", selection: encodingBinding) {
                        Text("自动识别").tag(LegacyEncoding?.none)
                        Divider()
                        ForEach(LegacyEncoding.allCases.filter { $0 != .utf8 }, id: \.self) { encoding in
                            Text(encoding.displayName).tag(LegacyEncoding?.some(encoding))
                        }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Button("移除文件夹…", role: .destructive) { confirmingRemoval = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
            .fixedSize()
            .help("文件夹操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog("从本地音乐移除「\(folder.url.lastPathComponent)」？", isPresented: $confirmingRemoval) {
            Button("移除", role: .destructive) {
                Task {
                    do {
                        try await model.localSource?.removeFolder(folder.id)
                    } catch {
                        model.showToast(ErrorText.describe(error))
                    }
                }
            }
        } message: {
            Text("文件本身不会被删除。之后再添加这个文件夹，歌曲的红心和播放次数会找回来。")
        }
    }

    private var details: String {
        var parts = [folder.isOffline ? "磁盘未连接" : "\(folder.trackCount) 首歌"]
        if folder.unsupportedCount > 0 { parts.append("\(folder.unsupportedCount) 个文件格式无法播放") }
        if folder.missingCount > 0 { parts.append("\(folder.missingCount) 首找不到文件") }
        if let encoding = folder.encoding { parts.append("标签按\(encoding.displayName)读取") }
        return parts.joined(separator: " · ")
    }

    private var encodingBinding: Binding<LegacyEncoding?> {
        Binding { folder.encoding } set: { encoding in
            Task { try? await model.localSource?.setEncoding(encoding, of: folder.id) }
        }
    }
}

/// Removing the songs that cannot be found, after a confirmation.
struct PurgeMissingButton: View {
    var count: Int
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        SettingsButton(title: "清除", systemName: "trash", role: .destructive) { confirming = true }
            .confirmationDialog("清除 \(count) 首找不到文件的歌？", isPresented: $confirming) {
                Button("清除", role: .destructive) {
                    Task {
                        let removed = (try? await model.localSource?.purgeMissing()) ?? 0
                        model.showToast("已清除 \(removed) 首歌")
                    }
                }
            } message: {
                Text("它们的红心、播放次数和在歌单里的位置会一起删除。文件只是暂时不在（比如拔下了移动硬盘）时不要清除。")
            }
    }
}
