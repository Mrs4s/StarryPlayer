import Foundation

public enum LyricsParseError: Error, Sendable, Equatable {
    case empty
    case unsupported(String)
    case malformed(String)
}

public protocol LyricsParser: Sendable {
    static var format: LyricsDocument.Format { get }
    static func parse(_ text: String) throws -> LyricsDocument
}

public enum LyricsParsing {
    public static func parse(_ body: String, format: LyricsDocument.Format, translation: String? = nil, romanization: String? = nil) throws -> LyricsDocument {
        let detected = format == .lrc ? LyricsFormatDetector.detect(body) : format
        let actual = format == .lrc && [.nicokara, .rl, .krl].contains(detected) ? detected : format
        var document = try parser(for: actual).parse(body)
        attach(translation: translation, romanization: romanization, to: &document)
        return document
    }

    public static func parser(for format: LyricsDocument.Format) -> any LyricsParser.Type {
        switch format {
        case .lrc: LRCParser.self
        case .yrc: YRCParser.self
        case .qrc: QRCParser.self
        case .krc: KRCParser.self
        case .ttml: TTMLParser.self
        case .srt: SRTParser.self
        case .ass: ASSParser.self
        case .nicokara: NicokaraParser.self
        case .rl: RLParser.self
        case .krl: KRLParser.self
        }
    }

    /// Attaches translation / romanization bodies to lines that have none yet. The bodies are
    /// usually LRC, but romanization may come as QRC or YRC, so the format is detected. Romanization in a timed format keeps its words and syllable
    /// times (`LyricLine.romanizationWords`), which lets the page align it word by word;
    /// untimed romanization of word-synced lines is timed by `LyricRomanizationAligner`.
    public static func attach(translation: String?, romanization: String?, to document: inout LyricsDocument) {
        if let extra = secondary(translation) {
            // `//` marks an untranslated line.
            merge(&document, extra: extra, accept: { $0 != "//" }, read: \.translation) { line, text, _ in line.translation = text }
        }
        if let extra = secondary(romanization) {
            let timed = extra.format == .lrc ? LRCContent.hasInlineTiming(romanization ?? "") : extra.format != .srt
            // Leading notes such as `以下音译标注由AI工具生产` are not romanization.
            merge(&document, extra: extra, accept: { !LyricWordGrouping.containsChineseJapanese($0) }, read: \.romanization) { line, text, source in
                line.romanization = text
                if timed, !source.words.isEmpty { line.romanizationWords = source.words }
            }
        }
        LyricRomanizationAligner.alignMissing(in: &document)
    }

    private static func secondary(_ text: String?) -> LyricsDocument? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? parser(for: LyricsFormatDetector.detect(text)).parse(text)
    }

    private static func merge(_ document: inout LyricsDocument, extra: LyricsDocument, accept: (String) -> Bool, read: KeyPath<LyricLine, String?>, apply: (inout LyricLine, String, LyricLine) -> Void) {
        let targets = Array(document.lines.indices)
        for extraLine in extra.lines {
            let text = extraLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, accept(text),
                  let index = targets.min(by: { abs(document.lines[$0].start - extraLine.start) < abs(document.lines[$1].start - extraLine.start) }),
                  abs(document.lines[index].start - extraLine.start) <= 0.5,
                  document.lines[index][keyPath: read]?.isEmpty ?? true else { continue }
            apply(&document.lines[index], text, extraLine)
        }
    }
}

/// Sniffs the lyric format of a body whose source did not say (secondary bodies, local files).
public enum LyricsFormatDetector {
    public static func detect(_ text: String) -> LyricsDocument.Format {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let head = text.prefix(4096)
        if head.contains("<QrcInfos") || head.contains("LyricContent=") { return .qrc }
        if head.contains("<tt ") || head.contains("<tt>") || head.contains("<tt\n") { return .ttml }
        if head.range(of: #"(?im)^\s*\[(Script Info|Events)\]\s*$"#, options: .regularExpression) != nil { return .ass }
        if head.range(of: #"(?m)^\s*\d+:\d{2}:\d{2}[,.]\d+\s*-->"#, options: .regularExpression) != nil { return .srt }
        if head.range(of: #"(?i)^\s*config\s*\{"#, options: .regularExpression) != nil || text.contains("【@") { return .krl }
        if text.range(of: #"\[\d+e?\|\d+:\d{2}:\d{2}\]|(?m)^\s*\[\d+e?\]|\{[^{}\r\n]*\|\[\d+e?\]"#, options: .regularExpression) != nil { return .rl }
        if text.range(of: #"(?m)^[ \t]*@(Ruby\d*|Emoji|Title|Artist)=|【sv\d+】|【(?!@)[^】]+】\s*\[\d+:"#, options: .regularExpression) != nil { return .nicokara }
        if text.range(of: #"\{[^{}\r\n]+\|[^{}\r\n]*\}"#, options: .regularExpression) != nil { return .krl }
        if text.range(of: #"\[\d+:\d{2}:\d{2,3}\]"#, options: .regularExpression) != nil,
           text.range(of: #"<\d+:\d{2}[.:]"#, options: .regularExpression) == nil { return .nicokara }
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(300) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let header = KaraokeLine.header(line) else { continue }
            let body = header.body
            if body.hasPrefix("<"), !KaraokeLine.tokens(in: body, open: "<", close: ">", textBeforeTag: false).isEmpty { return .krc }
            if body.hasPrefix("("), !KaraokeLine.tokens(in: body, open: "(", close: ")", textBeforeTag: false).isEmpty { return .yrc }
            if !KaraokeLine.tokens(in: body, open: "(", close: ")", textBeforeTag: true).isEmpty { return .qrc }
        }
        return .lrc
    }
}

public enum LRCParser: LyricsParser {
    public static let format: LyricsDocument.Format = .lrc

    public static func parse(_ text: String) throws -> LyricsDocument {
        try LRCContent(text).document()
    }

    static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber), let minutes = Double(parts[0]),
              let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
        var time = minutes * 60 + seconds
        if parts.count == 3 {
            guard !parts[1].contains("."), (2...3).contains(parts[2].count), parts[2].allSatisfy(\.isNumber), let fraction = Double(parts[2]) else { return nil }
            time += fraction / pow(10, Double(parts[2].count))
        }
        return time.isFinite && time >= 0 ? time : nil
    }
}

public enum YRCParser: LyricsParser {
    public static let format: LyricsDocument.Format = .yrc

    public static func parse(_ text: String) throws -> LyricsDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsParseError.empty }
        var lines: [LyricLine] = []
        var metadata: [String: String] = [:]

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{") {
                if let credit = creditText(line) { metadata["credit\(metadata.count)"] = credit }
                continue
            }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let header = line[line.index(after: line.startIndex)..<close].split(separator: ",")
            guard header.count >= 2, let startMs = Double(header[0]), let durationMs = Double(header[1]) else { continue }
            let body = line[line.index(after: close)...]
            var syllables: [LyricSyllable] = []
            var cursor = body.startIndex
            while cursor < body.endIndex {
                guard body[cursor] == "(", let paren = body[cursor...].firstIndex(of: ")") else { break }
                let parts = body[body.index(after: cursor)..<paren].split(separator: ",")
                let textStart = body.index(after: paren)
                let textEnd = body[textStart...].firstIndex(of: "(") ?? body.endIndex
                let wordText = String(body[textStart..<textEnd])
                if parts.count >= 2, let ws = Double(parts[0]), let wd = Double(parts[1]) {
                    syllables.append(LyricSyllable(start: ws / 1000, end: (ws + wd) / 1000, text: wordText))
                }
                cursor = textEnd
            }
            let start = startMs / 1000
            let end = (startMs + durationMs) / 1000
            var words = LyricWordGrouping.words(from: syllables)
            if words.isEmpty {
                words = [LyricWord(start: start, end: end, text: String(body))]
            }
            lines.append(LyricLine(id: lines.count, start: start, end: end, words: words))
        }
        return LyricsDocument(format: .yrc, lines: lines, metadata: metadata)
    }

    private static func creditText(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["c"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["tx"] as? String }.joined()
    }
}

/// AMLL TTML parser with syllables, singers, background vocals, timed romanization and ruby.
/// Invalid zero timestamps inherit neighbouring timing rather than starting at zero.
public enum TTMLParser: LyricsParser {
    public static let format: LyricsDocument.Format = .ttml

    public static func parse(_ text: String) throws -> LyricsDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsParseError.empty }
        guard let data = trimmed.data(using: .utf8) else { throw LyricsParseError.malformed("encoding") }
        let parser = XMLParser(data: data)
        let delegate = TTMLDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.lines.isEmpty else {
            throw LyricsParseError.malformed(parser.parserError?.localizedDescription ?? "xml")
        }
        guard !delegate.lines.isEmpty else { throw LyricsParseError.empty }
        var lines = delegate.lines
        for i in lines.indices {
            lines[i].id = i
            lines[i].singer = LyricAgent.singer(for: lines[i].agentIDs, in: delegate.agents)
        }
        var document = LyricsDocument(format: .ttml, lines: lines, metadata: delegate.metadata, agents: delegate.agents)
        LyricRomanizationAligner.alignMissing(in: &document)
        return document
    }

    static func parseTime(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("ms"), let ms = Double(value.dropLast(2)) { return ms / 1000 }
        if value.hasSuffix("s"), let s = Double(value.dropLast(1)) { return s }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, let seconds = Double(last) else { return nil }
        var total = seconds
        if parts.count >= 2, let minutes = Double(parts[parts.count - 2]) { total += minutes * 60 }
        if parts.count >= 3, let hours = Double(parts[parts.count - 3]) { total += hours * 3600 }
        return total
    }
}

/// SAX callbacks are single-threaded; the delegate belongs to one parse call.
private final class TTMLDelegate: NSObject, XMLParserDelegate {
    var lines: [LyricLine] = []
    var metadata: [String: String] = [:]

    var agents: [LyricAgent] = []
    private var inHead = false
    private var currentAgent: Int?
    private var agentName: LyricAgent.Name?
    private var agentStack: [[String]] = []
    private var namespaceStack: [[String: String]] = []
    private var languageStack: [String?] = []
    private var paragraphPending = false

    private var inParagraph = false
    private var lineStart: TimeInterval = 0
    private var lineEnd: TimeInterval = 0
    private var lineSinger: LyricSinger = .primary
    private var lineAgentIDs: [String] = []
    private var backgroundAgentIDs: [String] = []
    private var mainWords: [LyricWord] = []
    private var mainPlainText = ""
    private var translation: String?
    private var romanization: String?
    private var backgroundWords: [LyricWord] = []
    private var backgroundPlain = ""
    private var backgroundTranslation: String?
    private var backgroundRomanization: String?
    private var backgroundEnd: TimeInterval?
    private var backgroundSpan: (start: TimeInterval, end: TimeInterval)?
    private var mainPlaceholders: Set<Int> = []
    private var backgroundPlaceholders: Set<Int> = []
    private var mainTimed = false
    private var lineKey: String?

    private var inTransliteration = false
    private var transliterationRead = false
    private var transliterationKey: String?
    private var transliterationStack: [SpanKind] = []
    private var transliterationText = ""
    private var transliterationBreak = false
    private var transliterationMain: [LyricSyllable] = []
    private var transliterationBackground: [LyricSyllable] = []
    private var transliterations: [String: (main: [LyricSyllable], background: [LyricSyllable])] = [:]

    private enum SpanKind {
        case syllable(start: TimeInterval, end: TimeInterval), placeholder, background, translation, roman, other
        case ruby(start: TimeInterval?, end: TimeInterval?), rubyBase, rubyTexts, rubyText(start: TimeInterval?, end: TimeInterval?)
    }
    private var spanStack: [SpanKind] = []
    private var spanText = ""
    private var pendingWordBreak = false
    private var inBackground: Bool { spanStack.contains { if case .background = $0 { return true } else { return false } } }
    private var inRuby: Bool { spanStack.contains { if case .ruby = $0 { return true } else { return false } } }

    struct PendingRuby {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
    }
    private var rubyBase = ""
    private var rubyTexts: [PendingRuby] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        var namespaces = namespaceStack.last ?? [:]
        for (key, value) in attributes where key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
        namespaceStack.append(namespaces)
        var attributes = attributes
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch namespaces[String(parts[0])] {
            case "http://www.w3.org/ns/ttml#metadata": attributes["ttm:\(parts[1])"] = value
            case "http://www.w3.org/ns/ttml#styling": attributes["tts:\(parts[1])"] = value
            default: break
            }
        }
        let inheritedAgents = agentStack.last ?? []
        let language = attributes["xml:lang"] ?? (languageStack.last ?? nil)
        let currentAgents = (attributes["ttm:agent"] ?? attributes["agent"]).map {
            LyricAgent.references($0.split(whereSeparator: \.isWhitespace).map(String.init))
        } ?? inheritedAgents
        // Flush preceding text with its enclosing performers before pushing the new span.
        defer {
            agentStack.append(currentAgents)
            languageStack.append(language)
        }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "head": inHead = true
        case "agent":
            if inHead, let id = attributes["xml:id"], !agents.contains(where: { $0.id == id }) {
                agents.append(LyricAgent(id: id, kind: attributes["type"].flatMap(LyricAgent.Kind.init(rawValue:)) ?? .person))
                currentAgent = agents.count - 1
            }
        case "name" where currentAgent != nil:
            agentName = .init("", kind: attributes["type"].flatMap(LyricAgent.Name.Kind.init(rawValue:)) ?? .full, language: language)
        case "actor":
            if let currentAgent { agents[currentAgent].actorID = attributes["agent"] }
        case "meta":
            if let key = attributes["key"], let value = attributes["value"] { metadata[key] = value }
        case "div":
            paragraphPending = true
        case "transliteration":
            inTransliteration = !transliterationRead
        case "text":
            guard inTransliteration, let key = attributes["for"] else { return }
            transliterationKey = key
            transliterationStack = []
            transliterationText = ""
            transliterationBreak = false
            transliterationMain = []
            transliterationBackground = []
        case "span" where transliterationKey != nil:
            let role = attributes["ttm:role"] ?? attributes["role"] ?? ""
            if role == "x-bg" {
                transliterationStack.append(.background)
            } else if let b = attributes["begin"].flatMap(TTMLParser.parseTime) {
                transliterationStack.append(.syllable(start: b, end: max(b, attributes["end"].flatMap(TTMLParser.parseTime) ?? b)))
            } else {
                transliterationStack.append(.other)
            }
            transliterationText = ""
        case "p":
            inParagraph = true
            lineKey = attributes["itunes:key"] ?? attributes["key"]
            lineStart = attributes["begin"].flatMap(TTMLParser.parseTime) ?? 0
            lineEnd = attributes["end"].flatMap(TTMLParser.parseTime) ?? lineStart
            lineAgentIDs = currentAgents
            mainWords = []
            mainPlainText = ""
            translation = nil
            romanization = nil
            backgroundWords = []
            backgroundPlain = ""
            backgroundTranslation = nil
            backgroundRomanization = nil
            backgroundEnd = nil
            backgroundSpan = nil
            backgroundAgentIDs = []
            mainPlaceholders = []
            backgroundPlaceholders = []
            mainTimed = false
            spanStack = []
            spanText = ""
            pendingWordBreak = false
        case "span":
            guard inParagraph else { return }
            let begin = attributes["begin"].flatMap(TTMLParser.parseTime)
            let end = attributes["end"].flatMap(TTMLParser.parseTime)
            if inRuby {
                switch Self.rubyRole(attributes) {
                case "base": spanStack.append(.rubyBase)
                case "textContainer": spanStack.append(.rubyTexts)
                case "text": spanStack.append(.rubyText(start: begin, end: end))
                default: spanStack.append(.other)
                }
                spanText = ""
                return
            }
            flushLooseText()
            if let top = spanStack.last, case .background = top, !spanText.isEmpty {
                appendSyllable(text: spanText, start: nil, end: nil)
                spanText = ""
            }
            let role = attributes["ttm:role"] ?? attributes["role"] ?? ""
            let kind: SpanKind
            if Self.rubyRole(attributes) == "container" {
                kind = .ruby(start: begin, end: end)
                rubyBase = ""
                rubyTexts = []
            } else {
                switch role {
                case "x-bg":
                    kind = .background
                    backgroundAgentIDs = currentAgents == lineAgentIDs ? [] : currentAgents
                    if let b = begin {
                        let e = end ?? b
                        if !isPlaceholder(begin: b, end: e) { backgroundSpan = (b, max(b, e)) }
                    }
                case "x-translation": kind = .translation
                case "x-roman": kind = .roman
                default:
                    if let b = begin {
                        let e = end ?? b
                        kind = isPlaceholder(begin: b, end: e) ? .placeholder : .syllable(start: b, end: e)
                    } else {
                        kind = .other
                    }
                }
            }
            spanStack.append(kind)
            spanText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if agentName != nil {
            agentName?.text += string
            return
        }
        if transliterationKey != nil {
            if case .syllable = transliterationStack.last {
                transliterationText += string
            } else if string.contains(where: \.isWhitespace) {
                transliterationBreak = true
            }
            return
        }
        guard inParagraph else { return }
        let inContainer: Bool
        if let top = spanStack.last, case .background = top { inContainer = true } else { inContainer = spanStack.isEmpty }
        if inContainer {
            if string.allSatisfy(\.isWhitespace) {
                if !string.isEmpty { pendingWordBreak = true }
            } else {
                spanText += string
            }
        } else {
            spanText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer {
            _ = agentStack.popLast()
            _ = namespaceStack.popLast()
            _ = languageStack.popLast()
        }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "head": inHead = false
        case "agent": currentAgent = nil
        case "name":
            if let currentAgent, let agentName { agents[currentAgent].names.append(agentName) }
            agentName = nil
        case "span" where transliterationKey != nil:
            guard let kind = transliterationStack.popLast() else { return }
            if case .syllable(let start, let end) = kind {
                let inBackground = transliterationStack.contains { if case .background = $0 { return true } else { return false } }
                appendTransliteration(LyricSyllable(start: start, end: end, text: transliterationText.replacingOccurrences(of: "\n", with: "")), background: inBackground)
            }
            transliterationText = ""
        case "text":
            guard let key = transliterationKey else { return }
            transliterations[key] = (transliterationMain, transliterationBackground)
            transliterationKey = nil
        case "transliteration":
            if inTransliteration { transliterationRead = true }
            inTransliteration = false
        case "span":
            guard inParagraph, let kind = spanStack.popLast() else { return }
            let text = spanText
            spanText = ""
            switch kind {
            case .syllable(let start, let end):
                appendSyllable(text: text, start: start, end: end)
            case .placeholder:
                appendSyllable(text: text, start: nil, end: nil, placeholder: true)
            case .translation:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    if inBackground { backgroundTranslation = t } else { translation = t }
                }
            case .roman:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    if inBackground { backgroundRomanization = t } else { romanization = t }
                }
            case .background:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if backgroundWords.isEmpty, !t.isEmpty { backgroundPlain = t }
            case .other:
                if !text.isEmpty, !inRuby { appendSyllable(text: text, start: nil, end: nil) }
            case .rubyBase:
                rubyBase += text
            case .rubyText(let start, let end):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { rubyTexts.append(PendingRuby(text: t, start: start, end: end)) }
            case .rubyTexts:
                break
            case .ruby(let start, let end):
                appendRuby(start: start, end: end)
            }
        case "p":
            guard inParagraph else { return }
            flushLooseText()
            finishLine()
            inParagraph = false
        default:
            break
        }
    }

    private func appendTransliteration(_ syllable: LyricSyllable, background: Bool) {
        guard !syllable.text.isEmpty else { return }
        var list = background ? transliterationBackground : transliterationMain
        if transliterationBreak, let last = list.indices.last, !list[last].text.hasSuffix(" ") {
            list[last].text += " "
        }
        transliterationBreak = false
        list.append(syllable)
        if background { transliterationBackground = list } else { transliterationMain = list }
    }

    private func transliterationWords(_ syllables: [LyricSyllable]?) -> [LyricWord]? {
        guard let syllables, let first = syllables.first, let last = syllables.last else { return nil }
        return KaraokeLine.make(id: 0, start: first.start, end: last.end, syllables: syllables)?.words
    }

    private static func rubyRole(_ attributes: [String: String]) -> String? {
        attributes["tts:ruby"] ?? attributes.first { $0.key == "ruby" || $0.key.hasSuffix(":ruby") }?.value
    }

    /// A ruby container is one syllable, its base: timed by the container, or else by its ruby
    /// texts, whose own times are kept.
    private func appendRuby(start: TimeInterval?, end: TimeInterval?) {
        let base = rubyBase, texts = rubyTexts
        rubyBase = ""
        rubyTexts = []
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let begin = start ?? texts.compactMap(\.start).min() else {
            appendSyllable(text: base, start: nil, end: nil, ruby: texts)
            return
        }
        let finish = max(begin, end ?? texts.compactMap { $0.end ?? $0.start }.max() ?? begin)
        if isPlaceholder(begin: begin, end: finish) {
            appendSyllable(text: base, start: nil, end: nil, placeholder: true, ruby: texts)
        } else {
            appendSyllable(text: base, start: begin, end: finish, ruby: texts)
        }
    }

    /// Ruby texts keep their own times, within the syllable, when they all have one; otherwise
    /// they share the syllable by length.
    static func ruby(_ texts: [PendingRuby], start: TimeInterval, end: TimeInterval) -> [LyricRuby] {
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ $0.start != nil }) else { return LyricRuby.spread(texts.map(\.text), start: start, end: end) }
        return texts.map { text in
            let s = min(max(text.start!, start), end)
            return LyricRuby(start: s, end: min(max(text.end ?? s, s), end), text: text.text)
        }
    }

    private func flushLooseText() {
        guard spanStack.isEmpty, !spanText.isEmpty else { return }
        appendSyllable(text: spanText, start: nil, end: nil)
        spanText = ""
    }

    /// The AMLL editor exports times it never set as `00:00.000`: a zero `begin` is a
    /// placeholder unless it can be the real start of the song (a zero-length span, or a line
    /// that starts later or already has later syllables cannot).
    private func isPlaceholder(begin: TimeInterval, end: TimeInterval) -> Bool {
        begin <= 0 && (end <= 0 || lineStart > 0 || (mainWords.last?.end ?? 0) > 0 || (backgroundEnd ?? 0) > 0)
    }

    private func appendSyllable(text rawText: String, start: TimeInterval?, end: TimeInterval?, placeholder: Bool = false, ruby: [PendingRuby] = []) {
        let text = rawText.replacingOccurrences(of: "\n", with: "")
        guard !text.isEmpty else { return }
        let bg = inBackground
        let s = start ?? (bg ? (backgroundEnd ?? backgroundSpan?.start ?? lineStart) : (mainWords.last?.end ?? lineStart))
        let e = end ?? (bg && start == nil && !placeholder ? max(s, backgroundSpan?.end ?? s) : s)
        let voiceAgents = bg && !backgroundAgentIDs.isEmpty ? backgroundAgentIDs : lineAgentIDs
        let currentAgents = agentStack.last ?? []
        let syllable = LyricSyllable(start: s, end: e, text: text, ruby: Self.ruby(ruby, start: s, end: e), agentIDs: currentAgents == voiceAgents ? [] : currentAgents)
        if placeholder {
            let index = (bg ? backgroundWords : mainWords).reduce(0) { $0 + $1.syllables.count }
            if bg { backgroundPlaceholders.insert(index) } else { mainPlaceholders.insert(index) }
        } else if bg {
            backgroundEnd = max(backgroundEnd ?? e, e)
        } else if start != nil {
            mainTimed = true
        }
        var words = bg ? backgroundWords : mainWords
        if pendingWordBreak, !words.isEmpty {
            words[words.count - 1].text += " "
            words[words.count - 1].syllables[words[words.count - 1].syllables.count - 1].text += " "
        }
        if words.isEmpty || pendingWordBreak || text.hasPrefix(" ") || (words.last?.text.hasSuffix(" ") ?? false) {
            words.append(LyricWord(start: s, end: e, text: text, syllables: [syllable]))
        } else {
            words[words.count - 1].end = max(words[words.count - 1].end, e)
            words[words.count - 1].text += text
            words[words.count - 1].syllables.append(syllable)
        }
        pendingWordBreak = false
        if bg { backgroundWords = words } else { mainWords = words }
    }

    private func finishLine() {
        let transliteration = lineKey.flatMap { transliterations[$0] }
        var background = backgroundVocals(transliteration: transliterationWords(transliteration?.background))
        var words = mainWords
        if words.isEmpty {
            let plain = mainPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                words = [LyricWord(start: lineStart, end: lineEnd, text: plain)]
            } else if let bg = background {
                words = bg.words
                if !bg.agentIDs.isEmpty { lineAgentIDs = bg.agentIDs }
                background = nil
            } else {
                return
            }
        }
        if !mainWords.isEmpty {
            // Untimed text must span the paragraph; zero-length lines disappear immediately after
            // selection.
            let syllables = mainWords.flatMap(\.syllables)
            let untimed = mainTimed ? mainPlaceholders : Set(syllables.indices)
            let retimed = Self.retimePlaceholders(syllables, at: untimed, fallback: (lineStart, lineEnd))
            words = LyricWordGrouping.words(from: retimed)
        }
        if let last = words.last, last.text.hasSuffix(" ") {
            words[words.count - 1].text = String(last.text.dropLast())
            let n = words[words.count - 1].syllables.count
            words[words.count - 1].syllables[n - 1].text = String(words[words.count - 1].syllables[n - 1].text.dropLast())
        }
        let primaryStart = mainWords.isEmpty ? lineStart : (words.first?.start ?? lineStart)
        let primaryEnd = mainWords.isEmpty ? lineEnd : (words.last?.end ?? lineEnd)
        var contentStart = words.first?.start ?? lineStart
        var contentEnd = words.last?.end ?? lineEnd
        if let background {
            contentStart = min(contentStart, background.start)
            contentEnd = max(contentEnd, background.end)
        }
        // Some AMLL echo lines leave paragraph timing at 00:00.000; ignore non-overlapping
        // placeholders.
        var start = contentStart
        var end = contentEnd
        if lineEnd > lineStart, lineStart < contentEnd, lineEnd > contentStart {
            start = min(start, lineStart)
            end = max(end, lineEnd)
        }
        let romanizationWords = transliterationWords(transliteration?.main)
        let romanizationText = romanization ?? romanizationWords.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        lines.append(LyricLine(id: lines.count, start: start, end: end, words: words, translation: translation, romanization: romanizationText, romanizationWords: romanizationWords, singer: lineSinger, background: background, primaryStart: background == nil ? start : primaryStart, primaryEnd: background == nil ? end : primaryEnd, isParagraphStart: paragraphPending, agentIDs: lineAgentIDs))
        paragraphPending = false
    }

    /// Times placeholder syllables from their neighbours: a run of them ends where the next
    /// timed syllable starts and, like an echo, takes that syllable's length per syllable (the
    /// previous one's at the end of a line), never reaching back before the previous syllable.
    /// Without any timed syllable the run spreads over `fallback`.
    private static func retimePlaceholders(_ syllables: [LyricSyllable], at placeholders: Set<Int>, fallback: (start: TimeInterval, end: TimeInterval)) -> [LyricSyllable] {
        var result = syllables
        var i = 0
        while i < result.count {
            guard placeholders.contains(i) else { i += 1; continue }
            var j = i
            while j < result.count, placeholders.contains(j) { j += 1 }
            let count = Double(j - i)
            let previous = i > 0 ? result[i - 1] : nil
            let start: TimeInterval
            let end: TimeInterval
            if j < result.count {
                end = max(result[j].start, previous?.end ?? 0)
                start = max(previous?.end ?? 0, end - count * result[j].duration)
            } else if let previous {
                start = previous.end
                end = start + count * previous.duration
            } else {
                start = fallback.start
                end = max(fallback.start, fallback.end)
            }
            let step = (end - start) / count
            for k in i..<j {
                result[k].start = start + Double(k - i) * step
                result[k].end = result[k].start + step
                result[k].ruby = LyricRuby.spread(result[k].ruby.map(\.text), start: result[k].start, end: result[k].end)
            }
            i = j
        }
        return result
    }

    private func backgroundVocals(transliteration: [LyricWord]?) -> LyricBackgroundVocals? {
        let syllables = Self.retimePlaceholders(backgroundWords.flatMap(\.syllables), at: backgroundPlaceholders, fallback: backgroundSpan ?? (lineStart, lineEnd))
        var words = LyricWordGrouping.words(from: syllables)
        if words.isEmpty {
            guard !backgroundPlain.isEmpty else { return nil }
            words = [LyricWord(start: backgroundSpan?.start ?? lineStart, end: backgroundSpan?.end ?? lineEnd, text: backgroundPlain)]
        }
        if let last = words.last, last.text.hasSuffix(" ") {
            words[words.count - 1].text = String(last.text.dropLast())
            let n = words[words.count - 1].syllables.count
            words[words.count - 1].syllables[n - 1].text = String(words[words.count - 1].syllables[n - 1].text.dropLast())
        }
        let start = syllables.map(\.start).min() ?? backgroundSpan?.start ?? lineStart
        let end = syllables.map(\.end).max() ?? backgroundSpan?.end ?? lineEnd
        let romanization = backgroundRomanization ?? transliteration.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        return LyricBackgroundVocals(start: start, end: max(end, start), words: words, translation: backgroundTranslation, romanization: romanization, romanizationWords: transliteration, agentIDs: backgroundAgentIDs)
    }
}
