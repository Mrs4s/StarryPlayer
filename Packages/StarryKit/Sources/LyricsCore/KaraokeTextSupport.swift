import Foundation

struct KaraokePiece {
    var text: String
    var start: TimeInterval?
    var end: TimeInterval?
}

struct KaraokeAtom {
    var text: String
    var start: TimeInterval?
    var end: TimeInterval?
    var ruby: [KaraokePiece] = []
    var romanization: [KaraokePiece] = []
    var checkpoints: [TimeInterval?]?
    var agents: [String] = []
    var isRest = false
    var hasRelease = false
}

struct KaraokeRow {
    var atoms: [KaraokeAtom] = []
    var start: TimeInterval?
    var end: TimeInterval?
    var agents: [String] = []
    var wordTimed = true
}

struct KaraokeTextSource {
    var rows: [KaraokeRow] = []
    var agents: [LyricAgent] = []
    var metadata: [String: String] = [:]

    mutating func performers(_ label: String) -> [String] {
        let ids = label.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { name in
            if let agent = agents.first(where: { $0.displayName == name }) { return agent.id }
            var number = agents.count + 1
            while agents.contains(where: { $0.id == "v\(number)" }) { number += 1 }
            let id = "v\(number)"
            agents.append(LyricAgent(id: id, names: [.init(name)]))
            return id
        }
        return LyricAgent.references(ids)
    }

    func draft() throws -> LyricsDraft {
        var lines: [LyricsDraft.Line] = []
        for row in rows where !row.atoms.isEmpty {
            var syllables: [LyricsDraft.Syllable] = []
            var romaji: [KaraokePiece] = []
            for (index, atom) in row.atoms.enumerated() {
                let next = row.atoms.dropFirst(index + 1).compactMap(\.start).first
                let end = atom.end ?? next ?? row.end
                if let start = atom.start, let end, end < start { throw LyricsParseError.malformed("歌词单元的结束时间早于开始时间") }
                let ruby = atom.ruby.map { piece -> LyricsDraft.Ruby in
                    guard let start = atom.start, let end, end > start, let begin = piece.start else { return .init(text: piece.text) }
                    return .init(text: piece.text, span: LyricsDraft.Ruby.clamped((begin - start) / (end - start), ((piece.end ?? end) - start) / (end - start)))
                }
                let checkpoints = atom.checkpoints?.map { time -> TimeInterval? in
                    guard let time, let start = atom.start else { return nil }
                    return time - start
                }
                syllables.append(.init(text: atom.isRest ? "▨" : atom.text, start: row.wordTimed ? atom.start : nil, end: row.wordTimed ? end : nil,
                                       ruby: ruby.isEmpty ? nil : ruby, agentIDs: atom.agents == row.agents ? [] : atom.agents,
                                       checkpoints: checkpoints, isRest: atom.isRest, hasRelease: atom.hasRelease))
                for piece in atom.romanization where !piece.text.isEmpty {
                    romaji.append(KaraokePiece(text: piece.text, start: piece.start ?? atom.start, end: piece.end ?? end))
                }
            }
            var line = LyricsDraft.Line(syllables: syllables, singer: LyricAgent.singer(for: row.agents, in: agents), isParagraphStart: lines.isEmpty,
                                        start: row.start ?? row.atoms.compactMap(\.start).min(), end: row.end, agentIDs: row.agents)
            line.romanization = row.atoms.flatMap(\.romanization).map(\.text).joined()
            if romaji.contains(where: { $0.start != nil }) {
                let start = row.atoms.compactMap(\.start).min() ?? row.start ?? romaji.compactMap(\.start).min() ?? 0
                line.romanizationTiming = romaji.map {
                    .init(text: $0.text, start: ($0.start ?? start) - start, end: $0.end.map { $0 - start })
                }
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        return LyricsDraft(lines: lines, metadata: metadata, agents: agents)
    }

    func document(format: LyricsDocument.Format) throws -> LyricsDocument {
        var draft = try draft()
        guard draft.lines.contains(where: { $0.timedRange != nil }) else { throw LyricsParseError.empty }
        // Playback needs a tail past the last beat even when the release is still untimed.
        for l in draft.lines.indices {
            for s in draft.lines[l].syllables.indices where draft.lines[l].syllables[s].end == nil {
                let syllable = draft.lines[l].syllables[s]
                if let start = syllable.start, let last = syllable.checkpoints?.compactMap({ $0 }).max(), last > 0 {
                    draft.lines[l].syllables[s].end = start + last + 5
                }
            }
        }
        var document = draft.document()
        document.format = format
        document.lines.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        document.lines = document.lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        for index in document.lines.indices { document.lines[index].id = index }
        guard !document.lines.isEmpty else { throw LyricsParseError.empty }
        return document
    }
}

enum KaraokeText {
    struct Token {
        var range: Range<String.Index>
        var value: String
    }

    static func matches(_ pattern: String, in text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return Token(range: range, value: String(text[range]))
        }
    }

    static func time(_ text: String) -> TimeInterval? { LRCParser.parseTimestamp(Substring(text)) }

    static func timestamp(_ time: TimeInterval) throws -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max / 100) else { throw LyricsParseError.malformed("无效的歌词时间") }
        let cs = Int64((time * 100).rounded())
        return String(format: "%02lld:%02lld:%02lld", cs / 6000, cs / 100 % 60, cs % 100)
    }

    struct Beat {
        var count: Int?
        var time: TimeInterval?
        var release: Bool
    }

    static func beat(_ raw: String) -> Beat? {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        let value = String(raw.dropFirst().dropLast())
        if let time = time(value) { return Beat(time: time, release: false) }
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let n = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "e"))
        guard !n.isEmpty, n.allSatisfy(\.isNumber), let number = Int(n), number <= 990 else { return nil }
        let release = n.count > 1 && n.hasSuffix("0")
        let count = release ? number / 10 : number
        guard count <= 99 else { return nil }
        let stamp = parts.count == 2 ? time(String(parts[1])) : nil
        if parts.count == 2, stamp == nil { return nil }
        return Beat(count: count, time: stamp, release: release)
    }

    static func layer(_ text: String, rl: Bool = false) throws -> (pieces: [KaraokePiece], checkpoints: [TimeInterval?]?, release: TimeInterval?, hasRelease: Bool) {
        let tokens = matches(#"\[[^\]\r\n]+\]"#, in: text)
        if tokens.isEmpty { return (text.isEmpty ? [] : [KaraokePiece(text: text)], nil, nil, false) }
        var pieces: [KaraokePiece] = []
        var checkpoints: [TimeInterval?] = []
        var count: Int?
        var release: TimeInterval?
        var hasRelease = false
        if let first = tokens.first, first.range.lowerBound > text.startIndex { pieces.append(KaraokePiece(text: String(text[..<first.range.lowerBound]))) }
        for (index, token) in tokens.enumerated() {
            guard let beat = beat(token.value) else { throw LyricsParseError.malformed("无效的注音时间标签：\(token.value)") }
            let end = index + 1 < tokens.count ? tokens[index + 1].range.lowerBound : text.endIndex
            let content = String(text[token.range.upperBound..<end])
            if count == nil { count = beat.count }
            if content.isEmpty, index == tokens.count - 1, !pieces.isEmpty, (!rl && beat.count == nil) || beat.release {
                release = beat.time
                hasRelease = true
                if let last = pieces.indices.last { pieces[last].end = release }
                continue
            }
            if beat.release, content.isEmpty { release = beat.time; hasRelease = true; continue }
            if let previous = pieces.indices.last { pieces[previous].end = beat.time }
            pieces.append(KaraokePiece(text: content, start: beat.time))
            checkpoints.append(beat.time)
        }
        if count == 0 {
            checkpoints = []
        } else if let count, count > pieces.count, let last = pieces.last {
            let required = count - pieces.count + 1
            let moras = moraPieces(last.text, count: required)
            let tail = moras.enumerated().map { index, text in
                KaraokePiece(text: text, start: index == 0 ? last.start : nil, end: index == required - 1 ? last.end : nil)
            }
            pieces.replaceSubrange((pieces.count - 1)..., with: tail)
            checkpoints += Array(repeating: nil, count: max(0, count - checkpoints.count))
        } else if let count, checkpoints.count < count {
            checkpoints += Array(repeating: nil, count: count - checkpoints.count)
        }
        let known = checkpoints.compactMap { $0 }
        guard zip(known, known.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw LyricsParseError.malformed("注音节奏点的时间顺序无效") }
        if let release, let last = known.last, release < last { throw LyricsParseError.malformed("注音结束时间早于最后一个节奏点") }
        return (pieces, checkpoints, release, hasRelease)
    }

    static func moraPieces(_ text: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var moras: [String] = []
        for character in text {
            if "ゃゅょぁぃぅぇぉャュョァィゥェォ".contains(character), !moras.isEmpty { moras[moras.count - 1].append(character) }
            else { moras.append(String(character)) }
        }
        var result = Array(repeating: "", count: count)
        for (index, mora) in moras.enumerated() { result[min(index, count - 1)] += mora }
        return result
    }

    static func withoutConfig(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}")))
        guard text.range(of: #"(?i)^config\s*\{"#, options: .regularExpression) != nil,
              let open = text.firstIndex(of: "{") else { return text }
        var depth = 0, quoted = false, escaped = false
        for index in text.indices where index >= open {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return String(text[text.index(after: index)...]) }
            }
        }
        throw LyricsParseError.malformed("KRL 的 config 配置块未闭合")
    }
}

extension LyricsParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty: "没有可用的歌词"
        case .malformed(let reason): reason
        case .unsupported(let reason): "此格式无法表示：\(reason)"
        }
    }
}
