import Foundation
import Testing
@testable import LyricsCore

@Suite struct TTML2RubyTests {
    private func document(_ spans: String, begin: String = "1s", end: String = "4s") throws -> LyricsDocument {
        try TTMLParser.parse("""
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="\(begin)" end="\(end)">\(spans)</p>
        </div></body></tt>
        """)
    }

    private func roundTrip(_ original: LyricsDocument) throws {
        let written = TTMLWriter.write(original, format: .ttml2)
        let parsed = try TTMLParser.parse(written)
        #expect(parsed.lines.map(\.syllables) == original.lines.map(\.syllables))
        #expect(parsed.lines.map { $0.background?.syllables } == original.lines.map { $0.background?.syllables })
        #expect(!written.contains("ttx:ruby") && !written.contains("xmlns:ttx"))
        let xml = try XMLDocument(xmlString: written)
        let root = try #require(xml.rootElement())
        try checkRubyStructure(root)
    }

    // Validate the TTML2 content model independently of the lyric parser.
    private func checkRubyStructure(_ element: XMLElement) throws {
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        let role = element.attribute(forName: "tts:ruby")?.stringValue
        if role == "container" {
            let roles = children.compactMap { $0.attribute(forName: "tts:ruby")?.stringValue }
            #expect([["base", "text"], ["base", "delimiter", "text", "delimiter"],
                     ["baseContainer", "textContainer"], ["baseContainer", "textContainer", "textContainer"]].contains(roles))
        }
        if role == "base" || role == "text" || role == "delimiter" {
            func checkPlain(_ node: XMLElement) {
                for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
                    let role = child.attribute(forName: "tts:ruby")?.stringValue
                    #expect(role == nil || role == "none")
                    checkPlain(child)
                }
            }
            checkPlain(element)
        }
        for child in children { try checkRubyStructure(child) }
    }

    @Test func exportFormatsKeepSharedRuby() throws {
        let original = try TTMLParser.parse(SharedRubyTests.ttml)
        let amll = try LyricsExport.write(original, format: .ttml, duration: 30)
        let standard = try LyricsExport.write(original, format: .ttml2, duration: 30)
        #expect(amll.text.contains("ttx:rubyGroup") && !amll.text.contains(#"tts:ruby="base""#))
        #expect(!standard.text.contains("ttx:ruby") && standard.text.contains(#"tts:ruby="base""#))
        #expect(amll.losses.isEmpty && standard.losses.isEmpty)
        #expect(try TTMLParser.parse(amll.text).lines.map(\.syllables) == original.lines.map(\.syllables))
        #expect(try TTMLParser.parse(standard.text).lines.map(\.syllables) == original.lines.map(\.syllables))
        try checkRubyStructure(#require(try XMLDocument(xmlString: standard.text).rootElement()))
    }

    @Test func simpleRubyKeepsTheBaseDurationWhenTheReadingCoversOnlyPartOfIt() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="base" begin="1s" end="3s">愛</span><span tts:ruby="text" begin="1.4s" end="2.6s">あい</span></span>
        """)
        let syllable = try #require(original.lines.first?.syllables.first)
        #expect(syllable.text == "愛" && syllable.start == 1 && syllable.end == 3)
        #expect(syllable.ruby == [.init(start: 1.4, end: 2.6, text: "あい")])
        try roundTrip(original)
    }

    @Test func oneRubyTextContainsSeveralTimedReadingPieces() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="base" begin="1s" end="3s">詮</span><span tts:ruby="text">
          <span begin="1.2s" end="1.6s">せ</span><span begin="1.6s" end="2.8s">ん</span>
        </span></span>
        """)
        let syllable = try #require(original.lines.first?.syllables.first)
        #expect(syllable.ruby == [.init(start: 1.2, end: 1.6, text: "せ"), .init(start: 1.6, end: 2.8, text: "ん")])
        try roundTrip(original)
    }

    @Test func oneBaseContainsSeveralTimedSyllablesSharingOneReading() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="base">
          <span begin="1s" end="1.5s">今</span><span begin="1.5s" end="3s">日</span>
        </span><span tts:ruby="text" begin="1s" end="3s">きょう</span></span><span begin="3s" end="4s">を</span>
        """)
        let syllables = try #require(original.lines.first).syllables
        #expect(syllables.map(\.text) == ["今", "日", "を"])
        #expect(syllables.map(\.start) == [1, 1.5, 3] && syllables.map(\.end) == [1.5, 3, 4])
        #expect(syllables[0].groupRuby == [.init(start: 1, end: 3, text: "きょう")])
        #expect(syllables.map(\.joinsRubyGroup) == [false, true, false])
        try roundTrip(original)
    }

    @Test func sharedBaseAndReadingKeepWordBreaksAndLiteralSeparators() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="base"><span begin="1s" end="2s">永遠</span> <span begin="2s" end="3s">愛</span></span><span tts:ruby="text"><span begin="1s" end="2s">eternal </span><span begin="2s" end="3s">lo|ve\u{005C}&amp;</span></span></span>
        """)
        let line = try #require(original.lines.first)
        #expect(line.text == "永遠 愛")
        #expect(line.syllables[0].groupRuby.map(\.text) == ["eternal ", "lo|ve\\&"])
        try roundTrip(original)
    }

    @Test func explicitBaseAndTextContainersMapEqualNumbersInOrder() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="baseContainer">
          <span tts:ruby="base" begin="1s" end="2s">海</span><span tts:ruby="base" begin="2s" end="3s">空</span>
        </span><span tts:ruby="textContainer">
          <span tts:ruby="text" begin="1s" end="2s">うみ</span><span tts:ruby="text" begin="2s" end="3s">そら</span>
        </span></span>
        """)
        let syllables = try #require(original.lines.first).syllables
        #expect(syllables.map(\.text) == ["海", "空"])
        #expect(syllables.map { $0.ruby.map(\.text) } == [["うみ"], ["そら"]])
        #expect(syllables.allSatisfy { $0.groupRuby.isEmpty && !$0.joinsRubyGroup })
        try roundTrip(original)
    }

    @Test(arguments: [false, true])
    func undefinedUnequalMappingsPreserveAllBasesWithoutInventingRuby(oneBase: Bool) throws {
        let bases = oneBase
            ? #"<span tts:ruby="base" begin="1s" end="3s">今日</span>"#
            : #"<span tts:ruby="base" begin="1s" end="2s">今</span><span tts:ruby="base" begin="2s" end="3s">日</span>"#
        let texts = oneBase
            ? #"<span tts:ruby="text">きょ</span><span tts:ruby="text">う</span>"#
            : #"<span tts:ruby="text">きょう</span>"#
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="baseContainer">\(bases)</span><span tts:ruby="textContainer">\(texts)</span></span>
        """)
        let line = try #require(original.lines.first)
        #expect(line.text == "今日" && !line.hasRuby)
        #expect(line.syllables.map(\.start) == (oneBase ? [1] : [1, 2]))
        #expect(line.syllables.map(\.end) == (oneBase ? [3] : [2, 3]))
        try roundTrip(original)
    }

    @Test func untimedNestedBasesUseTheContainerAndShareItsReading() throws {
        let original = try document("""
        <span tts:ruby="container" begin="1s" end="3s"><span tts:ruby="base"><span>今</span><span>日</span></span><span tts:ruby="text">きょう</span></span>
        """)
        let syllables = try #require(original.lines.first).syllables
        #expect(syllables.map(\.start) == [1, 2] && syllables.map(\.end) == [2, 3])
        #expect(syllables[0].groupRuby == [.init(start: 1, end: 3, text: "きょう")])
        try roundTrip(original)
    }

    @Test func nestedSyllablesInheritTheContainerEndWhenTheirEndIsMissing() throws {
        let original = try document("""
        <span tts:ruby="container" begin="1s" end="3s"><span tts:ruby="base"><span begin="1s" end="2s">今</span><span begin="2s">日</span></span><span tts:ruby="text">きょう</span></span>
        """)
        let syllables = try #require(original.lines.first).syllables
        #expect(syllables.map(\.start) == [1, 2] && syllables.map(\.end) == [2, 3])
        #expect(syllables[0].groupRuby == [.init(start: 1, end: 3, text: "きょう")])
        try roundTrip(original)
    }

    @Test func missingAndPlaceholderTimesAreFilledBeforeSharedRubyIsApplied() throws {
        let original = try document("""
        <span begin="5s" end="6s">君</span><span tts:ruby="container"><span tts:ruby="base"><span begin="0s" end="0s">今</span><span begin="0s" end="0s">日</span></span><span tts:ruby="text" begin="0s" end="0s">きょう</span></span>
        """, begin: "5s", end: "8s")
        let syllables = try #require(original.lines.first).syllables
        #expect(syllables.map(\.start) == [5, 6, 7] && syllables.map(\.end) == [6, 7, 8])
        #expect(syllables[1].groupRuby == [.init(start: 6, end: 8, text: "きょう")])
        try roundTrip(original)
    }

    @Test func standardRubyKeepsNamespaceAliasesInlinePerformersAndBackgroundGroups() throws {
        let original = try TTMLParser.parse("""
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:s="http://www.w3.org/ns/ttml#styling" xmlns:m="http://www.w3.org/ns/ttml#metadata"><head><metadata><m:agent xml:id="a" type="person"/><m:agent xml:id="b" type="person"/></metadata></head><body><div>
          <p begin="1s" end="4s" m:agent="a"><span s:ruby="container"><span s:ruby="base"><span begin="1s" end="1.5s" m:agent="b">今</span><span begin="1.5s" end="3s">日</span></span><span s:ruby="text">きょう</span></span><span m:role="x-bg" m:agent="b"><span s:ruby="container"><span s:ruby="base"><span begin="3s" end="3.5s">今</span><span begin="3.5s" end="4s">日</span></span><span s:ruby="text">きょう</span></span></span></p>
        </div></body></tt>
        """)
        let line = try #require(original.lines.first)
        #expect(line.syllables.map(\.agentIDs) == [["b"], []])
        let background = try #require(line.background)
        #expect(background.agentIDs == ["b"])
        #expect(background.syllables[0].groupRuby == [.init(start: 3, end: 4, text: "きょう")])
        try roundTrip(original)
    }

    @Test func mixedTextAndNestedSpansKeepTheirOriginalOrder() throws {
        let original = try document("""
        <span tts:ruby="container"><span tts:ruby="base" begin="1s" end="3s">今<span>日</span>も</span><span tts:ruby="text">きょ<span>う</span>も</span></span>
        """)
        let line = try #require(original.lines.first)
        #expect(line.text == "今日も")
        #expect(line.syllables[0].groupRuby.map(\.text).joined() == "きょうも")
        try roundTrip(original)
    }
}
