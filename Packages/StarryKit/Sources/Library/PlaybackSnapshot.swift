import Foundation
import StarryCore

public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public var queue: [Track]
    public var index: Int
    /// Seconds into the current song.
    public var position: TimeInterval
    public var context: PlaybackContext?
    public var repeatMode: RepeatMode
    public var shuffle: Bool

    public static let queueLimit = 5000
    static let fileName = "playback-state"

    public init(queue: [Track], index: Int, position: TimeInterval, context: PlaybackContext?, repeatMode: RepeatMode, shuffle: Bool) {
        var queue = queue
        var index = index
        if queue.count > Self.queueLimit, queue.indices.contains(index) {
            let start = min(max(0, index - Self.queueLimit / 5), queue.count - Self.queueLimit)
            queue = Array(queue[start..<(start + Self.queueLimit)])
            index -= start
        }
        self.queue = queue
        self.index = index
        self.position = max(0, position)
        self.context = context
        self.repeatMode = repeatMode
        self.shuffle = shuffle
    }

    /// The song the snapshot stopped on, nil if the snapshot is damaged.
    public var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    public static func load(from directory: DataDirectory) -> PlaybackSnapshot? {
        guard let snapshot = directory.readCodable(PlaybackSnapshot.self, name: fileName), snapshot.current != nil else { return nil }
        return snapshot
    }

    public func save(to directory: DataDirectory) {
        try? directory.writeCodable(self, name: Self.fileName)
    }

    public static func delete(from directory: DataDirectory) {
        directory.delete(fileName)
    }
}
