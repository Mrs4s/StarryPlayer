import Foundation
import LyricsProviders
import MusicSources
import os
import StarryCore

/// The plugins the app runs: those in the development folders, every `.js` file in the plugin
/// folder, then the ones the app comes with; the first of each id wins, so an installed copy
/// replaces the one built in. A plugin turned off (in the plugin settings) is still read, so the
/// page can list it, but is neither a source nor a lyrics provider.
public final class PluginManager: Sendable {
    public enum Origin: String, Sendable, Hashable {
        case development
        case installed
        case builtIn
    }

    public struct Location: Sendable, Hashable {
        public var url: URL
        public var origin: Origin

        public init(_ url: URL, origin: Origin) {
            self.url = url
            self.origin = origin
        }
    }

    /// A file that is not a plugin this host runs, and why.
    public struct Failure: Sendable, Hashable {
        public var file: URL
        public var origin: Origin
        public var message: String
    }

    public static let empty = PluginManager(plugins: [], origins: [:], failures: [], replaced: [:], disabled: [])

    public static func installDirectory(in data: DataDirectory = DataDirectory()) -> URL {
        data.url.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    static func storageDirectory(in data: DataDirectory) -> URL {
        data.url.appending(path: "PluginData", directoryHint: .isDirectory)
    }

    public let plugins: [Plugin]
    public let failures: [Failure]
    public let replaced: [String: [URL]]
    public let disabled: Set<String>
    private let origins: [String: Origin]

    private init(plugins: [Plugin], origins: [String: Origin], failures: [Failure], replaced: [String: [URL]], disabled: Set<String>) {
        self.plugins = plugins
        self.origins = origins
        self.failures = failures
        self.replaced = replaced
        self.disabled = disabled
    }

    public convenience init(paths: [URL], options: Plugin.Options, disabled: Set<String> = []) {
        self.init(locations: paths.map { Location($0, origin: .installed) }, options: options, disabled: disabled)
    }

    /// Loads every plugin in `locations`, in order. A plugin that would be a platform's source or
    /// lyrics provider (`idNamespace`) when an earlier plugin that is on already is, is not loaded:
    /// a platform can have one of each, from one plugin or two (a source plugin and a lyrics plugin).
    public convenience init(locations: [Location], options: Plugin.Options, disabled: Set<String> = []) {
        let logger = Logger(subsystem: "moe.mrs4s.starry-player", category: "plugin")
        var plugins: [Plugin] = []
        var origins: [String: Origin] = [:]
        var failures: [Failure] = []
        var replaced: [String: [URL]] = [:]
        for (file, origin) in Self.files(in: locations) {
            do {
                let plugin = try Plugin.load(file: file, options: options)
                let id = plugin.manifest.id
                if plugins.contains(where: { $0.manifest.id == id }) {
                    replaced[id, default: []].append(file)
                    logger.info("\(file.path, privacy: .public): \(id, privacy: .public) is loaded from an earlier file")
                    continue
                }
                if let namespace = plugin.manifest.idNamespace, !disabled.contains(id) {
                    let rival = plugins.first { other in
                        other.manifest.sourceID == plugin.manifest.sourceID && !disabled.contains(other.manifest.id)
                            && (other.isSource && plugin.isSource || other.isLyricsProvider && plugin.isLyricsProvider)
                    }
                    if let first = rival {
                        let role = first.isSource && plugin.isSource ? "" : "的歌词"
                        throw PluginError.load("\(plugin.manifest.name)：\(namespace)\(role) 已由 \(first.manifest.name)（\(first.file.lastPathComponent)）提供")
                    }
                }
                plugins.append(plugin)
                origins[id] = origin
                logger.info("loaded plugin \(id, privacy: .public) \(plugin.manifest.version, privacy: .public) from \(file.path, privacy: .public)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                failures.append(Failure(file: file, origin: origin, message: message))
                logger.error("\(file.path, privacy: .public): \(message, privacy: .public)")
            }
        }
        self.init(plugins: plugins, origins: origins, failures: failures, replaced: replaced, disabled: disabled)
    }

    public static func installed(data: DataDirectory = DataDirectory(), appVersion: String, builtIn: URL? = nil,
                                 development: [URL] = [], disabled: Set<String> = [], inspectable: Bool = false,
                                 logsCalls: Bool = false) -> PluginManager {
        let options = Plugin.Options(
            storageDirectory: storageDirectory(in: data),
            appVersion: appVersion,
            inspectable: inspectable,
            logsCalls: logsCalls
        )
        let locations = development.map { Location($0, origin: .development) } + [Location(installDirectory(in: data), origin: .installed)] + (builtIn.map { [Location($0, origin: .builtIn)] } ?? [])
        return PluginManager(locations: locations, options: options, disabled: disabled)
    }

    private static func files(in locations: [Location]) -> [(URL, Origin)] {
        let manager = FileManager.default
        return locations.flatMap { location -> [(URL, Origin)] in
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: location.url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return [(location.url, location.origin)] }
            let contents = (try? manager.contentsOfDirectory(at: location.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return contents.filter { $0.pathExtension == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, location.origin) }
        }
    }

    public func origin(of plugin: Plugin) -> Origin { origins[plugin.manifest.id] ?? .installed }

    public func isEnabled(_ plugin: Plugin) -> Bool { !disabled.contains(plugin.manifest.id) }

    public var enabledPlugins: [Plugin] { plugins.filter(isEnabled) }

    public func plugin(id: String) -> Plugin? { plugins.first { $0.manifest.id == id } }

    public func sources(settings: (SourceID) -> SourceSettingValues) -> [PluginSource] {
        enabledPlugins.filter(\.isSource).map { PluginSource(plugin: $0, settings: settings($0.manifest.sourceID)) }
    }

    public func lyricsProviders(cache: LyricsCache, settings: (SourceID) -> SourceSettingValues) -> [ExternalLyricsProvider] {
        enabledPlugins.compactMap { plugin in
            if !plugin.isSource { plugin.applySettings(settings(plugin.settingsID), notify: false) }
            return plugin.lyricsProvider(cache: cache)
        }
    }
}
