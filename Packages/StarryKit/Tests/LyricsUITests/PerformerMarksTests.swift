import AppKit
import Foundation
import LyricsCore
import QuartzCore
import Testing
@testable import LyricsUI

@Suite(.serialized) @MainActor struct PerformerMarksTests {
    static let palette = LyricColor.performerPalette
    private let font = NSFont.systemFont(ofSize: 48, weight: .bold)

    @MainActor private final class Host {
        let window: NSWindow
        let view: LyricsView

        init(document: LyricsDocument, specs: LyricsSpecs = .windowed) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            view = LyricsView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
            window.contentView = view
            view.specs = specs
            view.document = document
            view.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }

        func line(_ index: Int) -> LineLayer? {
            func find(_ layer: CALayer) -> LineLayer? {
                if let line = layer as? LineLayer { return line.lineIndex == index ? line : nil }
                for sublayer in layer.sublayers ?? [] { if let found = find(sublayer) { return found } }
                return nil
            }
            return view.layer.flatMap(find)
        }

        func setTime(_ t: TimeInterval) {
            view.update(time: t, rate: 0)
            CATransaction.flush()
        }
    }

    static func document(colors: Bool = true) -> LyricsDocument {
        func words(_ text: String, _ start: Double, _ end: Double, agents: [String] = []) -> [LyricWord] {
            let characters = Array(text)
            let per = (end - start) / Double(characters.count)
            return characters.enumerated().map { j, c in
                let s = start + Double(j) * per
                return LyricWord(start: s, end: s + per, text: String(c), syllables: [LyricSyllable(start: s, end: s + per, text: String(c), agentIDs: agents)])
            }
        }
        let lines = [
            LyricLine(id: 0, start: 0, end: 2, words: words("城市的灯熄灭", 0, 2), agentIDs: ["v1"]),
            LyricLine(id: 1, start: 2, end: 4, words: words("你说别怕", 2, 3) + words("我在这边", 3, 4, agents: ["v2"]), agentIDs: ["v1"]),
            LyricLine(id: 2, start: 4, end: 6, words: words("一起唱", 4, 6), agentIDs: ["v1", "v2"]),
        ]
        return LyricsDocument(format: .ttml, lines: lines, agents: [
            .init(id: "v1", names: [.init("Luna")], color: colors ? palette[0] : nil),
            .init(id: "v2", names: [.init("Kai")], color: colors ? palette[1] : nil),
        ])
    }

    private func characters(_ text: String) -> LyricLine {
        LyricLine(id: 0, start: 0, end: 4, words: text.map { LyricWord(start: 0, end: 1, text: String($0)) })
    }

    private func rubyDocument(prefix: String = "", handoff: Bool = false, singer: LyricSinger = .primary) -> LyricsDocument {
        var document = Self.document()
        let pieces = Array(prefix).map(String.init) + ["ダンス", "ダンス"]
        let words = pieces.enumerated().map { index, text in
            let start = Double(index)
            let end = start + 1
            let ruby = index >= pieces.count - 2 ? LyricRuby.spread(["dance"], start: start, end: end) : []
            let ids = handoff && index == pieces.count - 1 ? ["v2"] : []
            let syllable = LyricSyllable(start: start, end: end, text: text, ruby: ruby, agentIDs: ids)
            return LyricWord(start: start, end: end, text: text, syllables: [syllable])
        }
        let end = Double(pieces.count)
        document.lines = [
            LyricLine(id: 0, start: 0, end: end, words: words, singer: singer, agentIDs: ["v1"]),
            LyricLine(id: 1, start: end, end: end + 1, words: [LyricWord(start: end, end: end + 1, text: "続き")], agentIDs: ["v2"]),
        ]
        return document
    }

    private func originalNameFrame(_ name: CALayer, bar: PerformerMarks.Bar, font: NSFont) -> CGRect {
        CGRect(x: name.frame.minX, y: bar.frame.minY - font.pointSize * 0.16 - name.bounds.height,
               width: name.bounds.width, height: name.bounds.height)
    }

    @Test(arguments: [LyricsSpecs.Preset.windowed, .fullscreen], [LyricSinger.primary, .secondary, .duet])
    func namesClearRubyAcrossPresetsAndPositions(preset: LyricsSpecs.Preset, singer: LyricSinger) throws {
        let specs = LyricsSpecs.preset(preset)
        let host = Host(document: rubyDocument(singer: singer), specs: specs)
        host.setTime(0.5)
        let voice = try #require(host.line(0)).main
        let ruby = try #require(voice.layout.furigana).text.rows[0]
        let name = try #require(voice.performerNameLayers.first)
        let bar = try #require(PerformerMarks.bars(text: voice.textLayout, runs: voice.layout.performers, specs: specs).first)
        let original = originalNameFrame(name, bar: bar, font: voice.textLayout.font)
        #expect(name.frame.minY < original.minY)
        #expect(name.frame.maxY < ruby.origin.y)
    }

    @Test func eachNameChecksItsOwnRubyAndTogglingRubyRestoresItsPosition() throws {
        let host = Host(document: rubyDocument(prefix: "ほらほら", handoff: true))
        host.setTime(0.5)
        let voice = try #require(host.line(0)).main
        let bars = PerformerMarks.bars(text: voice.textLayout, runs: voice.layout.performers, specs: .windowed)
        let names = voice.performerNameLayers
        let frames = names.map(\.frame)
        #expect(names.count == 2)
        #expect(names[0].frame == originalNameFrame(names[0], bar: bars[0], font: voice.textLayout.font))
        #expect(names[1].frame.minY < originalNameFrame(names[1], bar: bars[1], font: voice.textLayout.font).minY)

        var specs = LyricsSpecs.windowed
        specs.showRuby = false
        host.view.specs = specs
        CATransaction.flush()
        let plainBars = PerformerMarks.bars(text: voice.textLayout, runs: voice.layout.performers, specs: specs)
        for (name, bar) in zip(voice.performerNameLayers, plainBars) {
            #expect(name.frame == originalNameFrame(name, bar: bar, font: voice.textLayout.font))
        }

        specs.showRuby = true
        host.view.specs = specs
        CATransaction.flush()
        #expect(voice.performerNameLayers.map(\.frame) == frames)
    }

    @Test func rubyOnLaterRowsLeavesTheFirstRowNameInPlace() throws {
        let host = Host(document: rubyDocument(prefix: String(repeating: "ほ", count: 11)))
        host.setTime(0.5)
        let voice = try #require(host.line(0)).main
        let ruby = try #require(voice.layout.furigana?.text.rows.first)
        #expect(ruby.origin.y > voice.textLayout.rows[0].origin.y)
        let name = try #require(voice.performerNameLayers.first)
        let bar = try #require(PerformerMarks.bars(text: voice.textLayout, runs: voice.layout.performers, specs: .windowed).first)
        #expect(name.frame == originalNameFrame(name, bar: bar, font: voice.textLayout.font))
    }

    @Test func emphasisElsewhereInTheLineDoesNotWidenTheNamesGap() throws {
        var document = rubyDocument()
        document.lines[0].words.append(LyricWord(start: 2, end: 4, text: "長音"))
        document.lines[0].end = 4
        document.lines[1] = LyricLine(id: 1, start: 4, end: 5, words: [LyricWord(start: 4, end: 5, text: "続き")], agentIDs: ["v2"])
        let enabled = Host(document: document)
        var specs = LyricsSpecs.windowed
        specs.emphasisEnabled = false
        let disabled = Host(document: document, specs: specs)
        let withEmphasis = try #require(enabled.line(0)?.main.performerNameLayers.first)
        let withoutEmphasis = try #require(disabled.line(0)?.main.performerNameLayers.first)
        #expect(withEmphasis.frame == withoutEmphasis.frame)
    }

    @Test(arguments: [CGFloat(0.6), 1, 1.8])
    func sharedRubyCanLiftAndGrowWithoutReachingTheName(scale: CGFloat) throws {
        var document = rubyDocument()
        document.lines.removeLast()
        for index in document.lines[0].words.indices {
            let start = Double(index) * 2
            let end = start + 2
            let syllables = Array("ダンス").enumerated().map { part, character in
                LyricSyllable(start: start + Double(part) * 2 / 3, end: start + Double(part + 1) * 2 / 3,
                              text: String(character), groupRuby: part == 0 ? LyricRuby.spread(["dance"], start: start, end: end) : [],
                              joinsRubyGroup: part > 0)
            }
            document.lines[0].words[index] = LyricWord(start: start, end: end, text: "ダンス", syllables: syllables)
        }
        document.lines[0].end = 4
        document.lines[0].agentIDs = ["v1", "v2"]
        var specs = LyricsSpecs.windowed
        specs.scale = scale
        specs.emphasizingScaleRange = 1...1.4
        let host = Host(document: document, specs: specs)
        host.setTime(0.8)
        let voice = try #require(host.line(0)).main
        let name = try #require(voice.performerNameLayers.first)
        let annotation = try #require(voice.rows.first { $0.followsProgress })
        let ruby = try #require(voice.layout.furigana)
        let ink = try #require(PerformerMarks.rubyBounds(text: ruby.text).first).frame
        let rubyFrame = annotation.convert(ink.offsetBy(dx: 0, dy: -ruby.text.rows[0].origin.y), to: voice)
        #expect(name.frame.maxY + 1 < rubyFrame.minY)
    }

    @Test(arguments: [NSTextAlignment.right, .center])
    func aGapEndingARowLeavesItsTextInPlace(alignment: NSTextAlignment) {
        let line = characters("你说我在")
        let width = font.pointSize * 2.6
        let plain = LineTextLayout.layout(line: line, font: font, width: width, leading: 52, alignment: alignment, perSyllable: true)
        let spaced = LineTextLayout.layout(line: line, font: font, width: width, leading: 52, alignment: alignment, perSyllable: true, gaps: [1: 20])
        #expect(spaced.rows.map { $0.fragments.map(\.syllable) } == [[0, 1], [2, 3]])
        #expect(abs(spaced.rows[0].fragments[0].inkMinX - plain.rows[0].fragments[0].inkMinX) < 0.5)
        #expect(abs(spaced.rows[0].fragments[1].inkMaxX - plain.rows[0].fragments[1].inkMaxX) < 0.5)
    }

    @Test(arguments: [NSTextAlignment.left, .center, .right], [2, 3])
    func wrappedRowsMarkHandoffsWithoutRepeatingBars(alignment: NSTextAlignment, handoff: Int) {
        let line = characters("你说我在这里")
        let runs = [LyricPerformerRun(syllables: 0..<handoff, colors: [Self.palette[0]]),
                    LyricPerformerRun(syllables: handoff..<6, colors: [Self.palette[1]])]
        let text = LineTextLayout.layout(line: line, font: font, width: font.pointSize * 2.6, leading: 52,
                                         alignment: alignment, perSyllable: true)
        #expect(text.rows.map { $0.fragments.map(\.syllable) } == [[0, 1], [2, 3], [4, 5]])
        let bars = PerformerMarks.bars(text: text, runs: runs, specs: .windowed)
        #expect(bars.map(\.row) == [0, 1])
        #expect(bars.map(\.colors) == [[Self.palette[0]], [Self.palette[1]]])
    }

    @Test func everyRunStartsWithItsPerformersBarAndTheSelectedLineNamesThem() throws {
        let host = Host(document: Self.document())
        host.setTime(2.5)
        let line = try #require(host.line(1))
        let fragments = line.main.textLayout.rows[0].fragments
        let bars = line.main.performerBarLayers
        #expect(bars.count == 2)
        #expect(bars.map(\.backgroundColor) == [Self.palette[0], Self.palette[1]].map { PerformerMarks.displayColor($0, tint: .white) as CGColor? })
        #expect(bars[0].frame.maxX <= fragments[0].inkMinX)
        #expect(bars[1].frame.minX >= fragments[3].inkMaxX && bars[1].frame.maxX <= fragments[4].inkMinX)

        let names = line.main.performerNameLayers
        #expect(names.count == 2)
        #expect(line.main.performerNamesOpacity == 1)
        #expect(names[0].opacity > names[1].opacity)
        #expect(names.allSatisfy { $0.frame.maxY < bars[0].frame.minY })
        let past = try #require(host.line(0)).main
        #expect(past.performerMarksOpacity > 0 && past.performerMarksOpacity < line.main.performerMarksOpacity)
        #expect(past.performerNamesOpacity == 0)
        host.setTime(3.5)
        #expect(names[0].opacity < names[1].opacity)
    }

    @Test func wrappedCoSingingShowsOneSplitBarAndName() throws {
        var document = Self.document()
        document.lines[2].words = [LyricWord(start: 4, end: 6, text: String(repeating: "ありえることよりありえないこと", count: 3))]
        let host = Host(document: document)
        host.setTime(4.5)
        let voice = try #require(host.line(2)).main
        #expect(voice.textLayout.rows.count > 1)
        let bars = voice.performerBarLayers
        #expect(bars.count == 2)
        #expect(bars[0].frame.minX == bars[1].frame.minX)
        #expect(bars[0].frame.maxY < bars[1].frame.minY)
        #expect(voice.performerNameLayers.count == 1)
    }

    @Test func linesStayUnmarkedWithoutColorsOrWithMarksSwitchedOff() throws {
        var off = LyricsSpecs.windowed
        off.performerMarksEnabled = false
        for host in [Host(document: Self.document(colors: false)), Host(document: Self.document(), specs: off)] {
            host.setTime(2.5)
            let line = try #require(host.line(1))
            #expect(line.main.performerBarLayers.isEmpty)
            #expect(line.main.performerNameLayers.isEmpty)
            let fragments = line.main.textLayout.rows[0].fragments
            let plain = LineTextLayout.layout(line: line.main.line, font: line.main.textLayout.font, width: 2000, leading: nil, alignment: .left, perSyllable: true).rows[0].fragments
            #expect(abs((fragments[4].inkMinX - fragments[3].inkMaxX) - (plain[4].inkMinX - plain[3].inkMaxX)) < 0.5)
        }
    }

    @Test func namesCanBeSwitchedOffAlone() throws {
        var specs = LyricsSpecs.windowed
        specs.performerNamesEnabled = false
        let host = Host(document: Self.document(), specs: specs)
        host.setTime(2.5)
        let line = try #require(host.line(1))
        #expect(line.main.performerBarLayers.count == 2)
        #expect(line.main.performerNameLayers.isEmpty)
    }
}
