import SwiftUI

/// 64 pt header: sidebar button, back, search box; the account chip (with the account switcher,
/// `AccountChip`) and settings on the right. The floating sidebar carries its own button, so the
/// header drops it.
struct NavHeader: View {
    /// The account switcher's (`MainLayout` hangs its panel from the chip).
    var switcherSpace: Namespace.ID
    var switcherEvents: AccountSwitcherEvents
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if model.sidebarMode != .floating {
                IconButton(systemName: "sidebar.left", size: 40, iconSize: 16, help: sidebarHelp) { model.toggleSidebar() }
                    .transition(.opacity)
            }
            IconButton(systemName: "chevron.left", size: 40, iconSize: 16, help: "后退") { model.goBack() }
                .disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.35)

            Color.clear.searchBoxSlot()

            Spacer()

            if !model.registry.sources.isEmpty {
                AccountChip(namespace: switcherSpace, events: switcherEvents)
            }
            Menu {
                Picker("外观", selection: appearanceBinding) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
                Divider()
                Button("设置…") { model.openSettings() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(VariantButtonStyle(variant: .ghost, isCircle: true))
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.headerHeight)
        .contentShape(Rectangle())
        .modifier(WindowDrag())
    }

    private var sidebarHelp: String {
        switch model.sidebarMode {
        case .docked: model.sidebarCollapsed ? "展开侧栏（⌘S）" : "折叠侧栏（⌘S）"
        case .floating, .autoHide: "固定侧栏（⌘S）"
        }
    }

    private var appearanceBinding: Binding<Int> {
        Binding {
            switch model.settings.settings.appearance {
            case .system: 0
            case .light: 1
            case .dark: 2
            }
        } set: { value in
            model.settings.settings.appearance = [.system, .light, .dark][value]
        }
    }
}

/// Makes the header a window drag region on macOS 15+.
struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}
