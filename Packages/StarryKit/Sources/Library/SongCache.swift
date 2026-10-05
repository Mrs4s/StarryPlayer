import CryptoKit
import Foundation
import StarryCore

/// LRU disk cache of completed downloads, keyed by track and requested quality.
/// A lower-quality fallback satisfies the same request; startup removes orphaned files and entries.
public actor SongCache {
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "moe.mrs4s.starry-player/songs", directoryHint: .isDirectory)
    }

    public static let didChange = Notification.Name("SongCache.didChange")

    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public var track: Track
        public var file: String
        public var container: AudioContainer
        public var quality: AudioQuality
        public var requestedQuality: AudioQuality
        /// The source's tier the file is, and the one asked for when it came (nil in entries kept
        /// before tiers: a stereo file of `quality`).
        public var tier: QualityTier?
        public var requestedTier: String?

        public var playedTier: QualityTier { tier ?? QualityTier(quality) }
        public var size: Int64
        public var addedAt: Date
        public var lastPlayedAt: Date
        public var gain: ReplayGain? = nil

        public var id: TrackRef { track.id }
    }

    public struct Summary: Sendable, Equatable {
        public var count: Int
        public var size: Int64
        /// nil: no limit.
        public var limit: Int64?

        public init(count: Int, size: Int64, limit: Int64?) {
            self.count = count
            self.size = size
            self.limit = limit
        }
    }

    private struct Index: Codable {
        var version = 1
        var entries: [Entry]
    }

    public let directory: URL
    private var limit: Int64?
    private var entries: [TrackRef: Entry] = [:]
    private var loaded = false
    private var touchSave: Task<Void, Never>?
    private let now: @Sendable () -> Date

    /// `limit` in bytes, nil for none.
    public init(directory: URL = SongCache.defaultDirectory, limit: Int64?, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.limit = limit
        self.now = now
    }

    public func asset(for track: Track, tier: QualityTier) -> PlayableAsset? {
        load()
        guard var entry = entries[track.id], Self.answers(entry, tier) else { return nil }
        let url = fileURL(entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries[track.id] = nil
            save()
            notify()
            return nil
        }
        entry.lastPlayedAt = now()
        entries[track.id] = entry
        scheduleTouchSave()
        return PlayableAsset(url: url, container: entry.container, tier: entry.playedTier, supportsTap: true, supportsOverlap: true, provider: .cache, gain: entry.gain)
    }

    static func answers(_ entry: Entry, _ tier: QualityTier) -> Bool {
        let kept = entry.playedTier
        if kept.isSpatial || tier.isSpatial { return kept.id == tier.id || entry.requestedTier == tier.id }
        return kept.level >= tier.level || entry.requestedQuality >= tier.level
    }

    public func entry(for track: TrackRef) -> Entry? {
        load()
        return entries[track]
    }

    public func allEntries() -> [Entry] {
        load()
        return entries.values.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    public func summary() -> Summary {
        load()
        return Summary(count: entries.count, size: entries.values.reduce(0) { $0 + $1.size }, limit: limit)
    }

    public nonisolated func fileURL(_ entry: Entry) -> URL {
        directory.appending(path: entry.file, directoryHint: .notDirectory)
    }

    @discardableResult
    public func add(_ file: URL, for track: Track, container: AudioContainer, tier: QualityTier, requested: QualityTier, gain: ReplayGain? = nil) -> Bool {
        load()
        if let existing = entries[track.id], existing.quality > tier.level, existing.playedTier.isSpatial == tier.isSpatial,
           FileManager.default.fileExists(atPath: fileURL(existing).path) { return false }
        let fileManager = FileManager.default
        let name = Self.fileName(for: track.id, extension: file.pathExtension.isEmpty ? container.rawValue : file.pathExtension)
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        let staging = directory.appending(path: ".incoming-\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try fileManager.linkItem(at: file, to: staging)
            } catch {
                try fileManager.copyItem(at: file, to: staging)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            return false
        }
        if let existing = entries[track.id] { try? fileManager.removeItem(at: fileURL(existing)) }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            entries[track.id] = nil
            save()
            notify()
            return false
        }
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let date = now()
        entries[track.id] = Entry(
            track: track, file: name, container: container, quality: tier.level,
            requestedQuality: max(tier.level, requested.level), tier: tier, requestedTier: requested.id,
            size: size, addedAt: date, lastPlayedAt: date, gain: gain
        )
        evict(keeping: track.id)
        save()
        notify()
        return true
    }

    public func remove(_ track: TrackRef) {
        load()
        guard let entry = entries.removeValue(forKey: track) else { return }
        try? FileManager.default.removeItem(at: fileURL(entry))
        save()
        notify()
    }

    public func removeAll() {
        touchSave?.cancel()
        touchSave = nil
        entries.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: directory)
        notify()
    }

    /// A new size limit (bytes, nil for none); songs over it go at once.
    public func setLimit(_ limit: Int64?) {
        guard limit != self.limit else { return }
        self.limit = limit
        load()
        let before = entries.count
        evict(keeping: nil)
        if entries.count != before {
            save()
        }
        notify()
    }

    static func fileName(for track: TrackRef, extension pathExtension: String) -> String {
        let key = String(track.source.key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "-" })
        let safe = track.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } && !track.id.isEmpty && track.id.count <= 64
        let id = safe ? track.id : SHA256.hash(data: Data(track.description.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ext.isEmpty ? "\(key)-\(id)" : "\(key)-\(id).\(ext)"
    }

    private var indexURL: URL { directory.appending(path: "index.json", directoryHint: .notDirectory) }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let fileManager = FileManager.default
        var changed = false
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            for entry in index.entries {
                if fileManager.fileExists(atPath: fileURL(entry).path) {
                    entries[entry.id] = entry
                } else {
                    changed = true
                }
            }
        }
        let known = Set(entries.values.map(\.file))
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name != "index.json" && !known.contains(name) {
            try? fileManager.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
        if evict(keeping: nil) { changed = true }
        if changed { save() }
    }

    /// Removes the songs played longest ago until the total fits the limit. `keeping` is never
    /// removed (the song just added). Returns whether anything went.
    @discardableResult
    private func evict(keeping kept: TrackRef?) -> Bool {
        guard let limit else { return false }
        var total = entries.values.reduce(0) { $0 + $1.size }
        guard total > limit else { return false }
        var removed = false
        for entry in entries.values.sorted(by: { $0.lastPlayedAt < $1.lastPlayedAt }) where total > limit && entry.id != kept {
            entries[entry.id] = nil
            try? FileManager.default.removeItem(at: fileURL(entry))
            total -= entry.size
            removed = true
        }
        return removed
    }

    private func save() {
        touchSave?.cancel()
        touchSave = nil
        let fileManager = FileManager.default
        guard !entries.isEmpty else {
            try? fileManager.removeItem(at: indexURL)
            return
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = Index(entries: entries.values.sorted { $0.addedAt < $1.addedAt })
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func scheduleTouchSave() {
        guard touchSave == nil else { return }
        touchSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private nonisolated func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SongCache.didChange, object: nil)
        }
    }
}
