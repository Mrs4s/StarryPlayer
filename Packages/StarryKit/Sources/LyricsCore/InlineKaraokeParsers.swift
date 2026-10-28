import Foundation

public enum KRLParser: LyricsParser {
    public static let format: LyricsDocument.Format = .krl
    public static func parse(_ text: String) throws -> LyricsDocument { try source(text).document(format: format) }

    static func source(_ text: String) throws -> KaraokeTextSource {
        let body = try KaraokeText.withoutConfig(text)
        var source = KaraokeTextSource()
        var performers: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var row = KaraokeRow(agents: performers)
            var position = line.startIndex
            var pending: TimeInterval?
            var pendingIsStart = false
            var buffer = ""
            func flush() {
                guard !buffer.isEmpty else { return }
                row.atoms.append(KaraokeAtom(text: buffer, start: pending, agents: performers))
                pending = nil
                pendingIsStart = false
                buffer = ""
            }
            while position < line.endIndex {
                let rest = line[position...]
                if rest.hasPrefix("\\\\") || rest.hasPrefix("\\【") {
                    position = line.index(after: position)
                    buffer.append(line[position])
                    position = line.index(after: position)
                    continue
                }
                if rest.hasPrefix("【@"), let close = rest.firstIndex(of: "】") {
                    flush()
                    let name = String(line[line.index(position, offsetBy: 2)..<close])
                    performers = source.performers(name)
                    if row.atoms.isEmpty { row.agents = performers }
                    position = line.index(after: close)
                    continue
                }
                if line[position] == "[", let close = rest.firstIndex(of: "]") {
                    let rawTag = String(line[position...close])
                    if let beat = KaraokeText.beat(rawTag), beat.count == nil, let time = beat.time {
                        flush()
                        if let pending, let last = row.atoms.indices.last { row.atoms[last].end = pending }
                        pendingIsStart = pending != nil || row.atoms.isEmpty
                        pending = time
                        position = line.index(after: close)
                        continue
                    }
                    if rawTag.range(of: #"^\[\d+:"#, options: .regularExpression) != nil { throw LyricsParseError.malformed("无效的 KRL 时间标签") }
                }
                if line[position] == "{" {
                    flush()
                    guard let close = rest.firstIndex(of: "}") else { throw LyricsParseError.malformed("KRL 注音块未闭合") }
                    let group = String(line[line.index(after: position)..<close])
                    guard let pipe = group.firstIndex(of: "|"), pipe > group.startIndex else { throw LyricsParseError.malformed("KRL 注音块缺少原文或读音分隔符") }
                    let display = String(group[..<pipe])
                    let annotation = String(group[group.index(after: pipe)...])
                    if annotation.hasPrefix("|") { throw LyricsParseError.unsupported("SUG 双竖线全文本注音，请从原工具导出 RL 编辑模式") }
                    let layers = annotation.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    let kana = try KaraokeText.layer(layers[0])
                    let roman = try KaraokeText.layer(layers.count > 1 ? layers[1] : "")
                    let annotatedStart = kana.pieces.compactMap(\.start).first ?? roman.pieces.compactMap(\.start).first
                    let start = pendingIsStart ? pending ?? annotatedStart : annotatedStart ?? pending
                    if let pending, let last = row.atoms.indices.last, !pendingIsStart { row.atoms[last].end = pending }
                    row.atoms.append(KaraokeAtom(text: display, start: start, end: kana.release ?? roman.release,
                                                  ruby: kana.pieces, romanization: roman.pieces, checkpoints: kana.checkpoints, agents: performers))
                    pending = nil
                    pendingIsStart = false
                    position = line.index(after: close)
                    continue
                }
                buffer.append(line[position])
                position = line.index(after: position)
            }
            flush()
            if let pending, let last = row.atoms.indices.last { row.atoms[last].end = pending; row.end = pending }
            if !row.atoms.isEmpty { source.rows.append(row) }
        }
        return source
    }
}

public enum RLParser: LyricsParser {
    public static let format: LyricsDocument.Format = .rl
    public static func parse(_ text: String) throws -> LyricsDocument { try source(text).document(format: format) }

    static func source(_ text: String) throws -> KaraokeTextSource {
        var source = KaraokeTextSource()
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var row = KaraokeRow()
            var position = line.startIndex
            while position < line.endIndex {
                if line[position] == "{" {
                    guard let close = line[position...].firstIndex(of: "}") else { throw LyricsParseError.malformed("RL 注音块未闭合") }
                    let group = String(line[line.index(after: position)..<close])
                    guard let pipe = group.firstIndex(of: "|") else { throw LyricsParseError.malformed("RL 注音块缺少读音分隔符") }
                    let display = String(group[..<pipe])
                    let portions = group[group.index(after: pipe)...].components(separatedBy: "＋")
                    if portions.count > 1 {
                        guard portions.count == display.count else { throw LyricsParseError.malformed("RL 连词块的字符和读音数量不一致") }
                        for (character, portion) in zip(display, portions) {
                            let layer = try KaraokeText.layer(portion, rl: true)
                            let ruby = layer.pieces.contains(where: { !$0.text.isEmpty }) ? layer.pieces : []
                            row.atoms.append(KaraokeAtom(text: String(character), start: layer.pieces.compactMap(\.start).first,
                                                         end: layer.release, ruby: ruby, checkpoints: layer.checkpoints, hasRelease: layer.hasRelease))
                        }
                        // A linked group's reading has no per-character boundaries.
                        let lower = row.atoms.count - portions.count
                        if row.atoms[(lower + 1)...].allSatisfy({ $0.ruby.isEmpty && ($0.checkpoints ?? []).isEmpty }) {
                            var first = row.atoms[lower]
                            first.text = display
                            row.atoms.replaceSubrange(lower..., with: [first])
                        }
                    } else {
                        let layer = try KaraokeText.layer(portions[0], rl: true)
                        row.atoms.append(KaraokeAtom(text: display, start: layer.pieces.compactMap(\.start).first,
                                                     end: layer.release, ruby: layer.pieces, checkpoints: layer.checkpoints, hasRelease: layer.hasRelease))
                    }
                    position = line.index(after: close)
                    continue
                }
                if line[position] == "[" {
                    guard let close = line[position...].firstIndex(of: "]") else { throw LyricsParseError.malformed("RL 节奏标签未闭合") }
                    let tag = String(line[position...close])
                    guard let beat = KaraokeText.beat(tag) else { throw LyricsParseError.malformed("无效的 RL 节奏点：\(tag)") }
                    let begin = line.index(after: close)
                    let end = line[begin...].firstIndex(where: { $0 == "[" || $0 == "{" }) ?? line.endIndex
                    let content = String(line[begin..<end])
                    if beat.release, content.isEmpty {
                        if let last = row.atoms.indices.last { row.atoms[last].end = beat.time; row.atoms[last].hasRelease = true }
                        if end == line.endIndex { row.end = beat.time }
                    } else if let count = beat.count {
                        if !content.isEmpty {
                            let checkpoints: [TimeInterval?] = count > 0 ? [beat.time] + Array(repeating: nil, count: count - 1) : []
                            row.atoms.append(KaraokeAtom(text: content, start: beat.time, checkpoints: checkpoints, isRest: content == "▨"))
                        }
                    } else if let last = row.atoms.indices.last {
                        if let missing = row.atoms[last].checkpoints?.firstIndex(where: { $0 == nil }) { row.atoms[last].checkpoints?[missing] = beat.time }
                        else { row.atoms[last].checkpoints = (row.atoms[last].checkpoints ?? []) + [beat.time] }
                        if row.atoms[last].start == nil { row.atoms[last].start = beat.time }
                        if !content.isEmpty { row.atoms[last].text += content }
                    }
                    position = end
                    continue
                }
                let end = line[position...].firstIndex(where: { $0 == "[" || $0 == "{" }) ?? line.endIndex
                let content = String(line[position..<end])
                row.atoms.append(KaraokeAtom(text: content, checkpoints: [], isRest: content == "▨"))
                position = end
            }
            if !row.atoms.isEmpty { source.rows.append(row) }
        }
        return source
    }
}
