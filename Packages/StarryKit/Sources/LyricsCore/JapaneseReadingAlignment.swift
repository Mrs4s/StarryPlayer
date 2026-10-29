import Foundation

public enum JapaneseReadingAlignment {
    public struct Part: Sendable, Equatable {
        public var reading: String
        public var isEstimated: Bool
    }

    private struct Atom {
        var text: String
        var block: Int
        var kana: [Character]?
    }

    private struct Edge {
        var end: Int
        var cost: Int
        var estimated: Bool
    }

    private static let small = Set("ぁぃぅぇぉゃゅょゎゕゖ")
    public static func align(reading: String, to parts: [String]) -> [Part]? {
        align(reading: reading, to: parts) { JapaneseReadingDictionary.shared?.characterReadings(for: $0) ?? [] }
    }

    static func align(reading: String, to parts: [String], characterReadings: [String: [String]]) -> [Part]? {
        align(reading: reading, to: parts) { characterReadings[$0] ?? [] }
    }

    private static func align(reading: String, to parts: [String], lookup: (String) -> [String]) -> [Part]? {
        guard let target = kana(reading), !parts.isEmpty, parts.count <= 64, target.count <= 128 else { return nil }
        if parts.count == 1 { return [.init(reading: String(target), isEstimated: false)] }
        var atoms: [Atom] = []
        for (block, part) in parts.enumerated() {
            for char in part.precomposedStringWithCompatibilityMapping where !char.isWhitespace {
                if let own = kana(String(char)) {
                    if small.contains(char), let previous = atoms.last, previous.block == block, previous.kana != nil {
                        atoms[atoms.count - 1].text.append(char)
                        atoms[atoms.count - 1].kana! += own
                    } else { atoms.append(.init(text: String(char), block: block, kana: own)) }
                } else if isHan(char) {
                    atoms.append(.init(text: String(char), block: block, kana: nil))
                } else { return nil }
            }
        }
        guard !atoms.isEmpty, atoms.count <= 64, Set(atoms.map(\.block)).count == parts.count else { return nil }
        let width = target.count + 1, size = (atoms.count + 1) * width
        let infinity = Int.max / 4
        func boundary(_ index: Int) -> Bool { index == target.count || !small.contains(target[index]) }
        var edges = [[[Edge]]](repeating: [[Edge]](repeating: [], count: width), count: atoms.count)
        for (index, atom) in atoms.enumerated() {
            let candidates: [([Character], Int)]
            if let own = atom.kana { candidates = [(own, 0)] }
            else { candidates = lookup(atom.text).flatMap(variants) }
            for start in 0..<target.count where boundary(start) {
                var choices: [Int: Edge] = [:]
                for (value, cost) in candidates where !value.isEmpty && start + value.count <= target.count {
                    let end = start + value.count
                    if boundary(end), target[start..<end].elementsEqual(value), cost < choices[end]?.cost ?? infinity {
                        choices[end] = .init(end: end, cost: cost, estimated: false)
                    }
                }
                if atom.kana == nil {
                    for end in (start + 1)...target.count where boundary(end) && choices[end] == nil {
                        choices[end] = .init(end: end, cost: 128, estimated: true)
                    }
                }
                edges[index][start] = choices.values.sorted { $0.end < $1.end }
            }
        }
        var forward = [Int](repeating: infinity, count: size)
        var backward = forward
        var balance = [Double](repeating: .infinity, count: size)
        var back = [Int](repeating: -1, count: size)
        var estimated = [Bool](repeating: false, count: size)
        forward[0] = 0; balance[0] = 0
        let moraCuts = [0] + (1..<target.count).filter(boundary) + [target.count]
        let preferred = parts.indices.map {
            moraCuts[Int((Double($0 + 1) * Double(moraCuts.count - 1) / Double(parts.count)).rounded())]
        }
        for index in atoms.indices {
            for start in 0..<width where forward[index * width + start] < infinity {
                for edge in edges[index][start] {
                    let destination = (index + 1) * width + edge.end
                    let cost = forward[index * width + start] + edge.cost
                    let endsBlock = index + 1 == atoms.count || atoms[index + 1].block != atoms[index].block
                    // Equal-cost paths remain uncertain; balance only chooses a display split.
                    let tie = balance[index * width + start]
                        + (endsBlock ? pow(Double(edge.end - preferred[atoms[index].block]), 2) : 0)
                    if cost < forward[destination] || (cost == forward[destination] && tie < balance[destination]) {
                        forward[destination] = cost; balance[destination] = tie
                        back[destination] = start; estimated[destination] = edge.estimated
                    }
                }
            }
        }
        let finish = atoms.count * width + target.count, best = forward[finish]
        guard best < infinity else { return nil }
        backward[finish] = 0
        for index in atoms.indices.reversed() {
            for start in 0..<width {
                for edge in edges[index][start] {
                    backward[index * width + start] = min(backward[index * width + start], edge.cost + backward[(index + 1) * width + edge.end])
                }
            }
        }
        var result = [Part](repeating: .init(reading: "", isEstimated: false), count: parts.count)
        var end = target.count
        for index in atoms.indices.reversed() {
            let state = (index + 1) * width + end, start = back[state]
            guard start >= 0 else { return nil }
            let block = atoms[index].block
            result[block].reading = String(target[start..<end]) + result[block].reading
            result[block].isEstimated = result[block].isEstimated || estimated[state]
            end = start
        }
        for index in 1..<atoms.count where atoms[index - 1].block != atoms[index].block {
            let positions = (0..<width).filter { forward[index * width + $0] + backward[index * width + $0] == best }
            if positions.count > 1 {
                result[atoms[index - 1].block].isEstimated = true
                result[atoms[index].block].isEstimated = true
            }
        }
        return result
    }

    private static func variants(_ reading: String) -> [([Character], Int)] {
        guard let value = kana(reading) else { return [] }
        var result = [(value, 0)]
        // Rendaku and gemination must still match the whole-word reading.
        let plain = Array("かきくけこさしすせそたちつてとはひふへほ")
        let voiced = Array("がぎぐげござじずぜぞだぢづでどばびぶべぼ")
        if let first = value.first, let index = plain.firstIndex(of: first) {
            var changed = value; changed[0] = voiced[index]; result.append((changed, 1))
        }
        if let last = value.last, "くきつち".contains(last), value.count > 1 {
            var changed = value; changed[changed.count - 1] = "っ"; result.append((changed, 1))
        }
        return result
    }

    static func kana(_ text: String) -> [Character]? {
        let value = text.precomposedStringWithCompatibilityMapping
        let normalized = String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
        let chars = Array(normalized.filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC } }) else { return nil }
        return chars
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
    }
}
