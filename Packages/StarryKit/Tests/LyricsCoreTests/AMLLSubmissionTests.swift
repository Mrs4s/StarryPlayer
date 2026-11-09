import Foundation
import Testing
@testable import LyricsCore

@Suite struct AMLLSubmissionTests {
    private let metadata: [(key: String, value: String)] = [
        ("musicName", "干净的房间"), ("musicName", "Room to Begin"), ("artists", "田馥甄"), ("album", "要去什么地方"),
        ("ncmMusicId", "3439441346"), ("qqMusicId", "727857040"), ("isrc", "TWEW72601004"),
    ]

    private func ttml(_ paragraphs: String) -> String {
        """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>\(paragraphs)</div></body></tt>
        """
    }

    private var valid: String {
        ttml(#"<p begin="00:01.000" end="00:03.000"><span begin="00:01.000" end="00:02.000">Hel</span><span begin="00:02.000" end="00:03.000">lo</span></p>"#)
    }

    @Test func metadataNeedsSongAlbumAndAPlatformIDLikeTheBot() {
        let problems = AMLLSubmission.problems(ttml: valid, metadata: [("musicName", "Song"), ("artists", " "), ("isrc", "X")])
        #expect(problems == [.missingMetadata("artists"), .missingMetadata("album"), .missingPlatformID])
        #expect(problems.allSatisfy { $0.isMetadata })
    }

    @Test func untimedSyllablesBlockTheSubmission() {
        #expect(AMLLSubmission.problems(ttml: valid, metadata: metadata, untimedSyllables: 3) == [.untimedSyllables(3)])
    }

    @Test func unreadableTTMLIsReported() {
        let problems = AMLLSubmission.problems(ttml: "<tt><body>", metadata: metadata)
        #expect(problems.count == 1)
        guard case .unreadable = problems.first else { Issue.record("expected an unreadable TTML problem"); return }
    }

    @Test func linesFollowTheBotsTimingRules() {
        let line = Location(line: 1, background: false)
        let document = LyricsDocument(format: .ttml, lines: [
            LyricLine(id: 0, start: 1, end: 3, words: [
                LyricWord(start: 1, end: 2, text: "a"),
                LyricWord(start: 1.5, end: 2.5, text: "b"),
                LyricWord(start: 2.5, end: 2.4, text: "c"),
                LyricWord(start: 2, end: 2, text: " "),
            ]),
            LyricLine(id: 1, start: 5, end: 4, words: [LyricWord(start: 4, end: 5, text: "d")]),
            LyricLine(id: 2, start: 6, end: 7, words: [LyricWord(start: 6, end: 7, text: "  ")]),
        ])
        #expect(AMLLSubmission.lineProblems(document) == [
            .syllableStartsBeforePrevious(line, syllable: 2, text: "b"),
            .syllableEndsBeforeStart(line, syllable: 3, text: "c"),
            .lineEndsBeforeStart(Location(line: 2, background: false)),
            .emptyLine(Location(line: 3, background: false)),
        ])
    }

    @Test func lyricsWithoutAnyTimeAreRejected() {
        let document = LyricsDocument(format: .ttml, lines: [LyricLine(id: 0, start: 0, end: 0, words: [LyricWord(start: 0, end: 0, text: "a")])])
        #expect(AMLLSubmission.lineProblems(document) == [.allTimesZero])
        #expect(AMLLSubmission.lineProblems(LyricsDocument(format: .ttml, lines: [])) == [.emptyLyrics])
    }

    @Test func starryTTMLPassesItsOwnChecks() throws {
        let document = try TTMLParser.parse(LyricAgentTests.ttml)
        let text = TTMLWriter.write(document, metadata: metadata)
        #expect(AMLLSubmission.problems(ttml: text, metadata: metadata).isEmpty)
    }

    @Test func titleFollowsTheRepositoryConvention() {
        let title = AMLLSubmission.title(metadata: metadata + [("artists", "Hebe")], reason: .new)
        #expect(title == "[歌词提交] 田馥甄, Hebe - 干净的房间")
        #expect(AMLLSubmission.retag(title, as: .correction) == "[歌词补正] 田馥甄, Hebe - 干净的房间")
        #expect(AMLLSubmission.retag("我的标题", as: .correction) == "我的标题")
        #expect(AMLLSubmission.title(metadata: [], reason: .correction) == "[歌词补正]")
    }

    @Test func pullRequestBodyMatchesTheBot() {
        let body = AMLLSubmission.pullRequestBody(number: 10785, author: .init(id: 250306205, login: "alice"),
                                                  metadata: metadata + [("album", "with `tick`")], remarks: "  对 #1 的修正\n- 时间轴  ")
        #expect(body == """
        ### 歌词议题
        #10785

        ### 歌词作者
        @alice

        ### 音乐名称

        - `干净的房间`
        - `Room to Begin`

        ### 音乐作者

        - `田馥甄`

        ### 音乐专辑名称

        - `要去什么地方`
        - `` with `tick` ``

        ### 歌曲关联网易云音乐 ID

        - `3439441346`

        ### 歌曲关联 QQ 音乐 ID

        - `727857040`

        ### 歌曲关联 ISRC

        - `TWEW72601004`

        ### 备注

        对 #1 的修正
        - 时间轴
        """)
        #expect(AMLLSubmission.pullRequestBody(number: nil, author: .init(id: 1, login: "a"), metadata: [], remarks: " ") == "### 歌词作者\n@a")
    }

    @Test func rawFileNamesMatchTheRebuildStep() {
        let name = AMLLSubmission.rawFileName(date: Date(timeIntervalSince1970: 1_793_807_057.396_8), authorID: 250306205, token: "YKlFEmg2")
        #expect(name == "1793807057396-250306205-YKlFEmg2.ttml")
    }

    private typealias Location = AMLLSubmission.Location
}
