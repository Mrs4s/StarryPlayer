import Foundation
import StarryCore

@MainActor
public final class LibraryDatabase {
    public private(set) var history: [Track] = []
    public private(set) var likedTrackIDs: Set<TrackRef> = []

    public init() {}

    public func recordPlay(_ track: Track) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    public func clearHistory() {
        history.removeAll()
    }

    public func setLiked(_ ref: TrackRef, _ liked: Bool) {
        if liked { likedTrackIDs.insert(ref) } else { likedTrackIDs.remove(ref) }
    }
}
