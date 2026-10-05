import Foundation
import Testing
@testable import LyricsCore

@Suite struct TTMLTests {
    static let sample = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
      <head><metadata>
        <ttm:agent type="person" xml:id="v1"/>
        <ttm:agent type="person" xml:id="v2"/>
        <amll:meta key="ncmMusicId" value="123"/>
      </metadata></head>
      <body dur="00:30.000">
        <div begin="00:01.000" end="00:10.000">
          <p begin="00:01.000" end="00:04.000" ttm:agent="v1" itunes:key="L1"><span begin="00:01.000" end="00:01.400">Hel</span><span begin="00:01.400" end="00:01.900">lo</span> <span begin="00:02.000" end="00:03.500">world</span><span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span><span ttm:role="x-bg"><span begin="00:03.000" end="00:03.400">(ooh</span> <span begin="00:03.400" end="00:03.900">yeah)</span></span></p>
          <p begin="00:05.000" end="00:08.000" ttm:agent="v2"><span begin="00:05.000" end="00:06.000">Second</span> <span begin="00:06.000" end="00:08.000">voice</span></p>
        </div>
        <div begin="00:20.000" end="00:25.000">
          <p begin="00:20.000" end="00:25.000">Plain line</p>
        </div>
      </body>
    </tt>
    """

    @Test func parsesSyllablesWordsAndRoles() throws {
        let doc = try TTMLParser.parse(Self.sample)
        #expect(doc.format == .ttml)
        #expect(doc.metadata["ncmMusicId"] == "123")
        #expect(doc.lines.count == 3)  // main (with background vocals) + second voice + plain
        let first = doc.lines[0]
        #expect(first.text == "Hello world")
        #expect(first.words.count == 2)
        #expect(first.words[0].syllables.map(\.text) == ["Hel", "lo "])
        #expect(first.words[0].start == 1.0)
        #expect(first.words[1].end == 3.5)
        #expect(first.translation == "你好世界")
        #expect(first.singer == .primary)
        #expect(first.isParagraphStart)
        let bg = try #require(first.background)
        #expect(bg.text == "(ooh yeah)")
        #expect(bg.start == 3.0)
        #expect(bg.end == 3.9)
        #expect(!bg.isAbove(first))
        #expect(first.start == 1.0)
        #expect(first.end == 4.0)
        #expect(first.primaryStart == 1.0)
        #expect(first.primaryEnd == 3.5)
        let second = doc.lines[1]
        #expect(second.singer == .secondary)
        #expect(!second.isParagraphStart)
        #expect(second.background == nil)
        #expect(second.primaryEnd == second.end)
        let plain = doc.lines[2]
        #expect(plain.text == "Plain line")
        #expect(plain.words.count == 1)
        #expect(plain.start == 20 && plain.end == 25)
        #expect(plain.isParagraphStart)
        #expect(doc.hasSyllables)
        #expect(doc.hasBackgroundVocals)
        #expect(doc.hasDuet)
    }

    @Test func backgroundVocalsKeepTheirOwnTranslationAndPosition() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="00:10.000" end="00:14.000"><span ttm:role="x-bg"><span begin="00:10.000" end="00:10.800">(Hey)</span><span ttm:role="x-translation">（嘿）</span></span><span begin="00:11.000" end="00:12.000">Main</span> <span begin="00:12.000" end="00:13.000">line</span><span ttm:role="x-translation">主句</span></p>
          <p begin="00:20.000" end="00:21.000"><span ttm:role="x-bg"><span begin="00:20.000" end="00:21.000">(only)</span></span></p>
        </div></body></tt>
        """
        let doc = try TTMLParser.parse(ttml)
        #expect(doc.lines.count == 2)
        let line = doc.lines[0]
        #expect(line.text == "Main line")
        #expect(line.translation == "主句")
        let bg = try #require(line.background)
        #expect(bg.translation == "（嘿）")
        #expect(bg.isAbove(line))           // starts before the first main syllable
        #expect(line.start == 10 && line.primaryStart == 11 && line.primaryEnd == 13)
        #expect(doc.lines[1].text == "(only)")
        #expect(doc.lines[1].background == nil)
    }

    @Test func timestampsAcceptEveryTTMLForm() {
        #expect(TTMLParser.parseTime("00:01.500") == 1.5)
        #expect(TTMLParser.parseTime("01:02:03.250") == 3723.25)
        #expect(TTMLParser.parseTime("12.5") == 12.5)
        #expect(TTMLParser.parseTime("1.5s") == 1.5)
        #expect(TTMLParser.parseTime("1500ms") == 1.5)
        #expect(TTMLParser.parseTime("") == nil)
    }

    @Test func zeroParagraphTimingFallsBackToTheSpans() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="00:43.886" end="00:45.754"><span begin="00:43.886" end="00:44.536">aa</span><span begin="00:44.536" end="00:45.754">bb</span></p>
          <p begin="00:00.000" end="00:00.000"><span begin="00:44.536" end="00:44.900">cc</span><span begin="00:44.900" end="00:45.754">dd</span></p>
          <p begin="01:00.394" end="01:03.000"><span begin="01:00.394" end="01:01.000">ee</span><span begin="01:01.000" end="01:03.000">ff</span><span ttm:role="x-bg" begin="01:00.053" end="01:02.394">(gg)<span ttm:role="x-translation">hh</span></span></p>
        </div></body></tt>
        """
        let doc = try TTMLParser.parse(ttml)
        #expect(doc.lines.count == 3)
        #expect(doc.lines[1].start == 44.536)
        #expect(doc.lines[1].end == 45.754)
        let line = doc.lines[2]
        let bg = try #require(line.background)
        #expect(bg.start == 60.053 && bg.end == 62.394)
        #expect(bg.translation == "hh")
        #expect(bg.isAbove(line))
        #expect(line.start == 60.053 && line.primaryStart == 60.394)
    }

    @Test func placeholderSyllableTimesAreInferred() throws {
        // From an AMLL DB entry: an untimed echo syllable and its `x-bg` span
        // were exported at 00:00.000, which made the line start at 0 and capture the intro.
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="02:46.948" end="02:50.900"><span begin="02:46.948" end="02:47.156">夜</span><span begin="02:47.156" end="02:47.437">明</span><span begin="02:50.307" end="02:50.900">雨</span><span ttm:role="x-bg" begin="00:00.000" end="02:52.019"><span begin="02:47.325" end="02:47.632">(夜</span><span begin="02:47.632" end="02:47.834">明 </span><span begin="00:00.000" end="00:00.000">雨</span> <span begin="02:51.079" end="02:51.555">雨</span> <span begin="02:51.555" end="02:52.019">雨)</span></span></p>
          <p begin="00:05.000" end="00:07.000"><span begin="00:05.000" end="00:06.000">a</span><span begin="00:00.000" end="00:00.000">b</span><span begin="00:00.000" end="00:00.000">c</span></p>
        </div></body></tt>
        """
        let doc = try TTMLParser.parse(ttml)
        let line = doc.lines[0]
        #expect(line.start == 166.948 && line.end == 172.019)
        let bg = try #require(line.background)
        #expect(bg.start == 167.325 && bg.end == 172.019)
        let echo = try #require(bg.words.flatMap(\.syllables).first { $0.text.hasPrefix("雨") })
        #expect(abs(echo.start - 170.603) < 1e-9 && echo.end == 171.079)
        let tail = doc.lines[1].words.flatMap(\.syllables)
        #expect(tail.map(\.start) == [5, 6, 7] && tail.map(\.end) == [6, 7, 8])
    }

    @Test func untimedTextSpansItsParagraph() throws {
        // From an AMLL DB entry, two lines: a shout written as plain text in
        // the `<p>` between word-timed lines must not be zero long (at its `begin`).
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="00:06.522" end="00:09.403"><span begin="00:06.522" end="00:09.403">君の心</span></p>
          <p begin="00:09.403" end="00:09.680">ねえ!<span ttm:role="x-translation" xml:lang="zh-CN">呐！</span></p>
          <p begin="00:09.680" end="00:12.000">two words<span ttm:role="x-bg"><span begin="00:10.000" end="00:11.000">(bg)</span></span></p>
        </div></body></tt>
        """
        let doc = try TTMLParser.parse(ttml)
        let shout = doc.lines[1]
        #expect(shout.start == 9.403 && shout.end == 9.68)
        #expect(shout.words.map(\.start) == [9.403] && shout.words.map(\.end) == [9.68])
        #expect(shout.translation == "呐！")
        #expect(!shout.hasSyllableTiming)
        // Timed background vocals do not time the main text: it still spans the `<p>`.
        let line = doc.lines[2]
        #expect(line.start == 9.68 && line.end == 12)
        #expect(line.primaryStart == 9.68 && line.primaryEnd == 12)
        #expect(line.background?.start == 10)
    }

    @Test func instrumentalGapsNeedMoreThanSevenSeconds() throws {
        let doc = try TTMLParser.parse(Self.sample)
        // Breaks longer than 7 s; a break after a line starts 0.1 s after its end.
        let gaps = doc.instrumentalGaps()
        #expect(gaps.count == 1)
        #expect(gaps[0].afterLine == 1)
        #expect(abs(gaps[0].start - 8.1) < 1e-9)
        #expect(gaps[0].end == 20.0)
        #expect(doc.instrumentalGaps(minimum: 12).isEmpty)
    }

    @Test func emphasisFactorGrowsWithHeldShortWords() {
        // factor = min(duration, 2) − 1 for duration > 1 s and fewer than 8 UTF-16 units.
        #expect(LyricWord(start: 0, end: 0.5, text: "夜").emphasisFactor == 0)
        #expect(LyricWord(start: 0, end: 1, text: "star").emphasisFactor == 0)
        #expect(abs(LyricWord(start: 0, end: 1.2, text: "star ").emphasisFactor - 0.2) < 1e-9)
        #expect(LyricWord(start: 0, end: 2.4, text: "夜").emphasisFactor == 1)
        #expect(LyricWord(start: 0, end: 1.5, text: "forever").emphasisFactor == 0.5)
        #expect(LyricWord(start: 0, end: 1.5, text: "darkness").emphasisFactor == 0)
        #expect(LyricWord(start: 0, end: 3, text: "a rather long phrase").emphasisFactor == 0)
    }
}
