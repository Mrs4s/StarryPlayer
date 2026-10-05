import CryptoKit
import Foundation
import MusicSources

/// Coalesced lyric caches: provider/search hits 30 days, misses 1 day;
/// TTML hits until cleared, misses 72 hours. Cache nil, never thrown errors.
/// Without a directory, keep entries in memory only.
public actor LyricsCache {
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "moe.mrs4s.starry-player/lyrics", directoryHint: .isDirectory)
    }

    private let directory: URL?
    private var memory: [String: Data] = [:]
    private var inflight: [String: Task<(any Sendable)?, any Error>] = [:]
    private let now: @Sendable () -> Date

    public init(directory: URL? = LyricsCache.defaultDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    private static let day: TimeInterval = 86_400

    func lyrics(provider: LyricsProviderID, songID: String, load: @escaping @Sendable () async throws -> RawLyrics?) async throws -> RawLyrics? {
        try await cached("lyrics/\(provider.rawValue)", songID, hit: 30 * Self.day, miss: Self.day, load: load)
    }

    func match(provider: LyricsProviderID, fingerprint: String, load: @escaping @Sendable () async throws -> LyricsSongRef?) async throws -> LyricsSongRef? {
        try await cached("match/\(provider.rawValue)", fingerprint, hit: 30 * Self.day, miss: Self.day, load: load)
    }

    func storedMatch(provider: LyricsProviderID, fingerprint: String) -> LyricsSongRef? {
        let entry: Entry<LyricsSongRef>? = read("match/\(provider.rawValue)", fingerprint)
        guard let entry, now().timeIntervalSince(entry.savedAt) < 30 * Self.day else { return nil }
        return entry.value
    }

    func ttml(platform: String, id: String, load: @escaping @Sendable () async throws -> String?) async throws -> String? {
        try await cached("ttml/\(platform)", id, hit: .infinity, miss: 3 * Self.day, load: load)
    }

    func storedTTML(platform: String, id: String) -> String? {
        let entry: Entry<String>? = read("ttml/\(platform)", id)
        return entry?.value
    }

    public func clear() {
        memory.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    public func size() -> Int64 {
        guard let directory, let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return Int64(memory.values.reduce(0) { $0 + $1.count })
        }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private struct Entry<Value: Codable>: Codable {
        var savedAt: Date
        var value: Value?
    }

    private func cached<Value: Codable & Sendable>(_ table: String, _ key: String, hit: TimeInterval, miss: TimeInterval, load: @escaping @Sendable () async throws -> Value?) async throws -> Value? {
        if let entry: Entry<Value> = read(table, key) {
            let age = now().timeIntervalSince(entry.savedAt)
            if age < (entry.value == nil ? miss : hit) { return entry.value }
        }
        let flightKey = "\(table)/\(key)"
        if let running = inflight[flightKey] { return try await running.value as? Value }
        let task = Task<(any Sendable)?, any Error> { try await load() }
        inflight[flightKey] = task
        defer { inflight[flightKey] = nil }
        let value = try await task.value as? Value
        write(table, key, Entry(savedAt: now(), value: value))
        return value
    }

    private func read<Value: Codable>(_ table: String, _ key: String) -> Entry<Value>? {
        let data: Data?
        if let url = fileURL(table, key) { data = try? Data(contentsOf: url) } else { data = memory["\(table)/\(key)"] }
        return data.flatMap { try? JSONDecoder().decode(Entry<Value>.self, from: $0) }
    }

    private func write<Value: Codable>(_ table: String, _ key: String, _ entry: Entry<Value>) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        guard let url = fileURL(table, key) else {
            memory["\(table)/\(key)"] = data
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ table: String, _ key: String) -> URL? {
        guard let directory else { return nil }
        let safe = key.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let name = safe ? key : SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: table, directoryHint: .isDirectory).appending(path: "\(name).json")
    }
}
