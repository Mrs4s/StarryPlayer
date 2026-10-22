import Foundation
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorClockTests {
    private let ranges: [ClosedRange<TimeInterval>?] = [0...2, 4...8, 6...10, nil]

    @Test(arguments: [false, true])
    func scrubbingOwnsThePositionUntilItCommitsOnce(playing: Bool) {
        let clock = LyricsEditorClock()
        clock.sample(time: 1, playing: playing, ranges: ranges)
        // Both forward and backward movement must appear before the next playback sample.
        for target in [7.5, 6.5, 7] {
            clock.scrub(to: target, duration: 12, ranges: ranges)
            #expect(clock.time == target)
            clock.sample(time: 2, playing: playing, ranges: ranges)
            #expect(clock.time == target)
            #expect(clock.activeLines == [1, 2])
        }
        var seeks: [TimeInterval] = []
        // Mouse-up can be beyond the last drag-change event.
        clock.scrub(to: 8.5, duration: 12, ranges: ranges)
        clock.finishScrubbing { seeks.append($0) }
        clock.finishScrubbing { seeks.append($0) }
        clock.cancelScrubbing()
        #expect(seeks == [8.5])
        #expect(clock.time == 8.5)
        #expect(clock.scrubTime == nil)
        #expect(clock.isPlaying == playing)
        clock.sample(time: 9, playing: playing, ranges: ranges)
        #expect(clock.time == 9)
        #expect(clock.activeLines == [2])
    }

    @Test func cancelledScrubReturnsToLatestPlaybackWithoutSeeking() {
        let clock = LyricsEditorClock()
        clock.sample(time: 1, playing: true, ranges: ranges)
        clock.scrub(to: 7, duration: 12, ranges: ranges)
        clock.sample(time: 3, playing: true, ranges: ranges)
        clock.cancelScrubbing()
        var seeks = 0
        clock.finishScrubbing { _ in seeks += 1 }
        #expect(seeks == 0)
        #expect(clock.time == 3)
        #expect(clock.activeLines.isEmpty)
        #expect(clock.scrubTime == nil)
        #expect(clock.isPlaying)
    }

    @Test func scrubbingClampsAtSongEdgesAndAllowsUnknownDuration() {
        let clock = LyricsEditorClock()
        clock.scrub(to: -5, duration: 12, ranges: ranges)
        #expect(clock.time == 0)
        clock.scrub(to: 40, duration: 12, ranges: ranges)
        #expect(clock.time == 12)
        clock.scrub(to: 40, duration: 0, ranges: ranges)
        #expect(clock.time == 40)
        clock.scrub(to: .nan, duration: 0, ranges: ranges)
        #expect(clock.time == 40)
    }
}
