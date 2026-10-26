import Foundation

public enum TTMLWriter {
    /// `metadata`: `amll:meta` entries in order (a key may repeat, as `artists` does); nil writes
    /// the document's own, sorted by key. `duration` is the song's length for `<body dur>`.
    public static func write(_ document: LyricsDocument, metadata: [(key: String, value: String)]? = nil, duration: TimeInterval? = nil, translationLanguage: String? = nil) -> String {
        let lines = document.lines.filter { !$0.words.isEmpty }
        let styling = document.hasRuby ? #" xmlns:tts="http://www.w3.org/ns/ttml#styling""# : ""
        var out = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"\#(styling)>"#
        out += "<head><metadata>"
        out += #"<ttm:agent type="person" xml:id="v1"/>"#
        if lines.contains(where: { $0.singer == .secondary }) { out += #"<ttm:agent type="person" xml:id="v2"/>"# }
        if lines.contains(where: { $0.singer == .duet }) { out += #"<ttm:agent type="group" xml:id="v1000"/>"# }
        for entry in metadata ?? document.metadata.sorted(by: { $0.key < $1.key }).map({ ($0.key, $0.value) }) where !entry.value.isEmpty {
            out += #"<amll:meta key="\#(escape(entry.key))" value="\#(escape(entry.value))"/>"#
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
                out += #"<p begin="\#(timestamp(line.start))" end="\#(timestamp(line.end))" ttm:agent="\#(agent(line.singer))" itunes:key="L\#(key)">"#
                out += spans(line.words)
                if let background = line.background, !background.words.isEmpty {
                    out += #"<span ttm:role="x-bg" begin="\#(timestamp(background.start))" end="\#(timestamp(background.end))">"#
                    out += spans(background.words)
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

    private static func agent(_ singer: LyricSinger) -> String {
        switch singer {
        case .primary: "v1"
        case .secondary: "v2"
        case .duet: "v1000"
        }
    }

    /// A syllable span each; a word's trailing space goes between the spans, where the parser
    /// reads it as a word break.
    private static func spans(_ words: [LyricWord]) -> String {
        var out = ""
        for (index, word) in words.enumerated() {
            for syllable in word.syllables {
                let text = syllable.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let ruby = syllable.ruby.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                if ruby.isEmpty {
                    out += #"<span \#(times(syllable.start, syllable.end))>\#(escape(text))</span>"#
                } else {
                    // Ruby may cover only part of the base syllable's duration.
                    let timing = ruby.map(\.start).min() == syllable.start && ruby.map(\.end).max() == syllable.end
                        ? "" : " " + times(syllable.start, syllable.end)
                    out += #"<span tts:ruby="container"\#(timing)><span tts:ruby="base">\#(escape(text))</span><span tts:ruby="textContainer">"#
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
