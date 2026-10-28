import Foundation

/// Reads text and timing; subtitle styles and template effects are ignored.
public enum ASSParser: LyricsParser {
    public static let format: LyricsDocument.Format = .ass
    public static func parse(_ text: String) throws -> LyricsDocument { try source(text).document(format: format) }

    static func source(_ text: String) throws -> KaraokeTextSource {
        var source = KaraokeTextSource()
        var section = ""
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var sug = false
        var preRoll = 0.0
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") { section = line.lowercased(); continue }
            if section == "[script info]" {
                if line.range(of: #"(?i)^;\s*Generator:\s*StrangeUtaGame\s*$"#, options: .regularExpression) != nil { sug = true }
                if let token = KaraokeText.matches(#"(?i)^;\s*SUG-PreRollMs:\s*\d+"#, in: line).first,
                   let value = token.value.split(separator: ":").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), value.isFinite { preRoll = value / 1000 }
                if line.lowercased().hasPrefix("title:") { source.metadata["musicName"] = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            }
            guard section == "[events]" else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            guard fields.last == "text", fields.contains("start"), fields.contains("end") else { throw LyricsParseError.unsupported("ASS Events 的 Text 必须是最后一个字段") }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count else { throw LyricsParseError.malformed("ASS Dialogue 字段数量不正确") }
            let entry = Dictionary(zip(fields, values), uniquingKeysWith: { first, _ in first })
            guard let begin = entry["start"].flatMap(time), let end = entry["end"].flatMap(time), end >= begin else { throw LyricsParseError.malformed("ASS Dialogue 的起止时间无效") }
            let start = begin + (sug ? preRoll : 0)
            let name = (entry["name"] ?? entry["actor"] ?? "").trimmingCharacters(in: .whitespaces)
            let ids = name.isEmpty ? [] : source.performers(name)
            let body = entry["text"] ?? ""
            let blocks = KaraokeText.matches(#"\{[^{}]*\}"#, in: body)
            var row = KaraokeRow(start: start, end: end, agents: ids, wordTimed: false)
            var cursor = start
            var duration: Double?
            var buffer = ""
            var currentIDs = ids, segmentIDs = ids
            var drawing = false
            func flush() throws {
                let text = buffer.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: "\u{00A0}")
                buffer = ""
                guard let duration else {
                    if !text.isEmpty { row.atoms.append(KaraokeAtom(text: text, agents: segmentIDs)) }
                    return
                }
                let finish = ((cursor * 1000).rounded() + (duration * 1000).rounded()) / 1000
                guard finish.isFinite else { throw LyricsParseError.malformed("ASS 卡拉 OK 时长无效") }
                if text.isEmpty {
                    if let last = row.atoms.indices.last { row.atoms[last].end = min(row.atoms[last].end ?? cursor, cursor) }
                } else if let pipe = text.firstIndex(of: "|") {
                    let base = String(text[..<pipe])
                    var reading = String(text[text.index(after: pipe)...])
                    if reading.hasPrefix("<") { reading.removeFirst() }
                    let piece = KaraokePiece(text: reading, start: cursor, end: finish)
                    if base == "#", let last = row.atoms.indices.last {
                        row.atoms[last].ruby.append(piece)
                        row.atoms[last].checkpoints = (row.atoms[last].checkpoints ?? [row.atoms[last].start]) + [cursor]
                        row.atoms[last].end = finish
                    } else if !base.isEmpty {
                        row.atoms.append(KaraokeAtom(text: base, start: cursor, end: finish, ruby: [piece], checkpoints: [cursor], agents: segmentIDs))
                    }
                } else {
                    row.atoms.append(KaraokeAtom(text: text, start: cursor, end: finish, checkpoints: [cursor], agents: segmentIDs))
                }
                cursor = finish
            }
            var previous = body.startIndex
            for block in blocks {
                if !drawing { buffer += body[previous..<block.range.lowerBound] }
                let karaoke = KaraokeText.matches(#"\\[kK][fFoO]?\d+(?:\.\d+)?"#, in: block.value).first
                if let karaoke {
                    try flush()
                    let number = karaoke.value.dropFirst(2).drop(while: { !$0.isNumber })
                    guard let centiseconds = Double(number), centiseconds.isFinite, centiseconds >= 0 else { throw LyricsParseError.malformed("ASS 卡拉 OK 时长无效") }
                    duration = centiseconds / 100
                    row.wordTimed = true
                    segmentIDs = currentIDs
                }
                if let tag = KaraokeText.matches(#"\\sing_[^\\}]+"#, in: block.value).first {
                    currentIDs = source.performers(String(tag.value.dropFirst(6)))
                    if buffer.isEmpty {
                        segmentIDs = currentIDs
                        if row.atoms.isEmpty { row.agents = currentIDs }
                    }
                }
                if let tag = KaraokeText.matches(#"\\p\d+"#, in: block.value).first { drawing = String(tag.value.dropFirst(2)) != "0" }
                previous = block.range.upperBound
            }
            if !drawing { buffer += body[previous...] }
            try flush()
            if !row.wordTimed {
                row.atoms = row.atoms.map { atom in var atom = atom; atom.start = start; atom.end = end; return atom }
            }
            if !row.atoms.isEmpty { source.rows.append(row) }
        }
        return source
    }

    private static func time(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^\d+:\d{2}:\d{2}\.\d{2,3}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ":")
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]), minutes < 60, let seconds = Double(parts[2]), seconds < 60 else { return nil }
        let time = hours * 3600 + minutes * 60 + seconds
        return time.isFinite ? time : nil
    }
}
