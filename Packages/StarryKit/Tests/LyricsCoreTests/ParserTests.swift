import Foundation
import Testing
@testable import LyricsCore

@Suite struct ParserTests {
    @Test func lrcParsesTimestampsAndMetadata() throws {
        let doc = try LRCParser.parse("""
        [ar:周杰伦]
        [00:12.34]第一行
        [00:20.00][00:40.00]重复行
        [00:30.5]第三行
        """)
        #expect(doc.metadata["ar"] == "周杰伦")
        #expect(doc.lines.map(\.text) == ["第一行", "重复行", "第三行", "重复行"])
        #expect(doc.lines[0].start == 12.34)
        #expect(doc.lines[0].end == 20)
        #expect(doc.activeLineIndex(at: 31) == 2)
        #expect(doc.activeLineIndex(at: 1) == nil)
    }

    @Test func yrcGroupsSyllablesIntoWords() throws {
        let doc = try YRCParser.parse("""
        {"t":0,"c":[{"tx":"作词: "},{"tx":"某人"}]}
        [1000,2000](1000,500,0)你(1500,500,0)好(2000,1000,0)吗
        """)
        #expect(doc.metadata["credit0"] == "作词: 某人")
        #expect(doc.lines.count == 1)
        #expect(doc.lines[0].text == "你好吗")
        #expect(doc.lines[0].words.map(\.text) == ["你好", "吗"])
        #expect(doc.lines[0].words[0].syllables.count == 2)
        #expect(doc.lines[0].words[1].start == 2)
        #expect(doc.lines[0].end == 3)
        let progress = LyricsProgress.compute(doc, at: 1.75)
        #expect(progress.activeLine == 0)
        #expect(progress.wordProgress == [0.75, 0])
    }

    @Test func translationMergesByNearestStart() throws {
        let doc = try LyricsParsing.parse("[00:01.00]hello\n[00:05.00]world", format: .lrc, translation: "[00:01.20]你好\n[00:05.00]世界")
        #expect(doc.lines[0].translation == "你好")
        #expect(doc.lines[1].translation == "世界")
    }
}
