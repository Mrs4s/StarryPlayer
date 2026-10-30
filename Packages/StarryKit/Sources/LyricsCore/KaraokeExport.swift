import Foundation

enum KaraokeExport {
    struct Voice {
        var start: TimeInterval
        var end: TimeInterval
        var syllables: [LyricSyllable]
        var agents: [String]
        var singer: LyricSinger
        var romanization: String?
        var romanizationWords: [LyricWord]?
    }

    static func voices(_ document: LyricsDocument) -> [Voice] {
        document.lines.flatMap { line -> [Voice] in
            var result = [Voice(start: line.primaryStart, end: line.primaryEnd, syllables: line.syllables, agents: line.agentIDs,
                                singer: line.singer, romanization: line.romanization, romanizationWords: line.romanizationWords)]
            if let bg = line.background {
                result.append(Voice(start: bg.start, end: bg.end, syllables: bg.syllables, agents: bg.agentIDs.isEmpty ? line.agentIDs : bg.agentIDs,
                                    singer: line.singer, romanization: bg.romanization, romanizationWords: bg.romanizationWords))
            }
            return result
        }.filter { $0.syllables.contains(where: { !$0.text.isEmpty || $0.isRest }) }
            .enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    struct Labels {
        var names: [String: String] = [:]

        init(_ document: LyricsDocument, validate: Bool = true) throws {
            var used: Set<String> = []
            let ids = LyricAgent.references(document.agents.map(\.id) + voices(document).flatMap { $0.agents + $0.syllables.flatMap(\.agentIDs) })
            for id in ids {
                let base = document.agents.first { $0.id == id }?.displayName ?? id
                if validate, base.isEmpty || base.contains(where: { "【】{}\\+\n\r".contains($0) }) { throw LyricsParseError.unsupported("角色名称包含保留字符，请重命名或导出 TTML") }
                var label = base
                var suffix = 2
                while used.contains(label) { label = "\(base) (\(suffix))"; suffix += 1 }
                used.insert(label)
                names[id] = label
            }
        }

        func label(_ ids: [String], singer: LyricSinger = .primary) -> String {
            if !ids.isEmpty { return LyricAgent.references(ids).compactMap { names[$0] }.joined(separator: "+") }
            switch singer {
            case .primary: return "主唱"
            case .secondary: return "对唱"
            case .duet: return "主唱+对唱"
            }
        }
    }

    static func write(_ input: LyricsDocument, format: LyricsExportFormat, metadata: [(key: String, value: String)]?) throws -> LyricsExport.Output {
        var document = input
        if format == .krl {
            LyricRomanizationAligner.alignMissing(in: &document)
            for index in document.lines.indices {
                if document.lines[index].romanizationWords == nil, let text = document.lines[index].romanization, !text.isEmpty {
                    document.lines[index].romanizationWords = [.init(start: document.lines[index].primaryStart, end: document.lines[index].primaryEnd, text: text)]
                }
                if var bg = document.lines[index].background, bg.romanizationWords == nil, let text = bg.romanization, !text.isEmpty {
                    bg.romanizationWords = [.init(start: bg.start, end: bg.end, text: text)]
                    document.lines[index].background = bg
                }
            }
        }
        let voices = voices(document)
        for voice in voices {
            for syllable in voice.syllables {
                guard syllable.start.isFinite, syllable.end.isFinite, syllable.start >= 0, syllable.end >= syllable.start else { throw LyricsParseError.malformed("歌词时间无效") }
            }
        }
        let fields = metadata ?? document.metadata.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let losses = Self.losses(document, format: format, metadata: fields)
        let text: String
        switch format {
        case .ass: text = try ass(voices, labels: Labels(document), metadata: fields)
        case .nicokara, .nicokaraRuby: text = try nicokara(voices, labels: Labels(document), ruby: format == .nicokaraRuby, metadata: fields)
        case .krl, .kasugamuki: text = try krl(voices, labels: Labels(document, validate: format == .krl), roles: format == .krl, romanization: format == .krl)
        case .rl: text = try rl(LyricsDraft(document: document))
        default: throw LyricsParseError.unsupported(format.rawValue)
        }
        return .init(text: text, losses: losses)
    }

    static func losses(_ document: LyricsDocument, format: LyricsExportFormat, metadata: [(key: String, value: String)]?) -> [LyricsExport.Loss] {
        var losses: [LyricsExport.Loss] = []
        if document.hasTranslation { losses.append(.translation) }
        if document.hasBackgroundVocals { losses.append(.backgroundGrouping) }
        if format != .krl, document.hasRomanization { losses.append(.romanization) }
        if format == .krl, voices(document).contains(where: { $0.romanization?.isEmpty == false && $0.romanizationWords == nil }) { losses.append(.romanization) }
        if format == .nicokara, document.hasRuby { losses.append(.ruby) }
        if format != .nicokara, document.lines.contains(where: { line in
            (line.syllables + (line.background?.syllables ?? [])).contains { !$0.groupRuby.isEmpty }
        }) { losses.append(.sharedRuby) }
        if !document.agents.isEmpty || document.hasMultipleVocalists {
            losses.append(format == .rl || format == .kasugamuki ? .agents : .agentDetails)
        }
        if format != .rl, document.hasAuthoringTiming { losses.append(.editingState) }
        let nico = format == .nicokara || format == .nicokaraRuby
        let supported: Set<String> = nico ? ["musicName", "title", "ti", "artists", "artist", "ar", "album", "al", "by", "ttmlAuthorGithubLogin"] : format == .ass ? ["musicName", "title", "ti"] : []
        let fields = metadata ?? document.metadata.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if fields.contains(where: { !$0.value.isEmpty && !supported.contains($0.key) && !(nico && $0.key.hasPrefix("nicokara:")) }) { losses.append(.metadata) }
        return losses
    }

    static func rl(_ draft: LyricsDraft) throws -> String {
        var rows: [String] = []
        for line in draft.lines {
            var output = ""
            for (index, syllable) in line.syllables.enumerated() {
                let base = syllable.isRest ? "▨" : syllable.text
                guard !base.contains(where: { "{}\r\n".contains($0) }), KaraokeText.matches(#"\[\d+(?:\||\]|:)"#, in: base).isEmpty else {
                    throw LyricsParseError.unsupported("RL 正文中的花括号或节奏标签字面文本")
                }
                var ruby = syllable.ruby ?? []
                var points = syllable.checkpoints?.map { $0.flatMap { offset in syllable.start.map { $0 + offset } } }
                if points == nil {
                    if !ruby.isEmpty, let start = syllable.start, let end = syllable.end {
                        points = LyricsDraft.Ruby.absolute(ruby, start: start, end: end).map { Optional($0.start) }
                    } else { points = [syllable.start] }
                }
                var beats = points ?? []
                if !ruby.isEmpty, ruby.allSatisfy({ $0.span != nil }), let start = syllable.start, let end = syllable.end, end > start,
                   ruby.count == beats.count {
                    let absolute = LyricsDraft.Ruby.absolute(ruby, start: start, end: end)
                    var parts: [LyricsDraft.Ruby] = [], expanded: [TimeInterval?] = []
                    var cursor = start
                    for (index, part) in absolute.enumerated() {
                        if part.start > cursor + 0.000001 {
                            parts.append(.init(text: "", span: (cursor - start) / (end - start)...(part.start - start) / (end - start)))
                            expanded.append(cursor)
                        }
                        parts.append(ruby[index]); expanded.append(beats[index])
                        cursor = part.end
                    }
                    if cursor < end - 0.000001 {
                        parts.append(.init(text: "", span: (cursor - start) / (end - start)...1))
                        expanded.append(cursor)
                    }
                    ruby = parts; beats = expanded
                }
                guard beats.count <= 9 else { throw LyricsParseError.unsupported("RL 单个单元最多 9 个节奏点，请拆分后导出") }
                let known = beats.compactMap { $0 }
                guard zip(known, known.dropFirst()).allSatisfy({ $0 <= $1 }),
                      syllable.end.map({ end in known.allSatisfy { $0 <= end + 0.000001 } }) ?? true else {
                    throw LyricsParseError.malformed("RL 节奏点超出音节结束时间或顺序无效，请调整音节时间")
                }
                func firstTag() throws -> String {
                    if let first = beats.first ?? nil { return "[\(beats.count)|\(try KaraokeText.timestamp(first))]" }
                    return "[\(beats.count)]"
                }
                if !ruby.isEmpty {
                    guard !base.contains("|"), !ruby.contains(where: { $0.text.contains(where: { "{}[]＋\r\n".contains($0) }) }) else { throw LyricsParseError.unsupported("RL 注音块中的保留字符") }
                    if !beats.isEmpty, ruby.count != beats.count {
                        ruby = KaraokeText.moraPieces(ruby.map(\.text).joined(), count: beats.count).map { .init(text: $0) }
                    }
                    var reading = try firstTag()
                    for (i, part) in ruby.enumerated() {
                        if i > 0, i < beats.count, let time = beats[i] { reading += "[\(try KaraokeText.timestamp(time))]" }
                        reading += part.text
                    }
                    // RL's full-width plus separates display characters in a linked group.
                    let tails = base.dropFirst().map { _ in "＋[0]" }.joined()
                    output += "{\(base)|\(reading)\(tails)}"
                } else {
                    output += try firstTag() + base
                    var encounteredUntimed = beats.first == nil || (beats.first ?? nil) == nil
                    for time in beats.dropFirst() {
                        if let time {
                            guard !encounteredUntimed else { throw LyricsParseError.unsupported("RL 无注音单元中的非连续已打点节奏点") }
                            output += "[\(try KaraokeText.timestamp(time))]"
                        } else { encounteredUntimed = true }
                    }
                }
                let next = index + 1 < line.syllables.count ? line.syllables[index + 1].start : nil
                if let end = syllable.end, syllable.hasRelease || next == nil || next.map({ end < $0 }) == true {
                    output += "[10|\(try KaraokeText.timestamp(end))]"
                } else if syllable.hasRelease { output += "[10]" }
            }
            rows.append(output)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func krl(_ voices: [Voice], labels: Labels, roles: Bool, romanization: Bool) throws -> String {
        var rows: [String] = []
        for voice in voices {
            var output = "", previous: String?
            let roman = voice.romanizationWords?.flatMap(\.syllables) ?? []
            var consumed: Set<Int> = []
            let sung = voice.syllables.filter { !$0.isRest }
            var assignments: [Int: Int] = [:]
            for index in roman.indices where !sung.isEmpty {
                assignments[index] = sung.firstIndex(where: { roman[index].start < $0.end && roman[index].end > $0.start })
                    ?? sung.indices.min(by: { abs(sung[$0].start - roman[index].start) < abs(sung[$1].start - roman[index].start) })
            }
            for (syllableIndex, syllable) in sung.enumerated() {
                let ids = syllable.agentIDs.isEmpty ? voice.agents : syllable.agentIDs
                let label = labels.label(ids, singer: voice.singer)
                if roles, previous != label { output += "【@\(label)】"; previous = label }
                let base = syllable.text
                guard !base.contains(where: { "{}\r\n".contains($0) }) else { throw LyricsParseError.unsupported("KRL 正文中的花括号或换行") }
                let indices = romanization ? roman.indices.filter { !consumed.contains($0) && assignments[$0] == syllableIndex } : []
                consumed.formUnion(indices)
                let visibleRuby = syllable.ruby.filter { !$0.text.isEmpty }
                var ruby: [LyricRuby] = []
                if !visibleRuby.isEmpty {
                    var cursor = syllable.start
                    for piece in visibleRuby {
                        if piece.start > cursor + 0.000001 { ruby.append(.init(start: cursor, end: piece.start, text: "")) }
                        ruby.append(piece)
                        cursor = piece.end
                    }
                    if cursor < syllable.end - 0.000001 { ruby.append(.init(start: cursor, end: syllable.end, text: "")) }
                }
                if !ruby.isEmpty || !indices.isEmpty || base.contains("[") {
                    guard !base.contains("|"), !ruby.contains(where: { $0.text.contains(where: { "{}|>\r\n".contains($0) }) }) else { throw LyricsParseError.unsupported("KRL 注音块中的分隔符") }
                    var reading = ""
                    for piece in ruby { reading += "[\(try KaraokeText.timestamp(piece.start))]\(piece.text)" }
                    if !ruby.isEmpty { reading += "[\(try KaraokeText.timestamp(ruby.last!.end))]" }
                    if !indices.isEmpty {
                        reading += ">"
                        for index in indices {
                            guard !roman[index].text.contains(where: { "{}|>\r\n".contains($0) }) else { throw LyricsParseError.unsupported("KRL 罗马音中的分隔符") }
                            reading += "[\(try KaraokeText.timestamp(roman[index].start))]\(roman[index].text)"
                        }
                        reading += "[\(try KaraokeText.timestamp(roman[indices.last!].end))]"
                    }
                    output += "[\(try KaraokeText.timestamp(syllable.start))]{\(base)|\(reading)}[\(try KaraokeText.timestamp(syllable.end))]"
                } else {
                    let literal = base.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "【", with: "\\【")
                    output += "[\(try KaraokeText.timestamp(syllable.start))]\(literal)[\(try KaraokeText.timestamp(syllable.end))]"
                }
            }
            rows.append(output)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func nicokara(_ voices: [Voice], labels: Labels, ruby: Bool, metadata: [(key: String, value: String)]) throws -> String {
        var rows: [String] = [], annotations: [String] = []
        for voice in voices {
            var output = "", previous: String?
            for syllable in voice.syllables where !syllable.isRest {
                let ids = syllable.agentIDs.isEmpty ? voice.agents : syllable.agentIDs
                let label = labels.label(ids, singer: voice.singer)
                if previous != label { output += "【\(label)】"; previous = label }
                guard !syllable.text.contains(where: { "【】\r\n".contains($0) }), KaraokeText.matches(#"\[\d+:"#, in: syllable.text).isEmpty else { throw LyricsParseError.unsupported("Nicokara 正文中的角色标签、时间标签或换行字面文本") }
                output += "[\(try KaraokeText.timestamp(syllable.start))]\(syllable.text)[\(try KaraokeText.timestamp(syllable.end))]"
                if ruby, !syllable.ruby.isEmpty {
                    guard !syllable.text.contains(",") else { throw LyricsParseError.unsupported("Nicokara 注音原文中的半角逗号") }
                    var reading = ""
                    for (index, piece) in syllable.ruby.enumerated() {
                        guard !piece.text.contains(where: { "[]\r\n".contains($0) }) else { throw LyricsParseError.unsupported("Nicokara 注音中的时间标签字面文本") }
                        if index > 0 || piece.start > syllable.start { reading += "[\(try KaraokeText.timestamp(max(0, piece.start - syllable.start)))]" }
                        reading += piece.text
                        let next = index + 1 < syllable.ruby.count ? syllable.ruby[index + 1].start : nil
                        if next == nil || piece.end < next! { reading += "[\(try KaraokeText.timestamp(max(0, piece.end - syllable.start)))]" }
                    }
                    annotations.append("@Ruby\(annotations.count + 1)=\(syllable.text),\(reading),[\(try KaraokeText.timestamp(syllable.start))],[\(try KaraokeText.timestamp(syllable.end))]")
                }
            }
            rows.append(output)
        }
        for (tag, keys) in [("Title", ["musicName", "title", "ti"]), ("Artist", ["artists", "artist", "ar"]), ("Album", ["album", "al"]), ("TaggingBy", ["by", "ttmlAuthorGithubLogin"])] {
            if let key = keys.first(where: { key in metadata.contains(where: { $0.key == key }) }) {
                rows.append("@\(tag)=\(metadata.filter { $0.key == key }.map(\.value).joined(separator: " / ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))")
            }
        }
        for entry in metadata where entry.key.hasPrefix("nicokara:") {
            let key = String(entry.key.dropFirst(9))
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !key.isEmpty else { continue }
            let tag = key.range(of: #"^Emoji\d+$"#, options: .regularExpression) == nil ? key : "Emoji"
            rows.append("@\(tag)=\(entry.value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))")
        }
        return (rows + annotations).joined(separator: "\n") + "\n"
    }

    private static func ass(_ voices: [Voice], labels: Labels, metadata: [(key: String, value: String)]) throws -> String {
        let title = metadata.first(where: { ["musicName", "title", "ti"].contains($0.key) })?.value ?? ""
        var rows = ["[Script Info]", "ScriptType: v4.00+", "Title: " + title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "), "", "[V4+ Styles]",
                    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
                    "Style: Default,Arial,36,&H00FFFFFF,&H0000FFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1", "", "[Events]",
                    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
        func clock(_ time: TimeInterval) throws -> String {
            let token = try KaraokeText.timestamp(time).split(separator: ":").map(String.init)
            let minutes = Int(token[0]) ?? 0
            return String(format: "%d:%02d:%@.%@", minutes / 60, minutes % 60, token[1], token[2])
        }
        func escaped(_ text: String) throws -> String {
            guard !text.contains(where: { "{}|\\".contains($0) }) else { throw LyricsParseError.unsupported("ASS 注音模板的花括号、竖线或反斜线字面文本") }
            return text.replacingOccurrences(of: "\r\n", with: "\\N").replacingOccurrences(of: "\n", with: "\\N").replacingOccurrences(of: "\u{00A0}", with: "\\h")
        }
        for voice in voices {
            var text = "", cursor = voice.start
            func duration(_ from: Double, _ to: Double) throws -> Int64 {
                _ = try KaraokeText.timestamp(from); _ = try KaraokeText.timestamp(to)
                guard to >= from else { throw LyricsParseError.malformed("ASS 单元时间重叠") }
                // Round cumulative boundaries, avoiding one rounding error per syllable.
                return max(0, Int64((to * 100).rounded()) - Int64((from * 100).rounded()))
            }
            for syllable in voice.syllables {
                if syllable.start > cursor { text += "{\\k\(try duration(cursor, syllable.start))}" }
                let ids = syllable.agentIDs.isEmpty ? voice.agents : syllable.agentIDs
                text += "{\\sing_\(labels.label(ids, singer: voice.singer))}"
                let pieces = syllable.ruby
                if pieces.isEmpty {
                    text += "{\\kf\(try duration(syllable.start, syllable.end))}\(try escaped(syllable.isRest ? "" : syllable.text))"
                } else {
                    var point = syllable.start
                    var ruby: [LyricRuby] = []
                    for piece in pieces {
                        if piece.start > point { ruby.append(LyricRuby(start: point, end: piece.start, text: "")) }
                        ruby.append(piece)
                        point = piece.end
                    }
                    if point < syllable.end { ruby.append(LyricRuby(start: point, end: syllable.end, text: "")) }
                    for (index, piece) in ruby.enumerated() {
                        let base = index == 0 ? try escaped(syllable.text) : "#"
                        text += "{\\kf\(try duration(piece.start, piece.end))}\(base)|<\(try escaped(piece.text))"
                    }
                }
                cursor = syllable.end
            }
            rows.append("Dialogue: 0,\(try clock(voice.start)),\(try clock(max(voice.end, voice.start + 0.01))),Default,,0,0,0,,\(text)")
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
