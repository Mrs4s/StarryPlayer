import AppKit
import QuartzCore
import SwiftUI

struct LyricsEditorClockDriver: NSViewRepresentable {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    var ready: Bool
    var playing: Bool

    func makeNSView(context: Context) -> LyricsEditorClockView { LyricsEditorClockView() }
    func updateNSView(_ view: LyricsEditorClockView, context: Context) {
        view.session = session
        view.audio = audio
        view.clock = clock
        view.wake(playing: playing)
    }
    static func dismantleNSView(_ view: LyricsEditorClockView, coordinator: ()) { view.stop() }
}

/// Uses the window's display cadence (including ProMotion), in common run-loop modes so
/// scroll tracking and menus do not suspend the editor's clock. Idle sampling stays at 10 Hz.
final class LyricsEditorClockView: NSView {
    var session: LyricsEditorSession? {
        didSet { if oldValue !== session { revision = -1 } }
    }
    var audio: LyricsEditorAudio?
    var clock: LyricsEditorClock?
    private var link: CADisplayLink?
    private var revision = -1
    private var ranges: [ClosedRange<TimeInterval>?] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        self.link = link
        wake(playing: audio?.isPlaying ?? false)
        link.add(to: .main, forMode: .common)
    }

    func wake(playing: Bool) {
        link?.preferredFrameRateRange = playing
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)
        link?.isPaused = false
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick() {
        guard let session, let audio, let clock else { return }
        guard audio.isReady else {
            clock.cancelScrubbing()
            clock.sample(time: 0, playing: false, ranges: [])
            link?.isPaused = true
            return
        }
        if revision != session.revision {
            revision = session.revision
            ranges = session.timedRanges
        }
        let sample = audio.clock()
        clock.sample(time: sample.time, playing: sample.rate > 0, ranges: ranges)
    }
}
