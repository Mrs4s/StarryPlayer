import AppKit
import SwiftUI

extension Motion {
    /// The menu unfolding from its button (a touch of overshoot), and folding away.
    static let popMenuOpen = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let popMenuFade = Animation.easeOut(duration: 0.12)
    static let popMenuClose = Animation.easeIn(duration: 0.13)
    static let popMenuCloseDuration: TimeInterval = 0.14
    /// The highlight gliding from row to row.
    static let popMenuHighlight = Animation.spring(response: 0.22, dampingFraction: 0.86)
    /// A submenu sliding in over the menu, the card taking its size.
    static let popMenuPage = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// The picked row lighting up before the menu goes.
    static let popMenuPickDelay: TimeInterval = 0.07
}

/// A page of a menu (the menu itself or one of its submenus): its rows, the size they take
/// and its submenus' pages, measured when the menu opens so the card can move between sizes.
final class PopMenuPage: Identifiable {
    let title: String?
    let items: [PopMenuItem]
    let showsIcons: Bool
    let size: CGSize
    let depth: Int
    let children: [Int: PopMenuPage]

    @MainActor
    init(title: String?, items: [PopMenuItem], measurer: PopMenuMeasurer, depth: Int = 0) {
        self.title = title
        self.items = items
        self.depth = depth
        showsIcons = items.contains { $0.systemImage != nil || $0.isChecked }
        var children: [Int: PopMenuPage] = [:]
        for (index, item) in items.enumerated() {
            if case .submenu(let rows) = item.kind, !rows.isEmpty {
                children[index] = PopMenuPage(title: item.title, items: rows, measurer: measurer, depth: depth + 1)
            }
        }
        self.children = children
        size = measurer.size(title: title, items: items, showsIcons: showsIcons)
    }

    var tallest: CGFloat { children.values.reduce(size.height) { max($0, $1.tallest) } }
    var widest: CGFloat { children.values.reduce(size.width) { max($0, $1.widest) } }

    var selectable: [Int] { items.indices.filter { items[$0].isSelectable } }
}

/// The natural size of a page's rows, from the same views the card draws.
@MainActor
final class PopMenuMeasurer {
    private let theme: Theme
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(theme: Theme) {
        self.theme = theme
    }

    func size(title: String?, items: [PopMenuItem], showsIcons: Bool) -> CGSize {
        host.rootView = AnyView(
            PopMenuPageBody(title: title, items: items, showsIcons: showsIcons, session: nil)
                .fixedSize()
                .environment(\.theme, theme)
        )
        let size = host.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// What the card shows and where its highlight is. Rows are addressed by their index in the
/// page shown; `PopMenuSession.backRow` is a submenu's way back at its top.
@MainActor
@Observable
final class PopMenuSession {
    static let backRow = -1

    let theme: Theme
    let layout: PopMenuLayout
    private(set) var stack: [PopMenuPage]
    private(set) var highlighted: Int?
    private(set) var pressed: Int?
    private(set) var presented = false
    @ObservationIgnored var cardFrame: CGRect = .zero
    @ObservationIgnored var onPick: ((@escaping () -> Void) -> Void)?
    @ObservationIgnored private var picked: (() -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(root: PopMenuPage, theme: Theme, layout: PopMenuLayout) {
        stack = [root]
        self.theme = theme
        self.layout = layout
    }

    var page: PopMenuPage { stack[stack.count - 1] }

    func cardSize(of page: PopMenuPage) -> CGSize {
        CGSize(width: min(max(page.size.width, layout.minWidth), layout.frame.width), height: min(page.size.height, layout.maxHeight))
    }

    func present() {
        presented = true
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        presented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.popMenuCloseDuration) {
            MainActor.assumeIsolated { completion() }
        }
    }

    // MARK: Pointer

    func hover(_ row: Int, inside: Bool) {
        guard pressed == nil else { return }
        if inside {
            let selectable = row == Self.backRow || (page.items.indices.contains(row) && page.items[row].isSelectable)
            setHighlight(selectable ? row : nil)
        } else if row == Self.backRow, highlighted == row {
            setHighlight(nil)
        }
    }

    /// The pointer left the card: no row is under it.
    func leave() {
        guard pressed == nil else { return }
        setHighlight(nil)
    }

    func activate(_ row: Int) {
        guard pressed == nil else { return }
        if row == Self.backRow {
            back(closing: false)
            return
        }
        guard page.items.indices.contains(row) else { return }
        let item = page.items[row]
        guard item.isSelectable else { return }
        switch item.kind {
        case .submenu:
            enter(row)
        case .action(let action):
            highlighted = row
            picked = action
            withAnimation(.easeOut(duration: 0.06)) { pressed = row }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.popMenuPickDelay) { [weak self] in
                MainActor.assumeIsolated { self?.firePick() }
            }
        default:
            break
        }
    }

    private func firePick() {
        guard let picked else { return }
        self.picked = nil
        onPick?(picked)
    }

    // MARK: Keyboard

    func moveHighlight(by step: Int) {
        let rows = page.selectable
        guard !rows.isEmpty, pressed == nil else { return }
        let next: Int
        if let current = highlighted, let position = rows.firstIndex(of: current) {
            next = rows[(position + step + rows.count) % rows.count]
        } else if let checked = page.items.firstIndex(where: { $0.isChecked && $0.isSelectable }) {
            // The keys start from the choice made, as a pop-up button's do.
            next = checked
        } else {
            next = step > 0 ? rows[0] : rows[rows.count - 1]
        }
        setHighlight(next)
    }

    func activateHighlighted() {
        if let highlighted { activate(highlighted) }
    }

    func enterHighlighted() {
        if let highlighted, page.children[highlighted] != nil { enter(highlighted, fromKeyboard: true) }
    }

    /// Back to the menu a submenu came from; at the top, closes the menu (Esc) or does nothing (←).
    func back(closing: Bool = true) {
        guard pressed == nil else { return }
        guard stack.count > 1 else {
            if closing { onDismiss?() }
            return
        }
        let left = stack.count - 2
        let parent = stack[left]
        let returnRow = parent.children.first { $0.value === page }?.key
        withAnimation(Motion.popMenuPage) {
            stack.removeLast()
            highlighted = returnRow
        }
    }

    private func enter(_ row: Int, fromKeyboard: Bool = false) {
        guard let child = page.children[row] else { return }
        withAnimation(Motion.popMenuPage) {
            stack.append(child)
            highlighted = fromKeyboard ? child.items.firstIndex { $0.isChecked && $0.isSelectable } ?? child.selectable.first : nil
        }
    }

    private func setHighlight(_ row: Int?) {
        guard highlighted != row else { return }
        withAnimation(Motion.popMenuHighlight) { highlighted = row }
    }
}

/// The panel's content: the card in the corner by the button, with room around it for its
/// shadow and spring.
struct PopMenuCanvas: View {
    let session: PopMenuSession

    var body: some View {
        let frame = session.layout.frame
        PopMenuCard(session: session)
            .frame(width: frame.width, height: frame.height, alignment: session.layout.cardAlignment)
            .padding(PopMenuMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .environment(\.theme, session.theme)
            .environment(\.colorScheme, session.theme.isDark ? .dark : .light)
    }
}

private struct PopMenuCard: View {
    let session: PopMenuSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let page = session.page
        let size = session.cardSize(of: page)
        let presented = session.presented
        let layout = session.layout
        let shape = RoundedRectangle(cornerRadius: PopMenuMetrics.radius, style: .circular)
        ZStack(alignment: .topLeading) {
            ForEach([page]) { page in
                PopMenuPageView(page: page, size: session.cardSize(of: page), session: session)
                    .transition(page.depth == 0 ? .popMenuParent : .popMenuChild)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .background { PopMenuSurface() }
        .contentShape(shape)
        .onHover { inside in
            if !inside { session.leave() }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.cardFrame = $0 }
        .opacity(presented ? 1 : 0)
        .animation(presented ? Motion.popMenuFade : Motion.popMenuClose, value: presented)
        .scaleEffect(x: presented || reduceMotion ? 1 : 0.92, y: presented || reduceMotion ? 1 : 0.8, anchor: layout.unfoldAnchor)
        .offset(presented || reduceMotion ? .zero : layout.foldOffset)
        .animation(presented ? Motion.popMenuOpen : Motion.popMenuClose, value: presented)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private extension AnyTransition {
    /// The menu a submenu opens from: it slides off to the leading side, and back from it.
    static var popMenuParent: AnyTransition { page(x: -56) }

    /// A submenu, sliding in from the trailing side and back out to it.
    static var popMenuChild: AnyTransition { page(x: 56) }

    /// The page leaving goes quickly, so the two do not read over each other.
    private static func page(x: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: x).combined(with: .opacity),
            removal: .offset(x: x / 2).combined(with: .opacity).animation(.easeOut(duration: 0.12))
        )
    }
}

/// The card's surface: what is behind it blurred and washed with the page's colours, a light
/// edge on top and a soft shadow under it.
private struct PopMenuSurface: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopMenuMetrics.radius, style: .circular)
        let dark = theme.isDark
        ZStack {
            // Under the blur, which covers it: it only casts the shadow.
            shape.fill(theme.surfacePanel)
                .shadow(color: .black.opacity(dark ? 0.4 : 0.14), radius: 22, y: 12)
                .shadow(color: .black.opacity(dark ? 0.2 : 0.05), radius: 1.5, y: 0.5)
            PopMenuBackdrop(dark: dark)
            shape.fill(theme.surfacePanel.opacity(dark ? 0.62 : 0.72))
            shape.fill(LinearGradient(colors: [theme.primary.opacity(dark ? 0.08 : 0.03), theme.primary.opacity(0)], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.8), .white.opacity(dark ? 0.04 : 0.3)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .overlay(shape.stroke(Color.black.opacity(dark ? 0.4 : 0.08), lineWidth: 0.5))
    }
}

/// What is behind the panel, blurred: a SwiftUI material only blurs its own window, and the
/// panel has nothing under the card.
private struct PopMenuBackdrop: NSViewRepresentable {
    var dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// The card's rounded corners, stretched between them.
    private static let mask: NSImage = {
        let radius = PopMenuMetrics.radius
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

/// A page in the card, at its own size; a page taller than there is room for scrolls.
private struct PopMenuPageView: View {
    let page: PopMenuPage
    let size: CGSize
    let session: PopMenuSession

    var body: some View {
        PopMenuPageBody(title: page.title, items: page.items, showsIcons: page.showsIcons, session: session, scrolls: page.size.height > size.height)
            .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// A page's rows. Without a session it is only measured.
struct PopMenuPageBody: View {
    let title: String?
    let items: [PopMenuItem]
    let showsIcons: Bool
    let session: PopMenuSession?
    var scrolls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                PopMenuBackRow(title: title, session: session)
                PopMenuDivider()
            }
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .onChange(of: session?.highlighted) { _, row in
                            if let row, row >= 0 { withAnimation(Motion.popMenuHighlight) { proxy.scrollTo(row) } }
                        }
                }
            } else {
                rows
            }
        }
        .padding(PopMenuMetrics.inset)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                PopMenuRow(item: items[index], index: index, showsIcons: showsIcons, session: session)
                    .modifier(PopMenuRise(index: index, count: items.count, session: session))
                    .id(index)
                    .anchorPreference(key: PopMenuRowFrames.self, value: .bounds) { [index: $0] }
            }
        }
        .backgroundPreferenceValue(PopMenuRowFrames.self) { frames in
            if let session {
                PopMenuHighlight(session: session, frames: frames)
            }
        }
    }
}

private struct PopMenuRowFrames: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One highlight for the page, moving to the row under the pointer (or picked with the keys),
/// so it glides from row to row rather than blinking.
private struct PopMenuHighlight: View {
    let session: PopMenuSession
    let frames: [Int: Anchor<CGRect>]
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            if let row = session.highlighted, let anchor = frames[row] {
                let rect = proxy[anchor]
                let item = session.page.items.indices.contains(row) ? session.page.items[row] : nil
                let pressed = session.pressed == row
                RoundedRectangle(cornerRadius: PopMenuMetrics.radius - PopMenuMetrics.inset, style: .continuous)
                    .fill(fill(destructive: item?.isDestructive == true, pressed: pressed))
                    .frame(width: rect.width, height: rect.height)
                    .scaleEffect(pressed ? 0.985 : 1)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
    }

    private func fill(destructive: Bool, pressed: Bool) -> Color {
        if destructive { return PopMenuRow.destructive(theme).opacity(pressed ? 0.26 : 0.15) }
        return theme.onSurface.opacity(theme.isDark ? (pressed ? 0.2 : 0.11) : (pressed ? 0.14 : 0.075))
    }
}

private struct PopMenuRow: View {
    let item: PopMenuItem
    let index: Int
    let showsIcons: Bool
    let session: PopMenuSession?
    @Environment(\.theme) private var theme

    static let iconWidth: CGFloat = 18
    static let spacing: CGFloat = 8

    static func destructive(_ theme: Theme) -> Color {
        Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")
    }

    var body: some View {
        switch item.kind {
        case .action, .submenu:
            command
        case .info(let value):
            HStack(spacing: 16) {
                Text(item.title)
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                Spacer(minLength: 0)
                Text(value)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.onSurface.opacity(0.85))
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.leading, indent)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .onHover { if $0 { session?.hover(index, inside: true) } }
        case .header:
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                .lineLimit(1)
                .padding(.leading, indent)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
                .frame(height: 26, alignment: .bottomLeading)
                .onHover { if $0 { session?.hover(index, inside: true) } }
        case .divider:
            PopMenuDivider()
        case .empty:
            EmptyView()
        }
    }

    private var indent: CGFloat { showsIcons ? Self.iconWidth + Self.spacing : 0 }

    private var command: some View {
        let color = item.isDestructive ? Self.destructive(theme) : theme.onSurface
        let isSubmenu = if case .submenu = item.kind { true } else { false }
        return Button { session?.activate(index) } label: {
            HStack(spacing: Self.spacing) {
                if showsIcons {
                    Color.clear
                        .frame(width: Self.iconWidth, height: 1)
                        .overlay {
                            if item.isChecked {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(color)
                            } else if let systemImage = item.systemImage {
                                Image(systemName: systemImage).font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(item.isDestructive ? color : theme.onSurfaceVariant)
                            }
                        }
                }
                Text(item.title)
                    .font(.system(size: 13, weight: item.isChecked ? .semibold : .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 20)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                        .lineLimit(1)
                }
                if isSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: PopMenuMetrics.rowHeight)
            .contentShape(Rectangle())
            .opacity(item.isDisabled ? 0.38 : 1)
        }
        .buttonStyle(PopMenuRowStyle())
        .disabled(item.isDisabled)
        .onHover { session?.hover(index, inside: $0) }
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
        .accessibilityHint(isSubmenu ? "打开子菜单" : "")
    }
}

/// A row coming in a moment after the one nearer the button as the menu unfolds.
private struct PopMenuRise: ViewModifier {
    let index: Int
    let count: Int
    let session: PopMenuSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let session, session.page.depth == 0 {
            let presented = session.presented
            let upward = session.layout.opensUpward
            let order = upward ? count - 1 - index : index
            content
                .opacity(presented ? 1 : 0)
                .offset(y: presented || reduceMotion ? 0 : (upward ? 5 : -5))
                .animation(presented ? Motion.popMenuOpen.delay(Double(min(order, 12)) * 0.014) : Motion.popMenuClose, value: presented)
        } else {
            content
        }
    }
}

private struct PopMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct PopMenuBackRow: View {
    let title: String
    let session: PopMenuSession?
    @Environment(\.theme) private var theme

    var body: some View {
        let highlighted = session?.highlighted == PopMenuSession.backRow
        Button { session?.activate(PopMenuSession.backRow) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .offset(x: highlighted ? -2 : 0)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 10)
            .frame(height: PopMenuMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: PopMenuMetrics.radius - PopMenuMetrics.inset, style: .continuous)
                    .fill(theme.onSurface.opacity(highlighted ? (theme.isDark ? 0.11 : 0.075) : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PopMenuRowStyle())
        .onHover { session?.hover(PopMenuSession.backRow, inside: $0) }
        .animation(Motion.popMenuHighlight, value: highlighted)
        .accessibilityLabel("返回\(title)上一级")
    }
}

private struct PopMenuDivider: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.onSurface.opacity(theme.isDark ? 0.1 : 0.08))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}
