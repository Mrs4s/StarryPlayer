import AppKit
import AudioProcessing
import SwiftUI

struct LyricsEditorOverview: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    let viewport: LyricsTimelineViewport
    @Environment(\.theme) private var theme
    @State private var hoverX: CGFloat?
    @State private var scrubX: CGFloat?
    @State private var frameDrag: FrameDrag?

    static let height: CGFloat = 38

    private struct FrameDrag {
        enum Part { case body, start, end }
        var part: Part
        var original: ClosedRange<TimeInterval>
    }

    private var caretLine: Int? { (session.caret ?? session.lastStarted)?.line }

    private var duration: TimeInterval {
        max(audio.duration, session.track.duration, session.timedEnd, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = duration
            let scale = width / duration
            let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
            ZStack(alignment: .topLeading) {
                shape.fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035))
                OverviewProgress(clock: clock, scale: scale, scrubX: scrubX, isLive: audio.isReady) { x in
                    Rectangle().fill(theme.primary.opacity(theme.isDark ? 0.14 : 0.1)).frame(width: x)
                }
                OverviewWaveform(waveform: audio.waveform, duration: duration, color: theme.onSurface.opacity(theme.isDark ? 0.5 : 0.42))
                    .equatable()
                OverviewWaveform(waveform: audio.waveform, duration: duration, color: theme.primary)
                    .equatable()
                    .mask(alignment: .leading) {
                        OverviewProgress(clock: clock, scale: scale, scrubX: scrubX, isLive: audio.isReady) { x in
                            Rectangle().frame(width: x)
                        }
                    }
                caretRegion(scale: scale)
                OverviewLines(session: session, clock: clock, caret: caretLine, duration: duration, color: theme.onSurface, accent: theme.primary)
                    .allowsHitTesting(false)
                if audio.isReady {
                    OverviewProgress(clock: clock, scale: scale, scrubX: scrubX, isLive: true) { x in
                        Rectangle().fill(theme.primary).frame(width: 2).offset(x: x - 1)
                    }
                    .allowsHitTesting(false)
                }
                hoverGuide(width: width, scale: scale)
                if let range = viewport.range(caretLine: caretLine, in: session) {
                    viewFrame(range, scale: scale, duration: duration)
                }
            }
            .clipShape(shape)
            .contentShape(Rectangle())
            .gesture(scrub(width: width, scale: scale))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), width)
                case .ended: hoverX = nil
                }
            }
            .onHover { inside in
                if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
            .animation(frameDrag == nil ? Motion.selection : nil, value: viewport.range(caretLine: caretLine, in: session))
            .animation(Motion.reveal, value: audio.waveform != nil)
        }
        .frame(height: Self.height)
        .help("拖动或点按跳转；拖动方框移动下方时间轴，拖动方框两边缩放")
    }

    private func line(at time: TimeInterval) -> Int? {
        session.timedRanges.lastIndex { $0?.contains(time) ?? false }
    }

    // MARK: Parts

    @ViewBuilder
    private func caretRegion(scale: CGFloat) -> some View {
        if let caretLine, session.timedRanges.indices.contains(caretLine), let range = session.timedRanges[caretLine] {
            Rectangle()
                .fill(theme.primary.opacity(0.22))
                .frame(width: max(CGFloat(range.upperBound - range.lowerBound) * scale, 2))
                .offset(x: CGFloat(range.lowerBound) * scale)
                .allowsHitTesting(false)
                .animation(Motion.selection, value: range)
        }
    }

    @ViewBuilder
    private func hoverGuide(width: CGFloat, scale: CGFloat) -> some View {
        if frameDrag == nil, let x = scrubX ?? hoverX {
            let time = Double(x / scale)
            let lyric = line(at: time).map { session.draft.lines[$0].text.trimmingCharacters(in: .whitespaces) } ?? ""
            let label = lyric.isEmpty ? LyricsEditorFormat.time(time) : "\(LyricsEditorFormat.time(time))  \(lyric)"
            let flipped = width - x < 220
            let labelWidth: CGFloat = 210
            Rectangle()
                .fill(theme.primary.opacity(0.9))
                .frame(width: 1)
                .offset(x: x)
                .allowsHitTesting(false)
            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.surfaceAlt.opacity(0.92)))
                .frame(width: labelWidth, alignment: flipped ? .trailing : .leading)
                .offset(x: flipped ? x - 4 - labelWidth : x + 4, y: 4)
                .allowsHitTesting(false)
        }
    }

    private func viewFrame(_ range: ClosedRange<TimeInterval>, scale: CGFloat, duration: TimeInterval) -> some View {
        let x = CGFloat(range.lowerBound) * scale
        let w = max(CGFloat(range.upperBound - range.lowerBound) * scale, 6)
        return ZStack {
            Rectangle()
                .fill(theme.primary.opacity(0.08))
                .overlay(alignment: .leading) { Rectangle().fill(theme.primary.opacity(0.7)).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(theme.primary.opacity(0.7)).frame(width: 1) }
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(frameGesture(.body, range: range, scale: scale, duration: duration))
            HStack(spacing: 0) {
                frameHandle(.start, range: range, scale: scale, duration: duration)
                Spacer(minLength: 0)
                frameHandle(.end, range: range, scale: scale, duration: duration)
            }
            .padding(.horizontal, -4)
        }
        .frame(width: w)
        .offset(x: x)
    }

    private func frameHandle(_ part: FrameDrag.Part, range: ClosedRange<TimeInterval>, scale: CGFloat, duration: TimeInterval) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(frameGesture(part, range: range, scale: scale, duration: duration))
    }

    // MARK: Gestures

    private func scrub(width: CGFloat, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scrubX = min(max(value.location.x, 0), width)
            }
            .onEnded { value in
                let x = min(max(value.location.x, 0), width)
                let time = Double(x / scale)
                audio.seek(to: time)
                if let line = line(at: time) { session.selectLine(line) }
                scrubX = nil
            }
    }

    private func frameGesture(_ part: FrameDrag.Part, range: ClosedRange<TimeInterval>, scale: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if frameDrag == nil { frameDrag = FrameDrag(part: part, original: range) }
                guard let drag = frameDrag else { return }
                let delta = Double(value.translation.width / scale)
                let lo = drag.original.lowerBound, hi = drag.original.upperBound
                let minimum = 1.0
                switch drag.part {
                case .body:
                    let span = hi - lo
                    let start = min(max(lo + delta, 0), max(duration - span, 0))
                    viewport.manual = start...(start + span)
                case .start:
                    let start = min(max(lo + delta, 0), hi - minimum)
                    viewport.manual = start...hi
                case .end:
                    let end = max(min(hi + delta, duration), lo + minimum)
                    viewport.manual = lo...end
                }
            }
            .onEnded { _ in frameDrag = nil }
    }
}

/// Places its content by the playhead's x (or a scrub's); a leaf, so the clock re-runs only
/// this.
private struct OverviewProgress<Content: View>: View {
    let clock: LyricsEditorClock
    var scale: CGFloat
    var scrubX: CGFloat?
    var isLive: Bool
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        content(scrubX ?? (isLive ? max(CGFloat(clock.time) * scale, 0) : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct OverviewWaveform: View, @MainActor Equatable {
    let waveform: WaveformPeaks?
    var duration: TimeInterval
    var color: Color

    static func == (a: Self, b: Self) -> Bool {
        a.waveform == b.waveform && a.duration == b.duration && a.color == b.color
    }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            guard let waveform, duration > 0 else {
                context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(color))
                return
            }
            let step: CGFloat = 0.5
            let secondsPerStep = duration / Double(size.width) * Double(step)
            var tops: [CGPoint] = []
            var x: CGFloat = 0
            while x <= size.width {
                let t = Double(x) / Double(size.width) * duration
                let half = max(0.5, CGFloat(waveform.peak(from: t, to: t + secondsPerStep)) * (middle - 2))
                tops.append(CGPoint(x: x, y: middle - half))
                x += step
            }
            var path = Path()
            path.addLines(tops)
            for point in tops.reversed() { path.addLine(to: CGPoint(x: point.x, y: 2 * middle - point.y)) }
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

private struct OverviewLines: View {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    var caret: Int?
    var duration: TimeInterval
    var color: Color
    var accent: Color

    var body: some View {
        let ranges = session.timedRanges
        let lines = session.draft.lines
        let active = clock.activeLines
        Canvas { context, size in
            guard duration > 0 else { return }
            let scale = size.width / duration
            for (index, line) in lines.enumerated() {
                guard let range = ranges[index] else { continue }
                let rect = CGRect(x: CGFloat(range.lowerBound) * scale, y: size.height - (line.isBackground ? 3 : 6), width: max(CGFloat(range.upperBound - range.lowerBound) * scale - 1, 1.5), height: line.isBackground ? 2 : 3)
                let lit = active.contains(index) || index == caret
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? accent : color.opacity(line.isBackground ? 0.3 : 0.5)))
            }
        }
    }
}
