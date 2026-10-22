import AppKit
import AudioProcessing
import LyricsCore
import SwiftUI

struct LyricsEditorTimeline: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    let viewport: LyricsTimelineViewport
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage(LyricsEditorTimeline.gainKey) private var gain = Double(Spectrogram.defaultGain)
    @AppStorage(LyricsEditorTimeline.vocalsOnlyKey) private var vocalsOnly = false
    @State private var drag: Drag?

    static let gainKey = "starry.lyricsEditor.spectrogramGain"
    static let vocalsOnlyKey = "starry.lyricsEditor.vocalsOnly"
    static let gains: [Double] = [1, 1.5, 2, 3, 4, 6, 8]

    private var onSpectrogram: Bool { audio.isPrecise }
    private var accent: Color { onSpectrogram ? model.theme(for: .dark).primary : theme.primary }

    private struct Drag {
        enum Part { case start, end, body }
        var position: LyricsDraft.Position
        var part: Part
        var range: ClosedRange<TimeInterval>
        var original: LyricsDraft.Syllable
        var previous: LyricsDraft.Syllable?
        var next: LyricsDraft.Syllable?
        var width: CGFloat
    }

    private var lineIndex: Int? { (session.caret ?? session.lastStarted)?.line }

    private static let mainLane: (y: CGFloat, height: CGFloat) = (30, 44)
    private static let backgroundLane: (y: CGFloat, height: CGFloat) = (78, 22)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035))
                if let lineIndex, let range = drag?.range ?? viewport.range(caretLine: lineIndex, in: session) {
                    content(line: lineIndex, range: range, size: geo.size)
                } else {
                    Text("导入歌词并选中一行，这里会显示它的时间轴")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: lineIndex) { _, _ in viewport.manual = nil }
        .task(id: vocalsOnly && audio.isPrecise) {
            if vocalsOnly, audio.isPrecise { audio.prepareVocals() }
        }
    }

    private var vocalsSwitch: some View {
        Button {
            vocalsOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                switch (vocalsOnly, audio.vocals) {
                case (true, .separating(let progress)):
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("分离人声 \(Int(progress * 100))%")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                case (true, .failed):
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("仅人声")
                default:
                    Image(systemName: vocalsOnly ? "person.wave.2.fill" : "person.wave.2")
                    Text("仅人声")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(vocalsOnly ? theme.onPrimary : theme.onSurface.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(vocalsOnly ? theme.primary : theme.surfaceAlt.opacity(0.95)))
            .overlay(Capsule().strokeBorder(theme.onSurface.opacity(vocalsOnly ? 0 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: vocalsOnly)
        .animation(Motion.hover, value: audio.vocals)
        .help(vocalsHelp)
    }

    private var vocalsHelp: String {
        if case .failed(let message) = audio.vocals, vocalsOnly { return message }
        return vocalsOnly ? "频谱只显示分离出的人声，点按显示整首歌" : "用人声分离模型只显示人声的频谱，字的起止更清楚"
    }

    private func lines(in range: ClosedRange<TimeInterval>, caretLine: Int) -> [Int] {
        let ranges = session.timedRanges
        return ranges.indices.filter { index in
            if index == caretLine { return true }
            return ranges[index]?.overlaps(range) ?? false
        }
    }

    @ViewBuilder
    private func content(line caretLine: Int, range: ClosedRange<TimeInterval>, size: CGSize) -> some View {
        let line = session.draft.lines[caretLine]
        let scale = size.width / (range.upperBound - range.lowerBound)
        let x = { (time: TimeInterval) in CGFloat(time - range.lowerBound) * scale }
        ZStack(alignment: .topLeading) {
            if onSpectrogram {
                TimelineSpectrogram(audio: audio, range: range, gain: Float(gain), vocalsOnly: vocalsOnly && audio.vocals == .ready)
                    .padding(.top, 26)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if let waveform = audio.waveform {
                TimelineWaveform(waveform: waveform, range: range, color: theme.onSurface)
                    .padding(.top, 26)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            TimelineScrubSurface(session: session, audio: audio, clock: clock, range: range, scale: scale, color: theme.onSurfaceVariant)
            ForEach(lines(in: range, caretLine: caretLine), id: \.self) { index in
                let syllables = session.draft.lines[index].syllables
                let lane = session.draft.lines[index].isBackground ? Self.backgroundLane : Self.mainLane
                ForEach(Array(syllables.enumerated()), id: \.element.id) { s, syllable in
                    let position = LyricsDraft.Position(line: index, syllable: s)
                    if let start = syllable.start,
                       drag?.position == position || (start <= range.upperBound &&
                       (syllable.end ?? syllables[safe: s + 1]?.start ?? start + 0.3) >= range.lowerBound) {
                        let end = syllable.end ?? syllables[safe: s + 1]?.start ?? start + 0.3
                        // Keep the dragged block alive outside the viewport so its gesture
                        // still ends and closes the single undo step.
                        block(syllable, position: position, isCaret: session.caret == position, small: lane.height < 30, width: size.width)
                            .frame(width: max(x(max(end, start)) - x(start), 8), height: lane.height)
                            .modifier(TimelineLineActivity(clock: clock, index: index, isCaret: index == caretLine))
                            .offset(x: x(start), y: lane.y)
                    }
                }
            }
            if audio.isReady {
                TimelinePlayhead(clock: clock, range: range, scale: scale, color: accent)
            }
            if onSpectrogram {
                vocalsSwitch
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 3)
                    .padding(.trailing, 6)
            }
            let untimed = line.syllables.filter { !$0.isTimed }.count
            if untimed > 0 {
                Text("还有 \(untimed) 个音节没打点")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(theme.surfaceAlt.opacity(0.9)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .animation(drag == nil && viewport.manual == nil ? Motion.selection : nil, value: range)
        .animation(Motion.reveal, value: audio.waveform != nil)
        .animation(Motion.reveal, value: onSpectrogram)
    }

    private func block(_ syllable: LyricsDraft.Syllable, position: LyricsDraft.Position, isCaret: Bool, small: Bool, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: small ? 4 : 6, style: .continuous)
        let fill = onSpectrogram ? (isCaret ? accent.opacity(0.42) : Color.black.opacity(0.45)) : theme.primary.opacity(isCaret ? 0.32 : 0.16)
        let stroke = onSpectrogram ? (isCaret ? accent : Color.white.opacity(0.42)) : theme.primary.opacity(isCaret ? 0.9 : 0.3)
        return Text(syllable.text.trimmingCharacters(in: .whitespaces))
            .font(.system(size: small ? 10.5 : 13, weight: .semibold))
            .foregroundStyle(onSpectrogram ? Color.white : theme.onSurface)
            .shadow(color: .black.opacity(onSpectrogram ? 0.6 : 0), radius: 1.5)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: isCaret ? 1.5 : 1))
            .contentShape(shape)
            .gesture(dragGesture(position, part: .body, width: width))
            .overlay(alignment: .leading) { handle(position, part: .start, width: width) }
            .overlay(alignment: .trailing) { handle(position, part: .end, width: width) }
            .help("\(LyricsEditorFormat.time(syllable.start, digits: 3)) – \(LyricsEditorFormat.time(syllable.end, digits: 3))")
    }

    private func handle(_ position: LyricsDraft.Position, part: Drag.Part, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(dragGesture(position, part: part, width: width))
    }

    private func dragGesture(_ position: LyricsDraft.Position, part: Drag.Part, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if drag == nil {
                    // The span on screen holds still while the block is dragged.
                    guard let range = viewport.range(caretLine: lineIndex ?? position.line, in: session), session.draft.contains(position) else { return }
                    session.beginAdjusting()
                    session.caret = position
                    let line = session.draft.lines[position.line].syllables
                    drag = Drag(position: position, part: part, range: range, original: line[position.syllable], previous: line[safe: position.syllable - 1], next: line[safe: position.syllable + 1], width: width)
                }
                guard let drag else { return }
                apply(drag, translation: value.translation.width)
            }
            .onEnded { _ in
                drag = nil
                session.endAdjusting()
            }
    }

    /// How near, in points, a dragged edge comes to the neighbour's edge it faces before it
    /// sticks to it.
    static let stickiness: CGFloat = 6

    static func stick(_ value: TimeInterval, to edges: [TimeInterval?], reach: TimeInterval) -> TimeInterval {
        edges.compactMap { $0 }.filter { abs($0 - value) <= reach }.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// Moves the dragged part by `translation` points, to the hundredth of a second, keeping
    /// every syllable at least 20 ms long and shared edges together. An edge brought near the
    /// one it faces (the previous syllable's end, the next one's start) sticks to it.
    private func apply(_ drag: Drag, translation: CGFloat) {
        guard drag.width > 0 else { return }
        let secondsPerPoint = (drag.range.upperBound - drag.range.lowerBound) / Double(drag.width)
        let delta = Double(translation) * secondsPerPoint
        let reach = Double(Self.stickiness) * secondsPerPoint
        let snap = { (t: TimeInterval) in (t * 100).rounded() / 100 }
        let original = drag.original
        guard let start = original.start else { return }
        let end = original.end ?? drag.next?.start ?? start + 0.3
        let minimum = 0.02
        let linkedPrevious = drag.previous?.end.map { abs($0 - start) < 0.002 } ?? false
        let linkedNext = drag.next?.start.map { abs($0 - end) < 0.002 } ?? false
        let floor = drag.previous?.start.map { $0 + minimum } ?? 0
        let ceiling = drag.next?.end.map { $0 - minimum } ?? .infinity
        session.adjust { draft in
            let p = drag.position
            switch drag.part {
            case .start:
                let moved = Self.stick(snap(start + delta), to: linkedPrevious ? [] : [drag.previous?.end], reach: reach)
                let new = min(max(moved, linkedPrevious ? floor : 0), end - minimum)
                draft[p].start = new
                if linkedPrevious { draft[LyricsDraft.Position(line: p.line, syllable: p.syllable - 1)].end = new }
            case .end:
                let moved = Self.stick(snap(end + delta), to: linkedNext ? [] : [drag.next?.start], reach: reach)
                let new = max(min(moved, linkedNext ? ceiling : .infinity), start + minimum)
                draft[p].end = new
                if linkedNext { draft[LyricsDraft.Position(line: p.line, syllable: p.syllable + 1)].start = new }
            case .body:
                let facing = [drag.previous?.end.map { $0 - start }, drag.next?.start.map { $0 - end }]
                let shift = max(Self.stick(snap(delta), to: facing, reach: reach), -start)
                draft[p].start = start + shift
                draft[p].end = end + shift
            }
        }
    }
}

/// Pointer updates affect only the clock's leaves. The audio graph is rescheduled once,
/// on release; cancelling a gesture returns to playback without seeking.
private struct TimelineScrubSurface: View {
    let session: LyricsEditorSession
    let audio: LyricsEditorAudio
    let clock: LyricsEditorClock
    var range: ClosedRange<TimeInterval>
    var scale: CGFloat
    var color: Color
    @GestureState private var scrubbing = false

    var body: some View {
        TimelineTicks(range: range, color: color)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($scrubbing) { _, tracking, _ in tracking = true }
                .onChanged { value in preview(at: value.location.x) }
                .onEnded { value in
                    preview(at: value.location.x)
                    clock.finishScrubbing { audio.seek(to: $0) }
                })
            .allowsHitTesting(audio.isReady)
            .onChange(of: scrubbing) { _, tracking in
                if !tracking { clock.cancelScrubbing() }
            }
            .onDisappear { clock.cancelScrubbing() }
    }

    private func preview(at x: CGFloat) {
        guard audio.isReady, scale > 0 else { return }
        let target = range.lowerBound + Double(x / scale)
        clock.scrub(to: target, duration: audio.duration, ranges: session.timedRanges)
    }
}

/// Highlight changes do not rebuild the timeline's blocks, ticks or spectrogram.
private struct TimelineLineActivity: ViewModifier {
    let clock: LyricsEditorClock
    var index: Int
    var isCaret: Bool

    func body(content: Content) -> some View {
        content.opacity(isCaret || clock.activeLines.contains(index) ? 1 : 0.5)
    }
}

private struct TimelineTicks: View {
    var range: ClosedRange<TimeInterval>
    var color: Color

    private static let labelSteps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120]

    var body: some View {
        Canvas { context, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return }
            let scale = size.width / span
            let step = Self.labelSteps.first { CGFloat($0) * scale >= 56 } ?? Self.labelSteps.last!
            let minor = step / 4
            var k = Int((range.lowerBound / minor).rounded(.up))
            while Double(k) * minor <= range.upperBound {
                let tick = Double(k) * minor
                let x = CGFloat(tick - range.lowerBound) * scale
                let labelled = k % 4 == 0
                let height: CGFloat = labelled ? 10 : (k % 2 == 0 ? 6 : 3)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: height)), with: .color(color.opacity(labelled ? 0.5 : 0.25)))
                if labelled {
                    context.draw(Text(LyricsEditorFormat.time(tick).dropLast(3)).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundColor(color.opacity(0.8)), at: CGPoint(x: x + 3, y: 12), anchor: .topLeading)
                }
                k += 1
            }
        }
    }
}

private struct TimelineWaveform: View {
    let waveform: WaveformPeaks
    var range: ClosedRange<TimeInterval>
    var color: Color

    var body: some View {
        Canvas { context, size in
            let span = range.upperBound - range.lowerBound
            guard span > 0, size.width > 0 else { return }
            let step: CGFloat = 2
            let secondsPerStep = span / Double(size.width) * Double(step)
            let middle = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let t = range.lowerBound + Double(x) / Double(size.width) * span
                // A square root lifts quiet passages enough to see.
                let level = CGFloat(sqrt(waveform.peak(from: t, to: t + secondsPerStep)))
                let half = max(0.5, level * middle)
                path.addRect(CGRect(x: x, y: middle - half, width: step - 0.6, height: half * 2))
                x += step
            }
            context.fill(path, with: .color(color.opacity(0.32)))
        }
    }
}

/// Keeps the previous image at its original span until the debounced render completes.
private struct TimelineSpectrogram: View {
    let audio: LyricsEditorAudio
    var range: ClosedRange<TimeInterval>
    var gain: Float
    var vocalsOnly: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var picture: (image: CGImage, range: ClosedRange<TimeInterval>)?

    private struct Request: Equatable {
        var range: ClosedRange<TimeInterval>
        var size: CGSize
        var gain: Float
        var scale: CGFloat
        var vocalsOnly: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let scale = span > 0 ? geo.size.width / span : 0
            ZStack(alignment: .topLeading) {
                Color.black
                if let picture {
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: CGFloat(picture.range.upperBound - picture.range.lowerBound) * scale, height: geo.size.height)
                        .offset(x: CGFloat(picture.range.lowerBound - range.lowerBound) * scale)
                }
            }
            .task(id: Request(range: range, size: geo.size, gain: gain, scale: displayScale, vocalsOnly: vocalsOnly)) {
                // Spans change on every frame of a drag: draw once they settle.
                try? await Task.sleep(for: .milliseconds(picture == nil ? 0 : 40))
                guard !Task.isCancelled else { return }
                let width = Int(geo.size.width * displayScale), height = Int(geo.size.height * displayScale)
                guard let image = await audio.spectrogram(of: range, width: width, height: height, gain: gain, vocalsOnly: vocalsOnly), !Task.isCancelled else { return }
                picture = (image, range)
            }
        }
        .clipped()
    }
}

/// The song's position on the timeline; a leaf, so the clock re-runs only this.
private struct TimelinePlayhead: View {
    let clock: LyricsEditorClock
    var range: ClosedRange<TimeInterval>
    var scale: CGFloat
    var color: Color

    var body: some View {
        let time = clock.time
        if range.contains(time) {
            Rectangle()
                .fill(color)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    Circle().fill(color).frame(width: 8, height: 8).offset(y: -2)
                }
                .offset(x: CGFloat(time - range.lowerBound) * scale - 1)
                .allowsHitTesting(false)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
