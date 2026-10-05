import Foundation
import StarryCore
import Testing
@testable import StarryPlayer

private func track(_ id: String) -> Track {
    Track(id: TrackRef(source: .local, id: id), title: "Song \(id)", duration: 180)
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

@MainActor
private final class FakeRadio {
    var calls = 0
    var holding = false
    var failing = false
    var emptyAnswers = 0
    private var next = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func more() async throws -> [Track] {
        calls += 1
        if holding { await withCheckedContinuation { waiters.append($0) } }
        if failing { throw URLError(.notConnectedToInternet) }
        if emptyAnswers > 0 {
            emptyAnswers -= 1
            return []
        }
        defer { next += 3 }
        return (next..<next + 3).map { track("fm\($0)") }
    }

    func release() {
        holding = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite(.serialized)
@MainActor
struct PersonalFMTests {
    private let fm = PlaybackContext(source: .local, originType: .radio, originName: "私人 FM")
    private let list = PlaybackContext(source: .local, originType: .playlist, originID: "list")

    private func player(_ radio: FakeRadio) -> PlayerController {
        let player = PlayerController()
        player.refillQueue = { _, _ in try await radio.more() }
        return player
    }

    private func start(_ player: PlayerController, _ radio: FakeRadio) async throws {
        player.play(try await radio.more(), context: fm)
        try await waitUntil { player.current?.id.id == "fm0" }
    }

    @Test func playsOnForeverKeepingTenPlayedSongs() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        try await start(player, radio)

        for step in 1...30 {
            player.next()
            try await waitUntil { player.current?.id.id == "fm\(step)" }
            // Asked for more on reaching the last two songs, so the next one is always there.
            #expect(player.queue.count - player.index! >= 2)
            #expect(player.index! <= PlayerController.endlessHistory)
        }
        #expect(player.index == PlayerController.endlessHistory)
        #expect(ids(Array(player.queue.prefix(2))) == ["fm20", "fm21"])
        #expect(radio.calls == 11)
    }

    @Test func theEndWaitsForTheRefill() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        var skips: [(String, TimeInterval)] = []
        player.onEndlessSkip = { skips.append(($0.id.id, $1)) }
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        radio.holding = true
        player.play([track("first")], context: fm)
        try await waitUntil { player.current?.id.id == "first" }

        player.next()
        player.next()
        #expect(player.isLoading)
        #expect(player.current?.id.id == "first")
        #expect(skips.map(\.0) == ["first"])

        radio.release()
        try await waitUntil { player.current?.id.id == "fm0" }
        #expect(ids(player.queue) == ["first", "fm0", "fm1", "fm2"])
        #expect(player.isPlaying)
        #expect(!player.isLoading)
    }

    @Test func noRefillMeansTheQueueStops() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        var messages: [String] = []
        player.onMessage = { messages.append($0) }
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        radio.failing = true
        player.play([track("only")], context: fm)
        try await waitUntil { player.current != nil }
        try await waitUntil { radio.calls == 1 }

        player.next()
        try await waitUntil { !player.isLoading }
        #expect(player.current?.id.id == "only")
        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("没能取到更多推荐") == true)
    }

    @Test func nothingNewAsksAgainAFewTimes() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        var messages: [String] = []
        player.onMessage = { messages.append($0) }
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        radio.emptyAnswers = 3
        player.play([track("first")], context: fm)
        try await waitUntil { player.current != nil && radio.calls == 1 }

        player.next()
        try await waitUntil { player.current?.id.id == "fm0" }
        #expect(radio.calls == 4)
        #expect(messages.isEmpty)

        radio.emptyAnswers = 10
        var before = radio.calls
        player.play([track("again")], context: fm)
        try await waitUntil { player.current?.id.id == "again" && radio.calls == before + 1 }
        before = radio.calls
        player.next()
        try await waitUntil { !player.isLoading }
        #expect(radio.calls - before == 3)
        #expect(messages == ["暂时没有更多推荐"])
        #expect(player.current?.id.id == "again")
    }

    @Test func playsInOrderWithItsOwnLoop() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.shuffle = true
        player.repeatMode = .all
        try await start(player, radio)

        player.next()
        try await waitUntil { player.current?.id.id == "fm1" }
        #expect(player.activeRepeat == .off)
        player.cycleRepeat()
        #expect(player.activeRepeat == .one)
        #expect(player.repeatMode == .all)
        player.cycleRepeat()
        #expect(player.activeRepeat == .off)

        player.cycleRepeat()
        player.play([track("a"), track("b")], context: list)
        try await waitUntil { player.current?.id.id == "a" }
        #expect(player.activeRepeat == .all)
        player.play([track("x"), track("y"), track("z")], context: fm)
        try await waitUntil { player.current?.id.id == "x" }
        #expect(player.activeRepeat == .off)
    }

    @Test func dislikeDropsTheSongAndPlaysTheNext() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        try await start(player, radio)
        player.pause()

        player.dropCurrent()
        try await waitUntil { player.current?.id.id == "fm1" }
        #expect(!ids(player.queue).contains("fm0"))
        #expect(player.isPlaying)

        #expect(ids(player.queue) == ["fm1", "fm2", "fm3", "fm4", "fm5"])
        radio.holding = true
        for _ in 0..<4 { player.next() }
        try await waitUntil { player.current?.id.id == "fm5" }
        try await waitUntil { radio.calls == 3 }
        player.dropCurrent()
        #expect(player.isLoading)
        #expect(player.current?.id.id == "fm5")
        radio.release()
        try await waitUntil { player.current?.id.id == "fm6" }
        #expect(ids(player.queue) == ["fm1", "fm2", "fm3", "fm4", "fm6", "fm7", "fm8"])
    }

    @Test func otherQueuesNeverRefill() async throws {
        let radio = FakeRadio()
        let player = player(radio)
        defer { player.stop(); player.systemMediaControls?.shutdown() }
        player.play([track("a"), track("b")], context: list)
        try await waitUntil { player.current?.id.id == "a" }
        player.next()
        try await waitUntil { player.current?.id.id == "b" }
        player.next()
        try await waitUntil { !player.isPlaying }
        #expect(radio.calls == 0)
        #expect(player.current?.id.id == "b")
    }
}
