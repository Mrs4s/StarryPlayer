import CryptoKit
import Foundation
import LyricsProviders
import MusicSources
import os
import StarryCore

public final class Plugin: Sendable {
    public struct Options: @unchecked Sendable {
        /// Where `starry.storage` keeps each plugin's values (`<id>.json`); nil keeps them in memory.
        public var storageDirectory: URL?
        public var appVersion: String
        public var inspectable: Bool
        public var logsCalls: Bool
        public var callTimeout: TimeInterval
        public var executionLimit: TimeInterval
        public var protocolClasses: [AnyClass]

        public init(storageDirectory: URL? = nil, appVersion: String = "0", inspectable: Bool = false, logsCalls: Bool = false, callTimeout: TimeInterval = 30, executionLimit: TimeInterval = 5, protocolClasses: [AnyClass] = []) {
            self.storageDirectory = storageDirectory
            self.appVersion = appVersion
            self.inspectable = inspectable
            self.logsCalls = logsCalls
            self.callTimeout = callTimeout
            self.executionLimit = executionLimit
            self.protocolClasses = protocolClasses
        }
    }

    public let manifest: PluginManifest
    public let file: URL
    let description: PluginDescription
    public let settingsSections: [SourceSettingsSection]
    private let runtime: PluginRuntime
    private let functions: Set<String>
    private let script: String
    private let info: String
    private let executionLimit: TimeInterval
    private let logsCalls: Bool

    /// Reads and runs `file`. Throws `PluginError.load` when it is not a plugin this host runs.
    public static func load(file: URL, options: Options) throws -> Plugin {
        let script: String
        do {
            script = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw PluginError.load("读不了 \(file.lastPathComponent)：\(error.localizedDescription)")
        }
        return try load(script: script, file: file, options: options)
    }

    static func load(script: String, file: URL, options: Options) throws -> Plugin {
        var runtimeOptions = PluginRuntime.Options(name: file.deletingPathExtension().lastPathComponent)
        runtimeOptions.inspectable = options.inspectable
        runtimeOptions.callTimeout = options.callTimeout
        runtimeOptions.executionLimit = options.executionLimit
        runtimeOptions.protocolClasses = options.protocolClasses
        let runtime = try PluginRuntime(options: runtimeOptions)
        // The manifest is only known once the file ran, so the network opens after that.
        let text = try runtime.load(script: script, url: file, info: try info(plugin: nil, options: options))
        let description: PluginDescription
        do {
            description = try JSONDecoder().decode(PluginDescription.self, from: Data(text.utf8))
        } catch {
            throw PluginError.load("\(file.lastPathComponent) 导出的对象格式不对：\(Self.describe(error))")
        }
        let manifest = try description.manifest()
        let info = try info(plugin: manifest, options: options)
        try runtime.configure(name: manifest.name, hosts: manifest.hosts,
                              storageFile: options.storageDirectory?.appending(path: "\(manifest.id).json", directoryHint: .notDirectory),
                              info: info)
        return Plugin(manifest: manifest, file: file, description: description, runtime: runtime, script: script, info: info, executionLimit: options.executionLimit, logsCalls: options.logsCalls)
    }

    private static func info(plugin manifest: PluginManifest?, options: Options) throws -> String {
        let plugin: [String: String] = manifest.map { ["id": $0.id, "name": $0.name, "version": $0.version] } ?? [:]
        let info: [String: Any] = ["plugin": plugin, "app": PluginEnvironment.app(version: options.appVersion)]
        return String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)
    }

    private init(manifest: PluginManifest, file: URL, description: PluginDescription, runtime: PluginRuntime, script: String, info: String, executionLimit: TimeInterval, logsCalls: Bool) {
        self.manifest = manifest
        self.file = file
        self.description = description
        self.runtime = runtime
        self.script = script
        self.info = info
        self.executionLimit = executionLimit
        self.logsCalls = logsCalls
        settingsSections = description.settings.map(\.section).filter { !$0.settings.isEmpty }
        functions = Set((description.source?.functions ?? []).map { "source.\($0)" } + (description.lyrics?.functions ?? []).map { "lyrics.\($0)" }
            + (description.account?.functions ?? []).map { "account.\($0)" })
        if description.lyrics != nil {
            LyricsProviderID.register(lyricsProviderID, name: manifest.name, detail: description.lyrics?.detail)
        }
    }

    public var isSource: Bool { description.source != nil }
    public var isLyricsProvider: Bool { description.lyrics != nil }
    public var hasAccount: Bool { description.account != nil }

    var webPagesOverride: [String: String]? { runtime.webPages.withLock { $0 } }

    public var lyricsProviderID: LyricsProviderID { LyricsProviderID(source: manifest.sourceID) ?? LyricsProviderID(plugin: manifest.id) }

    /// Where Settings keeps the plugin's values (`AppSettings.sources`): under its source's id, and
    /// a lyrics-only plugin's under its own `plugin:<id>` even when it stands for a platform, so it
    /// never shares the values of that platform's source.
    public var settingsID: SourceID { isSource ? manifest.sourceID : .plugin(id: manifest.id) }

    func has(_ path: String) -> Bool { functions.contains(path) }

    func call<Result: Decodable>(_ path: String, _ arguments: any Encodable & Sendable...) async throws -> Result {
        try await call(path, timeout: nil, arguments: arguments)
    }

    func call<Result: Decodable>(_ path: String, timeout: TimeInterval?, arguments: [any Encodable & Sendable]) async throws -> Result {
        let encoder = JSONEncoder()
        let json = "[" + (try arguments.map { String(decoding: try encoder.encode($0), as: UTF8.self) }).joined(separator: ",") + "]"
        let output: String
        let start = Date()
        func trace(_ outcome: String) {
            guard logsCalls else { return }
            let line = "\(path)(\(json.prefix(200))) \(Int(Date().timeIntervalSince(start) * 1000)) ms → \(outcome)"
            runtime.log(.default, line)
            FileHandle.standardError.write(Data("[plugin] \(manifest.id) \(line)\n".utf8))
        }
        do {
            output = try await runtime.invoke(path, argumentsJSON: json, timeout: timeout)
        } catch let failure as PluginRuntime.ScriptFailure {
            trace("threw \(failure.code ?? "-"): \(failure.message)")
            runtime.log(.info, "\(path) 出错：\(failure.code.map { "[\($0)] " } ?? "")\(failure.message)")
            throw Self.error(for: failure, plugin: manifest.name)
        } catch PluginRuntime.Failure.timeout {
            trace("timed out")
            runtime.log(.error, "\(path) 超时")
            throw PluginError.timeout(plugin: manifest.name, path: path)
        } catch {
            trace("\(error)")
            throw error
        }
        trace("\(output.utf8.count) bytes: \(output.prefix(160))")
        do {
            return try JSONDecoder().decode(Result.self, from: Data(output.utf8))
        } catch {
            let detail = Self.describe(error)
            runtime.log(.error, "\(path) 的结果格式不对：\(detail)")
            throw PluginError.badResult(plugin: manifest.name, path: path, detail: detail)
        }
    }

    static func error(for failure: PluginRuntime.ScriptFailure, plugin: String) -> any Error {
        switch failure.code {
        case "vipRequired": PlaybackError.vipRequired
        case "loginExpired": PlaybackError.loginExpired
        case "unavailableInRegion": PlaybackError.unavailableInRegion
        case "trialOnly": PlaybackError.trialOnly
        case "sourceUnreachable": PlaybackError.sourceUnreachable
        case "rankingHidden": UserSourceError.rankingHidden
        case "followsHidden": UserSourceError.followsHidden
        case "notSupported": SourceError.notImplemented(failure.message)
        case "network", "timeout", "rateLimited", "hostNotAllowed": SourceError.network("\(plugin)：\(failure.message)")
        default: PluginError.script(plugin: plugin, code: failure.code, message: failure.message)
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        return switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): "\(path(context)) \(context.debugDescription)"
        case .keyNotFound(let key, let context): "\(path(context)).\(key.stringValue) 缺失"
        @unknown default: String(describing: error)
        }
    }

    func decryption(_ parameters: JSONValue) throws -> StreamDecryption {
        guard has("source.decryptor") else { throw SourceError.invalidResponse("\(manifest.name) 的播放地址需要解密，但插件没有 source.decryptor") }
        let text = String(decoding: try JSONEncoder().encode(parameters), as: UTF8.self)
        let id = SHA256.hash(data: Data("\(manifest.id)|\(text)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return StreamDecryption(id: id, decryptor: PluginDecryptor(script: script, file: file, info: info, parameters: text, executionLimit: executionLimit))
    }

    public func applySettings(_ values: SourceSettingValues, notify: Bool) {
        var effective: [String: Any] = [:]
        for setting in settingsSections.flatMap(\.settings) {
            switch setting.control {
            case .toggle: effective[setting.key] = values.bool(setting)
            case .text, .choice: effective[setting.key] = values.string(setting)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: effective) else { return }
        runtime.setSettings(String(decoding: data, as: UTF8.self), notify: notify)
    }

    public func lyricsProvider(cache: LyricsCache) -> ExternalLyricsProvider? {
        guard isLyricsProvider else { return nil }
        let name = manifest.name
        return ExternalLyricsProvider(id: lyricsProviderID, ttmlFolder: description.lyrics?.ttmlFolder, cache: cache, search: { [self] keyword in
            let hits: [WireLyricsHit] = try await call("lyrics.search", keyword)
            return hits.map(\.hit)
        }, fetch: { [self] song in
            let lyrics: WireLyrics? = try await call("lyrics.fetch", WireLyricsSong(song))
            return try lyrics?.raw(providerName: name)
        })
    }
}
