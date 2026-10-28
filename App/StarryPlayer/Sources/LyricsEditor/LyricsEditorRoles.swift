import AppKit
import LyricsCore
import SwiftUI

// MARK: - Session

extension LyricsEditorSession {
    static let legacyRoleNames: [LyricSinger: String] = [.primary: "主唱", .secondary: "对唱", .duet: "合唱"]

    nonisolated static func name(of agent: LyricAgent) -> String {
        agent.names.contains { !$0.text.isEmpty } ? agent.displayName : "未命名（\(agent.id)）"
    }

    nonisolated static func newAgentName(_ kind: LyricAgent.Kind, after agents: [LyricAgent]) -> String {
        let base = LyricsEditorRoleStyle.newName(for: kind)
        let names = Set(agents.map(\.displayName))
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    func agentName(_ id: String) -> String {
        draft.agents.first { $0.id == id }.map(Self.name(of:)) ?? id
    }

    @discardableResult
    func addAgent(kind: LyricAgent.Kind) -> String {
        var id = ""
        edit { draft in id = draft.addAgent(kind: kind, name: Self.newAgentName(kind, after: draft.agents)).id }
        return id
    }

    func updateAgent(_ agent: LyricAgent) {
        edit { $0.updateAgent(agent) }
    }

    func moveAgent(_ id: String, by offset: Int) {
        guard let index = draft.agents.firstIndex(where: { $0.id == id }) else { return }
        edit { $0.moveAgent(id, to: index + offset) }
    }

    func removeAgent(_ id: String) {
        let name = agentName(id)
        let usage = draft.usage(of: id)
        edit { $0.removeAgent(id) }
        flash(usage.lines + usage.syllables == 0 ? "已删除「\(name)」" : "已删除「\(name)」，它单独演唱的部分改为未分配，可用 ⌘Z 撤销")
    }

    func setAgents(_ ids: [String], ofLines lineIDs: [UUID]) {
        edit { draft in
            for id in lineIDs {
                if let index = draft.lines.firstIndex(where: { $0.id == id }) { draft.setAgents(ids, ofLine: index) }
            }
        }
    }

    func toggleAgent(_ agent: String, ofLine lineID: UUID) {
        edit { draft in
            guard let index = draft.lines.firstIndex(where: { $0.id == lineID }) else { return }
            var ids = draft.lines[index].agentIDs
            if let i = ids.firstIndex(of: agent) { ids.remove(at: i) } else { ids.append(agent) }
            draft.setAgents(ids, ofLine: index)
        }
    }

    func setAgents(_ ids: [String], at positions: [Position]) {
        edit { $0.setAgents(ids, at: positions) }
    }

    func assignUnassignedLinesBySinger() {
        var count = 0
        edit { count = $0.assignUnassignedLinesBySinger(names: Self.legacyRoleNames) }
        flash(count == 0 ? "没有需要分配的行" : "已按主唱、对唱、合唱分配 \(count) 行")
    }

    func clearAgentAssignments() {
        edit { draft in
            for index in draft.lines.indices {
                if !draft.lines[index].agentIDs.isEmpty { draft.setAgents([], ofLine: index) }
                for s in draft.lines[index].syllables.indices { draft.lines[index].syllables[s].agentIDs = [] }
            }
        }
    }
}

// MARK: - Style

enum LyricsEditorRoleStyle {
    private static let palette: [(light: String, dark: String)] = [
        ("#D9695B", "#F08A7C"), ("#4C6FD1", "#86A2F0"), ("#3F9A66", "#6CC892"), ("#C98A1E", "#E9B34F"),
        ("#8462CC", "#AF94EE"), ("#2F93A3", "#5EC0CF"), ("#C2558D", "#E58AB8"), ("#7D8A35", "#B0BD5E"),
    ]

    static let kinds: [(LyricAgent.Kind, String)] = [
        (.person, "歌手"), (.group, "组合"), (.character, "剧中角色"), (.organization, "机构"), (.other, "其他"),
    ]

    static func color(_ index: Int, dark: Bool) -> Color {
        let entry = palette[index % palette.count]
        return Color(hex: dark ? entry.dark : entry.light)
    }

    static func color(of id: String, in agents: [LyricAgent], dark: Bool) -> Color? {
        agents.firstIndex { $0.id == id }.map { color($0, dark: dark) }
    }

    static func title(of kind: LyricAgent.Kind) -> String {
        kinds.first { $0.0 == kind }?.1 ?? "其他"
    }

    static func newName(for kind: LyricAgent.Kind) -> String {
        switch kind {
        case .group: "组合"
        case .character: "剧中角色"
        default: "歌手"
        }
    }

    static func side(_ singer: LyricSinger) -> String {
        switch singer {
        case .primary: "左侧"
        case .secondary: "右侧"
        case .duet: "居中"
        }
    }

    @MainActor static func names(_ ids: [String], in session: LyricsEditorSession) -> String? {
        guard !ids.isEmpty else { return nil }
        let names = ids.map(session.agentName)
        return names.count > 2 ? names.prefix(2).joined(separator: "、") + " 等 \(names.count) 位" : names.joined(separator: "、")
    }
}

// MARK: - Menus

@MainActor
enum LyricsEditorRoleMenu {
    static func lineItems(_ session: LyricsEditorSession, line id: UUID, manage: (() -> Void)?) -> [PopMenuItem] {
        guard let line = session.draft.lines.first(where: { $0.id == id }) else { return [] }
        let agents = session.draft.agents
        let ids = line.agentIDs
        var items: [PopMenuItem] = [.option("未分配", selected: ids.isEmpty) { session.setAgents([], ofLines: [id]) }]
        for agent in agents {
            items.append(.option(LyricsEditorSession.name(of: agent), selected: ids == [agent.id]) { session.setAgents([agent.id], ofLines: [id]) })
        }
        if agents.count > 1 {
            items.append(.submenu("同唱", systemImage: "person.2", detail: ids.count > 1 ? "\(ids.count) 位" : nil) {
                for agent in agents {
                    PopMenuItem.option(LyricsEditorSession.name(of: agent), selected: ids.contains(agent.id)) { session.toggleAgent(agent.id, ofLine: id) }
                }
            })
        }
        if let manage {
            items += [.divider, .button("管理演唱角色…", systemImage: "person.crop.rectangle.stack", action: manage)]
        }
        return PopMenuItem.tidy(items)
    }

    static func syllableItem(_ session: LyricsEditorSession, positions: [LyricsDraft.Position]) -> PopMenuItem {
        let agents = session.draft.agents
        let positions = positions.filter { session.draft.contains($0) }
        guard !agents.isEmpty, !positions.isEmpty else { return .empty }
        let own = Set(positions.map { session.draft[$0].agentIDs })
        let current = own.count == 1 ? own.first : nil
        let detail = current.flatMap { $0.isEmpty ? "跟随所在行" : LyricsEditorRoleStyle.names($0, in: session) }
        return .submenu("单独演唱", systemImage: "person.wave.2", detail: detail) {
            PopMenuItem.option("跟随所在行", selected: current == [String]()) { session.setAgents([], at: positions) }
            PopMenuItem.divider
            for agent in agents {
                PopMenuItem.option(LyricsEditorSession.name(of: agent), selected: current == [agent.id]) { session.setAgents([agent.id], at: positions) }
            }
        }
    }
}

// MARK: - Panel

struct LyricsEditorRoles: View {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    var play: (Int) -> Void
    var close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var selectedID: String?
    @State private var addedID: String?
    @State private var filter = Filter.all
    @State private var anchor: UUID?
    @Namespace private var roleSelection

    private enum Filter: Hashable { case all, unassigned, role }

    private var agents: [LyricAgent] { session.draft.agents }
    private var selected: LyricAgent? { agents.first { $0.id == selectedID } ?? agents.first }

    private var unassigned: [UUID] {
        session.draft.lines.filter { $0.agentIDs.isEmpty && !$0.syllables.isEmpty }.map(\.id)
    }

    private var visibleLines: [(index: Int, line: LyricsDraft.Line)] {
        session.draft.lines.enumerated().compactMap { index, line in
            switch filter {
            case .all: return (index, line)
            case .unassigned: return line.agentIDs.isEmpty && !line.syllables.isEmpty ? (index, line) : nil
            case .role:
                guard let id = selected?.id else { return nil }
                return line.agentIDs.contains(id) || line.syllables.contains { $0.agentIDs.contains(id) } ? (index, line) : nil
            }
        }
    }

    var body: some View {
        EditorPanel(title: "演唱角色", subtitle: "为歌词行指定演唱者。排在最前的歌手显示在左侧，其他歌手在右侧，组合或多人同唱居中。", width: 900, close: close) {
            HStack(alignment: .top, spacing: 18) {
                roleColumn
                    .frame(width: 280)
                Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(width: 1)
                assignmentColumn
            }
            .frame(height: 452)
            footer
        }
        .onAppear { if selectedID == nil { selectedID = agents.first?.id } }
        .onChange(of: agents.map(\.id)) { _, ids in
            guard let selectedID, !ids.contains(selectedID) else { return }
            withAnimation(Motion.selection) { self.selectedID = ids.first }
        }
    }

    // MARK: Roles

    private var roleColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(agents.isEmpty ? "角色" : "角色 · \(agents.count)")
                Spacer(minLength: 0)
                addMenu
            }
            if agents.isEmpty {
                emptyRoles.transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            LyricsEditorRoleRow(session: session, agent: agent, index: index, isSelected: agent.id == selected?.id, namespace: roleSelection) {
                                withAnimation(Motion.selection) { selectedID = agent.id }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 196)
                .fixedSize(horizontal: false, vertical: true)
                if let selected, let index = agents.firstIndex(of: selected) {
                    LyricsEditorRoleDetail(session: session, agent: selected, index: index, focusName: selected.id == addedID)
                        .id(selected.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.listEdit, value: agents.map(\.id))
        .animation(Motion.selection, value: selected?.id)
    }

    private var addMenu: some View {
        PopMenu {
            PopMenuItem.button("歌手", systemImage: "person") { add(.person) }
            PopMenuItem.button("组合", systemImage: "person.3") { add(.group) }
            PopMenuItem.button("剧中角色", systemImage: "theatermasks") { add(.character) }
        } label: { _ in
            Label("添加", systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 28)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isPill: true))
        .help("添加歌手、组合或剧中角色")
    }

    private var emptyRoles: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.onSurfaceVariant)
            Text("还没有演唱角色")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.onSurface)
            Text("添加歌手后，在右侧点按歌词行即可分配；已有的主唱、对唱、合唱也可以直接转成角色。")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                PillButton(title: "按现有演唱生成", systemName: "wand.and.stars", variant: .secondary, height: 30, action: generate)
                    .disabled(unassigned.isEmpty)
                    .opacity(unassigned.isEmpty ? 0.45 : 1)
                    .help("为主唱、对唱、合唱各建一个角色，并把对应的行交给它")
                PillButton(title: "添加歌手", systemName: "plus", variant: .tertiary, height: 30) { add(.person) }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(theme.onSurface.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    private func add(_ kind: LyricAgent.Kind) {
        let id = session.addAgent(kind: kind)
        addedID = id
        withAnimation(Motion.selection) { selectedID = id }
    }

    private func generate() {
        session.assignUnassignedLinesBySinger()
        withAnimation(Motion.selection) { selectedID = agents.first?.id }
    }

    // MARK: Assignments

    private var assignmentColumn: some View {
        let lines = visibleLines
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SegmentSwitch(selection: $filter, options: [
                    (.all, "全部"),
                    (.unassigned, unassigned.isEmpty ? "未分配" : "未分配 \(unassigned.count)"),
                    (.role, selected.map { "「\(LyricsEditorSession.name(of: $0))」" } ?? "当前角色"),
                ])
                .controlSize(.small)
                Spacer(minLength: 0)
                bulkMenu
            }
            ZStack {
                if lines.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .transition(.opacity)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(lines, id: \.line.id) { item in
                            LyricsEditorRoleLineRow(session: session, clock: clock, line: item.line, index: item.index, role: selected?.id) {
                                tap(item.line)
                            } play: {
                                play(item.index)
                            }
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.onSurface.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .animation(Motion.listEdit, value: lines.map(\.line.id))
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .contentTransition(.opacity)
        }
        .animation(Motion.hover, value: filter)
    }

    private var emptyText: String {
        switch filter {
        case .all: "还没有歌词"
        case .unassigned: "每一行都有演唱者了"
        case .role: "这个角色还没有演唱任何一行"
        }
    }

    private var hint: String {
        guard let selected else { return "先在左侧添加角色，再点按歌词行分配。" }
        return "点按：交给「\(LyricsEditorSession.name(of: selected))」，再点一次取消　⌘ 点按：加入同唱　⇧ 点按：连续分配"
    }

    private var bulkMenu: some View {
        let name = selected.map(LyricsEditorSession.name(of:))
        let unassigned = unassigned
        let assigned = session.draft.lines.contains { !$0.agentIDs.isEmpty || $0.syllables.contains { !$0.agentIDs.isEmpty } }
        return PopMenu {
            PopMenuItem.button(name.map { "把未分配的行交给「\($0)」" } ?? "把未分配的行交给当前角色", systemImage: "arrow.right.circle", disabled: selected == nil || unassigned.isEmpty) {
                guard let id = selected?.id else { return }
                session.setAgents([id], ofLines: unassigned)
                session.flash("已把 \(unassigned.count) 行交给「\(name ?? id)」")
            }
            PopMenuItem.button("按主唱、对唱、合唱分配未分配的行", systemImage: "wand.and.stars", disabled: unassigned.isEmpty, action: generate)
            PopMenuItem.divider
            PopMenuItem.button("清除全部分配", systemImage: "eraser", role: .destructive, disabled: !assigned) {
                session.clearAgentAssignments()
                session.flash("已清除全部角色分配，可用 ⌘Z 撤销")
            }
        } label: { _ in
            Label("批量", systemImage: "square.stack.3d.up")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.onSurface.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 28)
        }
        .buttonStyle(VariantButtonStyle(variant: .ghost, isPill: true))
        .help("一次分配或清除多行")
    }

    private func tap(_ line: LyricsDraft.Line) {
        guard let role = selected?.id else { return session.flash("先在左侧添加或选中一个角色") }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let order = visibleLines.map(\.line.id)
        if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: line.id) {
            session.setAgents([role], ofLines: Array(order[min(from, to)...max(from, to)]))
        } else if flags.contains(.command) {
            session.toggleAgent(role, ofLine: line.id)
        } else {
            session.setAgents(line.agentIDs == [role] ? [] : [role], ofLines: [line.id])
        }
        anchor = line.id
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward", size: 30, iconSize: 13, help: "撤销（⌘Z）") { session.undo() }
                    .disabled(!session.canUndo)
                    .opacity(session.canUndo ? 1 : 0.4)
                    .accessibilityLabel("撤销")
                IconButton(systemName: "arrow.uturn.forward", size: 30, iconSize: 13, help: "重做（⇧⌘Z）") { session.redo() }
                    .disabled(!session.canRedo)
                    .opacity(session.canRedo ? 1 : 0.4)
                    .accessibilityLabel("重做")
            }
            Text("修改立即生效。角色随歌词工程保存，应用到歌曲或导出时写入 TTML。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
            Spacer(minLength: 0)
            PillButton(title: "保存工程…", systemName: "square.and.arrow.down.on.square", variant: .tertiary, height: 32) {
                model.saveLyricsProject(session)
            }
            .disabled(session.draft.isEmpty)
            .opacity(session.draft.isEmpty ? 0.45 : 1)
            .help("保存 .starrylyrics 工程（⇧⌘S）")
            PillButton(title: "完成", variant: .filled, height: 32, action: close)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.onSurfaceVariant)
            .contentTransition(.numericText())
    }
}

// MARK: - Role list

private struct LyricsEditorRoleRow: View {
    let session: LyricsEditorSession
    let agent: LyricAgent
    var index: Int
    var isSelected: Bool
    var namespace: Namespace.ID
    var select: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let lines = session.draft.usage(of: agent.id).lines
        Button(action: select) {
            HStack(spacing: 10) {
                LyricsEditorRoleAvatar(agent: agent, index: index, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LyricsEditorSession.name(of: agent))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text("\(LyricsEditorRoleStyle.title(of: agent.kind)) · \(LyricsEditorRoleStyle.side(session.draft.singer(for: [agent.id])))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 6)
                Text(lines == 0 ? "未使用" : "\(lines) 行")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(theme.onSurfaceVariant.opacity(lines == 0 ? 0.7 : 1))
                    .contentTransition(.numericText(value: Double(lines)))
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.menu, style: .continuous)
                        .fill(theme.onSurface.opacity(theme.isDark ? 0.09 : 0.06))
                        .matchedGeometryEffect(id: "role", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Radius.menu, style: .continuous)
                        .fill(theme.onSurface.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.selection, value: lines)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct LyricsEditorRoleAvatar: View {
    var agent: LyricAgent
    var index: Int
    var size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let color = LyricsEditorRoleStyle.color(index, dark: theme.isDark)
        ZStack {
            Circle().fill(color.opacity(0.16))
            switch agent.kind {
            case .group:
                Image(systemName: "person.2.fill").font(.system(size: size * 0.36, weight: .semibold))
            case .organization:
                Image(systemName: "building.2.fill").font(.system(size: size * 0.36, weight: .semibold))
            default:
                Text(LyricsEditorSession.name(of: agent).first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .contentTransition(.opacity)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(color.opacity(0.32), lineWidth: 1))
        .animation(Motion.selection, value: index)
        .animation(Motion.selection, value: agent.kind)
        .accessibilityHidden(true)
    }
}

// MARK: - Role detail

private struct LyricsEditorRoleDetail: View {
    let session: LyricsEditorSession
    let agent: LyricAgent
    var index: Int
    var focusName: Bool
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var alias = ""
    @FocusState private var focused: Field?

    private enum Field { case name, alias }

    var body: some View {
        let usage = session.draft.usage(of: agent.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LyricsEditorRoleAvatar(agent: agent, index: index, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LyricsEditorSession.name(of: agent))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(usageText(usage))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .contentTransition(.numericText(value: Double(usage.lines)))
                }
                Spacer(minLength: 0)
                IconButton(systemName: "chevron.up", size: 26, iconSize: 11, help: "上移；排在最前的歌手显示在左侧") { session.moveAgent(agent.id, by: -1) }
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.35 : 1)
                IconButton(systemName: "chevron.down", size: 26, iconSize: 11, help: "下移") { session.moveAgent(agent.id, by: 1) }
                    .disabled(index >= session.draft.agents.count - 1)
                    .opacity(index >= session.draft.agents.count - 1 ? 0.35 : 1)
                IconButton(systemName: "trash", size: 26, iconSize: 11, help: "删除角色；它单独演唱的部分改为未分配") { session.removeAgent(agent.id) }
                    .accessibilityLabel("删除角色")
            }
            row("名称") { field("角色名称", text: $name, as: .name) }
            row("别名") { field("可选，如简称或艺名", text: $alias, as: .alias) }
            row("类型") {
                SettingsMenu(selection: Binding { agent.kind } set: { kind in
                    var updated = agent
                    updated.kind = kind
                    if kind != .character { updated.actorID = nil }
                    session.updateAgent(updated)
                }, options: LyricsEditorRoleStyle.kinds, width: 150)
            }
            if agent.kind == .character {
                row("饰演者") {
                    SettingsMenu(selection: Binding { agent.actorID } set: { actor in
                        var updated = agent
                        updated.actorID = actor
                        session.updateAgent(updated)
                    }, options: actorOptions, width: 150)
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
            Text("ID \(agent.id) · 导出 TTML 时写作 ttm:agent")
                .font(.system(size: 11))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .animation(Motion.fold, value: agent.kind)
        .onAppear {
            name = agent.name(of: .full) ?? ""
            alias = agent.name(of: .alias) ?? ""
            if focusName { focused = .name }
        }
        .onChange(of: agent.name(of: .full)) { _, value in name = value ?? "" }
        .onChange(of: agent.name(of: .alias)) { _, value in alias = value ?? "" }
        .onChange(of: focused) { old, new in
            if let old, old != new { apply(old) }
        }
        .onDisappear {
            apply(.name)
            apply(.alias)
        }
    }

    private var actorOptions: [(String?, String)] {
        [(nil, "未指定")] + session.draft.agents.filter { $0.id != agent.id && $0.kind != .character }.map { ($0.id, LyricsEditorSession.name(of: $0)) }
    }

    private func usageText(_ usage: (lines: Int, syllables: Int)) -> String {
        switch (usage.lines, usage.syllables) {
        case (0, 0): "还没有分配歌词"
        case (let lines, 0): "演唱 \(lines) 行"
        case (0, let syllables): "单独演唱 \(syllables) 个音节"
        case (let lines, let syllables): "演唱 \(lines) 行，另单独演唱 \(syllables) 个音节"
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 44, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, as field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused, equals: field)
            .onSubmit { apply(field) }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(theme.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(theme.primary.opacity(focused == field ? 0.5 : 0), lineWidth: 1))
            .animation(Motion.hover, value: focused)
    }

    private func apply(_ field: Field) {
        var updated = agent
        switch field {
        case .name: updated.setName(name)
        case .alias: updated.setName(alias, kind: .alias)
        }
        if updated != agent { session.updateAgent(updated) }
    }
}

// MARK: - Assignment rows

private struct LyricsEditorRoleLineRow: View {
    let session: LyricsEditorSession
    let clock: LyricsEditorClock
    let line: LyricsDraft.Line
    var index: Int
    var role: String?
    var tap: () -> Void
    var play: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var alignment: Alignment {
        switch line.singer {
        case .primary: .leading
        case .secondary: .trailing
        case .duet: .center
        }
    }

    private var stackAlignment: HorizontalAlignment {
        switch line.singer {
        case .primary: .leading
        case .secondary: .trailing
        case .duet: .center
        }
    }

    private var highlighted: Bool { role.map { line.agentIDs.contains($0) } ?? false }

    private var inline: [String] {
        var seen: Set<String> = []
        return line.syllables.flatMap(\.agentIDs).filter { seen.insert($0).inserted }
    }

    var body: some View {
        let agents = session.draft.agents
        let tint = line.agentIDs.first.flatMap { LyricsEditorRoleStyle.color(of: $0, in: agents, dark: theme.isDark) } ?? theme.onSurface
        HStack(spacing: 8) {
            LyricsEditorRoleActiveMark(clock: clock, index: index)
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                .frame(width: 24, alignment: .trailing)
            bubble(tint: tint, agents: agents)
                .frame(maxWidth: .infinity, alignment: alignment)
            HStack(spacing: 0) {
                IconButton(systemName: "play.fill", size: 24, iconSize: 9, help: "从这一行试听") { play() }
                    .accessibilityLabel("从这一行试听")
                PopMenu {
                    LyricsEditorRoleMenu.lineItems(session, line: line.id, manage: nil)
                } label: { _ in
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.onSurface.opacity(0.85))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true))
                .help("选择这一行的演唱者")
                .accessibilityLabel("选择这一行的演唱者")
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Radius.menu, style: .continuous).fill(theme.onSurface.opacity(hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : Motion.selection, value: line.singer)
        .animation(Motion.selection, value: line.agentIDs)
        .animation(Motion.selection, value: role)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(index + 1) 行，\(line.text)，\(LyricsEditorRoleStyle.names(line.agentIDs, in: session) ?? "未分配")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "试听", play)
    }

    private func bubble(tint: Color, agents: [LyricAgent]) -> some View {
        VStack(alignment: stackAlignment, spacing: 4) {
            HStack(spacing: 6) {
                if line.isBackground { Tag(text: "背景", soft: true) }
                Text(line.syllables.isEmpty ? "空行" : line.text)
                    .font(.system(size: line.isBackground ? 12 : 13, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(line.syllables.isEmpty ? 0.45 : 0.92))
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                if line.agentIDs.isEmpty {
                    Text(line.singer == .primary ? "未分配" : "未分配 · 按\(LyricsEditorSession.legacyRoleNames[line.singer] ?? "")显示")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                        .transition(.opacity)
                } else {
                    ForEach(line.agentIDs, id: \.self) { id in
                        LyricsEditorRoleChip(name: session.agentName(id),
                                             color: LyricsEditorRoleStyle.color(of: id, in: agents, dark: theme.isDark) ?? theme.onSurfaceVariant)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                if !inline.isEmpty {
                    Text("含 \(line.syllables.filter { !$0.agentIDs.isEmpty }.count) 个单独演唱的音节")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .help(LyricsEditorRoleStyle.names(inline, in: session) ?? "")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.card - 2, style: .continuous).fill(tint.opacity(line.agentIDs.isEmpty ? 0.035 : (highlighted ? 0.16 : 0.08))))
        .overlay(RoundedRectangle(cornerRadius: Radius.card - 2, style: .continuous).strokeBorder(tint.opacity(highlighted ? 0.5 : 0), lineWidth: 1))
        .frame(maxWidth: 380, alignment: alignment)
    }
}

private struct LyricsEditorRoleChip: View {
    var name: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct LyricsEditorRoleActiveMark: View {
    let clock: LyricsEditorClock
    var index: Int
    @Environment(\.theme) private var theme

    var body: some View {
        let active = clock.activeLines.contains(index)
        Capsule()
            .fill(theme.primary)
            .frame(width: 3, height: 16)
            .opacity(active ? 1 : 0)
            .scaleEffect(x: 1, y: active ? 1 : 0.4)
            .animation(Motion.selection, value: active)
            .accessibilityHidden(true)
    }
}

// MARK: - Inspector

struct LyricsEditorRolePicker: View {
    let session: LyricsEditorSession
    let line: LyricsDraft.Line
    var manage: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let agents = session.draft.agents
        PopMenu {
            LyricsEditorRoleMenu.lineItems(session, line: line.id, manage: manage)
        } label: { open in
            HStack(spacing: 6) {
                HStack(spacing: -3) {
                    if line.agentIDs.isEmpty {
                        Circle().strokeBorder(theme.onSurfaceVariant.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(width: 9, height: 9)
                    }
                    ForEach(Array(line.agentIDs.prefix(3)), id: \.self) { id in
                        Circle()
                            .fill(LyricsEditorRoleStyle.color(of: id, in: agents, dark: theme.isDark) ?? theme.onSurfaceVariant)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(theme.surfaceAlt, lineWidth: 1.5))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(LyricsEditorRoleStyle.names(line.agentIDs, in: session) ?? "未分配")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.leading, 9)
            .padding(.trailing, 9)
            .frame(height: 26)
            .background(theme.onSurface.opacity(hovering || open ? 0.1 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 180, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.selection, value: line.agentIDs)
        .help("这一行由谁演唱")
        .accessibilityLabel("演唱者：\(LyricsEditorRoleStyle.names(line.agentIDs, in: session) ?? "未分配")")
    }
}
