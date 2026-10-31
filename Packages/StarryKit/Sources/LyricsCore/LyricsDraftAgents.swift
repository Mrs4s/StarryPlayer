import Foundation

extension LyricAgent {
    public mutating func setName(_ text: String, kind: Name.Kind = .full) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = names.firstIndex(where: { $0.kind == kind && !$0.text.isEmpty }) {
            if text.isEmpty { names.remove(at: index) } else { names[index].text = text }
        } else if !text.isEmpty {
            names.insert(Name(text, kind: kind), at: kind == .full ? 0 : names.endIndex)
        }
    }

    public func name(of kind: Name.Kind) -> String? {
        names.first { $0.kind == kind && !$0.text.isEmpty }?.text
    }
}

extension LyricsDraft {
    public func singer(for ids: [String]) -> LyricSinger {
        LyricAgent.singer(for: ids, in: agents)
    }

    public func agentIDs(at position: Position) -> [String] {
        let own = self[position].agentIDs
        return own.isEmpty ? lines[position.line].agentIDs : own
    }

    public func usage(of id: String) -> (lines: Int, syllables: Int) {
        var usage = (lines: 0, syllables: 0)
        for line in lines {
            if line.agentIDs.contains(id) { usage.lines += 1 }
            usage.syllables += line.syllables.filter { $0.agentIDs.contains(id) }.count
        }
        return usage
    }

    public func newAgentID() -> String {
        var used = Set(agents.map(\.id) + agents.compactMap(\.actorID))
        for line in lines {
            used.formUnion(line.agentIDs)
            for syllable in line.syllables { used.formUnion(syllable.agentIDs) }
        }
        var number = 1
        while used.contains("v\(number)") { number += 1 }
        return "v\(number)"
    }

    public func nextPerformerColor() -> LyricColor {
        let used = Set(agents.compactMap(\.color))
        let palette = LyricColor.performerPalette
        return palette.first { !used.contains($0) } ?? palette[agents.count % palette.count]
    }

    @discardableResult
    public mutating func addAgent(kind: LyricAgent.Kind = .person, name: String) -> LyricAgent {
        var agent = LyricAgent(id: newAgentID(), kind: kind, color: nextPerformerColor())
        agent.setName(name)
        agents.append(agent)
        return agent
    }

    public mutating func updateAgent(_ agent: LyricAgent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        var agent = agent
        if agent.actorID == agent.id || !agents.contains(where: { $0.id == agent.actorID }) { agent.actorID = nil }
        agents[index] = agent
        agents = LyricAgent.sanitizingMembers(agents)
    }

    public mutating func moveAgent(_ id: String, to destination: Int) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        let agent = agents.remove(at: index)
        agents.insert(agent, at: min(max(destination, 0), agents.count))
    }

    public mutating func removeAgent(_ id: String) {
        guard agents.contains(where: { $0.id == id }) else { return }
        agents = LyricAgent.sanitizingMembers(agents.filter { $0.id != id })
        for index in agents.indices where agents[index].actorID == id { agents[index].actorID = nil }
        for index in lines.indices {
            lines[index].agentIDs.removeAll { $0 == id }
            for s in lines[index].syllables.indices { lines[index].syllables[s].agentIDs.removeAll { $0 == id } }
            normalizeInlineAgents(ofLine: index)
        }
    }

    public mutating func setAgents(_ ids: [String], ofLine index: Int) {
        guard lines.indices.contains(index) else { return }
        let ids = LyricAgent.references(ids)
        lines[index].agentIDs = ids
        normalizeInlineAgents(ofLine: index)
    }

    /// Empty IDs inherit the line; matching assignments on every syllable become a line assignment.
    public mutating func setAgents(_ ids: [String], at positions: [Position]) {
        let ids = LyricAgent.references(ids)
        var touched: Set<Int> = []
        for position in positions where contains(position) {
            self[position].agentIDs = Set(ids) == Set(lines[position.line].agentIDs) ? [] : ids
            touched.insert(position.line)
        }
        for index in touched.sorted() {
            let syllables = lines[index].syllables
            if let first = syllables.first?.agentIDs, !first.isEmpty, syllables.allSatisfy({ Set($0.agentIDs) == Set(first) }) {
                setAgents(first, ofLine: index)
            }
        }
    }

    @discardableResult
    public mutating func assignUnassignedLinesBySinger(names: [LyricSinger: String]) -> Int {
        var assigned = 0
        for singer in [LyricSinger.primary, .secondary, .duet] {
            let targets = lines.indices.filter { lines[$0].agentIDs.isEmpty && !lines[$0].syllables.isEmpty && lines[$0].singer == singer }
            guard !targets.isEmpty else { continue }
            let id: String
            if let existing = agents.first(where: { self.singer(for: [$0.id]) == singer }) { id = existing.id }
            else { id = addAgent(kind: singer == .duet ? .group : .person, name: names[singer] ?? "").id }
            for index in targets { setAgents([id], ofLine: index) }
            assigned += targets.count
        }
        return assigned
    }

    private mutating func normalizeInlineAgents(ofLine index: Int) {
        let inherited = Set(lines[index].agentIDs)
        for s in lines[index].syllables.indices where !lines[index].syllables[s].agentIDs.isEmpty && Set(lines[index].syllables[s].agentIDs) == inherited {
            lines[index].syllables[s].agentIDs = []
        }
    }

}
