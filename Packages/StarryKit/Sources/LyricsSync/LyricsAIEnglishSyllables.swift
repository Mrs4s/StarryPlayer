import Foundation

public enum LyricsAIEnglishSplit: String, CaseIterable, Sendable {
    case automatic = "auto"
    case syllable
    case word

    public var title: String {
        switch self {
        case .automatic: "自动"
        case .syllable: "按音节"
        case .word: "按词"
        }
    }
}

enum LyricsAIEnglishSyllables {
    struct Piece: Sendable {
        var text: String
        var tokens: Range<Int>
        var endsInLongMark: Bool
    }

    private struct Lexicon: Sendable {
        var words: [String: [Int]] = [:]
        var clusters: [String: Int] = [:]
    }

    private static let hyphens = Set("-‐‑–")
    private static let small = Set("ぁぃぅぇぉゃゅょゎゕゖ")
    private static let onsets = Set("bcdfghjklmnpqrstvwxyz".map(String.init))
        .union("bl br ch cl cr dr fl fr gl gr kl kn kr ph pl pr qu sc sh sk sl sm sn sp st sw th tr tw wh wr chr sch scr shr spl spr squ str thr".split(separator: " ").map(String.init))
    private static let endings = ("thing things body where time times day days night nights way ways side light lights self land house like heart break beat town world room hood ship fall ground stone storm shine walk work book back down friend friends boy girl ly less ful ness ment")
        .split(separator: " ").map(String.init)
    private static let sibilantE = ["se", "ce", "ge", "ze", "xe", "che", "she"]
    private static let wordPattern = try! NSRegularExpression(pattern: #"(?<![\p{Latin}\p{M}\p{N}])[\p{Latin}\p{M}]+(?:['’‘ʼ\-‐‑–][\p{Latin}\p{M}]+)*(?![\p{Latin}\p{M}\p{N}])"#)

    private static let lexicon: Lexicon = {
        var result = Lexicon()
        guard let url = Bundle.module.url(forResource: "english-cuts", withExtension: "tsv", subdirectory: "EnglishSyllables"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return result }
        var habits: [String: [(offset: Int, count: Int)]] = [:]
        for row in text.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
            let fields = row.split(separator: "\t")
            guard fields.count >= 3, let songs = Int(fields[2]) else { continue }
            let word = String(fields[0]), parts = fields[1].split(separator: "|")
            var offsets: [Int] = [], position = 0
            for part in parts.dropLast() { position += part.count; offsets.append(position) }
            if songs >= 3 { result.words[word] = offsets }
            let chars = Array(word), spans = nuclei(chars)
            guard !offsets.isEmpty, offsets.count == spans.count - 1 else { continue }
            for (index, cut) in offsets.enumerated() {
                let lower = spans[index].upperBound, upper = spans[index + 1].lowerBound
                guard lower <= cut, cut <= upper else { continue }
                let cluster = String(chars[lower..<upper]), offset = cut - lower
                var counts = habits[cluster, default: []]
                if let index = counts.firstIndex(where: { $0.offset == offset }) { counts[index].count += songs }
                else { counts.append((offset, songs)) }
                habits[cluster] = counts
            }
        }
        for (cluster, counts) in habits {
            let best = counts.dropFirst().reduce(counts[0]) { $1.count > $0.count ? $1 : $0 }
            result.clusters[cluster] = best.offset
        }
        return result
    }()

    static func wordRanges(in text: String) -> [NSRange] {
        wordPattern.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)
    }

    static func cuts(_ word: String) -> [Int] {
        let plain = letters(word)
        guard plain.count <= 128, plain.contains(where: { $0.isASCII && $0.isLetter }) else { return [] }
        let words = lexicon.words
        var result: [Int] = [], lower = 0
        for upper in 0...plain.count where upper == plain.count || plain[upper] == "-" {
            let part = String(plain[lower..<upper])
            var own = words[part]
            if own == nil, part.hasSuffix("'s") { own = words[String(part.dropLast(2))] }
            if own == nil, part.hasSuffix("s"), !part.hasSuffix("ss"), !part.hasSuffix("'s") {
                let stem = String(part.dropLast())
                if !sibilantE.contains(where: { stem.hasSuffix($0) }) { own = words[stem] }
            }
            result += (own ?? spelled(Array(part))).map { lower + $0 }
            if upper < plain.count { result.append(upper + 1) }
            lower = upper + 1
        }
        return Set(result.filter { $0 > 0 && $0 < plain.count }).sorted()
    }

    private static func letters(_ word: String) -> [Character] {
        word.map { char in
            if "'’‘ʼ".contains(char) { return "'" }
            if hyphens.contains(char) { return "-" }
            let lower = String(char).lowercased()
            let base = lower.decomposedStringWithCompatibilityMapping.unicodeScalars.first.map { Character(String($0)) } ?? char
            if base == "e", lower != "e" { return "é" }
            return base == "œ" ? "o" : (base == "æ" ? "a" : base)
        }
    }

    private static func isVowel(_ w: [Character], _ i: Int) -> Bool {
        let c = w[i], before: Character? = i > 0 ? w[i - 1] : nil
        let after: Character? = i + 1 < w.count ? w[i + 1] : nil
        if c == "u" { return !(before == "q" || (before == "g" && after.map { "aeiy".contains($0) } == true)) }
        if c == "y" {
            let finalE = after == "e" && i + 2 == w.count
            return i > 0 && !(after.map { "aeou".contains($0) } == true && !finalE)
        }
        return "aeioé".contains(c)
    }

    private static func nuclei(_ w: [Character]) -> [Range<Int>] {
        var found: [Range<Int>] = [], i = 0
        while i < w.count {
            guard isVowel(w, i) else { i += 1; continue }
            var j = i + 1
            while j < w.count, isVowel(w, j) {
                let pair = String(w[(j - 1)...j]), before: Character? = j > 1 ? w[j - 2] : nil
                let after: Character? = j + 1 < w.count ? w[j + 1] : nil
                var hiatus = ["ia", "io", "eo", "iu", "ua"].contains(pair) || w[j - 1] == "y"
                if pair == "io", before.map({ "tscxg".contains($0) }) == true, after == "n" || after == "u" { hiatus = false }
                if pair == "ia", before.map({ "tc".contains($0) }) == true, after == "l" || after == "n" { hiatus = false }
                if hiatus { break }
                j += 1
            }
            found.append(i..<j); i = j
        }
        guard found.count >= 2 else { return found }
        let kept = found.filter { span in
            let start = span.lowerBound, end = span.upperBound
            guard String(w[span]) == "e", start > 0, !"aeio'".contains(w[start - 1]) else { return true }
            let rest = String(w[end...]), before = w[start - 1]
            if rest.isEmpty || rest == "s" {
                if before == "l", start > 1, !isVowel(w, start - 2) { return true }
                return !rest.isEmpty && ("sxzcg".contains(before) || (start > 1 && ["ch", "sh"].contains(String(w[(start - 2)..<start]))))
            }
            if rest == "d" { return "td".contains(before) }
            return true
        }
        return kept.isEmpty ? Array(found.prefix(1)) : kept
    }

    private static func spelled(_ w: [Character]) -> [Int] {
        let spans = nuclei(w)
        guard spans.count >= 2 else { return [] }
        let word = String(w), words = lexicon.words
        for tail in endings where word.hasSuffix(tail) && w.count >= tail.count + 2 {
            let head = Array(w.dropLast(tail.count)), right = Array(tail)
            guard !nuclei(head).isEmpty, !nuclei(right).isEmpty else { continue }
            let leftCuts = words[String(head)] ?? spelled(head)
            let rightCuts = words[tail] ?? spelled(right)
            return leftCuts + [head.count] + rightCuts.map { head.count + $0 }
        }
        return zip(spans, spans.dropFirst()).compactMap { left, right in
            let cluster = Array(w[left.upperBound..<right.lowerBound])
            guard !cluster.contains("'") else { return nil }
            let learned = lexicon.clusters[String(cluster)]
            let offset: Int
            if let learned { offset = learned }
            else if cluster.count < 2 { offset = 0 }
            else if cluster.count == 2, cluster[0] == cluster[1] { offset = 1 }
            else { offset = cluster.indices.first { onsets.contains(String(cluster[$0...])) } ?? (cluster.count - 1) }
            return left.upperBound + offset
        }
    }

    private static let consonants: [Character: String] = {
        let rows = ["k": "かきくけこ", "g": "がぎぐげご", "s": "さすせそ", "sh": "し", "z": "ざずぜぞ", "j": "じ",
                    "t": "たてと", "ch": "ち", "ts": "つ", "d": "だでど", "n": "なにぬねの", "h": "はひへほ",
                    "f": "ふ", "b": "ばびぶべぼ", "p": "ぱぴぷぺぽ", "m": "まみむめも", "y": "やゆよ", "r": "らりるれろ", "w": "わを", "v": "ゔ"]
        var result: [Character: String] = [:]
        for (consonant, row) in rows { for char in row { result[char] = consonant } }
        return result
    }()
    private static let kanaOnsets: [String: Set<String>] = [
        "": [""], "b": ["b"], "c": ["k", "s"], "ch": ["ch", "k", "sh"], "ck": ["k"], "d": ["d"], "f": ["f", "h"],
        "g": ["g", "j"], "gh": ["g"], "gn": ["n"], "h": ["h", "f"], "j": ["j"], "k": ["k"], "kn": ["n"], "l": ["r"],
        "m": ["m"], "n": ["n"], "p": ["p"], "ph": ["f", "h"], "ps": ["s"], "q": ["k"], "qu": ["k"], "r": ["r"],
        "s": ["s", "sh", "z"], "sc": ["s", "sh", "k"], "sh": ["sh", "s"], "t": ["t", "ch", "ts"], "th": ["s", "z", "t", "d"],
        "v": ["v", "b"], "w": ["w", "h"], "wh": ["w", "h"], "wr": ["r"], "x": ["k", "z"], "y": ["y", ""], "z": ["z", "j"]
    ]

    private static func onsetClasses(_ plain: [Character], cut: Int) -> Set<String> {
        var end = cut
        while end < plain.count, !isVowel(plain, end), !"'-".contains(plain[end]) { end += 1 }
        let onset = String(plain[cut..<end])
        if ["ti", "ci", "si"].contains(String(onset.prefix(2))) { return ["sh", "s", "ch"] }
        if plain[cut] == "c", cut + 1 < plain.count, "eiy".contains(plain[cut + 1]) { return ["s"] }
        if plain[cut] == "g", cut + 1 < plain.count, "eiy".contains(plain[cut + 1]) { return ["j", "g"] }
        for size in [2, 1] { if let value = kanaOnsets[String(onset.prefix(size))] { return value } }
        return [""]
    }

    static func tokenCuts(word: String, reading: [Character], cuts: [Int]) -> [Int] {
        let plain = letters(word)
        guard plain.count <= 128, !plain.isEmpty, cuts == cuts.sorted(), Set(cuts).count == cuts.count,
              cuts.allSatisfy({ $0 > 0 && $0 < plain.count }) else { return [] }
        var morae: [[Character]] = [], starts: [Int] = []
        for (index, char) in reading.enumerated() {
            if small.contains(char), !morae.isEmpty { morae[morae.count - 1].append(char) }
            else { starts.append(index); morae.append([char]) }
        }
        func consonant(_ i: Int) -> String? {
            let mora = morae[i], first = mora[0]
            if "んっー".contains(first) { return nil }
            if first == "う", mora.count > 1 { return "w" }
            return consonants[first] ?? ""
        }
        var found: [Int] = [], low = 1
        let high = morae.count - 1
        for cut in cuts {
            guard low <= high else { break }
            let wanted = onsetClasses(plain, cut: cut)
            var index = (low...high).first { consonant($0).map { wanted.contains($0) } == true }
            if index == nil, !wanted.contains("") { index = (low...high).first { consonant($0) == "" } }
            if index == nil {
                var proposed = min(max(Int((Double(morae.count * cut) / Double(plain.count)).rounded(.toNearestOrEven)), low), high)
                while proposed <= high, consonant(proposed) == nil { proposed += 1 }
                index = proposed <= high ? proposed : (low...high).first { consonant($0).map { !$0.isEmpty } == true }
            }
            guard let index else { break }
            found.append(starts[index]); low = index + 1
        }
        return found
    }

    static func pieces(text: String, wordRange: NSRange, reading: [Character]) -> [Piece] {
        let source = text as NSString, word = source.substring(with: wordRange), chars = Array(word)
        let cuts = cuts(word), tokenCuts = tokenCuts(word: word, reading: reading, cuts: cuts)
        guard !tokenCuts.isEmpty else { return [] }
        let charEdges = [0] + Array(cuts.prefix(tokenCuts.count)) + [chars.count]
        let tokenEdges = [0] + tokenCuts + [reading.count]
        var result: [Piece] = []
        for index in 0..<(tokenEdges.count - 1) {
            let tokens = tokenEdges[index]..<tokenEdges[index + 1]
            result.append(.init(text: String(chars[charEdges[index]..<charEdges[index + 1]]), tokens: tokens,
                                endsInLongMark: reading[tokens.upperBound - 1] == "ー"))
        }
        result[0].text = source.substring(to: wordRange.location) + result[0].text
        result[result.count - 1].text += source.substring(from: NSMaxRange(wordRange))
        return result
    }
}
