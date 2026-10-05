import MusicSources
import QuartzCore
import Observation
import StarryCore

/// Loads tracks in pages of 500, preserving order and a search index.
/// Search and playback fetch the remainder; reference semantics let loading outlive the page.
@MainActor @Observable
final class TrackListLoader {
    private(set) var tracks: [Track]
    private(set) var pendingIDs: [String]
    private(set) var paging: Paging?
    private(set) var isLoading = false
    private(set) var failure: String?
    private(set) var revision = 0
    private(set) var arrival: (id: TrackRef, time: CFTimeInterval)?

    @ObservationIgnored private var index: TrackSearchIndex
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var memo: (query: String, revision: Int, matches: [Int]?)?
    @ObservationIgnored private var placeMemo: (key: PlaceKey, place: Place?)?
    /// Songs taken out while a fetch runs, so their chunk does not bring them back.
    @ObservationIgnored private var removedWhileLoading: Set<TrackRef> = []
    @ObservationIgnored private let fetch: (@Sendable ([String]) async throws -> [Track])?
    @ObservationIgnored private let fetchPage: (@Sendable (Page) async throws -> TrackPage)?

    static let chunkSize = 500
    static let prefetchDistance = 100

    init(tracks: [Track], pendingIDs: [String] = [], fetch: @escaping @Sendable ([String]) async throws -> [Track]) {
        self.tracks = tracks
        self.pendingIDs = pendingIDs
        self.fetch = fetch
        fetchPage = nil
        index = TrackSearchIndex(tracks)
    }

    init(pages: @escaping @Sendable (Page) async throws -> TrackPage) {
        tracks = []
        pendingIDs = []
        paging = Paging(next: 0, total: nil, hasMore: true)
        fetch = nil
        fetchPage = pages
        index = TrackSearchIndex([])
    }

    struct Paging: Equatable {
        var next: Int
        var total: Int?
        var hasMore: Bool
    }

    var isComplete: Bool { pendingIDs.isEmpty && paging?.hasMore != true }
    var allIDs: [String] { tracks.map(\.id.id) + pendingIDs }
    /// Every song of the list; while a paged list has not told its length, the songs loaded.
    var totalCount: Int { tracks.count + pendingIDs.count + (paging?.total.map { max($0 - tracks.count, 0) } ?? 0) }

    /// Starts the next page when the row at `position` shows close to the end of the loaded
    /// songs. Not after a failure: that waits for the retry button.
    func prefetch(near position: Int) {
        guard position >= tracks.count - Self.prefetchDistance, !isComplete, run == nil, failure == nil else { return }
        Task { await loadNext() }
    }

    func loadNext(retrying: Bool = false) async {
        if let run {
            await run.value
            if Task.isCancelled { return }
        }
        if let run { return await run.value }
        guard !isComplete, failure == nil || retrying else { return }
        if let paging {
            await start([.page(Page(offset: paging.next, limit: Self.chunkSize))]).value
        } else {
            await start([.ids(Array(pendingIDs.prefix(Self.chunkSize)))]).value
        }
    }

    func loadRemaining() async {
        while let run {
            await run.value
            if failure != nil { return }
        }
        guard !isComplete else { return }
        guard let paging else {
            await start(stride(from: 0, to: pendingIDs.count, by: Self.chunkSize).map { .ids(Array(pendingIDs[$0..<min($0 + Self.chunkSize, pendingIDs.count)])) }).value
            return
        }
        if let total = paging.total {
            await start(stride(from: paging.next, to: total, by: Self.chunkSize).map { .page(Page(offset: $0, limit: Self.chunkSize)) }).value
        }
        while let paging = self.paging, paging.hasMore, failure == nil {
            await start([.page(Page(offset: paging.next, limit: Self.chunkSize))]).value
        }
    }

    private enum Batch: Sendable {
        case ids([String])
        case page(Page)
    }

    private func start(_ batches: [Batch]) -> Task<Void, Never> {
        failure = nil
        isLoading = true
        let fetch = fetch
        let fetchPage = fetchPage
        let task = Task { @MainActor in
            await withTaskGroup(of: (Int, Result<Chunk, any Error>).self) { group in
                for (number, batch) in batches.enumerated() {
                    group.addTask {
                        do {
                            let chunk: Chunk
                            switch batch {
                            case .ids(let ids):
                                let tracks = try await fetch?(ids) ?? []
                                // Folded off the main thread.
                                chunk = Chunk(ids: ids, tracks: tracks, index: TrackSearchIndex(tracks))
                            case .page(let page):
                                let result = try await fetchPage?(page) ?? TrackPage(tracks: [], hasMore: false)
                                chunk = Chunk(ids: [], tracks: result.tracks, index: TrackSearchIndex(result.tracks), page: page, total: result.total, hasMore: result.hasMore,
                                              nextOffset: result.nextOffset ?? page.offset + result.tracks.count)
                            }
                            return (number, .success(chunk))
                        } catch {
                            return (number, .failure(error))
                        }
                    }
                }
                var arrived: [Int: Chunk] = [:]
                var next = 0
                var failed: (chunk: Int, message: String)?
                for await (number, result) in group {
                    switch result {
                    case .success(let chunk):
                        arrived[number] = chunk
                    case .failure(let error):
                        if number < failed?.chunk ?? .max { failed = (number, ErrorText.describe(error)) }
                    }
                    var ready: [Chunk] = []
                    while next < failed?.chunk ?? .max, let chunk = arrived.removeValue(forKey: next) {
                        ready.append(chunk)
                        next += 1
                    }
                    if !ready.isEmpty { append(ready) }
                    if let failed, next == failed.chunk {
                        failure = failed.message
                        group.cancelAll()
                        break
                    }
                }
            }
            run = nil
            removedWhileLoading = []
            isLoading = false
        }
        run = task
        return task
    }

    private struct Chunk: Sendable {
        var ids: [String]
        var tracks: [Track]
        var index: TrackSearchIndex
        var page: Page?
        var total: Int?
        var hasMore = false
        var nextOffset = 0
    }

    private func append(_ chunks: [Chunk]) {
        let fetched = Set(chunks.flatMap(\.ids))
        pendingIDs.removeAll { fetched.contains($0) }
        var present = Set(tracks.map(\.id))
        for chunk in chunks {
            if chunk.page != nil, var paging {
                // A page that does not move the list on ends it, whatever it says.
                paging.hasMore = chunk.hasMore && chunk.nextOffset > paging.next
                paging.next = max(paging.next, chunk.nextOffset)
                paging.total = chunk.total ?? paging.total
                self.paging = paging
            }
            let keep = chunk.tracks.map { !removedWhileLoading.contains($0.id) && present.insert($0.id).inserted }
            if keep.allSatisfy({ $0 }) {
                tracks += chunk.tracks
                index.append(chunk.index)
            } else {
                let kept = zip(chunk.tracks, keep).filter(\.1).map(\.0)
                tracks += kept
                index.append(contentsOf: kept)
            }
        }
        revision += 1
    }

    func prepend(_ track: Track) {
        guard !tracks.contains(where: { $0.id == track.id }) else { return }
        pendingIDs.removeAll { $0 == track.id.id }
        removedWhileLoading.remove(track.id)
        tracks.insert(track, at: 0)
        index.insert(track, at: 0)
        arrival = (track.id, CACurrentMediaTime())
        revision += 1
    }

    func remove(_ id: TrackRef) {
        pendingIDs.removeAll { $0 == id.id }
        if isLoading { removedWhileLoading.insert(id) }
        var removed = false
        while let position = tracks.firstIndex(where: { $0.id == id }) {
            tracks.remove(at: position)
            index.remove(at: position)
            removed = true
        }
        if removed { revision += 1 }
    }

    func move(from: Int, to: Int) {
        guard tracks.indices.contains(from), (0...tracks.count).contains(to), to != from, to != from + 1 else { return }
        let track = tracks.remove(at: from)
        index.remove(at: from)
        let target = to > from ? to - 1 : to
        tracks.insert(track, at: target)
        index.insert(track, at: target)
        revision += 1
    }

    func load(through id: String) async {
        while let run {
            await run.value
            if failure != nil { return }
        }
        guard paging == nil else { return await loadRemaining() }
        guard let index = pendingIDs.firstIndex(of: id) else { return }
        let end = min((index / Self.chunkSize + 1) * Self.chunkSize, pendingIDs.count)
        await start(stride(from: 0, to: end, by: Self.chunkSize).map { .ids(Array(pendingIDs[$0..<min($0 + Self.chunkSize, end)])) }).value
    }

    enum Place: Equatable {
        case loaded(Int)
        case pending(Int)
    }

    private struct PlaceKey: Equatable {
        var id: TrackRef
        var revision: Int
        var pending: Int
    }

    /// Where the song `id` (one of the list's source) first is; nil when it is not in the list,
    /// or not loaded yet in a list fetched by page. Remembered until the song or the list changes.
    func place(of id: TrackRef) -> Place? {
        let key = PlaceKey(id: id, revision: revision, pending: pendingIDs.count)
        if let placeMemo, placeMemo.key == key { return placeMemo.place }
        let place: Place? = if let position = tracks.firstIndex(where: { $0.id == id }) {
            .loaded(position)
        } else {
            pendingIDs.firstIndex(of: id.id).map(Place.pending)
        }
        placeMemo = (key, place)
        return place
    }

    /// Positions in `tracks` of the songs matching `query` (title, alias, artists, album);
    /// nil when the query is blank. Remembered until the query or the list changes.
    func matches(_ query: String) -> [Int]? {
        if let memo, memo.query == query, memo.revision == revision { return memo.matches }
        let matches = index.matches(query)
        memo = (query, revision, matches)
        return matches
    }

    /// Plays the list from `position` (from the top, skipping songs that cannot play, when
    /// nil). Songs not loaded yet join the queue once they arrive.
    func play(startAt position: Int? = nil, shuffled: Bool = false, on player: PlayerController, context: PlaybackContext) {
        guard !tracks.isEmpty else { return }
        if shuffled {
            player.shufflePlay(tracks, context: context)
        } else {
            player.play(tracks, startAt: position, context: context)
        }
        guard !isComplete else { return }
        let known = tracks.count
        Task {
            await loadRemaining()
            guard tracks.count > known else { return }
            player.extendQueue(Array(tracks[known...]), from: context)
        }
    }
}
