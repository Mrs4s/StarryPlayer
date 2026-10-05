import Foundation
import MusicSources
import StarryCore

/// AMLL lookup using `%p` (folder) and `%s` (song id) URL placeholders.
/// Treat redirects as misses, like 404; cache hits until cleared and misses for 72 hours.
public struct AMLLDatabase: Sendable {
    public static let defaultTemplate = "https://amlldb.bikonoo.com/%p/%s.ttml"

    private let cache: LyricsCache
    private let http: LyricsHTTP

    public init(cache: LyricsCache, timeout: TimeInterval = 8) {
        self.cache = cache
        http = LyricsHTTP(timeout: timeout)
    }

    public static func url(template: String, folder: String, id: String) -> URL? {
        var pattern = template.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        if !pattern.contains("%s") {
            while pattern.hasSuffix("/") { pattern.removeLast() }
            pattern += "/%p/%s.ttml"
        }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return URL(string: pattern.replacingOccurrences(of: "%p", with: folder).replacingOccurrences(of: "%s", with: escaped))
    }

    public func storedTTML(template: String, folder: String, ids: [String]) async -> String? {
        for id in ids where !id.isEmpty {
            guard let url = Self.url(template: template, folder: folder, id: id) else { return nil }
            if let text = await cache.storedTTML(platform: Self.table(url, folder), id: id) { return text }
        }
        return nil
    }

    private static func table(_ url: URL, _ folder: String) -> String {
        "\(url.host() ?? "amll")/\(folder)"
    }

    public func ttml(template: String, folder: String, ids: [String]) async -> String? {
        for id in ids where !id.isEmpty {
            guard let url = Self.url(template: template, folder: folder, id: id) else { return nil }
            let body = try? await cache.ttml(platform: Self.table(url, folder), id: id) { [http] in
                let (data, status) = try await http.get(url, followRedirects: false)
                switch status {
                case 200:
                    let text = String(decoding: data, as: UTF8.self)
                    return text.contains("<tt") ? text : nil
                case 300...399, 404, 410:
                    return nil
                default:
                    throw LyricsHTTP.Failure.status(status)
                }
            }
            if let body { return body }
        }
        return nil
    }
}

public actor LocalTTMLRepository {
    private struct Entry {
        var file: URL
        var artists: [String]
    }

    private struct Index {
        var directory: URL
        var modified: Date?
        var ids: [String: [String: URL]] = [:]
        var titles: [String: [Entry]] = [:]
    }

    private static let metaKeys = ["ncmMusicId": "ncm-lyrics", "qqMusicId": "qq-lyrics", "spotifyId": "spotify-lyrics", "appleMusicId": "am-lyrics"]

    private var index: Index?

    public init() {}

    public func ttml(for track: Track, folder: String?, in directory: URL) -> String? {
        let index = currentIndex(for: directory)
        let given = (track.ttml ?? []).lazy.compactMap { index.ids[$0.folder]?[$0.id] }.first
        let file = given ?? folder.flatMap { index.ids[$0]?[track.id.id] } ?? byTitle(track, index)
        return file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Same title; when both sides name artists they must share one.
    private func byTitle(_ track: Track, _ index: Index) -> URL? {
        let entries = index.titles[LyricCandidateMatcher.normalize(track.title)] ?? []
        let artists = track.artists.map { LyricCandidateMatcher.normalize($0.name) }.filter { !$0.isEmpty }
        return entries.first { entry in
            artists.isEmpty || entry.artists.isEmpty || entry.artists.contains { name in artists.contains { name.contains($0) || $0.contains(name) } }
        }?.file
    }

    private func currentIndex(for directory: URL) -> Index {
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let index, index.directory == directory, index.modified == modified { return index }
        let built = Self.build(directory, modified: modified)
        index = built
        return built
    }

    private static func build(_ directory: URL, modified: Date?) -> Index {
        var index = Index(directory: directory, modified: modified)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return index }
        for case let file as URL in files where file.pathExtension.lowercased() == "ttml" {
            let meta = readMeta(file)
            let name = file.deletingPathExtension().lastPathComponent
            let numericName = !name.isEmpty && name.allSatisfy(\.isNumber)
            var named = false
            for (key, folder) in metaKeys {
                for id in meta[key] ?? [] {
                    index.ids[folder, default: [:]][id] = index.ids[folder]?[id] ?? file
                    named = true
                }
            }
            if numericName, !named {
                let folders = Set(metaKeys.values)
                let folder = file.deletingLastPathComponent().pathComponents.last { folders.contains($0) } ?? "ncm-lyrics"
                index.ids[folder, default: [:]][name] = file
            }
            let artists = (meta["artists"] ?? []).map(LyricCandidateMatcher.normalize)
            for title in meta["musicName"] ?? [] {
                let key = LyricCandidateMatcher.normalize(title)
                guard !key.isEmpty else { continue }
                index.titles[key, default: []].append(Entry(file: file, artists: artists))
            }
        }
        return index
    }

    private static func readMeta(_ file: URL) -> [String: [String]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        let limit = head.range(of: "<body")?.lowerBound ?? head.endIndex
        var result: [String: [String]] = [:]
        var cursor = head.startIndex
        while let tag = head.range(of: "<amll:meta", range: cursor..<limit) {
            guard let end = head.range(of: ">", range: tag.upperBound..<head.endIndex) else { break }
            let element = head[tag.upperBound..<end.lowerBound]
            if let key = attribute("key", in: element), let value = attribute("value", in: element), !value.isEmpty {
                result[key, default: []].append(XMLText.unescape(value))
            }
            cursor = end.upperBound
        }
        return result
    }

    private static func attribute(_ name: String, in element: Substring) -> String? {
        guard let start = element.range(of: "\(name)=\"") else { return nil }
        guard let end = element[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(element[start.upperBound..<end])
    }
}

enum XMLText {
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
