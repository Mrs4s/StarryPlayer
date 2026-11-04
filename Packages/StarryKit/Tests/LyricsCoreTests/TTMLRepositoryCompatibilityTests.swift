import Foundation
import Testing
@testable import LyricsCore

@Suite struct TTMLRepositoryCompatibilityTests {
    private func document() throws -> LyricsDocument {
        var document = try TTMLParser.parse(LyricAgentTests.ttml)
        document.agents[1].color = LyricColor(hex: "#AABBCC")
        document.agents[0].memberIDs = ["alice", "bob"]
        document.lines[0].singer = .secondary
        var shared = try #require(try TTMLParser.parse(SharedRubyTests.ttml).lines.first)
        shared.singer = .duet
        shared.agentIDs = ["alice", "bob"]
        document.lines.append(shared)
        document.metadata = ["musicName": "Test & <song>", "artists": "Alice", "album": "Test", "ncmMusicId": "123456789"]
        return document
    }

    private func stripped(_ text: String) throws -> String {
        let xml = try XMLDocument(xmlString: text, options: .nodePreserveWhitespace)
        func visit(_ element: XMLElement) {
            for attribute in element.attributes ?? [] {
                let name = attribute.name ?? ""
                if ["ttx:", "ttv:", "ttd:"].contains(where: name.hasPrefix)
                    || element.name == "span" && name == "ttm:agent" {
                    element.removeAttribute(forName: name)
                }
            }
            if element.name == "ttm:agent" {
                let names = (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == "ttm:name" }
                let name = names.last?.stringValue
                element.setChildren(nil)
                if let name { element.addChild(XMLElement(name: "ttm:name", stringValue: name)) }
            }
            for child in element.children ?? [] {
                if let child = child as? XMLElement { visit(child) }
            }
        }
        visit(try #require(xml.rootElement()))
        return xml.xmlString
    }

    @Test func compatibilityIsOptInAndOnlyAppliesToAMLL() throws {
        let source = try document()
        #expect(!TTMLWriter.write(source).contains(TTMLRepositoryCompatibility.metadataKey))
        #expect(TTMLWriter.write(source, repositoryCompatible: true).contains(TTMLRepositoryCompatibility.metadataKey))
        #expect(!TTMLWriter.write(source, format: .ttml2, repositoryCompatible: true).contains(TTMLRepositoryCompatibility.metadataKey))
        let draft = LyricsDraft(document: source)
        #expect(try LyricsExport.write(draft, format: .ttml, repositoryCompatible: true).text.contains(TTMLRepositoryCompatibility.metadataKey))
    }

    @Test func repositoryProcessingKeepsSharedRubyRolesAndInlinePerformers() throws {
        let source = try document()
        let exported = TTMLWriter.write(source, repositoryCompatible: true)
        let expected = try TTMLParser.parse(TTMLWriter.write(source))
        let processed = try stripped(exported)
        let restored = try TTMLParser.parse(processed)
        #expect(restored == expected)
        #expect(restored.metadata[TTMLRepositoryCompatibility.metadataKey] == nil)
        let second = try stripped(TTMLWriter.write(restored, repositoryCompatible: true))
        #expect(try TTMLParser.parse(second) == expected)
    }

    @Test func ordinaryRubyKeepsItsBaseRangeAfterTheBotUsesReadingTiming() throws {
        let source = LyricsDocument(format: .ttml, lines: [
            .init(id: 0, start: 1, end: 3, words: [.init(start: 1, end: 3, text: "愛", syllables: [
                .init(start: 1, end: 3, text: "愛", ruby: [.init(start: 1.4, end: 2.6, text: "あい")]),
            ])]),
        ])
        let exported = TTMLWriter.write(source, repositoryCompatible: true)
        let processed = exported.replacingOccurrences(of: #"tts:ruby="container" begin="00:01.000" end="00:03.000""#,
                                                      with: #"tts:ruby="container""#)
        let restored = try TTMLParser.parse(processed)
        #expect(restored.lines[0].syllables == source.lines[0].syllables)
    }

    @Test func changedLyricsAndTimingIgnoreTheWholeBackup() throws {
        let exported = try stripped(TTMLWriter.write(document(), repositoryCompatible: true))
        for changed in [exported.replacingOccurrences(of: ">One<", with: ">Changed<"),
                        exported.replacingOccurrences(of: "</span> <span", with: "</span><span"),
                        exported.replacingOccurrences(of: "00:10.500", with: "00:10.600"),
                        exported.replacingOccurrences(of: "L1", with: "renamed")] {
            let parsed = try TTMLParser.parse(changed)
            #expect(parsed.agents.allSatisfy { $0.color == nil && $0.memberIDs.isEmpty })
            #expect(parsed.lines.last?.syllables.first?.groupRuby.isEmpty == true)
        }
    }

    @Test func nativeExtensionsTakePriorityOverTheBackup() throws {
        let exported = TTMLWriter.write(try document(), repositoryCompatible: true)
        let changed = exported.replacingOccurrences(of: "#AABBCC", with: "#112233")
        let parsed = try TTMLParser.parse(changed)
        #expect(parsed.agents.first { $0.id == "alice" }?.color == LyricColor(hex: "#112233"))
    }

    @Test func invalidOrUnsupportedPayloadsLeaveTheLyricsReadable() throws {
        let exported = try stripped(TTMLWriter.write(document(), repositoryCompatible: true))
        for value in ["not base64", Data("{}".utf8).base64EncodedString(), Data(#"{"version":2,"agents":[],"lines":[]}"#.utf8).base64EncodedString()] {
            let xml = try XMLDocument(xmlString: exported)
            let node = try #require(try xml.nodes(forXPath: "//*[@key='starry:extensions:v1']").first as? XMLElement)
            node.attribute(forName: "value")?.stringValue = value
            let parsed = try TTMLParser.parse(xml.xmlString)
            #expect(parsed.lines.count == 4)
            #expect(parsed.agents.allSatisfy { $0.color == nil })
        }
    }

    @Test func oldMetadataIsReplacedOrRemovedWhenExportingAgain() throws {
        var source = try document()
        source.metadata[TTMLRepositoryCompatibility.metadataKey] = "stale"
        #expect(!TTMLWriter.write(source).contains(TTMLRepositoryCompatibility.metadataKey))
        let output = TTMLWriter.write(source, repositoryCompatible: true)
        let xml = try XMLDocument(xmlString: output)
        let nodes = try xml.nodes(forXPath: "//*[@key='starry:extensions:v1']")
        #expect(nodes.count == 1)
        #expect((nodes.first as? XMLElement)?.attribute(forName: "value")?.stringValue != "stale")
    }

    @Test func corruptedTimingInTheBackupIsIgnored() throws {
        let xml = try XMLDocument(xmlString: stripped(TTMLWriter.write(document(), repositoryCompatible: true)), options: .nodePreserveWhitespace)
        let meta = try #require(try xml.nodes(forXPath: "//*[@key='starry:extensions:v1']").first as? XMLElement)
        let value = try #require(meta.attribute(forName: "value")?.stringValue)
        let data = try #require(Data(base64Encoded: value))
        let json = try #require(String(data: data, encoding: .utf8))
        meta.attribute(forName: "value")?.stringValue = Data(json.replacingOccurrences(of: #""start":10"#, with: #""start":1e100"#).utf8).base64EncodedString()
        let parsed = try TTMLParser.parse(xml.xmlString)
        #expect(parsed.agents.allSatisfy { $0.color == nil })
        #expect(!TTMLWriter.write(parsed).isEmpty)
    }
}
