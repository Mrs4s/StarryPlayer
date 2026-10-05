import Foundation
import Testing
@testable import LyricsCore

@Suite struct KaraokeParserTests {
    static let qrc = """
    <?xml version="1.0" encoding="utf-8"?>
    <QrcInfos>
    <QrcHeadInfo SaveTime="1432882846" Version="100"/>
    <LyricInfo LyricCount="1">
    <Lyric_1 LyricType="1" LyricContent="[ti:明知故犯]
    [ar:许美静]
    [offset:0]
    [0,6780]明(0,678)知(678,678)故(1356,678)犯(2034,678) (2712,678)-(3390,678) (4068,678)许(4746,678)美(5424,678)静(6102,678)
    [6780,6780]词(6780,1695)：(8475,1695)林(10170,1695)夕(11865,1695)
    [20347,2439]为(20347,540)何(20887,500)要(21387,460)落(21847,290)泪(22137,649)
    [23426,3289]&quot;落(23426,210)泪(23636,260)&quot;(23896,0)
    "/>
    </LyricInfo>
    </QrcInfos>
    """

    @Test func qrcUnwrapsXMLAndReadsTimestampsAfterText() throws {
        let doc = try QRCParser.parse(Self.qrc)
        #expect(doc.metadata["ti"] == "明知故犯")
        #expect(doc.lines.count == 4)
        let line = doc.lines[2]
        #expect(line.text == "为何要落泪")
        #expect(line.start == 20.347)
        #expect(abs(line.end - 22.786) < 1e-9)
        #expect(line.syllables.map(\.text) == ["为", "何", "要", "落", "泪"])
        #expect(line.syllables[1].start == 20.887)
        #expect(doc.lines[3].text == "\"落泪\"")
    }

    @Test func qrcRomanizationMergesAsLineText() throws {
        let roma = """
        <QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent="[0,6780]以(0,521)下(521,521)音(1042,521)译(1563,521)
        [6780,6780] (11865,1695)
        [20347,2439]wai (20347,540)ho (20887,500)yiu (21387,460)lo (21847,290)lui (22137,649)
        "/></LyricInfo></QrcInfos>
        """
        var doc = try QRCParser.parse(Self.qrc)
        LyricsParsing.attach(translation: "[00:20.35]为何要落泪\n[00:23.43]//", romanization: roma, to: &doc)
        #expect(doc.lines[2].romanization == "wai ho yiu lo lui")
        #expect(doc.lines[2].translation == "为何要落泪")
        // CJK notes are not romanization; `//` marks an untranslated line.
        #expect(doc.lines[0].romanization == nil)
        #expect(doc.lines[3].translation == nil)
    }

    static let krc = "\u{FEFF}[id:$00000000]\r\n[ar:米津玄師]\r\n[ti:Lemon]\r\n[offset:0]\r\n"
        + "[language:eyJjb250ZW50IjogW3sibGFuZ3VhZ2UiOiAwLCAidHlwZSI6IDEsICJseXJpY0NvbnRlbnQiOiBbWyIgIl0sIFsi5aaC5p6c6L+Z5piv5qKmIl1dfSwgeyJsYW5ndWFnZSI6IDAsICJ0eXBlIjogMCwgImx5cmljQ29udGVudCI6IFtbInlvIG5lICIsICJ0c3UiXSwgWyJ5dSBtZSAiLCAibmEgIiwgInJhICIsICJiYSAiXV19XSwgInZlcnNpb24iOiAxfQ==]\r\n"
        + "[0,366]<0,61,0>米<61,61,0>津\r\n"
        + "[1134,1246]<0,328,0>夢<328,272,0>な<600,168,0>ら<768,312,0>ば\r\n"

    @Test func krcUsesLineRelativeOffsetsAndLanguageTag() throws {
        let doc = try KRCParser.parse(Self.krc)
        #expect(doc.metadata["ti"] == "Lemon")
        #expect(doc.lines.count == 2)
        let line = doc.lines[1]
        #expect(line.text == "夢ならば")
        #expect(line.start == 1.134)
        #expect(line.syllables[1].start == 1.462)
        #expect(abs(line.syllables[3].end - 2.214) < 1e-9)
        #expect(line.translation == "如果这是梦")
        #expect(line.romanization == "yu me na ra ba")
        #expect(doc.lines[0].translation == nil)
    }

    @Test func detectsFormats() {
        #expect(LyricsFormatDetector.detect(Self.qrc) == .qrc)
        #expect(LyricsFormatDetector.detect("[20347,2439]为(20347,540)何(20887,500)") == .qrc)
        #expect(LyricsFormatDetector.detect(Self.krc) == .krc)
        #expect(LyricsFormatDetector.detect("{\"t\":0}\n[1000,2000](1000,500,0)你(1500,500,0)好") == .yrc)
        #expect(LyricsFormatDetector.detect("[00:01.00]hello") == .lrc)
        #expect(LyricsFormatDetector.detect("<tt xmlns=\"http://www.w3.org/ns/ttml\"><body/></tt>") == .ttml)
    }

    @Test func textMayContainBrackets() throws {
        let doc = try QRCParser.parse("[0,2000](Live)(0,500) ok(500,500)")
        #expect(doc.lines[0].text == "(Live) ok")
        let krc = try KRCParser.parse("[0,1000]<0,500,0><3<500,500,0> you")
        #expect(krc.lines[0].text == "<3 you")
    }

    @Test func creditStripperRemovesHeadAndTailMetadata() throws {
        let doc = try QRCParser.parse(Self.qrc)
        let stripped = LyricsCreditStripper.strip(doc, title: "明知故犯", artists: ["许美静"])
        #expect(stripped.lines.map(\.text) == ["为何要落泪", "\"落泪\""])
        #expect(stripped.lines.map(\.id) == [0, 1])

        let lrc = try LRCParser.parse("""
        [00:00.00]作词 : 周杰伦
        [00:01.00]作曲 : 周杰伦
        [00:02.00]Producer: 某人
        [00:10.00]他说：你好
        [00:12.00]故事的小黄花
        [03:50.00]未经著作权人许可 不得翻唱翻录或使用
        """)
        let cleaned = LyricsCreditStripper.strip(lrc, title: "晴天", artists: ["周杰伦"])
        #expect(cleaned.lines.map(\.text) == ["他说：你好", "故事的小黄花"])
    }

    @Test func creditStripperRemovesSplitTitleAndArtistAtTheTopOnly() throws {
        let yrc = try YRCParser.parse("""
        [0,3000](0,3000,0)明知故犯
        [11650,2000](11650,2000,0)许美静
        [20400,2400](20400,500,0)为(20900,500,0)何(21400,500,0)要(21900,500,0)落(22400,400,0)泪
        [250000,3000](250000,3000,0)明知故犯
        """)
        let stripped = LyricsCreditStripper.strip(yrc, title: "明知故犯", artists: ["许美静"])
        #expect(stripped.lines.map(\.text) == ["为何要落泪", "明知故犯"])
    }

    @Test func creditStripperKeepsDocumentsThatAreAllMetadata() throws {
        let lrc = try LRCParser.parse("[00:00.00]作词 : 某人\n[00:01.00]作曲 : 某人")
        #expect(LyricsCreditStripper.strip(lrc, title: nil, artists: []).lines.count == 2)
    }
}
