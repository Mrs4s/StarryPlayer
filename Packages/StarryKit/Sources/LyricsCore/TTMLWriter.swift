import Foundation

public enum TTMLWriter {
    public enum Format: Sendable, Equatable {
        case amll, ttml2
    }

    /// `metadata`: `amll:meta` entries in order (a key may repeat, as `artists` does); nil writes
    /// the document's own, sorted by key. `duration` is the song's length for `<body dur>`.
    /// Ruby defaults to AMLL's representation; `.ttml2` uses the TTML2 base/text content model.
    public static func write(_ document: LyricsDocument, metadata: [(key: String, value: String)]? = nil, duration: TimeInterval? = nil,
                             translationLanguage: String? = nil, format: Format = .amll) -> String {
        let lines = document.lines.filter { !$0.words.isEmpty }
        let agents = Agents(document: document, lines: lines)
        let styling = document.hasRuby ? #" xmlns:tts="http://www.w3.org/ns/ttml#styling""# : ""
        let grouped = format == .amll && lines.contains { line in
            !LyricRubyGroup.groups(in: line.syllables).isEmpty || !LyricRubyGroup.groups(in: line.background?.syllables ?? []).isEmpty
        }
        let sharedRuby = grouped ? #" xmlns:ttx="\#(LyricRubyGroup.namespace)""# : ""
        let vocalistStyle = agents.usesStyle ? #" xmlns:ttv="\#(LyricAgent.styleNamespace)""# : ""
        let displayPosition = agents.separatesPosition ? #" xmlns:ttd="\#(LyricSinger.positionNamespace)""# : ""
        var out = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"\#(styling)\#(sharedRuby)\#(vocalistStyle)\#(displayPosition)>"#
        out += "<head><metadata>"
        out += agents.declarations
        for entry in metadata ?? document.metadata.sorted(by: { $0.key < $1.key }).map({ ($0.key, $0.value) }) where !entry.value.isEmpty {
            out += #"<amll:meta key="\#(escape(entry.key))" value="\#(escape(entry.value))"/>"#
        }
        if lines.contains(where: { $0.romanizationWords != nil || $0.background?.romanizationWords != nil }) {
            out += #"<iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><transliterations><transliteration xml:lang="und-Latn">"#
            for (index, line) in lines.enumerated() where line.romanizationWords != nil || line.background?.romanizationWords != nil {
                var groups = 0
                out += #"<text for="L\#(index + 1)">"#
                if let words = line.romanizationWords { out += spans(words, agents: agents, format: format, groups: &groups) }
                if let words = line.background?.romanizationWords {
                    out += #"<span ttm:role="x-bg">"# + spans(words, agents: agents, format: format, groups: &groups) + "</span>"
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
                out += #"<p begin="\#(timestamp(line.start))" end="\#(timestamp(line.end))"\#(agents.lineAttributes(line)) itunes:key="L\#(key)">"#
                var groups = 0
                out += spans(line.words, agents: agents, format: format, groups: &groups)
                if let background = line.background, !background.words.isEmpty {
                    out += #"<span ttm:role="x-bg" begin="\#(timestamp(background.start))" end="\#(timestamp(background.end))"\#(agents.attribute(background.agentIDs))>"#
                    out += spans(background.words, agents: agents, format: format, groups: &groups)
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
        var positions: [(singer: LyricSinger, id: String)] = []

        var separatesPosition: Bool { !positions.isEmpty }

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
            let separatesPosition = !entries.isEmpty
            for (singer, preferred) in [(LyricSinger.primary, "v1"), (.secondary, "v2"), (.duet, "v1000")] {
                if separatesPosition { continue }
                guard singer == .primary || lines.contains(where: { $0.singer == singer }) else { continue }
                var id = preferred
                var suffix = 2
                while seen.contains(id) { id = "\(preferred)_\(suffix)"; suffix += 1 }
                include(LyricAgent(id: id, kind: singer == .duet ? .group : singer == .secondary ? .other : .person))
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
            if separatesPosition {
                // AMLL derives positions from paragraph agents; preserve performers in ttd:agents.
                // A leading person anchors older parsers; `other` also starts right in AMLL 2.
                for (singer, preferred) in [(LyricSinger.primary, "v1"), (.secondary, "v2"), (.duet, "v1000")] {
                    guard singer == .primary || lines.contains(where: { $0.singer == singer }) else { continue }
                    var id = preferred
                    var suffix = 2
                    while reserved.contains(id) { id = "\(preferred)_\(suffix)"; suffix += 1 }
                    reserved.insert(id)
                    positions.append((singer, id))
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

        var usesStyle: Bool { entries.contains { !style(of: $0).isEmpty } }

        func style(of entry: LyricAgent) -> String {
            var out = entry.color.map { #" ttv:color="\#($0.hex)""# } ?? ""
            let members = entry.kind == .group ? LyricAgent.references(entry.memberIDs).compactMap { xmlIDs[$0] } : []
            if !members.isEmpty { out += #" ttv:members="\#(escape(members.joined(separator: " ")))""# }
            return out
        }

        func attribute(_ ids: [String]) -> String {
            let ids = LyricAgent.references(ids).compactMap { xmlIDs[$0] }
            return ids.isEmpty ? "" : #" ttm:agent="\#(escape(ids.joined(separator: " ")))""#
        }

        func lineAttributes(_ line: LyricLine) -> String {
            if let position = positions.first(where: { $0.singer == line.singer }) {
                let ids = LyricAgent.references(line.agentIDs).compactMap { xmlIDs[$0] }
                return #" ttm:agent="\#(position.id)" ttd:agents="\#(escape(ids.joined(separator: " ")))""#
            }
            let ids = line.agentIDs.isEmpty ? fallbacks[line.singer].map { [$0] } ?? [] : line.agentIDs
            return attribute(ids)
        }

        var declarations: String {
            let display = positions.map { position in
                let kind: LyricAgent.Kind = position.singer == .duet ? .group : position.singer == .secondary ? .other : .person
                return #"<ttm:agent type="\#(kind.rawValue)" xml:id="\#(position.id)" ttd:position="\#(position.singer.rawValue)"/>"#
            }.joined()
            return display + entries.map { entry in
                var out = #"<ttm:agent type="\#(entry.kind.rawValue)" xml:id="\#(escape(xmlIDs[entry.id]!))""# + style(of: entry)
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

    private static func spans(_ words: [LyricWord], agents: Agents, format: Format, groups: inout Int) -> String {
        switch format {
        case .amll: amllSpans(words, agents: agents, groups: &groups)
        case .ttml2: ttml2Spans(words, agents: agents)
        }
    }

    // One base/text pair avoids ambiguity when syllable and reading counts differ.
    private static func ttml2Spans(_ words: [LyricWord], agents: Agents) -> String {
        let syllables = words.flatMap(\.syllables)
        func written(_ index: Int) -> Bool { !syllables[index].text.trimmingCharacters(in: .whitespaces).isEmpty }
        let annotations = Dictionary(uniqueKeysWithValues: LyricRubyGroup.annotations(in: syllables).compactMap { annotation -> (Int, LyricRubyGroup)? in
            var annotation = annotation
            annotation.ruby = annotation.ruby.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !annotation.ruby.isEmpty, annotation.syllables.contains(where: written) else { return nil }
            return (annotation.syllables.lowerBound, annotation)
        })
        var breaks: Set<Int> = []
        var offset = 0
        for (index, word) in words.enumerated() {
            offset += word.syllables.count
            if offset > 0, index < words.count - 1, word.text.last?.isWhitespace == true { breaks.insert(offset - 1) }
        }
        func plain(_ syllable: LyricSyllable) -> String {
            let text = syllable.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return "" }
            return #"<span \#(times(syllable.start, syllable.end))\#(agents.attribute(syllable.agentIDs))>\#(escape(text))</span>"#
        }
        var out = "", position = 0
        while position < syllables.count {
            let last: Int
            if let annotation = annotations[position] {
                last = annotation.syllables.upperBound
                let members = annotation.syllables.filter(written)
                let first = syllables[members[0]]
                if members.count == 1 {
                    out += #"<span tts:ruby="container"\#(agents.attribute(first.agentIDs))><span tts:ruby="base" \#(times(first.start, first.end))>\#(escape(first.text.trimmingCharacters(in: .whitespaces)))</span>"#
                } else {
                    out += #"<span tts:ruby="container"><span tts:ruby="base">"#
                    for member in annotation.syllables {
                        out += plain(syllables[member])
                        if member < last, breaks.contains(member) { out += " " }
                    }
                    out += "</span>"
                }
                out += rubyText(annotation.ruby) + "</span>"
            } else {
                last = position
                out += plain(syllables[position])
            }
            if breaks.contains(last) { out += " " }
            position = last + 1
        }
        return out
    }

    private static func amllSpans(_ words: [LyricWord], agents: Agents, groups: inout Int) -> String {
        let syllables = words.flatMap(\.syllables)
        func written(_ index: Int) -> Bool { !syllables[index].text.trimmingCharacters(in: .whitespaces).isEmpty }
        var shared: [Int: String] = [:]
        var own: [Int: [LyricRuby]] = [:]
        for group in LyricRubyGroup.groups(in: syllables) {
            let ruby = group.ruby.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let members = group.syllables.filter(written)
            guard let first = members.first, !ruby.isEmpty else { continue }
            guard members.count > 1 else {
                own[first] = ruby
                continue
            }
            groups += 1
            for member in members { shared[member] = #" ttx:rubyGroup="\#(groups)""# }
            let stamps = ruby.map { "\(timestamp($0.start)),\(timestamp(max($0.end, $0.start)))" }.joined(separator: " ")
            shared[first, default: ""] += #" ttx:rubyText="\#(escape(LyricRubyGroup.encode(ruby.map(\.text))))" ttx:rubyTimes="\#(stamps)""#
        }
        var out = ""
        var position = 0
        for (index, word) in words.enumerated() {
            for syllable in word.syllables {
                defer { position += 1 }
                let text = syllable.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if let attributes = shared[position] {
                    out += #"<span \#(times(syllable.start, syllable.end))\#(agents.attribute(syllable.agentIDs))\#(attributes)>\#(escape(text))</span>"#
                    continue
                }
                let ruby = (own[position] ?? syllable.ruby).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
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

    private static func rubyText(_ ruby: [LyricRuby]) -> String {
        if ruby.count == 1, let piece = ruby.first {
            return #"<span tts:ruby="text" \#(times(piece.start, piece.end))>\#(escape(piece.text.trimmingCharacters(in: .whitespaces)))</span>"#
        }
        var out = #"<span tts:ruby="text">"#
        for (index, piece) in ruby.enumerated() {
            var text = piece.text.trimmingCharacters(in: .whitespaces)
            if index < ruby.count - 1, piece.text.last?.isWhitespace == true { text += " " }
            out += #"<span \#(times(piece.start, piece.end))>\#(escape(text))</span>"#
        }
        return out + "</span>"
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
