import Foundation

public struct LyricPerformerRun: Sendable, Hashable {
    /// Indices into the voice's `syllables`.
    public var syllables: Range<Int>
    /// Colours in agent declaration order.
    public var colors: [LyricColor]
    public var label: String?

    public init(syllables: Range<Int>, colors: [LyricColor], label: String? = nil) {
        self.syllables = syllables
        self.colors = colors
        self.label = label
    }
}

public struct LyricPerformerStyle: Sendable, Hashable {
    private let agents: [String: LyricAgent]
    private let order: [String: Int]
    private let colors: [String: LyricColor]

    public init?(document: LyricsDocument) {
        guard document.hasMultipleVocalists, document.agents.contains(where: { $0.color != nil }) else { return nil }
        self.init(agents: document.agents)
    }

    init(agents: [LyricAgent]) {
        var byID: [String: LyricAgent] = [:]
        var order: [String: Int] = [:]
        for (index, agent) in agents.enumerated() where byID[agent.id] == nil {
            byID[agent.id] = agent
            order[agent.id] = index
        }
        self.agents = byID
        self.order = order
        self.colors = Self.colors(of: agents)
    }

    public static func colors(of agents: [LyricAgent]) -> [String: LyricColor] {
        let palette = LyricColor.performerPalette
        let unused = palette.filter { color in !agents.contains { $0.color == color } }
        let fallback = unused.isEmpty ? palette : unused
        var colors: [String: LyricColor] = [:]
        var next = 0
        for agent in agents where colors[agent.id] == nil {
            if let color = agent.color {
                colors[agent.id] = color
            } else {
                colors[agent.id] = fallback[next % fallback.count]
                next += 1
            }
        }
        return colors
    }

    public func runs(of line: LyricLine) -> [LyricPerformerRun] {
        runs(line.syllables, inherited: line.agentIDs)
    }

    public func backgroundRuns(of line: LyricLine) -> [LyricPerformerRun] {
        guard let background = line.background else { return [] }
        return runs(background.syllables, inherited: background.agentIDs.isEmpty ? line.agentIDs : background.agentIDs)
    }

    func runs(_ syllables: [LyricSyllable], inherited: [String]) -> [LyricPerformerRun] {
        var result: [LyricPerformerRun] = []
        for (index, syllable) in syllables.enumerated() {
            let ids = syllable.agentIDs.isEmpty ? inherited : syllable.agentIDs
            let performers = self.performers(ids)
            let run = LyricPerformerRun(syllables: index..<index + 1, colors: performers.compactMap { colors[$0.id] }, label: label(ids, performers: performers))
            if var last = result.last, syllable.text.allSatisfy(\.isWhitespace) || (last.colors == run.colors && last.label == run.label) {
                last.syllables = last.syllables.lowerBound..<index + 1
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    private func performers(_ ids: [String]) -> [LyricAgent] {
        var result: [LyricAgent] = []
        for id in LyricAgent.references(ids) {
            guard let agent = agents[id] else { continue }
            let expanded = agent.kind == .group && !agent.memberIDs.isEmpty ? agent.memberIDs.compactMap { agents[$0] } : [agent]
            for performer in expanded where !result.contains(where: { $0.id == performer.id }) { result.append(performer) }
        }
        return result.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }

    private func label(_ ids: [String], performers: [LyricAgent]) -> String? {
        let known = LyricAgent.references(ids).compactMap { agents[$0] }
        if known.count == 1, let group = known.first, group.kind == .group, !group.names.isEmpty { return group.displayName }
        let names = performers.filter { !$0.names.isEmpty }.map(\.displayName)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }
}
