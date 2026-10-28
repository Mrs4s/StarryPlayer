import Foundation

public enum NicokaraParser: LyricsParser {
    public static let format: LyricsDocument.Format = .nicokara
    public static func parse(_ text: String) throws -> LyricsDocument { try source(text).document(format: format) }

    static func source(_ text: String) throws -> KaraokeTextSource {
        var source = KaraokeTextSource()
        var body: [String] = [], ruby: [String] = [], emoji: [String] = []
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("@"), let equal = line.firstIndex(of: "=") {
                let key = String(line[line.index(after: line.startIndex)..<equal])
                let value = String(line[line.index(after: equal)...])
                if key.range(of: #"^Ruby\d*$"#, options: .regularExpression) != nil { ruby.append(value) }
                else if key == "Emoji" {
                    emoji.append(value)
                    source.metadata["nicokara:Emoji\(emoji.count)"] = value
                }
                else {
                    let mapped = ["Title": "musicName", "Artist": "artists", "Album": "album", "TaggingBy": "by"][key] ?? "nicokara:\(key)"
                    source.metadata[mapped] = value
                }
            } else if line.range(of: #"^\[[A-Za-z]+:"#, options: .regularExpression) != nil, line.hasSuffix("]"), let colon = line.firstIndex(of: ":") {
                source.metadata[String(line[line.index(after: line.startIndex)..<colon]).lowercased()] = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
            } else { body.append(line) }
        }
        var performers: [String] = []
        for line in body {
            var row = KaraokeRow(agents: performers)
            let tokens = KaraokeText.matches(#"\[[^\]\r\n]*\]|【[^】\r\n]+】"#, in: line)
            var previous = line.startIndex
            var pending: TimeInterval?
            func append(_ content: Substring) {
                guard !content.isEmpty else { return }
                row.atoms.append(KaraokeAtom(text: String(content), start: pending, agents: performers))
                pending = nil
            }
            for token in tokens {
                append(line[previous..<token.range.lowerBound])
                if token.value.hasPrefix("【") {
                    performers = source.performers(String(token.value.dropFirst().dropLast()))
                    if row.atoms.isEmpty { row.agents = performers }
                } else if let beat = KaraokeText.beat(token.value), beat.count == nil, let time = beat.time {
                    if let pending, let last = row.atoms.indices.last { row.atoms[last].end = pending }
                    pending = time
                } else if token.value.range(of: #"^\[\d+:"#, options: .regularExpression) != nil {
                    throw LyricsParseError.malformed("无效的 Nicokara 时间标签：\(token.value)")
                } else { append(Substring(token.value)) }
                previous = token.range.upperBound
            }
            append(line[previous...])
            if let pending, let last = row.atoms.indices.last { row.atoms[last].end = pending; row.end = pending }
            if !row.atoms.isEmpty { source.rows.append(row) }
        }
        for entry in ruby { try applyRuby(entry, to: &source) }
        for value in emoji {
            for token in KaraokeText.matches(#"【[^】]+】"#, in: value) { _ = source.performers(String(token.value.dropFirst().dropLast())) }
        }
        return source
    }

    private static func applyRuby(_ value: String, to source: inout KaraokeTextSource) throws {
        var fields = value.components(separatedBy: ",")
        guard fields.count >= 2 else { throw LyricsParseError.malformed("Nicokara @Ruby 缺少原文或读音") }
        var positions: [TimeInterval?] = []
        while fields.count > 2, let last = fields.last {
            if last.isEmpty { positions.insert(nil, at: 0); fields.removeLast() }
            else if last.hasPrefix("["), let beat = KaraokeText.beat(last), let time = beat.time {
                positions.insert(time, at: 0); fields.removeLast()
            } else { break }
        }
        let base = fields.removeFirst()
        guard !base.isEmpty else { throw LyricsParseError.malformed("Nicokara @Ruby 原文为空") }
        let reading = try KaraokeText.layer(fields.joined(separator: ","))
        let lower = positions.first ?? nil
        let upper = positions.count > 1 ? positions[1] : nil
        for r in source.rows.indices {
            var index = 0
            while index < source.rows[r].atoms.count {
                var display = ""
                var end = index
                while end < source.rows[r].atoms.count {
                    display += source.rows[r].atoms[end].text
                    if display == base { break }
                    if !base.hasPrefix(display) { break }
                    end += 1
                }
                guard display == base, end < source.rows[r].atoms.count else { index += 1; continue }
                let atoms = Array(source.rows[r].atoms[index...end])
                let begin = atoms.compactMap(\.start).first
                if lower != nil || upper != nil {
                    guard let begin,
                          lower.map({ begin >= $0 - 0.011 }) ?? true,
                          upper.map({ begin < $0 - 0.001 }) ?? lower.map({ abs(begin - $0) <= 0.011 }) ?? true else { index += 1; continue }
                }
                guard atoms.allSatisfy({ $0.agents == atoms[0].agents }) else { throw LyricsParseError.unsupported("跨演唱者的 Nicokara 共享注音") }
                let finish = atoms.last?.end ?? (end + 1 < source.rows[r].atoms.count ? source.rows[r].atoms[end + 1].start : source.rows[r].end)
                var merged = atoms[0]
                merged.text = base
                merged.end = finish
                merged.ruby = reading.pieces.map { piece in
                    KaraokePiece(text: piece.text, start: begin.map { $0 + (piece.start ?? 0) }, end: piece.end.flatMap { offset in begin.map { $0 + offset } } ?? finish)
                }
                merged.checkpoints = merged.ruby.map(\.start)
                source.rows[r].atoms.replaceSubrange(index...end, with: [merged])
                index += 1
            }
        }
    }
}
