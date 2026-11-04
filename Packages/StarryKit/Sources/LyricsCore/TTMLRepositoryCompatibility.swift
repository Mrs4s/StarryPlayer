import CryptoKit
import Foundation

enum TTMLRepositoryCompatibility {
    static let metadataKey = "starry:extensions:v1"

    private struct Payload: Codable {
        var version = 1
        var agents: [LyricAgent]
        var lines: [Line]
    }

    private struct Line: Codable {
        var key: String
        var signature: String
        var processedSignature: String
        var singer: LyricSinger
        var agentIDs: [String]
        var main: Voice
        var background: Voice?
        var romanization: Voice?
        var backgroundRomanization: Voice?

        init(_ line: LyricLine, index: Int) {
            key = "L\(index + 1)"
            signature = TTMLRepositoryCompatibility.signature(line, processed: false)
            processedSignature = TTMLRepositoryCompatibility.signature(line, processed: true)
            singer = line.singer
            agentIDs = line.agentIDs
            main = Voice(line.words)
            background = line.background.map { Voice($0.words, agentIDs: $0.agentIDs) }
            romanization = line.romanizationWords.map { Voice($0) }
            backgroundRomanization = line.background?.romanizationWords.map { Voice($0) }
        }

        func isValid(for line: LyricLine) -> Bool {
            main.isValid(for: line.words)
                && (background?.isValid(for: line.background?.words ?? []) ?? true)
                && (romanization?.isValid(for: line.romanizationWords ?? []) ?? true)
                && (backgroundRomanization?.isValid(for: line.background?.romanizationWords ?? []) ?? true)
        }

        func restore(_ line: inout LyricLine) {
            line.singer = singer
            line.agentIDs = agentIDs
            main.restore(&line.words)
            if let background, var voice = line.background {
                background.restore(&voice.words)
                voice.agentIDs = background.agentIDs
                voice.start = voice.words.first?.start ?? voice.start
                voice.end = voice.words.last?.end ?? voice.end
                if let backgroundRomanization, var words = voice.romanizationWords {
                    backgroundRomanization.restore(&words)
                    voice.romanizationWords = words
                }
                line.background = voice
            }
            if let romanization, var words = line.romanizationWords {
                romanization.restore(&words)
                line.romanizationWords = words
            }
            line.primaryStart = line.background == nil ? line.start : line.words.first?.start ?? line.start
            line.primaryEnd = line.background == nil ? line.end : line.words.last?.end ?? line.end
        }
    }

    private struct Voice: Codable {
        var agentIDs: [String]
        var syllables: [Syllable]

        init(_ words: [LyricWord], agentIDs: [String] = []) {
            self.agentIDs = agentIDs
            syllables = words.flatMap(\.syllables).enumerated().compactMap { index, syllable in
                guard !syllable.ruby.isEmpty || !syllable.groupRuby.isEmpty || syllable.joinsRubyGroup || !syllable.agentIDs.isEmpty else { return nil }
                return Syllable(syllable, index: index)
            }
        }

        func isValid(for words: [LyricWord]) -> Bool {
            let count = words.reduce(0) { $0 + $1.syllables.count }
            return Set(syllables.map(\.index)).count == syllables.count && syllables.allSatisfy { saved in
                (0..<count).contains(saved.index)
                    && (saved.start.map(TTMLRepositoryCompatibility.validTime) ?? true)
                    && (saved.end.map(TTMLRepositoryCompatibility.validTime) ?? true)
                    && (saved.start ?? 0) <= (saved.end ?? .greatestFiniteMagnitude)
                    && ((saved.ruby ?? []) + (saved.groupRuby ?? [])).allSatisfy {
                        TTMLRepositoryCompatibility.validTime($0.start) && TTMLRepositoryCompatibility.validTime($0.end) && $0.start <= $0.end
                    }
            }
        }

        func restore(_ words: inout [LyricWord]) {
            guard !syllables.isEmpty else { return }
            var base = words.flatMap(\.syllables)
            for saved in syllables where base.indices.contains(saved.index) {
                if let ruby = saved.ruby {
                    base[saved.index].ruby = ruby.map(\.value)
                    base[saved.index].start = saved.start ?? base[saved.index].start
                    base[saved.index].end = saved.end ?? base[saved.index].end
                }
                if let ruby = saved.groupRuby { base[saved.index].groupRuby = ruby.map(\.value) }
                base[saved.index].joinsRubyGroup = saved.joinsRubyGroup ?? false
                base[saved.index].agentIDs = saved.agentIDs ?? []
            }
            words = LyricWordGrouping.words(from: base)
        }
    }

    private struct Syllable: Codable {
        var index: Int
        var start: TimeInterval?
        var end: TimeInterval?
        var ruby: [Reading]?
        var groupRuby: [Reading]?
        var joinsRubyGroup: Bool?
        var agentIDs: [String]?

        init(_ syllable: LyricSyllable, index: Int) {
            self.index = index
            if !syllable.ruby.isEmpty {
                start = syllable.start
                end = syllable.end
                ruby = syllable.ruby.map(Reading.init)
            }
            if !syllable.groupRuby.isEmpty { groupRuby = syllable.groupRuby.map(Reading.init) }
            if syllable.joinsRubyGroup { joinsRubyGroup = true }
            if !syllable.agentIDs.isEmpty { agentIDs = syllable.agentIDs }
        }
    }

    private struct Reading: Codable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String

        init(_ ruby: LyricRuby) {
            start = ruby.start
            end = ruby.end
            text = ruby.text
        }

        var value: LyricRuby { .init(start: start, end: end, text: text) }
    }

    static func encode(_ exportedTTML: String) -> String? {
        guard let document = try? TTMLParser.parse(exportedTTML, alignRomanization: false) else { return nil }
        let payload = Payload(agents: document.agents, lines: document.lines.enumerated().map { Line($0.element, index: $0.offset) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload))?.base64EncodedString()
    }

    static func restore(in document: inout LyricsDocument, lineKeys: [String?], hasNativeExtensions: Bool) {
        guard let value = document.metadata.removeValue(forKey: metadataKey), !hasNativeExtensions,
              let data = Data(base64Encoded: value), let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1, payload.lines.count == document.lines.count, lineKeys.count == document.lines.count else { return }
        let keys = payload.lines.map(\.key)
        guard Set(keys).count == keys.count, Set(lineKeys.compactMap { $0 }) == Set(keys) else { return }
        let saved = Dictionary(uniqueKeysWithValues: payload.lines.map { ($0.key, $0) })
        let matches = zip(document.lines, lineKeys).compactMap { line, key -> Line? in
            guard let key, let backup = saved[key], backup.isValid(for: line) else { return nil }
            let current = signature(line, processed: false)
            return current == backup.signature || current == backup.processedSignature ? backup : nil
        }
        guard matches.count == document.lines.count else { return }
        for index in document.lines.indices { matches[index].restore(&document.lines[index]) }
        document.agents = LyricAgent.sanitizingMembers(payload.agents)
    }

    private static func validTime(_ time: TimeInterval) -> Bool {
        time.isFinite && time >= 0 && time < Double(Int.max / 1000)
    }

    private static func signature(_ line: LyricLine, processed: Bool) -> String {
        func voice(_ words: [LyricWord]?) -> [[String]]? {
            words.map { words in words.flatMap(\.syllables).map { syllable in
                let start = processed ? syllable.ruby.first?.start ?? syllable.start : syllable.start
                let end = processed ? syllable.ruby.last?.end ?? syllable.end : syllable.end
                return [syllable.text, TTMLWriter.timestamp(start), TTMLWriter.timestamp(end)]
            } }
        }
        let shape: [[[String]]?] = [
            [[TTMLWriter.timestamp(line.start), TTMLWriter.timestamp(line.end)]],
            voice(line.words), voice(line.background?.words), voice(line.romanizationWords), voice(line.background?.romanizationWords),
        ]
        let data = (try? JSONEncoder().encode(shape)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
