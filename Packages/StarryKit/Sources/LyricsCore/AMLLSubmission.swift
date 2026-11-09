import Foundation

/// Validation and pull request formatting for AMLL TTML DB submissions.
public enum AMLLSubmission {
    public static let owner = "amll-dev"
    public static let repository = "amll-ttml-db"
    public static let baseBranch = "main"
    public static let rawDirectory = "raw-lyrics"
    public static let guideURL = URL(string: "https://github.com/amll-dev/amll-ttml-db/wiki/%E4%B8%8A%E4%BC%A0%E6%AD%8C%E8%AF%8D")!

    public static let authorIDKey = "ttmlAuthorGithub"
    public static let authorLoginKey = "ttmlAuthorGithubLogin"
    private static let requiredKeys = ["musicName", "artists", "album"]
    private static let platformKeys = ["ncmMusicId", "qqMusicId", "spotifyId", "appleMusicId"]

    public struct Author: Sendable, Equatable, Decodable {
        public var id: Int
        public var login: String

        public init(id: Int, login: String) {
            self.id = id
            self.login = login
        }
    }

    public enum Reason: String, Sendable, CaseIterable, Identifiable {
        case new, correction

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .new: "新歌词提交"
            case .correction: "修正已有歌词"
            }
        }

        var tag: String {
            switch self {
            case .new: "歌词提交"
            case .correction: "歌词补正"
            }
        }
    }

    /// One-based line number in the exported TTML.
    public struct Location: Sendable, Hashable {
        public var line: Int
        public var background: Bool

        var label: String { background ? "第 \(line) 句的背景人声" : "第 \(line) 句" }
    }

    public enum Problem: Sendable, Hashable {
        case missingMetadata(String)
        case missingPlatformID
        case untimedSyllables(Int)
        case unreadable(String)
        case emptyLyrics
        case allTimesZero
        case emptyLine(Location)
        case lineEndsBeforeStart(Location)
        case syllableEndsBeforeStart(Location, syllable: Int, text: String)
        case syllableStartsBeforePrevious(Location, syllable: Int, text: String)

        public var isMetadata: Bool {
            switch self {
            case .missingMetadata, .missingPlatformID: true
            default: false
            }
        }

        public var message: String {
            switch self {
            case .missingMetadata(let key): "缺少\(Self.name(of: key))"
            case .missingPlatformID: "缺少音乐平台 ID：网易云音乐、QQ 音乐、Spotify、Apple Music 至少填一个"
            case .untimedSyllables(let count): "还有 \(count) 个音节没有打点，歌词库要求逐字时间准确，不接受推算的时间"
            case .unreadable(let reason): "导出的 TTML 读不出来：\(reason)"
            case .emptyLyrics: "歌词是空的"
            case .allTimesZero: "所有时间都是 0"
            case .emptyLine(let location): "\(location.label)没有文字"
            case .lineEndsBeforeStart(let location): "\(location.label)的结束时间早于开始时间"
            case let .syllableEndsBeforeStart(location, syllable, text): "\(location.label)第 \(syllable) 个音节「\(text)」的结束时间早于开始时间"
            case let .syllableStartsBeforePrevious(location, syllable, text): "\(location.label)第 \(syllable) 个音节「\(text)」早于前一个音节的结束时间"
            }
        }

        private static func name(of key: String) -> String {
            switch key {
            case "musicName": "歌名"
            case "artists": "歌手"
            case "album": "专辑（单曲填歌名）"
            default: key
            }
        }
    }

    // MARK: Checks

    public static func problems(ttml: String, metadata: [(key: String, value: String)], untimedSyllables: Int = 0) -> [Problem] {
        let present = Set(metadata.filter { !trimmed($0.value).isEmpty }.map(\.key))
        var problems = requiredKeys.filter { !present.contains($0) }.map(Problem.missingMetadata)
        if !platformKeys.contains(where: present.contains) { problems.append(.missingPlatformID) }
        if untimedSyllables > 0 { problems.append(.untimedSyllables(untimedSyllables)) }
        do {
            problems += lineProblems(try TTMLParser.parse(ttml))
        } catch {
            problems.append(.unreadable(error.localizedDescription))
        }
        return problems
    }

    /// The bot's checks compare whole milliseconds, which is what a TTML file holds.
    static func lineProblems(_ document: LyricsDocument) -> [Problem] {
        guard !document.lines.isEmpty else { return [.emptyLyrics] }
        var problems: [Problem] = []
        var timed = false
        for (index, line) in document.lines.enumerated() {
            var voices = [(Location(line: index + 1, background: false), line.text, line.syllables, line.start, line.end)]
            if let background = line.background, !background.syllables.isEmpty || !trimmed(background.text).isEmpty {
                voices.append((Location(line: index + 1, background: true), background.text, background.syllables, background.start, background.end))
            }
            for (location, text, syllables, start, end) in voices {
                if ms(start) != 0 || ms(end) != 0 || syllables.contains(where: { ms($0.start) != 0 || ms($0.end) != 0 }) { timed = true }
                guard syllables.contains(where: { !trimmed($0.text).isEmpty }) || !trimmed(text).isEmpty else {
                    problems.append(.emptyLine(location))
                    continue
                }
                if ms(end) < ms(start) { problems.append(.lineEndsBeforeStart(location)) }
                var previousEnd: Int?
                for (offset, syllable) in syllables.enumerated() where !trimmed(syllable.text).isEmpty {
                    let start = ms(syllable.start), end = ms(syllable.end)
                    if end < start { problems.append(.syllableEndsBeforeStart(location, syllable: offset + 1, text: syllable.text)) }
                    if let previousEnd, start < previousEnd {
                        problems.append(.syllableStartsBeforePrevious(location, syllable: offset + 1, text: syllable.text))
                    }
                    previousEnd = max(previousEnd ?? 0, max(start, end))
                }
            }
        }
        if !timed { problems.insert(.allTimesZero, at: 0) }
        return problems
    }

    // MARK: Pull request

    public static func title(metadata: [(key: String, value: String)], reason: Reason) -> String {
        let song = [values("artists", in: metadata).joined(separator: ", "), values("musicName", in: metadata).first ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return song.isEmpty ? "[\(reason.tag)]" : "[\(reason.tag)] \(song)"
    }

    public static func retag(_ title: String, as reason: Reason) -> String {
        for other in Reason.allCases where title.hasPrefix("[\(other.tag)]") {
            return "[\(reason.tag)]" + title.dropFirst(other.tag.count + 2)
        }
        return title
    }

    /// The pull request's own number lets the bot verify its author for `/label` and `/close`.
    public static func pullRequestBody(number: Int?, author: Author, metadata: [(key: String, value: String)], remarks: String) -> String {
        var parts: [String] = []
        if let number { parts.append("### 歌词议题\n#\(number)") }
        parts.append("### 歌词作者\n@\(author.login)")
        for (heading, key) in bodySections {
            let list = values(key, in: metadata)
            guard !list.isEmpty else { continue }
            parts.append("### \(heading)")
            parts.append(list.map { "- " + code($0) }.joined(separator: "\n"))
        }
        let remarks = trimmed(remarks)
        if !remarks.isEmpty {
            parts.append("### 备注")
            parts.append(remarks)
        }
        return parts.joined(separator: "\n\n")
    }

    private static let bodySections = [
        ("音乐名称", "musicName"), ("音乐作者", "artists"), ("音乐专辑名称", "album"),
        ("歌曲关联网易云音乐 ID", "ncmMusicId"), ("歌曲关联 QQ 音乐 ID", "qqMusicId"),
        ("歌曲关联 Spotify ID", "spotifyId"), ("歌曲关联 Apple Music ID", "appleMusicId"), ("歌曲关联 ISRC", "isrc"),
    ]

    private static func code(_ value: String) -> String {
        value.contains("`") ? "`` \(value) ``" : "`\(value)`"
    }

    // MARK: Files

    /// `TIMESTAMP-AUTHORID-RANDOM.ttml`. The rebuild step skips other names, and the latest timestamp wins for a song.
    public static func rawFileName(date: Date, authorID: Int, token: String) -> String {
        "\(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))-\(authorID)-\(token).ttml"
    }

    public static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    public static func credits(_ author: Author, in metadata: [(key: String, value: String)]) -> Bool {
        values(authorIDKey, in: metadata).contains(String(author.id))
    }

    // MARK: Helpers

    private static func values(_ key: String, in metadata: [(key: String, value: String)]) -> [String] {
        var seen: Set<String> = []
        return metadata.compactMap { entry in
            let value = trimmed(entry.value)
            guard entry.key == key, !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func ms(_ time: TimeInterval) -> Int { Int((time * 1000).rounded()) }
}
