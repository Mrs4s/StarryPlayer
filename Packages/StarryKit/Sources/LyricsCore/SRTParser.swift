import Foundation

public enum SRTParser: LyricsParser {
    public static let format: LyricsDocument.Format = .srt

    public static func parse(_ text: String) throws -> LyricsDocument {
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsParseError.empty }
        let blocks = normalized.replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\n\n", options: .regularExpression).components(separatedBy: "\n\n")
        var lines: [LyricLine] = []
        for block in blocks where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rows = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let header = rows.firstIndex(where: { $0.contains("-->") }) else { throw LyricsParseError.malformed("SRT: 缺少字幕时间") }
            guard header == 0 || (header == 1 && rows[0].trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber)) else {
                throw LyricsParseError.malformed("SRT: 无效的字幕序号")
            }
            let pair = rows[header].components(separatedBy: "-->")
            guard pair.count == 2, let start = timestamp(pair[0].trimmingCharacters(in: .whitespaces)),
                  let token = pair[1].split(whereSeparator: \.isWhitespace).first, let end = timestamp(String(token)), end > start else {
                throw LyricsParseError.malformed("SRT: 无效的开始或结束时间")
            }
            var body = rows.dropFirst(header + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body = body.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)</?(?:i|b|u|s|font)(?:\s+[^>]*)?>"#, with: "", options: .regularExpression)
            body = XMLEntities.decode(body)
            if !body.isEmpty { lines.append(.plain(id: lines.count, start: start, end: end, text: body)) }
        }
        lines = lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        for index in lines.indices { lines[index].id = index }
        guard !lines.isEmpty else { throw LyricsParseError.empty }
        return LyricsDocument(format: .srt, lines: lines)
    }

    private static func timestamp(_ text: String) -> TimeInterval? {
        guard text.range(of: #"^\d+:\d{2}:\d{2}[,.]\d{3}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]), minutes < 60,
              let seconds = Double(parts[2]), seconds < 60 else { return nil }
        let time = hours * 3600 + minutes * 60 + seconds
        return time.isFinite ? time : nil
    }
}
