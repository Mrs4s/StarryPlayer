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
        var document = try parser(for: format).parse(body)
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
            let timed = extra.format != .lrc
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
        let head = text.prefix(4096)
        if head.contains("<QrcInfos") || head.contains("LyricContent=") { return .qrc }
        if head.contains("<tt ") || head.contains("<tt>") || head.contains("<tt\n") { return .ttml }
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsParseError.empty }
        var metadata: [String: String] = [:]
        var stamped: [(TimeInterval, String)] = []

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            var times: [TimeInterval] = []
            var rest = Substring(line)
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = parseTimestamp(tag) {
                    times.append(time)
                } else if let colon = tag.firstIndex(of: ":") {
                    metadata[String(tag[..<colon])] = String(tag[tag.index(after: colon)...])
                }
            }
            let content = rest.trimmingCharacters(in: .whitespaces)
            for time in times { stamped.append((time, content)) }
        }

        stamped.sort { $0.0 < $1.0 }
        let lines = stamped.enumerated().map { index, entry in
            let end = index + 1 < stamped.count ? stamped[index + 1].0 : entry.0 + 5
            return LyricLine.plain(id: index, start: entry.0, end: end, text: entry.1)
        }
        return LyricsDocument(format: .lrc, lines: lines, metadata: metadata)
    }

    static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
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

/// AMLL TTML parser with syllables, singers, background vocals and timed romanization.
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
        for i in lines.indices { lines[i].id = i }
        var document = LyricsDocument(format: .ttml, lines: lines, metadata: delegate.metadata)
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

    private var agents: [String] = []          // xml:id in declaration order
    private var agentTypes: [String: String] = [:]
    private var paragraphPending = false

    private var inParagraph = false
    private var lineStart: TimeInterval = 0
    private var lineEnd: TimeInterval = 0
    private var lineSinger: LyricSinger = .primary
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

    private enum SpanKind { case syllable(start: TimeInterval, end: TimeInterval), placeholder, background, translation, roman, other }
    private var spanStack: [SpanKind] = []
    private var spanText = ""
    private var pendingWordBreak = false
    private var inBackground: Bool { spanStack.contains { if case .background = $0 { return true } else { return false } } }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "agent":
            if let id = attributes["xml:id"] {
                agents.append(id)
                agentTypes[id] = attributes["type"] ?? "person"
            }
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
            let agent = attributes["ttm:agent"] ?? attributes["agent"]
            if let agent, let index = agents.firstIndex(of: agent), index > 0 {
                lineSinger = agentTypes[agent] == "group" ? .duet : .secondary
            } else {
                lineSinger = .primary
            }
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
            mainPlaceholders = []
            backgroundPlaceholders = []
            mainTimed = false
            spanStack = []
            spanText = ""
            pendingWordBreak = false
        case "span":
            guard inParagraph else { return }
            flushLooseText()
            if let top = spanStack.last, case .background = top, !spanText.isEmpty {
                appendSyllable(text: spanText, start: nil, end: nil)
                spanText = ""
            }
            let role = attributes["ttm:role"] ?? attributes["role"] ?? ""
            let kind: SpanKind
            switch role {
            case "x-bg":
                kind = .background
                if let b = attributes["begin"].flatMap(TTMLParser.parseTime) {
                    let e = attributes["end"].flatMap(TTMLParser.parseTime) ?? b
                    if !isPlaceholder(begin: b, end: e) { backgroundSpan = (b, max(b, e)) }
                }
            case "x-translation": kind = .translation
            case "x-roman": kind = .roman
            default:
                if let b = attributes["begin"].flatMap(TTMLParser.parseTime) {
                    let e = attributes["end"].flatMap(TTMLParser.parseTime) ?? b
                    kind = isPlaceholder(begin: b, end: e) ? .placeholder : .syllable(start: b, end: e)
                } else {
                    kind = .other
                }
            }
            spanStack.append(kind)
            spanText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
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
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
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
                if !text.isEmpty { appendSyllable(text: text, start: nil, end: nil) }
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

    private func appendSyllable(text rawText: String, start: TimeInterval?, end: TimeInterval?, placeholder: Bool = false) {
        let text = rawText.replacingOccurrences(of: "\n", with: "")
        guard !text.isEmpty else { return }
        let bg = inBackground
        let s = start ?? (bg ? (backgroundEnd ?? backgroundSpan?.start ?? lineStart) : (mainWords.last?.end ?? lineStart))
        let e = end ?? (bg && start == nil && !placeholder ? max(s, backgroundSpan?.end ?? s) : s)
        let syllable = LyricSyllable(start: s, end: e, text: text)
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
        lines.append(LyricLine(id: lines.count, start: start, end: end, words: words, translation: translation, romanization: romanizationText, romanizationWords: romanizationWords, singer: lineSinger, background: background, primaryStart: background == nil ? start : primaryStart, primaryEnd: background == nil ? end : primaryEnd, isParagraphStart: paragraphPending))
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
        return LyricBackgroundVocals(start: start, end: max(end, start), words: words, translation: backgroundTranslation, romanization: romanization, romanizationWords: transliteration)
    }
}
