import SwiftUI

struct PriorityList: View {
    struct Entry: Identifiable {
        var id: String
        var title: String
        var detail: String?
    }

    var entries: [Entry]
    @Binding var order: [String]
    var allowsDisabling: Bool
    @Environment(\.theme) private var theme

    private var enabled: [Entry] {
        order.compactMap { id in entries.first { $0.id == id } }
    }

    private var disabled: [Entry] {
        entries.filter { !order.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 6) {
            let enabled = enabled
            ForEach(Array(enabled.enumerated()), id: \.element.id) { index, entry in
                row(entry, rank: index + 1, isEnabled: true, canMoveUp: index > 0, canMoveDown: index < enabled.count - 1)
            }
            if allowsDisabling {
                ForEach(disabled) { entry in
                    row(entry, rank: nil, isEnabled: false, canMoveUp: false, canMoveDown: false)
                }
            }
        }
    }

    private func row(_ entry: Entry, rank: Int?, isEnabled: Bool, canMoveUp: Bool, canMoveDown: Bool) -> some View {
        HStack(spacing: 10) {
            Text(rank.map(String.init) ?? "–")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(isEnabled ? theme.accent : theme.onSurfaceVariant)
                .contentTransition(.numericText())
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13, weight: .medium))
                if let detail = entry.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(theme.onSurfaceVariant) }
            }
            .foregroundStyle(isEnabled ? theme.onSurface : theme.onSurfaceVariant)
            Spacer(minLength: 8)
            if isEnabled {
                IconButton(systemName: "chevron.up", size: 26, iconSize: 11, help: "上移") { move(entry.id, by: -1) }
                    .disabled(!canMoveUp).opacity(canMoveUp ? 1 : 0.3)
                IconButton(systemName: "chevron.down", size: 26, iconSize: 11, help: "下移") { move(entry.id, by: 1) }
                    .disabled(!canMoveDown).opacity(canMoveDown ? 1 : 0.3)
            }
            if allowsDisabling {
                Toggle("", isOn: Binding(get: { isEnabled }, set: { setEnabled(entry.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func move(_ id: String, by offset: Int) {
        var ids = enabled.map(\.id)
        guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return }
        ids.swapAt(from, from + offset)
        withAnimation(Motion.listEdit) { order = ids }
    }

    private func setEnabled(_ id: String, _ isOn: Bool) {
        var ids = enabled.map(\.id)
        if isOn { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        withAnimation(Motion.listEdit) { order = ids }
    }
}
