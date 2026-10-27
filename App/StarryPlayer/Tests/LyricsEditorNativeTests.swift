import AppKit
import LyricsCore
import StarryCore
import Testing
@testable import StarryPlayer

@MainActor
struct LyricsEditorNativeTests {
    private func session() -> LyricsEditorSession {
        let track = Track(id: TrackRef(source: .local, id: "native-editor-test"), title: "Test", artists: [], duration: 30)
        let line = LyricsDraft.Line(syllables: [
            .init(text: "一", start: 1, end: 2),
            .init(text: "二", start: 2, end: 3),
            .init(text: "三", start: 3, end: 4)
        ])
        return LyricsEditorSession(track: track, draft: LyricsDraft(lines: [line]))
    }

    private func adjustment(_ session: LyricsEditorSession, part: LyricsTimelineAdjustment.Part) throws -> LyricsTimelineAdjustment {
        try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 1), part: part, range: 0...10, width: 1_000))
    }

    @Test(arguments: [false, true], [false, true])
    func selectingAnotherTimelineLineKeepsTheRangeAndZoom(manuallyPositioned: Bool, usingAccessibility: Bool) throws {
        let audio = LyricsEditorAudio()
        let track = Track(id: TrackRef(source: .local, id: "viewport-test"), title: "Viewport", artists: [], album: nil, duration: 30)
        let session = LyricsEditorSession(track: track, draft: LyricsDraft(lines: [
            .init(syllables: [.init(text: "一", start: 1, end: 2)]),
            .init(syllables: [.init(text: "二", start: 3, end: 4)]),
        ]))
        let original = session.draft
        let viewport = LyricsTimelineViewport()
        if manuallyPositioned { viewport.manual = 0...8 }
        let visible = try #require(viewport.range(caretLine: 0, in: session))
        let view = LyricsTimelineView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 180))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.disconnect(); window.close(); audio.stop() }
        view.configure(LyricsTimelineSurface(session: session, audio: audio, clock: LyricsEditorClock(), viewport: viewport,
                                             revision: session.revision, caret: session.caret, range: visible,
                                             theme: .darkBase, accent: .white, onSpectrogram: true, canPlay: false))
        view.layoutSubtreeIfNeeded()
        let target = try #require(view.accessibilityChildren()?.compactMap { $0 as? LyricsEditorActionElement }
            .first { $0.accessibilityLabel()?.hasPrefix("二，") == true })
        if usingAccessibility {
            #expect(target.accessibilityPerformPress())
            viewport.selectionChanged(from: 0, to: 1, in: session)
        } else {
            let rect = window.convertFromScreen(target.accessibilityFrame())
            let location = NSPoint(x: rect.midX, y: rect.midY)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.1,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            view.mouseDown(with: down)
            viewport.selectionChanged(from: 0, to: 1, in: session)
            #expect(viewport.range(caretLine: 1, in: session) == visible)
            view.mouseUp(with: up)
        }
        #expect(session.caret?.line == 1)
        #expect(viewport.interactionRange == nil)
        #expect(viewport.range(caretLine: 1, in: session) == visible)
        #expect(session.draft == original)
        session.selectLine(0)
        viewport.selectionChanged(from: 1, to: 0, in: session)
        #expect(viewport.manual == visible)
    }

    @Test func draggingSharedEdgesKeepsBothSyllablesJoinedAndAtLeastTwentyMillisecondsLong() throws {
        let session = session()
        let start = try adjustment(session, part: .start)
        let moved = start.preview(translation: 20)
        #expect(moved.syllables[0].end == 2.2)
        #expect(moved.syllables[1].start == 2.2)
        let limited = start.preview(translation: -1_000)
        #expect(limited.syllables[0].end == 1.02)
        #expect(limited.syllables[1].start == 1.02)
        let end = try adjustment(session, part: .end).preview(translation: 1_000)
        #expect(end.syllables[1].end == 3.98)
        #expect(end.syllables[2].start == 3.98)
        #expect(session.draft.lines[0].syllables[1].start == 2)
    }

    @Test func movingABlockPreservesItsDurationAndCannotGoBeforeZero() throws {
        let moved = try adjustment(session(), part: .body).preview(translation: -1_000)
        #expect(moved.syllables[1].start == 0)
        #expect(moved.syllables[1].end == 1)
        #expect(moved.syllables[0].end == 2)
        #expect(moved.syllables[2].start == 3)
    }

    @Test func onsetSnappingMatchesCommittedPreviewAndCanBeBypassed() throws {
        let session = session()
        let drag = try adjustment(session, part: .start)
        let hints = [2.23]
        let preview = drag.preview(translation: 20, onsets: hints)
        #expect(preview.syllables[1].start == 2.23)
        #expect(preview.syllables[0].end == 2.23)
        #expect(drag.preview(translation: 20).syllables[1].start == 2.2)
        #expect(drag.preview(translation: 0, onsets: hints) == drag.original)
        #expect(drag.commit(translation: 20, onsets: hints, in: session))
        #expect(session.draft.lines[0] == preview)
        session.undo()
        #expect(session.draft.lines[0] == drag.original)
    }

    @Test func onsetSnappingRespectsZoomDistanceAndMinimumDuration() throws {
        let session = session()
        let wide = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 1),
                                                        part: .start, range: 0...100, width: 1_000))
        #expect(wide.preview(translation: 2, onsets: [2.5]).syllables[1].start == 2.2)
        let narrow = try #require(LyricsTimelineAdjustment(session: session, position: .init(line: 0, syllable: 1),
                                                          part: .start, range: 0...1, width: 1_000))
        #expect(narrow.preview(translation: 200, onsets: [2.23]).syllables[1].start == 2.2)
        let end = try adjustment(session, part: .end).preview(translation: -98, onsets: [2.001])
        #expect(end.syllables[1].end == 2.02)
        #expect(end.syllables[2].start == 2.02)
        let body = try adjustment(session, part: .body)
        #expect(body.preview(translation: 20, onsets: [2.23]) == body.preview(translation: 20))
    }

    @Test func clickAndCancelledDragPreserveSavedStateAndRedo() throws {
        let session = session()
        session.edit { $0.lines[0].translation = "translation" }
        session.undo()
        session.markSaved()
        let revision = session.revision
        let drag = try adjustment(session, part: .body)
        _ = drag.preview(translation: 30) // Cancel: no commit.
        #expect(!drag.commit(translation: 0, in: session))
        #expect(!drag.commit(translation: .nan, in: session))
        #expect(session.revision == revision)
        #expect(!session.hasUnsavedChanges)
        #expect(session.canRedo)
        session.redo()
        #expect(session.draft.lines[0].translation == "translation")
    }

    @Test func staleDragCannotOverwriteTextEditsOrUndo() throws {
        let session = session()
        let drag = try adjustment(session, part: .start)
        session.edit { $0.lines[0].translation = "new" }
        #expect(!drag.commit(translation: 20, in: session))
        #expect(session.draft.lines[0].translation == "new")
        let second = try adjustment(session, part: .body)
        session.undo()
        #expect(!second.commit(translation: 20, in: session))
        #expect(session.draft.lines[0].syllables[1].start == 2)
    }

    @Test func wrappedLinesKeepEverySyllableHittableAndAnnotationsBelowTheChips() {
        let line = LyricsDraft.Line(syllables: (0..<40).map { .init(text: "字\($0) ") }, translation: "这是一段翻译", romanization: "romanization", isBackground: true)
        let layout = LyricsEditorLineLayout(input: .init(line: line, width: 460, paragraph: true, editing: false))
        #expect(layout.chips.count == line.syllables.count)
        #expect(layout.chips.last!.minY > layout.chips.first!.minY)
        for (index, rect) in layout.chips.enumerated() {
            #expect(layout.syllable(at: .init(x: rect.midX, y: rect.midY)) == index)
            #expect(rect.maxX < layout.play.minX)
            #expect(rect.maxY < layout.translation!.minY)
        }
        #expect(layout.translation!.maxY < layout.romanization!.minY)
        #expect(layout.romanization!.maxY < layout.height)
    }

    @Test func rubySitsInABandOverTheChipsThatTheRowLinesUpWith() {
        let plain = LyricsDraft.Line(syllables: [.init(text: "所"), .init(text: "詮")])
        var annotated = plain
        annotated.syllables[0].ruby = [.init(text: "しょ")]
        annotated.syllables[1].ruby = [.init(text: "せ"), .init(text: "ん")]
        let a = LyricsEditorLineLayout(input: .init(line: plain, width: 500, paragraph: false, editing: false))
        let b = LyricsEditorLineLayout(input: .init(line: annotated, width: 500, paragraph: false, editing: false))
        #expect(b.input.rubies == ["しょ", "せん"])
        #expect(a.rubyBand == 0 && b.rubyBand > 0)
        #expect(b.chips[0].height == a.chips[0].height + b.rubyBand)
        #expect(b.chips[0].width > a.chips[0].width)
        #expect(b.height == a.height + b.rubyBand)
        #expect(b.play.minY == a.play.minY + b.rubyBand)
        #expect(LyricsEditorLineLayout(input: .init(line: annotated, width: 500, paragraph: false, editing: true)).rubyBand == 0)
    }

    @Test func rubyIsClearedAndRestoredByUndo() {
        let session = session()
        let at = LyricsDraft.Position(line: 0, syllable: 1)
        session.edit { $0.setRuby("に", at: at) }
        #expect(session.draft[at].ruby == [.init(text: "に")])
        session.clearRuby([at])
        #expect(session.draft[at].ruby == nil)
        session.undo()
        #expect(session.draft[at].ruby == [.init(text: "に")])
    }

    @Test func leavingAnEditorDoesNotCancelAnotherRowsEditingSession() {
        let row = LyricsEditorRowView()
        let line = session().draft.lines[0]
        let editing = LyricsEditorLineLayout(input: .init(line: line, width: 500, paragraph: false, editing: true))
        row.configure(line: line, index: 0, layout: editing, theme: .darkBase, caret: 0, pulse: 0, lastTapped: nil)
        var cancellations = 0
        row.cancel = { cancellations += 1 }
        let plain = LyricsEditorLineLayout(input: .init(line: line, width: 500, paragraph: false, editing: false))
        row.configure(line: line, index: 0, layout: plain, theme: .darkBase, caret: 0, pulse: 0, lastTapped: nil)
        #expect(cancellations == 0)
        #expect(!row.subviews.contains { $0 is NSTextField })
    }

    @Test func nativeFrameObserversReceiveScrubbingAndCanDetach() {
        let clock = LyricsEditorClock()
        var times: [Double] = []
        let token = clock.observeFrames { times.append(clock.time) }
        clock.sample(time: 1, playing: true, ranges: [0...3])
        clock.scrub(to: 2, duration: 3, ranges: [0...3])
        clock.cancelScrubbing()
        #expect(times == [1, 2, 1])
        clock.removeFrameObserver(token)
        clock.sample(time: 3, playing: false, ranges: [0...3])
        #expect(times == [1, 2, 1])
    }

    @Test func nativeTextEditingKeepsFocusAndCommitsTheLatestFieldEditorValue() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = LyricsEditorRowView()
        window.contentView = row
        let line = session().draft.lines[0]
        let layout = LyricsEditorLineLayout(input: .init(line: line, width: 500, paragraph: false, editing: true))
        row.configure(line: line, index: 0, layout: layout, theme: .darkBase, caret: 0, pulse: 0, lastTapped: nil)
        var commits = 0
        var saved: String?
        row.commit = { saved = $0; commits += 1 }
        row.focusEditor()
        row.focusEditor()
        let field = try #require(row.subviews.first { $0 is NSTextField } as? NSTextField)
        #expect(field.currentEditor() != nil)
        #expect(commits == 0)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "中文|edited|歌词"
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(commits == 1)
        #expect(saved == "中文|edited|歌词")
    }

    @Test func aReusedRowCannotSelectThroughAnOldAccessibilityElement() throws {
        let row = LyricsEditorRowView()
        let line = session().draft.lines[0]
        let layout = LyricsEditorLineLayout(input: .init(line: line, width: 500, paragraph: false, editing: false))
        row.configure(line: line, index: 0, layout: layout, theme: .darkBase, caret: nil, pulse: 0, lastTapped: nil)
        let old = try #require(row.accessibilityChildren()?.first as? LyricsEditorActionElement)
        let replacement = LyricsDraft.Line(syllables: [.init(text: "另一行")])
        let newLayout = LyricsEditorLineLayout(input: .init(line: replacement, width: 500, paragraph: false, editing: false))
        row.configure(line: replacement, index: 1, layout: newLayout, theme: .darkBase, caret: nil, pulse: 0, lastTapped: nil)
        var selections = 0
        row.select = { _ in selections += 1 }
        _ = old.accessibilityPerformPress()
        #expect(selections == 0)
        let current = try #require(row.accessibilityChildren()?.first as? LyricsEditorActionElement)
        _ = current.accessibilityPerformPress()
        #expect(selections == 1)
    }
}
