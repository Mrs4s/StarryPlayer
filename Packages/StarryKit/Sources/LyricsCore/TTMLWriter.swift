import Foundation

public enum TTMLWriter {
    /// `metadata`: `amll:meta` entries in order (a key may repeat, as `artists` does); nil writes
    /// the document's own, sorted by key. `duration` is the song's length for `<body dur>`.
    public static func write(_ document: LyricsDocument, metadata: [(key: String, value: String)]? = nil, duration: TimeInterval? = nil, translationLanguage: String? = nil) -> String {
        let lines = document.lines.filter { !$0.words.isEmpty }
        let agents = Agents(document: document, lines: lines)
        let styling = document.hasRuby ? #" xmlns:tts="http://www.w3.org/ns/ttml#styling""# : ""
        var out = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"\#(styling)>"#
        out += "<head><metadata>"
        out += agents.declarations
        for entry in metadata ?? document.metadata.sorted(by: { $0.key < $1.key }).map({ ($0.key, $0.value) }) where !entry.value.isEmpty {
            out += #"<amll:meta key="\#(escape(entry.key))" value="\#(escape(entry.value))"/>"#
        }
        if lines.contains(where: { $0.romanizationWords != nil || $0.background?.romanizationWords != nil }) {
            out += #"<iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><transliterations><transliteration xml:lang="und-Latn">"#
            for (index, line) in lines.enumerated() where line.romanizationWords != nil || line.background?.romanizationWords != nil {
                out += #"<text for="L\#(index + 1)">"#
                if let words = line.romanizationWords { out += spans(words, agents: agents) }
                if let words = line.background?.romanizationWords {
                    out += #"<span ttm:role="x-bg">"# + spans(words, agents: agents) + "</span>"
                }
                out += "</text>"
            }
            out += "</transliteration></transliterations></iTunesMetadata>"
        }
        out += "</metadata></head>"
        let end = max(lines.map(\.end).max() ?? 0, duration ?? 0)
        out += #"<body dur="\#(timestamp(end))">"#
        var paragraphs: [[LyricLine]] = []
        for line in lines {
            if line.isParagraphStart || paragraphs.isEmpty { paragraphs.append([line]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        var key = 0
        for paragraph in paragraphs {
            out += #"<div begin="\#(timestamp(paragraph.map(\.start).min() ?? 0))" end="\#(timestamp(paragraph.map(\.end).max() ?? 0))">"#
            for line in paragraph {
                key += 1
                let ids = line.agentIDs.isEmpty ? agents.fallbacks[line.singer].map { [$0] } ?? [] : line.agentIDs
                out += #"<p begin="\#(timestamp(line.start))" end="\#(timestamp(line.end))"\#(agents.attribute(ids)) itunes:key="L\#(key)">"#
                out += spans(line.words, agents: agents)
                if let background = line.background, !background.words.isEmpty {
                    out += #"<span ttm:role="x-bg" begin="\#(timestamp(background.start))" end="\#(timestamp(background.end))"\#(agents.attribute(background.agentIDs))>"#
                    out += spans(background.words, agents: agents)
                    out += extras(translation: background.translation, romanization: background.romanization, language: translationLanguage)
                    out += "</span>"
                }
                out += extras(translation: line.translation, romanization: line.romanization, language: translationLanguage)
                out += "</p>"
            }
            out += "</div>"
        }
        out += "</body></tt>"
        return out
    }

    private struct Agents {
        var entries: [LyricAgent] = []
        var xmlIDs: [String: String] = [:]
        var fallbacks: [LyricSinger: String] = [:]

        init(document: LyricsDocument, lines: [LyricLine]) {
            var seen: Set<String> = []
            func include(_ agent: LyricAgent) {
                if !agent.id.isEmpty, seen.insert(agent.id).inserted { entries.append(agent) }
            }
            for agent in document.agents { include(agent) }
            let actorIDs = entries.compactMap(\.actorID)
            var references = actorIDs
            for line in lines {
                references += line.agentIDs + line.syllables.flatMap(\.agentIDs)
                if let background = line.background { references += background.agentIDs + background.syllables.flatMap(\.agentIDs) }
            }
            for id in references { include(LyricAgent(id: id)) }
            for (singer, preferred) in [(LyricSinger.primary, "v1"), (.secondary, "v2"), (.duet, "v1000")] {
                if singer == .primary, !document.agents.isEmpty { continue }
                guard (singer == .primary && document.agents.isEmpty) || lines.contains(where: { $0.agentIDs.isEmpty && $0.singer == singer }) else { continue }
                var id = preferred
                var suffix = 2
                while seen.contains(id) { id = "\(preferred)_\(suffix)"; suffix += 1 }
                include(LyricAgent(id: id, kind: singer == .duet ? .group : .person))
                fallbacks[singer] = id
            }
            var reserved = Set(entries.map(\.id).filter(Self.isXMLID))
            var next = 1
            for entry in entries {
                if Self.isXMLID(entry.id) {
                    xmlIDs[entry.id] = entry.id
                } else {
                    var id = "agent\(next)"
                    while reserved.contains(id) { next += 1; id = "agent\(next)" }
                    reserved.insert(id)
                    xmlIDs[entry.id] = id
                    next += 1
                }
            }
        }

        private static func isXMLID(_ id: String) -> Bool {
            // XML 1.0 NCName ranges (NameStartChar without ':', followed by NameChar).
            func isStart(_ value: UInt32) -> Bool {
                value == 0x5F || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
                    || (0xC0...0xD6).contains(value) || (0xD8...0xF6).contains(value)
                    || (0xF8...0x2FF).contains(value) || (0x370...0x37D).contains(value)
                    || (0x37F...0x1FFF).contains(value) || (0x200C...0x200D).contains(value)
                    || (0x2070...0x218F).contains(value) || (0x2C00...0x2FEF).contains(value)
                    || (0x3001...0xD7FF).contains(value) || (0xF900...0xFDCF).contains(value)
                    || (0xFDF0...0xFFFD).contains(value) || (0x10000...0xEFFFF).contains(value)
            }
            guard let first = id.unicodeScalars.first, isStart(first.value) else { return false }
            return id.unicodeScalars.dropFirst().allSatisfy {
                isStart($0.value) || (0x30...0x39).contains($0.value) || $0.value == 0x2D || $0.value == 0x2E
                    || $0.value == 0xB7 || (0x300...0x36F).contains($0.value) || (0x203F...0x2040).contains($0.value)
            }
        }

        func attribute(_ ids: [String]) -> String {
            let ids = LyricAgent.references(ids).compactMap { xmlIDs[$0] }
            return ids.isEmpty ? "" : #" ttm:agent="\#(escape(ids.joined(separator: " ")))""#
        }

        var declarations: String {
            entries.map { entry in
                var out = #"<ttm:agent type="\#(entry.kind.rawValue)" xml:id="\#(escape(xmlIDs[entry.id]!))""#
                if entry.names.isEmpty && entry.actorID == nil { return out + "/>" }
                out += ">"
                for name in entry.names {
                    let language = name.language.map { #" xml:lang="\#(escape($0))""# } ?? ""
                    out += #"<ttm:name type="\#(name.kind.rawValue)"\#(language)>\#(escape(name.text))</ttm:name>"#
                }
                if let actor = entry.actorID.flatMap({ xmlIDs[$0] }) { out += #"<ttm:actor agent="\#(escape(actor))"/>"# }
                return out + "</ttm:agent>"
            }.joined()
        }
    }

    /// A syllable span each; a word's trailing space goes between the spans, where the parser
    /// reads it as a word break.
    private static func spans(_ words: [LyricWord], agents: Agents) -> String {
        var out = ""
        for (index, word) in words.enumerated() {
            for syllable in word.syllables {
                let text = syllable.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let ruby = syllable.ruby.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                if ruby.isEmpty {
                    out += #"<span \#(times(syllable.start, syllable.end))\#(agents.attribute(syllable.agentIDs))>\#(escape(text))</span>"#
                } else {
                    // Ruby may cover only part of the base syllable's duration.
                    let timing = ruby.map(\.start).min() == syllable.start && ruby.map(\.end).max() == syllable.end
                        ? "" : " " + times(syllable.start, syllable.end)
                    out += #"<span tts:ruby="container"\#(timing)\#(agents.attribute(syllable.agentIDs))><span tts:ruby="base">\#(escape(text))</span><span tts:ruby="textContainer">"#
                    for r in ruby {
                        out += #"<span tts:ruby="text" \#(times(r.start, r.end))>\#(escape(r.text.trimmingCharacters(in: .whitespaces)))</span>"#
                    }
                    out += "</span></span>"
                }
            }
            if index < words.count - 1, word.text.last?.isWhitespace == true { out += " " }
        }
        return out
    }

    private static func times(_ start: TimeInterval, _ end: TimeInterval) -> String {
        // A zero-length span at 0 would read as an unset placeholder.
        let end = start <= 0 && end <= 0 ? 0.001 : end
        return #"begin="\#(timestamp(start))" end="\#(timestamp(max(end, start)))""#
    }

    private static func extras(translation: String?, romanization: String?, language: String?) -> String {
        var out = ""
        if let translation, !translation.isEmpty {
            let lang = language.map { #" xml:lang="\#(escape($0))""# } ?? ""
            out += #"<span ttm:role="x-translation"\#(lang)>\#(escape(translation))</span>"#
        }
        if let romanization, !romanization.isEmpty {
            out += #"<span ttm:role="x-roman">\#(escape(romanization))</span>"#
        }
        return out
    }

    public static func timestamp(_ time: TimeInterval) -> String {
        let ms = Int((max(time, 0) * 1000).rounded())
        let hours = ms / 3_600_000
        let minutes = ms / 60_000 % 60
        let seconds = ms / 1000 % 60
        let millis = ms % 1000
        if hours > 0 { return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, millis) }
        return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r": out += " "
            default: out.append(character)
            }
        }
        return out
    }
}
