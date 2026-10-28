import Foundation

public enum LyricsExportFormat: String, Sendable, CaseIterable {
    case ttml, lrcLine, lrcEnhanced, lrcWord, kra, txt, txt2ass, srt, ass, nicokara, nicokaraRuby, rl, kasugamuki, krl

    public var fileExtension: String {
        switch self {
        case .ttml: "ttml"
        case .lrcLine, .lrcEnhanced, .lrcWord, .nicokara, .nicokaraRuby: "lrc"
        case .kra: "kra"
        case .txt, .txt2ass, .rl, .kasugamuki: "txt"
        case .srt: "srt"
        case .ass: "ass"
        case .krl: "krl"
        }
    }
}

public enum LyricsExport {
    public enum Loss: String, Sendable, Hashable {
        case timing, syllableTiming, lineEndTiming, translation, romanization, ruby, agents, backgroundGrouping, metadata, agentDetails, editingState
    }

    public struct Output: Sendable {
        public var text: String
        public var losses: [Loss]
    }

    /// Losses describe authored timing, excluding times inferred for preview.
    public static func write(_ draft: LyricsDraft, format: LyricsExportFormat, metadata: [(key: String, value: String)]? = nil, duration: TimeInterval? = nil) throws -> Output {
        if format == .rl {
            // Unfinished beats can extend beyond the inferred playback end.
            return Output(text: try KaraokeExport.rl(draft), losses: KaraokeExport.losses(draft.document(), format: .rl, metadata: metadata))
        }
        var output = try write(draft.document(), format: format, metadata: metadata, duration: duration)
        if draft.hasAuthoringTiming, !output.losses.contains(.editingState) { output.losses.append(.editingState) }
        if draft.timedCount == 0 { output.losses.removeAll { $0 == .syllableTiming } }
        if !draft.lines.contains(where: { $0.timedRange != nil }) { output.losses.removeAll { $0 == .timing } }
        return output
    }

    public static func write(_ document: LyricsDocument, format: LyricsExportFormat, metadata: [(key: String, value: String)]? = nil, duration: TimeInterval? = nil) throws -> Output {
        let editingState = document.hasAuthoringTiming
        if format == .ttml { return Output(text: TTMLWriter.write(document, metadata: metadata, duration: duration), losses: editingState ? [.editingState] : []) }
        if [.ass, .nicokara, .nicokaraRuby, .rl, .kasugamuki, .krl].contains(format) { return try KaraokeExport.write(document, format: format, metadata: metadata) }
        let sourceVoices = document.lines.flatMap { line -> [Voice] in
            let main = Voice(start: line.primaryStart, end: line.primaryEnd, text: line.text, syllables: line.syllables)
            guard let bg = line.background else { return [main] }
            return [main, Voice(start: bg.start, end: bg.end, text: bg.text, syllables: bg.syllables)]
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let voices = format == .txt ? sourceVoices : sourceVoices.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        var losses: [Loss] = []
        if editingState { losses.append(.editingState) }
        if format == .txt { losses.append(.timing) }
        else if [.lrcLine, .txt2ass, .srt].contains(format), document.hasSyllables { losses.append(.syllableTiming) }
        if [.lrcLine, .txt2ass].contains(format), zip(voices, voices.dropFirst()).contains(where: { $0.end > $1.start }) { losses.append(.lineEndTiming) }
        if document.hasTranslation { losses.append(.translation) }
        if document.hasRomanization { losses.append(.romanization) }
        if document.hasRuby { losses.append(.ruby) }
        if !document.agents.isEmpty || document.hasMultipleVocalists || document.lines.contains(where: { !$0.agentIDs.isEmpty || $0.syllables.contains(where: { !$0.agentIDs.isEmpty }) }) { losses.append(.agents) }
        if document.hasBackgroundVocals { losses.append(.backgroundGrouping) }
        let fields = metadata ?? document.metadata.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        let supportedMetadata: Set<String> = [.srt, .txt].contains(format) ? [] : format == .txt2ass
            ? ["musicName", "title", "ti", "artists", "artist", "ar"]
            : ["musicName", "title", "ti", "artists", "artist", "ar", "album", "al", "ttmlAuthorGithubLogin", "by"]
        if fields.contains(where: { !$0.value.isEmpty && !supportedMetadata.contains($0.key) }) { losses.append(.metadata) }
        if format == .txt { return Output(text: voices.map(\.text).joined(separator: "\n") + "\n", losses: losses) }
        for voice in voices {
            guard valid(voice.start, voice.end), voice.syllables.allSatisfy({ valid($0.start, $0.end) }) else {
                throw LyricsParseError.malformed("导出时间无效")
            }
        }
        if format == .srt {
            let blocks = voices.enumerated().map { index, voice in
                "\(index + 1)\n\(srtTime(voice.start)) --> \(srtTime(max(voice.end, voice.start + 0.001)))\n\(escapeSRT(voice.text))"
            }
            return Output(text: blocks.joined(separator: "\n\n") + "\n", losses: losses)
        }
        let precision = format == .kra || format == .txt2ass ? 2 : 3
        func tag(_ time: TimeInterval, angle: Bool = false) -> String {
            (angle ? "<" : "[") + lrcTime(time, precision: precision) + (angle ? ">" : "]")
        }
        var rows: [String] = []
        for (lrc, keys) in [("ti", ["musicName", "title", "ti"]), ("ar", ["artists", "artist", "ar"]), ("al", ["album", "al"]), ("by", ["ttmlAuthorGithubLogin", "by"])] {
            if let key = keys.first(where: { key in fields.contains(where: { $0.key == key && !$0.value.isEmpty }) }) {
                let value = fields.filter { $0.key == key }.map(\.value).joined(separator: " / ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                if format == .txt2ass {
                    if lrc == "ti" { rows.append("# Title: \(value)") }
                    if lrc == "ar" { rows.append("# Artist: \(value)") }
                } else {
                    rows.append("[\(lrc):\(value)]")
                }
            }
        }
        if format == .txt2ass { rows.append("# Format: [mm:ss.xx]Lyrics") }
        for (index, voice) in voices.enumerated() {
            if format == .lrcLine || format == .txt2ass {
                rows.append(tag(voice.start) + voice.text.replacingOccurrences(of: "\n", with: " "))
                // Empty tags end gaps but would prematurely end overlapping voices.
                let next = index + 1 < voices.count ? voices[index + 1].start : .infinity
                let otherActive = voices[..<index].contains { $0.end > voice.end }
                if voice.end < next, !otherActive { rows.append(tag(voice.end)) }
            } else {
                let angle = format != .lrcWord
                var row = angle ? tag(voice.start) : ""
                for (index, syllable) in voice.syllables.enumerated() {
                    row += tag(syllable.start, angle: angle) + syllable.text.replacingOccurrences(of: "\n", with: " ")
                    let next = index + 1 < voice.syllables.count ? voice.syllables[index + 1].start : nil
                    if next == nil || syllable.end < next! { row += tag(syllable.end, angle: angle) }
                }
                rows.append(row)
            }
        }
        return Output(text: rows.joined(separator: "\n") + "\n", losses: losses)
    }

    private struct Voice {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var syllables: [LyricSyllable]
    }

    private static func valid(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end >= start && end < Double(Int.max / 1000)
    }

    private static func lrcTime(_ time: TimeInterval, precision: Int) -> String {
        let units = precision == 2 ? 100 : 1000
        let value = Int((time * Double(units)).rounded())
        return String(format: "%02d:%02d.%0*d", value / (60 * units), value / units % 60, precision, value % units)
    }

    private static func srtTime(_ time: TimeInterval) -> String {
        let ms = Int((time * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func escapeSRT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
