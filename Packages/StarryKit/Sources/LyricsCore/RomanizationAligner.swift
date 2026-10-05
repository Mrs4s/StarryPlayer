import Foundation

/// Derive romanization timing by aligning tokenizer readings with the supplied text.
/// Keep the original text and leave weak matches untimed; compare Japanese and Chinese
/// readings for kanji-only lines and pair per-character Chinese tokens directly.
public enum LyricRomanizationAligner {
    /// Above this cost per letter the texts are taken not to match.
    static let maximumCost = 0.45

    public static func alignMissing(in document: inout LyricsDocument) {
        for i in document.lines.indices {
            let line = document.lines[i]
            if line.romanizationWords == nil, line.hasSyllableTiming, let text = line.romanization {
                document.lines[i].romanizationWords = align(text, to: line.words)
            }
            if var background = line.background, background.romanizationWords == nil, background.hasSyllableTiming, let text = background.romanization {
                background.romanizationWords = align(text, to: background.words)
                document.lines[i].background = background
            }
        }
    }

    /// Words of `romanization` timed against `words`, or nil when the texts do not match.
    public static func align(_ romanization: String, to words: [LyricWord]) -> [LyricWord]? {
        let syllables = words.flatMap(\.syllables)
        let tokens = romanization.split(whereSeparator: \.isWhitespace).map { Token(String($0)) }
        guard !syllables.isEmpty, tokens.contains(where: { !$0.letters.isEmpty }) else { return nil }
        let text = syllables.map(\.text).joined()
        if let paired = pairPerCharacter(tokens, syllables: syllables, text: text) { return paired }

        let letters = tokens.flatMap(\.letters)
        var best: (boundary: [Int], cost: Double, readingStart: [Int], japanese: Bool)?
        for identifier in readingLocales(for: text) {
            var expected: [Character] = []
            var starts: [Int] = []
            for r in readings(of: syllables, text: text, locale: identifier) {
                starts.append(expected.count)
                expected += r
            }
            starts.append(expected.count)
            guard let found = alignment(expected, letters), found.cost < best?.cost ?? .infinity else { continue }
            best = (found.boundary, found.cost, starts, identifier == "ja")
        }
        guard let (boundary, _, readingStart, japanese) = best else { return nil }

        var syllableOfLetter = [Int](repeating: 0, count: letters.count)
        for s in syllables.indices {
            let lower = boundary[readingStart[s]], upper = boundary[readingStart[s + 1]]
            for r in lower..<max(lower, upper) { syllableOfLetter[r] = s }
        }
        if let first = syllables.indices.first(where: { readingStart[$0] < readingStart[$0 + 1] }) {
            for r in 0..<boundary[readingStart[first]] { syllableOfLetter[r] = first }
        }

        var pieces: [Piece] = []
        var letter = 0
        for token in tokens {
            guard !token.letters.isEmpty else {
                if let last = pieces.indices.last { pieces[last].trailing += " " + token.text }
                continue
            }
            var runs: [(syllable: Int, text: Substring)] = []
            var runStart = token.text.startIndex
            var current = syllableOfLetter[letter]
            for k in token.letters.indices {
                let s = syllableOfLetter[letter + k]
                if s != current {
                    let cut = token.offsets[k]
                    if cut > runStart { runs.append((current, token.text[runStart..<cut])) }
                    runStart = cut
                    current = s
                }
            }
            runs.append((current, token.text[runStart...]))
            letter += token.letters.count
            pieces.append(Piece(runs: runs, word: wordIndex(of: current, in: words)))
        }
        if japanese, isSpacedByMora(pieces, syllables: syllables) { pieces = joinedPerWord(pieces, words: words) }

        return pieces.enumerated().map { i, piece in
            var parts = piece.runs.map { LyricSyllable(start: syllables[$0.syllable].start, end: syllables[$0.syllable].end, text: String($0.text)) }
            parts[parts.count - 1].text += piece.trailing + (i < pieces.count - 1 ? " " : "")
            return LyricWord(start: parts[0].start, end: parts[parts.count - 1].end, text: parts.map(\.text).joined(), syllables: parts)
        }
    }

    struct Token {
        let text: String
        let letters: [Character]
        let offsets: [String.Index]

        init(_ text: String) {
            self.text = text
            var letters: [Character] = [], offsets: [String.Index] = []
            for i in text.indices {
                for c in LyricRomanizationAligner.fold(text[i]) {
                    letters.append(c)
                    offsets.append(i)
                }
            }
            self.letters = letters
            self.offsets = offsets
        }
    }

    struct Piece {
        var runs: [(syllable: Int, text: Substring)]
        var word: Int
        var trailing = ""
    }

    static func fold(_ c: Character) -> [Character] {
        switch c {
        case "ā", "Ā", "â", "Â": return ["a", "a"]
        case "ī", "Ī", "î", "Î": return ["i", "i"]
        case "ū", "Ū", "û", "Û": return ["u", "u"]
        case "ē", "Ē", "ê", "Ê": return ["e", "e"]
        case "ō", "Ō", "ô", "Ô": return ["o", "u"]
        default:
            let plain = String(c).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            return plain.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { $0 }
        }
    }

    static func fold(_ s: String) -> [Character] { s.flatMap(fold) }

    /// Romanization written one mora per token (`ke i mo u shi te`): most tokens on Japanese
    /// syllables are a single Hepburn mora (Latin words of the line do not count). Word-spaced
    /// romanization has longer tokens, so a word it splits (`janguru jimu`) stays split.
    static func isSpacedByMora(_ pieces: [Piece], syllables: [LyricSyllable]) -> Bool {
        let japanese = pieces.filter { piece in
            syllables[piece.runs[0].syllable].text.unicodeScalars.contains { isKana($0) || isHan($0) }
        }
        guard japanese.count >= 2 else { return false }
        let morae = japanese.filter { isMora(String(fold(piece: $0))) }
        return Double(morae.count) >= Double(japanese.count) * 0.85
    }

    private static func fold(piece: Piece) -> [Character] { piece.runs.flatMap { fold(String($0.text)) } }

    private static func isMora(_ s: String) -> Bool {
        s.range(of: "^(n|[bcdfghjklmnprstvwyz]{0,3}[aeiou]{1,2})$", options: .regularExpression) != nil
    }

    static func joinedPerWord(_ pieces: [Piece], words: [LyricWord]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            if var last = result.last, last.word == piece.word, last.trailing.isEmpty {
                for run in piece.runs {
                    if let tail = last.runs.last, tail.syllable == run.syllable {
                        last.runs[last.runs.count - 1].text = Substring(String(tail.text) + String(run.text))
                    } else {
                        last.runs.append(run)
                    }
                }
                last.trailing = piece.trailing
                result[result.count - 1] = last
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private static func wordIndex(of syllable: Int, in words: [LyricWord]) -> Int {
        var count = 0
        for (w, word) in words.enumerated() {
            count += word.syllables.count
            if syllable < count { return w }
        }
        return max(words.count - 1, 0)
    }

    static func pairPerCharacter(_ tokens: [Token], syllables: [LyricSyllable], text: String) -> [LyricWord]? {
        guard !text.unicodeScalars.contains(where: isKana), text.unicodeScalars.contains(where: isHan) else { return nil }
        let content = syllables.indices.filter { !fold(syllables[$0].text).isEmpty || syllables[$0].text.unicodeScalars.contains(where: isHan) }
        let lettered = tokens.filter { !$0.letters.isEmpty }
        guard content.count == lettered.count,
              content.allSatisfy({ i in
                  let t = syllables[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                  return t.unicodeScalars.count == 1 || !t.unicodeScalars.contains(where: isHan)
              }) else { return nil }
        return zip(content, lettered).enumerated().map { k, pair in
            let s = syllables[pair.0]
            let text = pair.1.text + (k < content.count - 1 ? " " : "")
            return LyricWord(start: s.start, end: s.end, text: text, syllables: [LyricSyllable(start: s.start, end: s.end, text: text)])
        }
    }

    static func readings(of syllables: [LyricSyllable], text: String, locale: String) -> [[Character]] {
        let ns = text as NSString
        var starts: [Int] = []
        var offset = 0
        for s in syllables {
            starts.append(offset)
            offset += s.text.utf16.count
        }
        func syllable(at utf16: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= utf16 { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        var result = [[Character]](repeating: [], count: syllables.count)
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: locale) as CFLocale)
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.length > 0 else { continue }
            let surface = ns.substring(with: NSRange(location: range.location, length: range.length))
            let latin = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String) ?? surface
            let reading = fold(latin)
            guard !reading.isEmpty else { continue }
            var parts: [(syllable: Int, surface: String)] = []
            var cursor = range.location
            let end = range.location + range.length
            while cursor < end {
                let s = syllable(at: cursor)
                let syllableEnd = s + 1 < starts.count ? starts[s + 1] : ns.length
                let upper = min(end, syllableEnd)
                parts.append((s, ns.substring(with: NSRange(location: cursor, length: upper - cursor))))
                cursor = upper
            }
            for (part, letters) in zip(parts, spread(reading, over: parts.map(\.surface))) {
                result[part.syllable] += letters
            }
        }
        return result
    }

    static func spread(_ reading: [Character], over parts: [String]) -> [[Character]] {
        guard parts.count > 1 else { return [reading] }
        let own = parts.map(ownReading)
        if own.allSatisfy({ $0 != nil }) { return own.map { $0! } }
        var result = [[Character]](repeating: [], count: parts.count)
        var position = 0
        var pending: [Int] = []
        func flush(_ letters: ArraySlice<Character>) {
            guard !pending.isEmpty else { return }
            for (i, share) in zip(pending, shares(Array(letters), count: pending.count)) { result[i] = share }
            pending = []
        }
        for (i, part) in own.enumerated() {
            guard let known = part else {
                pending.append(i)
                continue
            }
            guard !known.isEmpty else { continue }
            guard let hit = find(known, in: reading, from: position + pending.count) else { return shares(reading, count: parts.count) }
            if !pending.isEmpty {
                flush(reading[position..<hit])
                result[i] = known
            } else if hit > position, i > 0 {
                // Letters the known parts do not explain stay with the part before.
                result[i - 1] += reading[position..<hit]
                result[i] = known
            } else {
                result[i] = Array(reading[position..<hit]) + known
            }
            position = hit + known.count
        }
        if !pending.isEmpty {
            flush(reading[position...])
        } else if position < reading.count, let last = result.indices.last {
            result[last] += reading[position...]
        }
        return result
    }

    /// Reading of kana or Latin text, nil for anything else (kanji).
    static func ownReading(_ surface: String) -> [Character]? {
        let scalars = surface.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        if scalars.allSatisfy(isKana) {
            // A trailing sokuon tokenizes as `~tsu`; it contributes no romanized letters.
            let latin = (surface.applyingTransform(.toLatin, reverse: false) ?? "").replacingOccurrences(of: "~tsu", with: "").replacingOccurrences(of: "~", with: "")
            return fold(latin)
        }
        if scalars.allSatisfy({ !isHan($0) && !isKana($0) && !isHangul($0) }) { return fold(surface) }
        return nil
    }

    private static func find(_ needle: [Character], in haystack: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from <= haystack.count - needle.count else { return nil }
        for i in from...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    static func shares(_ letters: [Character], count: Int) -> [[Character]] {
        guard count > 1 else { return [letters] }
        let morae = split(morae: letters)
        var result: [[Character]] = []
        var index = 0
        for k in 0..<count {
            let take = (morae.count - index) / (count - k) + ((morae.count - index) % (count - k) > 0 ? 1 : 0)
            result.append(morae[index..<min(morae.count, index + take)].flatMap { $0 })
            index = min(morae.count, index + take)
        }
        return result
    }

    static func split(morae letters: [Character]) -> [[Character]] {
        let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
        var result: [[Character]] = []
        var current: [Character] = []
        for (i, c) in letters.enumerated() {
            let next = i + 1 < letters.count ? letters[i + 1] : nil
            current.append(c)
            if vowels.contains(c) {
                result.append(current)
                current = []
            } else if c == "n", current.count == 1, next.map({ !vowels.contains($0) && $0 != "y" }) ?? true {
                result.append(current)
                current = []
            } else if let next, next == c, !vowels.contains(c) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func readingLocales(for text: String) -> [String] {
        let scalars = text.unicodeScalars
        if scalars.contains(where: isKana) { return ["ja"] }
        if scalars.contains(where: isHangul) { return ["ko"] }
        if scalars.contains(where: isHan) { return ["ja", "zh-Hans"] }
        return ["en"]
    }

    static func isKana(_ s: Unicode.Scalar) -> Bool { (0x3040...0x30FF).contains(s.value) || (0x31F0...0x31FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value) }
    static func isHan(_ s: Unicode.Scalar) -> Bool { (0x3400...0x4DBF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) || (0x20000...0x323AF).contains(s.value) || s.value == 0x3005 }
    static func isHangul(_ s: Unicode.Scalar) -> Bool { (0xAC00...0xD7AF).contains(s.value) || (0x1100...0x11FF).contains(s.value) || (0x3130...0x318F).contains(s.value) }

    /// Letter alignment of the reading `e` with the romanization `r`: for every reading
    /// boundary 0…e.count the romanization boundary it falls on (romanized letters the reading
    /// lacks join the letter before). Nil when the texts differ too much.
    static func alignment(_ e: [Character], _ r: [Character]) -> (boundary: [Int], cost: Double)? {
        let n = e.count, m = r.count
        guard n > 0, m > 0 else { return nil }
        let width = m + 1
        var cost = [Double](repeating: .infinity, count: (n + 1) * width)
        var step = [UInt8](repeating: 0, count: (n + 1) * width)  // 0 match, 1 skip reading, 2 extra romanized
        cost[0] = 0
        for i in 0...n {
            for j in 0...m {
                let here = cost[i * width + j]
                guard here.isFinite else { continue }
                if i < n, j < m {
                    let c = here + substitution(e[i], r[j])
                    if c < cost[(i + 1) * width + j + 1] { cost[(i + 1) * width + j + 1] = c; step[(i + 1) * width + j + 1] = 0 }
                }
                if i < n {
                    let c = here + skipReading(e[i], after: i > 0 ? e[i - 1] : nil)
                    if c < cost[(i + 1) * width + j] { cost[(i + 1) * width + j] = c; step[(i + 1) * width + j] = 1 }
                }
                if j < m {
                    let c = here + extraRomanized(r[j], after: j > 0 ? r[j - 1] : nil)
                    if c < cost[i * width + j + 1] { cost[i * width + j + 1] = c; step[i * width + j + 1] = 2 }
                }
            }
        }
        let total = cost[n * width + m] / Double(max(n, m))
        guard total <= maximumCost else { return nil }
        var path: [UInt8] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let s = step[i * width + j]
            path.append(s)
            switch s {
            case 0: i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        var boundary = [Int](repeating: m, count: n + 1)
        var e0 = 0, r0 = 0
        for s in path.reversed() {
            switch s {
            case 0:
                boundary[e0] = r0
                e0 += 1; r0 += 1
            case 1:
                boundary[e0] = r0
                e0 += 1
            default:
                r0 += 1
            }
        }
        boundary[n] = m
        return (boundary, total)
    }

    private static let similar: Set<String> = ["hw", "wh", "lr", "rl", "dz", "zd", "jz", "zj", "ou", "uo", "nm", "mn", "ie", "ei", "sz", "zs", "fh", "hf", "tc", "ct", "jd", "dj"]

    private static func substitution(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        return similar.contains(String([a, b])) ? 0.4 : 1
    }

    private static func skipReading(_ c: Character, after previous: Character?) -> Double {
        if let previous, previous == c { return 0.5 }
        return "hwudy".contains(c) ? 0.6 : 1
    }

    private static func extraRomanized(_ c: Character, after previous: Character?) -> Double {
        if let previous, previous == c { return 0.5 }
        return "aiueonhw".contains(c) ? 0.7 : 1
    }
}
