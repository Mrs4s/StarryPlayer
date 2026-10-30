import Foundation

struct TTMLRuby {
    struct Piece {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
        var agentIDs: [String] = []
    }

    struct Annotation {
        var base: [Piece]
        var ruby: [Piece]
    }

    private struct Element {
        var role: String?
        var start: TimeInterval?
        var end: TimeInterval?
        var agentIDs: [String]
        var content: [Content] = []

        var children: [Element] {
            content.compactMap { if case .span(let element) = $0 { element } else { nil } }
        }
    }

    private indirect enum Content {
        case text(String)
        case span(Element)
    }

    private var stack: [Element]

    init(start: TimeInterval?, end: TimeInterval?, agentIDs: [String]) {
        stack = [Element(role: "container", start: start, end: end, agentIDs: agentIDs)]
    }

    var start: TimeInterval? { stack.first?.start }
    var end: TimeInterval? { stack.first?.end }

    mutating func begin(role: String?, start: TimeInterval?, end: TimeInterval?, agentIDs: [String]) {
        // Direct bases may infer their start from ruby; only nested spans inherit it.
        let parent = stack.last
        let inheritedStart = stack.count > 1 ? parent?.start : nil
        stack.append(Element(role: role, start: start ?? inheritedStart, end: end ?? parent?.end, agentIDs: agentIDs))
    }

    mutating func append(_ text: String) {
        guard let index = stack.indices.last else { return }
        if case .text(let previous) = stack[index].content.last {
            stack[index].content[stack[index].content.count - 1] = .text(previous + text)
        } else {
            stack[index].content.append(.text(text))
        }
    }

    mutating func finishSpan() {
        guard stack.count > 1, let element = stack.popLast() else { return }
        stack[stack.count - 1].content.append(.span(element))
    }

    var annotations: [Annotation] {
        guard let root = stack.first else { return [] }
        let bases = root.children.flatMap { element -> [Element] in
            if element.role == "base" { return [element] }
            return element.role == "baseContainer" ? element.children.filter { $0.role == "base" } : []
        }
        // Only the first annotation layer is supported.
        let texts = root.children.first(where: { $0.role == "textContainer" })?.children.filter { $0.role == "text" }
            ?? root.children.filter { $0.role == "text" }
        let legacy = root.children.contains(where: { $0.role == "base" })
            && root.children.contains(where: { $0.role == "textContainer" })
        if bases.count == 1, texts.count <= 1 || legacy {
            return [Annotation(base: Self.pieces(in: bases[0]), ruby: Self.cleaned(texts.flatMap { Self.pieces(in: $0) }))]
        }
        if bases.count == texts.count {
            return zip(bases, texts).map { Annotation(base: Self.pieces(in: $0), ruby: Self.cleaned(Self.pieces(in: $1))) }
        }
        // Unequal TTML2 base/text counts have no defined pairing.
        return bases.map { Annotation(base: Self.pieces(in: $0), ruby: []) }
    }

    private static func pieces(in element: Element) -> [Piece] {
        var result: [Piece] = []
        for content in element.content {
            switch content {
            case .span(let child):
                if child.role != "delimiter" { result += pieces(in: child) }
            case .text(let raw):
                // Ignore XML indentation, but keep an explicit word break between child spans.
                let text = raw.contains(where: \.isNewline)
                    ? raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "")
                    : raw
                guard !text.isEmpty else { continue }
                if text.allSatisfy(\.isWhitespace) {
                    if !result.isEmpty, result[result.count - 1].text.last?.isWhitespace != true { result[result.count - 1].text += " " }
                } else {
                    result.append(Piece(text: text, start: element.start, end: element.end, agentIDs: element.agentIDs))
                }
            }
        }
        return result
    }

    private static func cleaned(_ pieces: [Piece]) -> [Piece] {
        var result = pieces.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for index in result.indices {
            let space = index < result.count - 1 && result[index].text.last?.isWhitespace == true
            result[index].text = result[index].text.trimmingCharacters(in: .whitespacesAndNewlines) + (space ? " " : "")
        }
        return result
    }
}
