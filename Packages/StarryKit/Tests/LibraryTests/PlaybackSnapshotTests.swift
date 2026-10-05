import Foundation
import StarryCore
import Testing
@testable import Library

struct PlaybackSnapshotTests {
    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: TrackRef(source: .example, id: "\($0)"), title: "Song \($0)", duration: 200) }
    }

    @Test func savesAndLoads() throws {
        let directory = DataDirectory(url: FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let context = PlaybackContext(source: .example, originType: .playlist, originID: "42", originName: "Mix")
        let snapshot = PlaybackSnapshot(queue: tracks(3), index: 1, position: 83.5, context: context, repeatMode: .all, shuffle: true)
        snapshot.save(to: directory)
        let loaded = try #require(PlaybackSnapshot.load(from: directory))
        #expect(loaded == snapshot)
        #expect(loaded.current?.title == "Song 1")
        PlaybackSnapshot.delete(from: directory)
        #expect(PlaybackSnapshot.load(from: directory) == nil)
    }

    @Test func trimsHugeQueueAroundCurrentSong() {
        let queue = tracks(12_000)
        let middle = PlaybackSnapshot(queue: queue, index: 6_000, position: 0, context: nil, repeatMode: .off, shuffle: false)
        #expect(middle.queue.count == PlaybackSnapshot.queueLimit)
        #expect(middle.current?.id.id == "6000")
        #expect(middle.index == PlaybackSnapshot.queueLimit / 5)
        let end = PlaybackSnapshot(queue: queue, index: 11_999, position: 0, context: nil, repeatMode: .off, shuffle: false)
        #expect(end.queue.count == PlaybackSnapshot.queueLimit)
        #expect(end.current?.id.id == "11999")
        let start = PlaybackSnapshot(queue: queue, index: 3, position: 0, context: nil, repeatMode: .off, shuffle: false)
        #expect(start.index == 3)
        #expect(start.queue.first?.id.id == "0")
    }

    @Test func damagedSnapshotIsIgnored() throws {
        let directory = DataDirectory(url: FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory.url) }
        PlaybackSnapshot(queue: tracks(2), index: 5, position: 0, context: nil, repeatMode: .off, shuffle: false).save(to: directory)
        #expect(PlaybackSnapshot.load(from: directory) == nil)
    }
}
