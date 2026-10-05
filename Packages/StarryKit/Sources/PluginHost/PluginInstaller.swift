import Foundation

/// A plugin file read but not installed: what the plugin settings ask the listener to confirm.
public struct PluginPackage: Sendable {
    public let manifest: PluginManifest
    public let isSource: Bool
    public let isLyricsProvider: Bool
    public let hasAccount: Bool
    let script: String
}

public enum PluginInstaller {
    public enum Failure: Error, LocalizedError, Equatable {
        case badAddress(String)
        case download(String)
        case tooLarge
        case notText

        public var errorDescription: String? {
            switch self {
            case .badAddress(let address): "不是 http(s) 地址：\(address)"
            case .download(let reason): "下载失败：\(reason)"
            case .tooLarge: "文件太大，不像是插件"
            case .notText: "文件不是 UTF-8 文本，不像是插件"
            }
        }
    }

    static let sizeLimit = 10 << 20

    /// Runs `script` once to read what it is (no network, no storage), as loading does.
    public static func inspect(script: String, name: String) throws -> PluginPackage {
        let plugin = try Plugin.load(script: script, file: URL(fileURLWithPath: "/\(name)"), options: Plugin.Options())
        return PluginPackage(manifest: plugin.manifest, isSource: plugin.isSource, isLyricsProvider: plugin.isLyricsProvider, hasAccount: plugin.hasAccount, script: script)
    }

    public static func inspect(file: URL) throws -> PluginPackage {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw PluginError.load("读不了 \(file.lastPathComponent)：\(error.localizedDescription)")
        }
        return try inspect(script: try text(data), name: file.lastPathComponent)
    }

    public static func inspect(address: URL, session: URLSession = .shared) async throws -> PluginPackage {
        guard ["http", "https"].contains(address.scheme?.lowercased() ?? "") else { throw Failure.badAddress(address.absoluteString) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: address)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.download("HTTP \(http.statusCode)") }
        return try inspect(script: try text(data), name: address.lastPathComponent.isEmpty ? "plugin.js" : address.lastPathComponent)
    }

    private static func text(_ data: Data) throws -> String {
        guard data.count <= sizeLimit else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notText }
        return text
    }

    @discardableResult
    public static func install(_ package: PluginPackage, into directory: URL, replacing: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(package.manifest.id).js", directoryHint: .notDirectory)
        try Data(package.script.utf8).write(to: file, options: .atomic)
        if let replacing, replacing.standardizedFileURL != file.standardizedFileURL, replacing.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: replacing)
        }
        return file
    }
}
