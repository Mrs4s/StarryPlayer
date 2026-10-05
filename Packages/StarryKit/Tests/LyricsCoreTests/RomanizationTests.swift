import Foundation
import Testing
@testable import LyricsCore

@Suite struct RomanizationTests {
    private func words(_ pieces: [String], start: Double = 0) -> [LyricWord] {
        var t = start
        return pieces.map { text in
            let syllables = Array(text).map { c -> LyricSyllable in
                defer { t += 1 }
                return LyricSyllable(start: t, end: t + 1, text: String(c))
            }
            return LyricWord(start: syllables[0].start, end: syllables[syllables.count - 1].end, text: text, syllables: syllables)
        }
    }

    private func romaji(_ text: String, _ start: Double, _ end: Double) -> LyricWord {
        LyricWord(start: start, end: end, text: text)
    }

    private var line: [LyricWord] { words(["抜け", "てる", "とこ", "さえ", "彼女", "の"]) }

    @Test func eachRomanizedWordTakesTheWordsItOverlaps() {
        let groups = LyricRomanizationGrouping.groups(words: line, romanization: [
            romaji("nuketeru ", 0, 4), romaji("toko ", 4, 6), romaji("sae ", 6, 8), romaji("kanojo ", 8, 10), romaji("no", 10, 11),
        ])
        #expect(groups.map(\.words) == [0...1, 2...2, 3...3, 4...4, 5...5])
        #expect(groups.map(\.romanization) == [[0], [1], [2], [3], [4]])
    }

    @Test func aWordRunningIntoTheNextClaimsItAndTheFollowerJoins() {
        let groups = LyricRomanizationGrouping.groups(words: line, romanization: [
            romaji("nuketeru ", 0, 4), romaji("toko ", 4, 6.2), romaji("sae ", 6.2, 8), romaji("kanojo ", 8, 10.3), romaji("no", 10.3, 11),
        ])
        #expect(groups.map(\.words) == [0...1, 2...3, 4...5])
        #expect(groups.map(\.romanization) == [[0], [1, 2], [3, 4]])
    }

    @Test func touchingRangesDoNotOverlapAndStrayWordsAreLeftOut() {
        let groups = LyricRomanizationGrouping.groups(words: words(["完璧", "で"]), romanization: [
            romaji("kanpeki ", 0, 2), romaji("de", 2, 3), romaji("extra", 5, 6),
        ])
        #expect(groups.map(\.words) == [0...0, 1...1])
        #expect(groups.map(\.romanization) == [[0], [1]])
    }

    @Test func emptyRangesNeverMatch() {
        let groups = LyricRomanizationGrouping.groups(words: words(["君"]), romanization: [romaji("kimi", 0.5, 0.5)])
        #expect(groups.isEmpty)
    }

    @Test func interleavedGroupsMerge() {
        let groups = LyricRomanizationGrouping.groups(words: words(["あ", "い", "う"]), romanization: [
            romaji("i", 1, 2), romaji("a u", 0, 3),
        ])
        #expect(groups.map(\.words) == [0...2])
        #expect(groups[0].romanization == [0, 1])
    }

    @Test func timedRomanizationBodiesKeepTheirWords() throws {
        var doc = try QRCParser.parse(KaraokeParserTests.qrc)
        let roma = """
        <QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent="[0,6780]以(0,521)下(521,521)音(1042,521)译(1563,521)
        [20347,2439]wai (20347,540)ho (20887,500)yiu (21387,460)lo (21847,290)lui (22137,649)
        "/></LyricInfo></QrcInfos>
        """
        LyricsParsing.attach(translation: nil, romanization: roma, to: &doc)
        let words = try #require(doc.lines[2].romanizationWords)
        #expect(words.map(\.text) == ["wai ", "ho ", "yiu ", "lo ", "lui"])
        #expect(words[1].start == 20.887)
        #expect(doc.lines[2].romanization == "wai ho yiu lo lui")

        var lrc = try QRCParser.parse(KaraokeParserTests.qrc)
        LyricsParsing.attach(translation: nil, romanization: "[00:20.35]wai ho yiu lo lui", to: &lrc)
        #expect(lrc.lines[2].romanization == "wai ho yiu lo lui")
        #expect(lrc.lines[2].romanizationWords?.map(\.start) == lrc.lines[2].syllables.map(\.start))
    }

    private func timedWords(_ text: String) -> [LyricWord] {
        LyricWordGrouping.words(from: Array(text).enumerated().map { LyricSyllable(start: Double($0.offset), end: Double($0.offset + 1), text: String($0.element)) })
    }

    @Test func moraSpacedRomanizationJoinsPerWordWithKanjiTiming() throws {
        let words = timedWords("啓蒙して洗脳して")
        let aligned = try #require(LyricRomanizationAligner.align("ke i mo u shi te se n no u shi te", to: words))
        #expect(aligned.map(\.text) == ["keimou ", "shi ", "te ", "sennou ", "shi ", "te"])
        #expect(aligned.map(\.start) == words.map(\.start))
        #expect(aligned[0].syllables.map(\.text) == ["kei", "mou "])
        #expect(aligned[0].syllables.map(\.start) == [0, 1])
    }

    @Test func wordSpacedRomanizationKeepsItsWords() throws {
        let words = timedWords("君は水で私は魚")
        let aligned = try #require(LyricRomanizationAligner.align("Kimi wa mizu de watashi wa sakana", to: words))
        #expect(aligned.map(\.text) == ["Kimi ", "wa ", "mizu ", "de ", "watashi ", "wa ", "sakana"])
        #expect(aligned.map(\.start) == words.map(\.start))
    }

    @Test func kanjiOnlyLinesAreReadAsJapaneseWhenThatMatchesBetter() throws {
        let aligned = try #require(LyricRomanizationAligner.align("mo u so u", to: timedWords("妄想")))
        #expect(aligned.map(\.text) == ["mousou"])
        #expect(aligned[0].syllables.map(\.start) == [0, 1])
    }

    @Test func chineseCharactersPairWithTokens() throws {
        let aligned = try #require(LyricRomanizationAligner.align("wai ho yiu lo lui", to: timedWords("为何要落泪")))
        #expect(aligned.map(\.text) == ["wai ", "ho ", "yiu ", "lo ", "lui"])
        #expect(aligned.map(\.start) == [0, 1, 2, 3, 4])
    }

    @Test func unrelatedTextStaysUntimed() {
        #expect(LyricRomanizationAligner.align("completely different words here", to: timedWords("君は水")) == nil)
    }

    @Test func amllRomanLinesAreTimedWhenParsed() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="1.0" end="5.0"><span begin="1.0" end="1.5">じゃん</span><span begin="1.5" end="2.0">じゃ</span><span begin="2.0" end="3.0">かの</span><span begin="3.0" end="5.0">じゃん</span><span ttm:role="x-roman">ja n ja ka no ja n </span></p>
          <p begin="6.0" end="7.0"><span begin="6.0" end="7.0">Plain</span><span ttm:role="x-roman">nothing alike at all</span></p>
        </div></body></tt>
        """
        let doc = try TTMLParser.parse(ttml)
        let words = try #require(doc.lines[0].romanizationWords)
        #expect(words.count < 7)
        #expect(words.map(\.text).joined().filter { !$0.isWhitespace } == "janjakanojan")
        #expect(words.first?.start == 1.0)
        #expect(words.last?.end == 5.0)
        #expect(doc.lines[0].romanization == "ja n ja ka no ja n")
        #expect(doc.lines[1].romanizationWords == nil)
    }

    @Test func krcRomanizationTakesTheSyllableTimes() throws {
        let doc = try KRCParser.parse(KaraokeParserTests.krc)
        let words = try #require(doc.lines[1].romanizationWords)
        #expect(words.map(\.text) == ["yu me ", "na ", "ra ", "ba"])
        #expect(words[0].start == doc.lines[1].syllables[0].start)
        #expect(words[3].end == doc.lines[1].syllables[3].end)
    }

    @Test func ttmlTransliterationsAttachByLineKey() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
          <head><metadata><ttm:agent type="person" xml:id="v1"/>
            <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
              <translations><translation type="replacement" xml:lang="en"><text for="L1">Even the gaps</text></translation></translations>
              <transliterations><transliteration xml:lang="ja-Latn">
                <text for="L1"><span begin="1.0" end="1.5">nu</span><span begin="1.5" end="2.0">ke</span> <span begin="2.0" end="2.4">to</span><span begin="2.4" end="2.8">ko</span><span ttm:role="x-bg"><span begin="3.0" end="3.5">a</span></span></text>
              </transliteration></transliterations>
            </iTunesMetadata>
          </metadata></head>
          <body><div>
            <p begin="1.0" end="3.5" itunes:key="L1" ttm:agent="v1"><span begin="1.0" end="1.5">抜</span><span begin="1.5" end="2.0">け</span><span begin="2.0" end="2.4">と</span><span begin="2.4" end="2.8">こ</span><span ttm:role="x-bg"><span begin="3.0" end="3.5">(あ)</span></span></p>
            <p begin="4.0" end="5.0" itunes:key="L2"><span begin="4.0" end="5.0">君</span></p>
          </div></body>
        </tt>
        """
        let doc = try TTMLParser.parse(ttml)
        let words = try #require(doc.lines[0].romanizationWords)
        #expect(words.map(\.text) == ["nuke ", "toko"])
        #expect(words[1].syllables.map(\.start) == [2.0, 2.4])
        #expect(doc.lines[0].romanization == "nuke toko")
        #expect(doc.lines[0].background?.romanizationWords?.map(\.text) == ["a"])
        #expect(doc.lines[1].romanizationWords == nil)
    }
}
