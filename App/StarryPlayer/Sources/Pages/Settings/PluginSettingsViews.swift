import AppKit
import LyricsProviders
import PluginHost
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

// The plugins settings page: a row per plugin, the files that did not load, and the two ways
// to install. Changes apply at once (`AppModel.reloadPlugins`).

/// One plugin: what it is and gives, where it came from and the sites it may reach; its switch,
/// and update / homepage / reveal (not built-in) / remove.
struct PluginRow: View {
    var plugin: Plugin
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmingRemoval = false
    @State private var update: AppModel.PendingPlugin?
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        let manager = model.plugins
        let manifest = plugin.manifest
        let enabled = manager.isEnabled(plugin)
        let origin = manager.origin(of: plugin)
        HStack(alignment: .top, spacing: 12) {
            PluginIcon(symbol: manifest.icon, enabled: enabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(manifest.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.onSurface).lineLimit(1)
                    Text(manifest.version).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(theme.onSurfaceVariant)
                    ForEach(Self.kinds(plugin), id: \.self) { Tag(text: $0, soft: true) }
                    switch origin {
                    case .builtIn: Tag(text: "自带", style: .primary, soft: true)
                    case .development: Tag(text: "开发", style: .amber, soft: true)
                    case .installed: EmptyView()
                    }
                }
                if let description = manifest.description {
                    Text(description).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
                }
                Text(Self.details(plugin, replaced: manager.replaced[manifest.id]?.isEmpty == false))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.75))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")).lineLimit(3)
                }
            }
            .opacity(enabled ? 1 : 0.55)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                if model.settings.settings.plugins.addresses[manifest.id] != nil {
                    IconButton(systemName: "arrow.down.circle", size: 26, iconSize: 12, variant: .tertiary, help: "从原网址更新") { Task { await checkUpdate() } }
                        .disabled(checking)
                }
                if let homepage = manifest.homepage {
                    IconButton(systemName: "safari", size: 26, iconSize: 12, variant: .tertiary, help: "打开插件主页") { NSWorkspace.shared.open(homepage) }
                }
                if origin != .builtIn {
                    IconButton(systemName: "folder", size: 26, iconSize: 12, variant: .tertiary, help: "在访达中显示插件文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([plugin.file])
                    }
                }
                if origin == .installed {
                    IconButton(systemName: "trash", size: 26, iconSize: 11, variant: .tertiary, help: "移除这个插件") { confirmingRemoval = true }
                }
                SettingsSwitch(isOn: Binding { enabled } set: { model.setPlugin(plugin, enabled: $0) })
                    .padding(.leading, 6)
                    .help(enabled ? "关掉这个插件" : "打开这个插件")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("移除「\(manifest.name)」？", isPresented: $confirmingRemoval) {
            Button("移除", role: .destructive) {
                do {
                    try model.remove(plugin)
                } catch {
                    self.error = ErrorText.describe(error)
                }
            }
        } message: {
            Text(manager.replaced[manifest.id]?.isEmpty == false
                 ? "插件文件会被删除，改用播放器自带的版本。"
                 : "插件文件会被删除。它保存的登录信息和设置会留下，重新安装后还在。")
        }
        .pluginInstallConfirmation($update) { self.error = $0 }
    }

    private func checkUpdate() async {
        checking = true
        defer { checking = false }
        error = nil
        do {
            update = try await model.readUpdate(of: plugin)
        } catch {
            self.error = ErrorText.describe(error)
        }
    }

    static func kinds(_ plugin: Plugin) -> [String] {
        (plugin.isSource ? ["音源"] : []) + (plugin.isLyricsProvider ? ["歌词"] : []) + (plugin.hasAccount ? ["账号"] : [])
    }

    static func kinds(_ package: PluginPackage) -> [String] {
        (package.isSource ? ["音源"] : []) + (package.isLyricsProvider ? ["歌词"] : []) + (package.hasAccount ? ["账号"] : [])
    }

    static func details(_ plugin: Plugin, replaced: Bool) -> String {
        let manifest = plugin.manifest
        var parts = [manifest.id]
        if let author = manifest.author { parts.append("作者 \(author)") }
        parts.append(access(manifest.hosts))
        if replaced { parts.append("代替了播放器自带的版本") }
        return parts.joined(separator: " · ")
    }

    static func access(_ hosts: [String]) -> String {
        if hosts.isEmpty { return "不联网" }
        if hosts.contains("*") { return "可以访问任何网站" }
        return "可以访问 " + hosts.joined(separator: "、")
    }
}

struct PluginIcon: View {
    var symbol: String?
    var enabled = true
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((enabled ? theme.accent : theme.onSurface).opacity(theme.isDark ? 0.18 : 0.12))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: symbol ?? "puzzlepiece.extension")
                    .symbolVariant(.fill)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(enabled ? theme.accent : theme.onSurfaceVariant)
            }
    }
}

/// A file that did not load, and why; one in the plugin folder can be removed from here.
struct PluginFailureRow: View {
    var failure: PluginManager.Failure
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: "#F0625D").opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A"))
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.file.lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.onSurface).lineLimit(1)
                Text(failure.message).font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant).lineLimit(4).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                IconButton(systemName: "folder", size: 26, iconSize: 12, variant: .tertiary, help: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([failure.file])
                }
                if failure.origin == .installed {
                    IconButton(systemName: "trash", size: 26, iconSize: 11, variant: .tertiary, help: "删除这个文件") { confirmingRemoval = true }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("删除「\(failure.file.lastPathComponent)」？", isPresented: $confirmingRemoval) {
            Button("删除", role: .destructive) { try? model.removePluginFile(failure) }
        } message: {
            Text("文件会从插件文件夹里删除。")
        }
    }
}

struct PluginFileInstaller: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var pending: AppModel.PendingPlugin?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 10) {
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
            }
            SettingsButton(title: "选择文件…", systemName: "doc.badge.plus") { choose() }
        }
        .pluginInstallConfirmation($pending) { error = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]
        panel.allowsMultipleSelection = false
        panel.message = "选择一个插件文件（.js）"
        panel.prompt = "读取"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        error = nil
        do {
            pending = try model.readPlugin(file: file)
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

struct PluginAddressInstaller: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var pending: AppModel.PendingPlugin?
    @State private var reading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://example.com/my-plugin.js", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { Task { await read() } }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(theme.onSurface.opacity(focused ? 0.08 : 0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.onSurface.opacity(focused ? 0.16 : 0), lineWidth: 1))
                SettingsButton(title: reading ? "读取中…" : "安装", systemName: "arrow.down.circle") { Task { await read() } }
                    .disabled(reading || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")).lineLimit(3)
            }
        }
        .pluginInstallConfirmation($pending) { error = $0 }
        .onChange(of: pending == nil) { _, done in
            if done, error == nil { address = "" }
        }
    }

    private func read() async {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !reading else { return }
        error = nil
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            error = "请输入 http:// 或 https:// 开头的地址"
            return
        }
        reading = true
        defer { reading = false }
        do {
            pending = try await model.readPlugin(address: url)
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

extension View {
    /// Asks before `pending` is installed: what it gives, the sites it may reach, what it replaces.
    /// `failed` gets the reason an install did not go through.
    func pluginInstallConfirmation(_ pending: Binding<AppModel.PendingPlugin?>, failed: @escaping (String) -> Void) -> some View {
        modifier(PluginInstallConfirmation(pending: pending, failed: failed))
    }
}

private struct PluginInstallConfirmation: ViewModifier {
    @Binding var pending: AppModel.PendingPlugin?
    var failed: (String) -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding { pending != nil } set: { if !$0 { pending = nil } }, presenting: pending) { pending in
            Button(model.pluginReplaced(by: pending) == nil ? "安装" : "替换") {
                do {
                    try model.install(pending)
                } catch {
                    failed(ErrorText.describe(error))
                }
            }
        } message: { pending in
            Text(message(pending))
        }
    }

    private var title: String {
        guard let manifest = pending?.package.manifest else { return "" }
        return "安装「\(manifest.name)」\(manifest.version)？"
    }

    private func message(_ pending: AppModel.PendingPlugin) -> String {
        let package = pending.package
        let manifest = package.manifest
        var lines: [String] = []
        let kinds = PluginRow.kinds(package)
        if !kinds.isEmpty { lines.append("提供：" + kinds.joined(separator: "、")) }
        lines.append(PluginRow.access(manifest.hosts))
        if manifest.idNamespace != nil {
            let platform = model.platformName(manifest.sourceID)
            lines.append(package.isSource ? "它会接管「\(platform)」：这个平台已有的歌曲、账号和设置都交给它" : "它会提供「\(platform)」的歌词，在歌词来源顺序里占用这一项")
        }
        if let replaced = model.pluginReplaced(by: pending) {
            let origin = model.plugins.origin(of: replaced) == .builtIn ? "播放器自带的" : "已安装的"
            lines.append("将替换\(origin) \(replaced.manifest.version)")
        }
        if let author = manifest.author { lines.append("作者：\(author)") }
        lines.append("只安装来源可信的插件。")
        return lines.joined(separator: "\n")
    }
}
