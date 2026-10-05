import CryptoKit
import Foundation

public struct ScanSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var moved = 0
    public var missing = 0
    /// The root could not be reached.
    public var offline = false

    public var changed: Bool { added + updated + moved + missing > 0 }

    public static func += (lhs: inout ScanSummary, rhs: ScanSummary) {
        lhs.added += rhs.added
        lhs.updated += rhs.updated
        lhs.moved += rhs.moved
        lhs.missing += rhs.missing
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var folder: String
    /// Files read so far, of those to read.
    public var done: Int
    public var total: Int
}

/// Brings the database in step with a root's folders: walks them,
/// reads the files that are new or changed, finds moved files their old ids, marks vanished ones
/// missing (never after a walk that did not finish), then cleans each changed folder's songs
/// together and rebuilds albums and artists.
actor LibraryScanner {
    enum Scope: Sendable {
        case whole
        case folders(Set<String>)
    }

    let store: LibraryStore
    let artworkDirectory: URL
    var rules: LibraryRules
    private var report: @Sendable (ScanProgress?) -> Void

    /// Files read at once: AVFoundation's loads suspend, the own readers read a few kilobytes.
    private static let parallelReads = 4
    private static let batchSize = 200

    init(store: LibraryStore, artworkDirectory: URL, rules: LibraryRules, progress: @escaping @Sendable (ScanProgress?) -> Void) {
        self.store = store
        self.artworkDirectory = artworkDirectory
        self.rules = rules
        report = progress
    }

    func setRules(_ rules: LibraryRules) { self.rules = rules }

    func setProgressHandler(_ handler: @escaping @Sendable (ScanProgress?) -> Void) { report = handler }

    private var folderIDs: [String: Int64] = [:]

    /// One scan (or clean-up) at a time, whoever asks: an actor alone would interleave them at
    /// every `await`.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private var removed: Set<Int64> = []

    func forget(_ root: Int64) async {
        removed.insert(root)
        await acquire()
        release()
    }

    func forgotten(_ root: Int64) { removed.remove(root) }

    private func folderID(_ path: String, root: Int64) async throws -> Int64 {
        if let id = folderIDs[path] { return id }
        let id = try await store.folderID(root: root, relativePath: path)
        folderIDs[path] = id
        return id
    }

    /// The root's folder: where it was, else where its bookmark finds it (moved or renamed; the
    /// new path is kept). nil when it cannot be reached (volume not mounted): it is then offline.
    func locate(_ root: LibraryStore.RootAccess) async throws -> URL? {
        let url = URL(fileURLWithPath: root.path, isDirectory: true)
        if FolderWalk.isFolder(url) { return url }
        guard let bookmark = root.bookmark else { return nil }
        // A bookmark to a volume that is not there is not resolved: that could mount a network
        // share or wait for it.
        if let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmark)?.volume, !FileManager.default.fileExists(atPath: volume.path) {
            return nil
        }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FolderWalk.isFolder(resolved) else { return nil }
        let fresh = stale ? try? resolved.bookmarkData(options: .minimalBookmark) : nil
        try await store.updateRoot(root.id, path: resolved.path, bookmark: fresh)
        return resolved
    }

    func scan(_ root: LibraryStore.RootAccess, scope: Scope, rereadTags: Bool = false) async throws -> ScanSummary {
        await acquire()
        defer { release() }
        guard !removed.contains(root.id) else { throw CancellationError() }
        var summary = ScanSummary()
        guard let rootURL = try await locate(root) else {
            try await store.updateRoot(root.id, offline: true)
            summary.offline = true
            return summary
        }
        let rootName = rootURL.lastPathComponent
        report(ScanProgress(folder: rootName, done: 0, total: 0))
        defer { report(nil) }

        let known = try await store.folders(of: root.id)
        let (walk, vanishedFolders) = await walkScope(scope, root: root, rootURL: rootURL, known: known)

        let files = try await store.files(of: root.id)
        let filesByPath = Dictionary(files.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var vanished: [StoredFile] = files.filter { file in
            guard file.missingSince == nil else { return false }
            let folder = Self.parent(of: file.relativePath)
            if vanishedFolders.contains(folder) { return true }
            // A folder with an entry that could not be read says nothing about what is gone.
            guard let walked = walk.folders[folder], walked.isComplete else { return false }
            return !walked.audio.contains { $0.name == Self.name(of: file.relativePath) }
        }

        var toRead: [(folder: String, file: WalkedFile, existing: StoredFile?)] = []
        var changedFolders: Set<String> = []
        var restored: [(StoredFile, String)] = []
        for (path, folder) in walk.folders {
            let isChanged = rereadTags || known[path]?.signature != folder.signature
            guard isChanged else { continue }
            changedFolders.insert(path)
            for file in folder.audio {
                let relative = path.isEmpty ? file.name : path + "/" + file.name
                if let existing = filesByPath[relative] {
                    if !rereadTags, existing.size == file.size, existing.modified == file.modified {
                        if existing.missingSince != nil { restored.append((existing, path)) }
                        continue
                    }
                    toRead.append((path, file, existing))
                } else {
                    toRead.append((path, file, nil))
                }
            }
        }
        var candidates = vanished + (try await store.missingFiles()).filter { missing in !vanished.contains { $0.id == missing.id } }

        folderIDs = known.mapValues(\.id)
        var movedOutOf: Set<String> = []
        var done = 0
        report(ScanProgress(folder: rootName, done: 0, total: toRead.count))
        for batch in stride(from: 0, to: toRead.count, by: Self.batchSize).map({ Array(toRead[$0..<min($0 + Self.batchSize, toRead.count)]) }) {
            guard !removed.contains(root.id) else { throw CancellationError() }
            let read = await readFiles(batch.map { rootURL.appending(path: $0.folder.isEmpty ? $0.file.name : $0.folder + "/" + $0.file.name) })
            var covers: [String: String] = [:]
            for (index, entry) in batch.enumerated() {
                let relative = entry.folder.isEmpty ? entry.file.name : entry.folder + "/" + entry.file.name
                guard let tags = read[index] else { continue }
                let url = rootURL.appending(path: relative)
                var coverID: String?
                if let picture = tags.picture {
                    let key = "\(entry.folder)#\(picture.length)"
                    coverID = covers[key] ?? ArtworkStore.store(picture, of: url, directory: artworkDirectory)
                    covers[key] = coverID
                }
                var stored = StoredFile(
                    id: entry.existing?.id ?? StableID.newTrack(), rootID: root.id, folderID: try await folderID(entry.folder, root: root.id),
                    relativePath: relative, fileID: entry.file.fileID, size: entry.file.size, modified: entry.file.modified, missingSince: nil,
                    reader: tags.reader, tags: tags.tags, audio: tags.audio, isPlayable: tags.isPlayable, hasLyrics: tags.hasLyrics,
                    coverID: coverID, metadataHash: Self.metadataHash(tags)
                )
                var isNew = entry.existing == nil
                if isNew, let match = Self.match(stored, among: candidates) {
                    stored.id = match.id
                    isNew = false
                    candidates.removeAll { $0.id == match.id }
                    vanished.removeAll { $0.id == match.id }
                    if match.rootID == root.id { movedOutOf.insert(Self.parent(of: match.relativePath)) }
                    summary.moved += 1
                } else if isNew {
                    summary.added += 1
                } else {
                    summary.updated += 1
                }
                try await store.save(stored, isNew: isNew)
            }
            done += batch.count
            report(ScanProgress(folder: rootName, done: done, total: toRead.count))
        }
        for (file, folder) in restored {
            try await store.move(file.id, root: root.id, folder: try await folderID(folder, root: root.id), relativePath: file.relativePath)
            summary.updated += 1
        }
        for file in vanished {
            guard let fileID = file.fileID,
                  let twins = try? await store.recentFiles(root: root.id, fileID: fileID, size: file.size, since: Date().addingTimeInterval(-3600)).filter({ $0.id != file.id }),
                  twins.count == 1, let twin = twins.first, let folder = twin.folderID else { continue }
            try await store.merge(twin.id, into: file.id)
            try await store.move(file.id, root: root.id, folder: folder, relativePath: twin.relativePath)
            vanished.removeAll { $0.id == file.id }
            movedOutOf.insert(Self.parent(of: twin.relativePath))
            movedOutOf.insert(Self.parent(of: file.relativePath))
            summary.moved += 1
        }
        if !vanished.isEmpty {
            try await store.markMissing(vanished.map(\.id))
            summary.missing += vanished.count
        }
        if !vanishedFolders.isEmpty {
            try await store.deleteFolders(vanishedFolders.compactMap { known[$0]?.id })
        }

        let rootEncoding = try await store.rootEncoding(root.id)
        for path in changedFolders.union(movedOutOf) where walk.folders[path] != nil || known[path] != nil {
            guard !vanishedFolders.contains(path) else { continue }
            let id = try await folderID(path, root: root.id)
            let walked = walk.folders[path]
            let cover = walked.flatMap { coverFile(for: $0, rootURL: rootURL, walk: walk) } ?? known[path]?.coverFile
            let encoding = try await derive(folder: id, path: path, encoding: known[path]?.encodingOverride ?? rootEncoding)
            try await store.updateFolder(id, signature: walked?.signature ?? known[path]?.signature ?? "", encoding: encoding, coverFile: cover)
        }
        if summary.changed || !changedFolders.isEmpty {
            try await store.rebuildAggregates()
        }
        if case .whole = scope {
            try await store.updateRoot(root.id, offline: false, lastScan: Date(), unsupported: walk.folders.values.reduce(0) { $0 + $1.unsupported })
        } else {
            try await store.updateRoot(root.id, offline: false, lastScan: Date())
        }
        return summary
    }

    func rederive(_ root: LibraryStore.RootAccess) async throws {
        await acquire()
        defer { release() }
        let rootEncoding = try await store.rootEncoding(root.id)
        for (path, folder) in try await store.folders(of: root.id) {
            let encoding = try await derive(folder: folder.id, path: path, encoding: folder.encodingOverride ?? rootEncoding)
            try await store.updateFolder(folder.id, signature: folder.signature, encoding: encoding, coverFile: folder.coverFile)
        }
        try await store.rebuildAggregates()
    }

    @discardableResult
    private func derive(folder id: Int64, path: String, encoding: LegacyEncoding?) async throws -> LegacyEncoding? {
        let members = try await store.files(inFolder: id)
        guard !members.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let disc = FolderRules.discNumber(folderName: name)
        let albumFolder = disc != nil ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent : name
        let (facts, decided) = FolderRules.facts(
            members.map { FolderMember(fileName: Self.name(of: $0.relativePath), tags: $0.tags) },
            albumFolderName: albumFolder.isEmpty ? name : albumFolder,
            discFromFolder: disc,
            encoding: encoding,
            rules: rules
        )
        for (member, fact) in zip(members, facts) {
            try await store.saveFacts(fact, of: member.id, albumID: fact.albumKey.map(StableID.album))
        }
        return decided
    }

    private func walkScope(_ scope: Scope, root: LibraryStore.RootAccess, rootURL: URL, known: [String: FolderRecord]) async -> (FolderWalk.Result, Set<String>) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                switch scope {
                case .whole:
                    let walk = FolderWalk.walk(root: rootURL, excluded: root.excluded)
                    // Only a complete walk can determine which files were removed.
                    let vanished = walk.isComplete ? Set(known.keys).subtracting(walk.folders.keys) : []
                    continuation.resume(returning: (walk, vanished))
                case .folders(let paths):
                    var result = FolderWalk.Result()
                    var vanished = Set<String>()
                    for path in paths.sorted() where !root.excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                        let folderURL = path.isEmpty ? rootURL : rootURL.appending(path: path, directoryHint: .isDirectory)
                        guard FolderWalk.isFolder(folderURL) else {
                            vanished.formUnion(known.keys.filter { $0 == path || $0.hasPrefix(path + "/") })
                            continue
                        }
                        let listing = FolderWalk.walk(root: rootURL, from: path, recursive: false, excluded: root.excluded)
                        guard listing.isComplete, let folder = listing.folders[path] else { continue }
                        result.folders[path] = folder
                        let children = Set(folder.subfolders.map { path.isEmpty ? $0 : path + "/" + $0 })
                        for knownPath in known.keys where Self.parent(of: knownPath) == path && !knownPath.isEmpty && !children.contains(knownPath) {
                            vanished.formUnion(known.keys.filter { $0 == knownPath || $0.hasPrefix(knownPath + "/") })
                        }
                        for child in children where known[child] == nil {
                            let subtree = FolderWalk.walk(root: rootURL, from: child, excluded: root.excluded)
                            result.folders.merge(subtree.folders) { first, _ in first }
                        }
                    }
                    continuation.resume(returning: (result, vanished))
                }
            }
        }
    }

    private func coverFile(for folder: WalkedFolder, rootURL: URL, walk: FolderWalk.Result) -> String? {
        if let name = ArtworkStore.folderCover(among: folder.imageNames) {
            return folder.relativePath.isEmpty ? name : folder.relativePath + "/" + name
        }
        guard FolderRules.discNumber(folderName: folder.name) != nil, !folder.relativePath.isEmpty else { return nil }
        let parent = Self.parent(of: folder.relativePath)
        let names = walk.folders[parent]?.imageNames
            ?? ((try? FileManager.default.contentsOfDirectory(atPath: (parent.isEmpty ? rootURL : rootURL.appending(path: parent)).path)) ?? [])
        guard let name = ArtworkStore.folderCover(among: names) else { return nil }
        return parent.isEmpty ? name : parent + "/" + name
    }

    private func readFiles(_ urls: [URL]) async -> [FileTags?] {
        await withTaskGroup(of: (Int, FileTags?).self) { group in
            var results = [FileTags?](repeating: nil, count: urls.count)
            var next = 0
            func start() {
                guard next < urls.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await TagReader.read(urls[index])) }
            }
            for _ in 0..<Self.parallelReads { start() }
            while let (index, tags) = await group.next() {
                results[index] = tags
                start()
            }
            return results
        }
    }

    static func match(_ file: StoredFile, among candidates: [StoredFile]) -> StoredFile? {
        if let fileID = file.fileID {
            let same = candidates.filter { $0.fileID == fileID && $0.size == file.size && ($0.rootID == file.rootID || $0.rootID == nil) }
            if same.count == 1 { return same[0] }
        }
        let identical = candidates.filter { $0.metadataHash == file.metadataHash }
        if identical.count == 1 { return identical[0] }
        if let recording = file.tags.first(TagKey.musicBrainzTrack) {
            let same = candidates.filter { $0.tags.first(TagKey.musicBrainzTrack) == recording }
            if same.count == 1 { return same[0] }
        }
        return nil
    }

    /// Tags and audio, not the file: the same after a move or a rename, different after an edit.
    static func metadataHash(_ file: FileTags) -> String {
        var hasher = SHA256()
        for key in file.tags.fields.keys.sorted() where !TagKey.transient.contains(key) {
            hasher.update(data: Data("\(key)=\(file.tags[key].joined(separator: "\u{1}"))\u{2}".utf8))
        }
        hasher.update(data: Data("\(file.audio.codec)|\(Int(file.audio.duration.rounded()))|\(file.audio.sampleRate ?? 0)".utf8))
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
