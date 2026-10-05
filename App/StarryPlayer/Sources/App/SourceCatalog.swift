import Foundation
import Library
import LocalLibrary
import MusicSources
import PluginHost
import StarryCore

@MainActor
enum SourceCatalog {
    static func plugins(settings: AppSettings) -> PluginManager {
        PluginManager.installed(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            builtIn: Bundle.main.resourceURL?.appending(path: "builtin", directoryHint: .isDirectory),
            development: settings.plugins.developmentFolders.map { URL(fileURLWithPath: $0) },
            disabled: Set(settings.plugins.disabled),
            inspectable: settings.plugins.inspectable,
            logsCalls: settings.plugins.logsCalls
        )
    }

    static func localSource(settings: AppSettings, directory: DataDirectory) -> LocalSource {
        LocalSource(directory: directory, settings: settings.sourceSettings(.local))
    }

    /// The plugins' sources in load order, except that the first one the app comes with (they load
    /// in file name order) leads, so it is the one browsed at launch even with plugins installed.
    /// Those it comes with for a server of the listener's own (Jellyfin, Subsonic) come after its others:
    /// they have nothing to show before one is signed in to.
    static func pluginSources(settings: AppSettings, plugins: PluginManager) -> [PluginSource] {
        let loaded = plugins.sources { settings.sourceSettings($0) }
        let builtIn = { (source: PluginSource) in plugins.origin(of: source.plugin) == .builtIn }
        let ownServer = { (source: PluginSource) in builtIn(source) && source.account.serverPrompt != nil }
        var sources = loaded.filter { !ownServer($0) } + loaded.filter(ownServer)
        if let index = sources.firstIndex(where: builtIn) {
            sources.insert(sources.remove(at: index), at: 0)
        }
        return sources
    }
}
