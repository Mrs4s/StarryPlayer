import Foundation

/// Keeps the library in step with its folders: scans one at a time,
/// FSEvents replay at launch and live watching after, a few seconds' quiet before a change is
/// scanned, and the status the settings page shows.
actor LibraryEngine {
    let store: LibraryStore
    let scanner: LibraryScanner
    private(set) var status = LibraryStatus()
    private var subscribers: [UUID: AsyncStream<LibraryStatus>.Continuation] = [:]
    private var watches: Bool
    private var watchers: [Int64: FolderWatcher] = [:]
    private var watchedPaths: [Int64: String] = [:]
    private var pending: [Int64: Request] = [:]
    private var eventIDs: [Int64: UInt64] = [:]
    /// The last event a waiting request covers: saved once its scan is done, so a change still
    /// in its quiet time when the app quits is replayed next time.
    private var coveredEventIDs: [Int64: UInt64] = [:]
    private var quietTimers: [Int64: Task<Void, Never>] = [:]
    private var running: Task<Void, Never>?
    private var started = false

    private static let quiet: Duration = .seconds(3)

    enum Request: Sendable {
        case whole(rereadTags: Bool)
        case folders(Set<String>)

        var isWhole: Bool {
            if case .whole = self { return true }
            return false
        }

        func merged(with other: Request) -> Request {
            switch (self, other) {
            case (.whole(let a), .whole(let b)): .whole(rereadTags: a || b)
            case (.whole, _): self
            case (_, .whole): other
            case (.folders(let a), .folders(let b)): .folders(a.union(b))
            }
        }
    }

    init(store: LibraryStore, artworkDirectory: URL, rules: LibraryRules, watches: Bool) {
        self.store = store
        self.watches = watches
        scanner = LibraryScanner(store: store, artworkDirectory: artworkDirectory, rules: rules) { _ in }
    }

    func subscribe(_ id: UUID, _ continuation: AsyncStream<LibraryStatus>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(status)
    }

    func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func publish() {
        for continuation in subscribers.values { continuation.yield(status) }
    }

    private func refreshStatus() async {
        status.folders = (try? await store.roots()) ?? []
        status.trackCount = (try? await store.trackCount()) ?? 0
        status.isBusy = running != nil || !pending.isEmpty
        publish()
    }

    private func setProgress(_ progress: ScanProgress?) {
        guard status.progress != progress else { return }
        status.progress = progress
        publish()
    }

    func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: LocalSource.didChange, object: nil) }
    }

    func start() async {
        guard !started else { return }
        started = true
        await scanner.setProgressHandler { [weak self] progress in
            Task { await self?.setProgress(progress) }
        }
        await refreshStatus()
        for root in (try? await store.rootAccess()) ?? [] { open(root) }
    }

    /// Brings a root up to date and follows it: a root watched before replays what changed since;
    /// one never watched (or on a network volume, where FSEvents sees only this Mac's changes) is
    /// walked whole.
    private func open(_ root: LibraryStore.RootAccess) {
        let local = Self.isLocalVolume(root.path)
        if watches, local {
            watch(root, since: root.lastEventID)
            if root.lastEventID == nil { enqueue(root.id, .whole(rereadTags: false)) }
        } else {
            enqueue(root.id, .whole(rereadTags: false))
        }
    }

    private func watch(_ root: LibraryStore.RootAccess, since: UInt64?) {
        watchers[root.id]?.stop()
        let resolved = FolderWalk.canonicalPath(root.path)
        watchedPaths[root.id] = resolved
        let id = root.id
        watchers[id] = FolderWatcher(path: resolved, since: since) { [weak self] batch in
            Task { await self?.received(batch, root: id) }
        }
        // Not watched after all (the folder went meanwhile): walked instead.
        if watchers[id] == nil { enqueue(id, .whole(rereadTags: false)) }
    }

    private func unwatch(_ id: Int64) {
        watchers.removeValue(forKey: id)?.stop()
        watchedPaths[id] = nil
        quietTimers.removeValue(forKey: id)?.cancel()
    }

    private var replaying: [Int64: Request] = [:]

    private func received(_ batch: FolderWatcher.Batch, root: Int64) {
        if batch.lastEventID > 0 { eventIDs[root] = max(eventIDs[root] ?? 0, batch.lastEventID) }
        var request: Request?
        if batch.rootChanged || !batch.subtrees.isEmpty {
            request = .whole(rereadTags: false)
        } else if !batch.folders.isEmpty, let rootPath = watchedPaths[root] {
            var folders = Set<String>()
            for path in batch.folders {
                if path == rootPath {
                    folders.insert("")
                } else if path.hasPrefix(rootPath + "/") {
                    folders.insert(String(path.dropFirst(rootPath.count + 1)))
                }
            }
            if !folders.isEmpty { request = .folders(folders) }
        }
        if let request {
            replaying[root] = replaying[root].map { $0.merged(with: request) } ?? request
        }
        if batch.historyDone {
            // The time the app was not running: scanned at once.
            if let request = replaying.removeValue(forKey: root) {
                enqueue(root, request, covering: eventIDs[root])
            } else if let event = eventIDs[root], pending[root] == nil, replaying[root] == nil {
                Task { try? await store.setLastEventID(event, of: root) }
            }
            return
        }
        guard request != nil else { return }
        quietTimers[root]?.cancel()
        quietTimers[root] = Task { [weak self] in
            try? await Task.sleep(for: Self.quiet)
            guard !Task.isCancelled else { return }
            await self?.quietEnded(root)
        }
    }

    private func quietEnded(_ root: Int64) {
        quietTimers[root] = nil
        guard let request = replaying.removeValue(forKey: root) else { return }
        enqueue(root, request, covering: eventIDs[root])
    }

    private func enqueue(_ root: Int64, _ request: Request, covering event: UInt64? = nil) {
        pending[root] = pending[root].map { $0.merged(with: request) } ?? request
        if let event { coveredEventIDs[root] = max(coveredEventIDs[root] ?? 0, event) }
        status.isBusy = true
        publish()
        guard running == nil else { return }
        running = Task { await drain() }
    }

    private func drain() async {
        while let root = pending.keys.sorted().first, let request = pending.removeValue(forKey: root) {
            let covered = coveredEventIDs.removeValue(forKey: root)
            guard let access = try? await store.rootAccess().first(where: { $0.id == root }) else { continue }
            let mark = FolderWatcher.currentEventID
            let started = Date()
            do {
                let summary: ScanSummary
                switch request {
                case .whole(let reread):
                    summary = try await scanner.scan(access, scope: .whole, rereadTags: reread)
                    if !summary.offline, watches { try await store.setLastEventID(mark, of: root) }
                case .folders(let folders):
                    summary = try await scanner.scan(access, scope: .folders(folders))
                    if let covered { try await store.setLastEventID(covered, of: root) }
                }
                if watches, let now = try await store.rootAccess().first(where: { $0.id == root }), now.path != access.path, Self.isLocalVolume(now.path) {
                    watch(now, since: FolderWatcher.currentEventID)
                }
                if summary.changed { changed() }
                print(String(format: "[local] %@ %@: +%d ~%d moved %d missing %d in %.2f s", request.isWhole ? "scanned" : "updated", (access.path as NSString).lastPathComponent,
                             summary.added, summary.updated, summary.moved, summary.missing, Date().timeIntervalSince(started)))
            } catch {
                print("[local] scan of \(access.path) failed: \(error)")
            }
            await refreshStatus()
        }
        running = nil
        await refreshStatus()
    }

    func idle() async {
        while let running { await running.value }
    }

    func rescan(_ id: Int64?, rereadTags: Bool = false) async {
        for root in (try? await store.rootAccess()) ?? [] where id == nil || root.id == id {
            enqueue(root.id, .whole(rereadTags: rereadTags))
        }
    }

    func rederive(_ id: Int64?) async {
        for root in (try? await store.rootAccess()) ?? [] where id == nil || root.id == id {
            try? await scanner.rederive(root)
        }
        changed()
        await refreshStatus()
    }

    func apply(rules: LibraryRules, watches: Bool) async {
        if await scanner.rules != rules {
            await scanner.setRules(rules)
            await rederive(nil)
        }
        guard watches != self.watches else { return }
        self.watches = watches
        for root in (try? await store.rootAccess()) ?? [] {
            if watches, Self.isLocalVolume(root.path) {
                watch(root, since: root.lastEventID)
            } else {
                unwatch(root.id)
            }
        }
    }

    func volumesDidChange() async {
        for folder in (try? await store.roots()) ?? [] {
            let reachable = FolderWalk.isFolder(folder.url)
            guard folder.isOffline == reachable else { continue }
            enqueue(folder.id, .whole(rereadTags: false))
            if reachable, watches, Self.isLocalVolume(folder.path), let access = try? await store.rootAccess().first(where: { $0.id == folder.id }) {
                watch(access, since: access.lastEventID)
            }
        }
    }

    /// A song's file was not there when it was played: its folder is scanned.
    func fileWentMissing(_ url: URL) async {
        guard let (root, relative) = await rootContaining(url) else { return }
        enqueue(root, .folders([LibraryScanner.parent(of: relative)]))
    }

    func addFolder(_ url: URL) async throws {
        let path = FolderWalk.canonicalPath(url.path)
        let roots = try await store.roots()
        if let containing = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            throw LocalLibraryError.alreadyAdded(containing.path)
        }
        for inner in roots where inner.path.hasPrefix(path + "/") {
            unwatch(inner.id)
            try await store.removeRoot(inner.id)
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let bookmark = try? folder.bookmarkData(options: .minimalBookmark)
        let volume = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let id = try await store.addRoot(path: path, bookmark: bookmark, volumeUUID: volume)
        await refreshStatus()
        if let access = try await store.rootAccess().first(where: { $0.id == id }) {
            if watches, Self.isLocalVolume(path) { watch(access, since: nil) }
            enqueue(id, .whole(rereadTags: false))
        }
    }

    func removeFolder(_ id: Int64) async throws {
        unwatch(id)
        pending[id] = nil
        await scanner.forget(id)
        defer { Task { await scanner.forgotten(id) } }
        try await store.removeRoot(id)
        try await store.rebuildAggregates()
        changed()
        await refreshStatus()
    }

    private func rootContaining(_ url: URL) async -> (Int64, String)? {
        let path = FolderWalk.canonicalPath(url.path)
        for root in (try? await store.rootAccess()) ?? [] {
            let rootPath = FolderWalk.canonicalPath(root.path)
            if path.hasPrefix(rootPath + "/") { return (root.id, String(path.dropFirst(rootPath.count + 1))) }
        }
        return nil
    }

    func songID(forFile url: URL) async throws -> String? {
        if let (root, relative) = await rootContaining(url) {
            if let file = try await store.file(root: root, relativePath: relative), file.missingSince == nil { return file.id }
            if let access = try await store.rootAccess().first(where: { $0.id == root }) {
                _ = try await scanner.scan(access, scope: .folders([LibraryScanner.parent(of: relative)]))
                changed()
                if let file = try await store.file(root: root, relativePath: relative) { return file.id }
            }
        }
        let path = url.standardizedFileURL.path
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileIdentifierKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let existing = try await store.externalFile(path: path)
        if let existing, existing.size == size, existing.modified == modified { return existing.id }
        guard let tags = await TagReader.read(url) else { return nil }
        let coverID = tags.picture.flatMap { ArtworkStore.store($0, of: url, directory: scanner.artworkDirectory) }
        let file = StoredFile(id: existing?.id ?? StableID.newTrack(), rootID: nil, folderID: nil, relativePath: path, fileID: values?.fileIdentifier,
                              size: size, modified: modified, missingSince: nil, reader: tags.reader, tags: tags.tags, audio: tags.audio,
                              isPlayable: tags.isPlayable, hasLyrics: tags.hasLyrics, coverID: coverID, metadataHash: LibraryScanner.metadataHash(tags))
        try await store.save(file, isNew: existing == nil)
        let folderName = url.deletingLastPathComponent().lastPathComponent
        let (facts, _) = FolderRules.facts([FolderMember(fileName: url.lastPathComponent, tags: tags.tags)], albumFolderName: folderName, discFromFolder: nil, encoding: nil, rules: await scanner.rules)
        if let fact = facts.first { try await store.saveFacts(fact, of: file.id, albumID: nil) }
        return file.id
    }

    static func isLocalVolume(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }
}
