import AppKit
import Foundation
import Library
import LyricsProviders
import PluginHost
import StarryCore

extension AppModel {
    enum PluginActionError: LocalizedError {
        case notRemovable(String)
        case noAddress(String)

        var errorDescription: String? {
            switch self {
            case .notRemovable(let plugin): "「\(plugin)」不是安装进来的插件，只能关掉"
            case .noAddress(let plugin): "「\(plugin)」不是从网址安装的，没有可以更新的地方"
            }
        }
    }

    struct PendingPlugin: Identifiable {
        var package: PluginPackage
        /// Where it was downloaded from; nil for a file.
        var address: URL?
        var id: String { package.manifest.id }
    }

    var pluginFolder: URL { PluginManager.installDirectory() }

    func readPlugin(file: URL) throws -> PendingPlugin {
        PendingPlugin(package: try PluginInstaller.inspect(file: file), address: nil)
    }

    func readPlugin(address: URL) async throws -> PendingPlugin {
        PendingPlugin(package: try await PluginInstaller.inspect(address: address), address: address)
    }

    func readUpdate(of plugin: Plugin) async throws -> PendingPlugin {
        guard let text = settings.settings.plugins.addresses[plugin.manifest.id], let address = URL(string: text) else {
            throw PluginActionError.noAddress(plugin.manifest.name)
        }
        return try await readPlugin(address: address)
    }

    func platformName(_ id: SourceID) -> String {
        registry.source(for: id)?.displayName ?? LyricsProviderID(source: id)?.displayName ?? id.key
    }

    /// The loaded plugin `pending` would take the place of, if any.
    func pluginReplaced(by pending: PendingPlugin) -> Plugin? {
        plugins.plugin(id: pending.package.manifest.id)
    }

    func install(_ pending: PendingPlugin) throws {
        let id = pending.package.manifest.id
        let installed = plugins.plugin(id: id).flatMap { plugins.origin(of: $0) == .installed ? $0.file : nil }
        try PluginInstaller.install(pending.package, into: pluginFolder, replacing: installed)
        var preferences = settings.settings.plugins
        preferences.addresses[id] = pending.address?.absoluteString
        preferences.disabled.removeAll { $0 == id }
        settings.settings.plugins = preferences
        reloadPlugins()
    }

    func remove(_ plugin: Plugin) throws {
        guard plugins.origin(of: plugin) == .installed else { throw PluginActionError.notRemovable(plugin.manifest.name) }
        try FileManager.default.removeItem(at: plugin.file)
        settings.settings.plugins.addresses[plugin.manifest.id] = nil
        reloadPlugins()
    }

    /// Deletes a file in the plugin folder that did not load.
    func removePluginFile(_ failure: PluginManager.Failure) throws {
        guard failure.origin == .installed else { return }
        try FileManager.default.removeItem(at: failure.file)
        reloadPlugins()
    }

    func setPlugin(_ plugin: Plugin, enabled: Bool) {
        let id = plugin.manifest.id
        var disabled = settings.settings.plugins.disabled.filter { $0 != id }
        if !enabled { disabled.append(id) }
        guard disabled != settings.settings.plugins.disabled else { return }
        settings.settings.plugins.disabled = disabled
        reloadPlugins()
    }

    func revealPluginFolder() {
        try? FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(pluginFolder)
    }
}
