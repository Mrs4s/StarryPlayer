import Foundation

/// JSON files in the app's data directory for account cookies and server credentials:
/// `~/Library/Application Support/moe.mrs4s.starry-player/<name>.json`. The directory is 0700
/// and files are 0600, so only the current user can read them.
public struct DataDirectory: Sendable {
    public var url: URL

    public init(url: URL = DataDirectory.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "moe.mrs4s.starry-player", directoryHint: .isDirectory)
    }

    public func fileURL(_ name: String) -> URL {
        url.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    public func readCodable<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func writeCodable<T: Encodable>(_ value: T, name: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = fileURL(name)
        try encoder.encode(value).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func delete(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }
}
