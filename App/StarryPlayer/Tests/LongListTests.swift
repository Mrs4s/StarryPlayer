import Foundation
import StarryCore
import Testing
@testable import StarryPlayer

private func track(_ id: String, _ title: String? = nil) -> Track {
    Track(id: TrackRef(source: .local, id: id), title: title ?? "Song \(id)", duration: 180)
}

private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id.id) }

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite(.serialized)
@MainActor
struct PlayerQueueBatchTests {
    private let list = PlaybackContext(source: .local, originType: .playlist, originID: "list")
    private let other = PlaybackContext(source: .local, originType: .playlist, originID: "other")

    @Test func playNextMovesSongsAfterTheCurrentOne() async throws {
        let player = PlayerController()
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        let queue = ["a", "b", "c", "d", "e"].map { track($0) }
        player.play(queue, startAt: 1)
        try await waitUntil { player.current?.id.id == "b" }

        player.playNext([track("d"), track("a"), track("b"), track("x"), track("x")])
        #expect(ids(player.queue) == ["b", "d", "a", "x", "c", "e"])
        #expect(player.index == 0)
        #expect(player.current?.id.id == "b")
    }

    @Test func addToQueueAppendsOnlyNewSongs() async throws {
        let player = PlayerController()
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.play([track("a"), track("b")])
        try await waitUntil { player.current != nil }
        player.addToQueue([track("b", "Other title"), track("c"), track("c"), track("d")])
        #expect(ids(player.queue) == ["a", "b", "c", "d"])
    }

    @Test func tenThousandSongsInOneChange() async throws {
        let player = PlayerController()
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.play([track("first")])
        try await waitUntil { player.current != nil }
        let many = (0..<10_000).map { track("\($0)") }
        let start = ContinuousClock.now
        player.addToQueue(many)
        player.playNext(Array(many.reversed()))
        // One change, not one per song: one by one, the queue would be searched for every song.
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(player.queue.count == 10_001)
        #expect(ids(Array(player.queue.prefix(3))) == ["first", "9999", "9998"])
    }

    @Test func extendQueueOnlyForTheSameList() async throws {
        let player = PlayerController()
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.play([track("a"), track("b")], context: list)
        player.extendQueue([track("b"), track("c")], from: list)
        player.extendQueue([track("z")], from: other)
        try await waitUntil { player.current != nil }
        #expect(ids(player.queue) == ["a", "b", "c"])

        player.extendQueue([track("d")], from: list)
        player.extendQueue([track("y")], from: other)
        #expect(ids(player.queue) == ["a", "b", "c", "d"])
    }
}

@Suite
@MainActor
struct TrackListLoaderTests {
    private final class FakeSource: @unchecked Sendable {
        let lock = NSLock()
        var requests: [[String]] = []
        var failing: Set<String> = []

        func fetch(_ ids: [String]) async throws -> [Track] {
            lock.withLock { requests.append(ids) }
            let delay = max(0, 40 - (Int(ids[0]) ?? 0) / 100)
            try await Task.sleep(for: .milliseconds(delay))
            if lock.withLock({ !failing.isDisjoint(with: ids) }) { throw URLError(.timedOut) }
            return ids.map { track($0) }
        }
    }

    private func loader(first: Int, total: Int, source: FakeSource) -> TrackListLoader {
        TrackListLoader(tracks: (0..<first).map { track("\($0)") }, pendingIDs: (first..<total).map(String.init)) { try await source.fetch($0) }
    }

    @Test func nextPageThenTheRestInOrder() async {
        let source = FakeSource()
        let list = loader(first: 500, total: 2_300, source: source)
        #expect(list.totalCount == 2_300)

        await list.loadNext()
        #expect(list.tracks.count == 1_000)
        #expect(source.requests.map(\.count) == [500])

        await list.loadRemaining()
        #expect(list.isComplete)
        #expect(ids(list.tracks) == (0..<2_300).map(String.init))
        #expect(source.requests.map(\.count).sorted() == [300, 500, 500, 500])
    }

    @Test func prefetchOnlyNearTheEnd() async throws {
        let source = FakeSource()
        let list = loader(first: 500, total: 1_500, source: source)
        list.prefetch(near: 100)
        try await Task.sleep(for: .milliseconds(80))
        #expect(source.requests.isEmpty)
        list.prefetch(near: 450)
        try await waitUntil { list.tracks.count == 1_000 }
        #expect(source.requests.count == 1)
    }

    @Test func aFailureKeepsWhatArrivedBeforeIt() async {
        let source = FakeSource()
        source.failing = ["1500"]
        let list = loader(first: 500, total: 2_500, source: source)
        await list.loadRemaining()
        #expect(list.failure != nil)
        #expect(list.tracks.count == 1_500)
        #expect(list.pendingIDs.first == "1500")
        // The list's rows do not retry by themselves after a failure…
        list.prefetch(near: 999)
        #expect(!list.isLoading)
        source.failing = []
        await list.loadRemaining()
        #expect(list.failure == nil)
        #expect(ids(list.tracks) == (0..<2_500).map(String.init))
    }

    @Test func loadsAsFarAsASongToLocate() async {
        let source = FakeSource()
        let list = loader(first: 500, total: 3_000, source: source)
        let song = TrackRef(source: .local, id: "1700")
        #expect(list.place(of: song) == .pending(1_200))
        #expect(list.place(of: TrackRef(source: .local, id: "missing")) == nil)

        await list.load(through: "1700")
        // Its chunk and the ones before it, not the rest.
        #expect(list.place(of: song) == .loaded(1_700))
        #expect(ids(list.tracks) == (0..<2_000).map(String.init))
        #expect(source.requests.map(\.count) == [500, 500, 500])
        #expect(list.pendingIDs.first == "2000")
    }

    @Test func likesAndUnlikesEditTheList() async throws {
        let source = FakeSource()
        let list = loader(first: 3, total: 600, source: source)
        list.prepend(track("new", "Just liked"))
        list.prepend(track("1"))
        #expect(ids(Array(list.tracks.prefix(4))) == ["new", "0", "1", "2"])
        #expect(list.arrival?.id.id == "new")

        // Unliked while its page is on its way: the page does not bring it back.
        let loading = Task { await list.loadRemaining() }
        try await waitUntil { list.isLoading }
        list.remove(TrackRef(source: .local, id: "450"))
        list.remove(TrackRef(source: .local, id: "0"))
        await loading.value
        #expect(list.tracks.count == 1 + 600 - 2)
        #expect(!list.tracks.contains { $0.id.id == "450" || $0.id.id == "0" })
        #expect(list.matches("just liked") == [0])
        #expect(list.matches("song 2")?.first == 2)
        #expect(list.matches(" ") == nil)
    }
}
