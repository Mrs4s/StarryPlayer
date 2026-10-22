import Foundation
import Observation

/// Playback samples drive the display until a drag takes over. Scrubbing updates the small
/// position/highlight views immediately, without seeking or waiting for the paused clock.
@MainActor @Observable
final class LyricsEditorClock {
    private(set) var time: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var activeLines: Set<Int> = []
    private(set) var scrubTime: TimeInterval?
    @ObservationIgnored private var playbackTime: TimeInterval = 0
    @ObservationIgnored private var playbackRanges: [ClosedRange<TimeInterval>?] = []

    func sample(time: TimeInterval, playing: Bool, ranges: [ClosedRange<TimeInterval>?]) {
        playbackTime = time
        playbackRanges = ranges
        if isPlaying != playing { isPlaying = playing }
        guard scrubTime == nil else { return }
        show(time, in: ranges)
    }

    func scrub(to time: TimeInterval, duration: TimeInterval, ranges: [ClosedRange<TimeInterval>?]) {
        guard time.isFinite else { return }
        let target = min(max(time, 0), duration > 0 ? duration : .infinity)
        if scrubTime != target { scrubTime = target }
        show(target, in: ranges)
    }

    /// Commit exactly once on mouse-up, retaining the last pointer position until the next
    /// playback sample. Audio keeps its play/pause state throughout the gesture.
    func finishScrubbing(seek: (TimeInterval) -> Void) {
        guard let target = scrubTime else { return }
        seek(target)
        scrubTime = nil
    }

    func cancelScrubbing() {
        guard scrubTime != nil else { return }
        scrubTime = nil
        show(playbackTime, in: playbackRanges)
    }

    private func show(_ time: TimeInterval, in ranges: [ClosedRange<TimeInterval>?]) {
        if abs(self.time - time) > 0.0005 { self.time = time }
        let active = Self.lines(at: time, in: ranges)
        if activeLines != active { activeLines = active }
    }

    private static func lines(at time: TimeInterval, in ranges: [ClosedRange<TimeInterval>?]) -> Set<Int> {
        Set(ranges.indices.filter { ranges[$0]?.contains(time) ?? false })
    }
}
