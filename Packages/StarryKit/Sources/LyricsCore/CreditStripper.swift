import Foundation

/// Removes the credit lines that line-timed sources put around the lyrics: "Title - Artist",
/// `词：…`, `作曲 : …`, `Producer: …`, `未经许可不得翻唱…`. Only contiguous runs at the head
/// (up to 16 lines) and tail (up to 8) are removed, and never every line. TTML is left alone.
public enum LyricsCreditStripper {
    public static func strip(_ document: LyricsDocument, title: String?, artists: [String]) -> LyricsDocument {
        guard document.format != .ttml, document.lines.count > 1 else { return document }
        let title = title.map(normalize) ?? ""
        let artists = artists.map(normalize).filter { !$0.isEmpty }
        let isMetadata: (LyricLine) -> Bool = { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || isCredit(text) || isTitleLine(text, title: title, artists: artists)
        }
        // Only at the very top: the title or an artist alone on a line (some lyrics split
        // title and artist over two lines). Choruses often end on the title, so not at the tail.
        let isHeading: (LyricLine) -> Bool = { line in
            let text = normalize(line.text)
            return !text.isEmpty && (text == title || artists.contains(text))
        }
        var lines = document.lines
        var head = 0
        while head < min(lines.count, 16), isMetadata(lines[head]) || (head < 3 && isHeading(lines[head])) { head += 1 }
        var tail = lines.count
        while tail > max(head, lines.count - 8), isMetadata(lines[tail - 1]) { tail -= 1 }
        guard head < tail, head > 0 || tail < lines.count else { return document }
        lines = Array(lines[head..<tail])
        for i in lines.indices { lines[i].id = i }
        var stripped = document
        stripped.lines = lines
        return stripped
    }

    static func isCredit(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("不得翻唱") || lower.contains("未经许可") || lower.contains("未經許可") { return true }
        if byPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        guard let colon = text.prefix(24).firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let key = normalize(String(text[..<colon]))
        guard !key.isEmpty, key.count <= 12 else { return false }
        return exactKeys.contains(key) || keywords.contains { key.contains($0) }
    }

    static func isTitleLine(_ text: String, title: String, artists: [String]) -> Bool {
        guard !title.isEmpty, text.contains("-") || text.contains("—") || text.contains("–") else { return false }
        let normalized = normalize(text)
        guard normalized.contains(title) else { return false }
        return artists.isEmpty || artists.contains { normalized.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) })
    }

    private static let byPrefixes = ["lyrics by ", "music by ", "composed by ", "written by ", "produced by ", "arranged by ", "mixed by ", "mastered by "]

    private static let exactKeys: Set<String> = ["op", "sp", "isrc", "pv", "mv"]

    private static let keywords: [String] = [
        "词", "詞", "曲", "编", "編", "作词", "作詞", "作曲", "制作", "製作", "监制", "監製", "出品", "发行", "發行",
        "演唱", "原唱", "翻唱", "歌手", "混音", "缩混", "录音", "錄音", "母带", "母帶", "和声", "和聲", "配唱", "合声",
        "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤", "钢琴", "鋼琴", "弦乐", "弦樂", "人声", "人聲", "伴奏", "策划",
        "企划", "企劃", "统筹", "統籌", "出版", "版权", "版權", "营销", "宣传", "推广", "监修", "監修", "录制", "錄製",
        "lyric", "composer", "composed", "arrange", "producer", "produced", "written", "writer",
        "mix", "master", "vocal", "recording", "recorded", "engineer", "guitar", "bass", "drum", "piano", "keyboard",
        "strings", "publisher", "label",
    ]
}
