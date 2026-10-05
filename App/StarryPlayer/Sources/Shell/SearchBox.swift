import AppKit
import MusicSources
import StarryCore
import SwiftUI

/// The header's room for the search box. `NavHeader` reserves it; `MainLayout` lays the box over
/// it, above the pages (the open panel overhangs them) and outside the header's window-drag
/// gesture (dragging in the panel must not move the window).
struct SearchSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    func searchBoxSlot() -> some View {
        frame(width: SearchBox.restWidth, height: SearchBox.fieldHeight)
            .anchorPreference(key: SearchSlotKey.self, value: .bounds) { $0 }
    }
}

struct SearchBoxLayer: View {
    var slot: Anchor<CGRect>?

    var body: some View {
        GeometryReader { geo in
            if let slot {
                SearchBox(slot: geo[slot], container: geo.size)
            }
        }
    }
}

struct SearchBox: View {
    static let restWidth: CGFloat = 240
    static let fieldHeight: CGFloat = 36
    static let openWidth: CGFloat = 480
    /// The open card's margin around the field. Its corners are the field's radius plus this, so
    /// the two curves stay concentric.
    static let margin: CGFloat = 6

    var slot: CGRect
    var container: CGSize
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var panelHeight: CGFloat = 0
    @State private var hovering = false
    @State private var events = SearchBoxEvents()

    var body: some View {
        let search = model.search
        let open = search.isActive
        let margin = open ? Self.margin : 0
        let openWidth = max(min(Self.openWidth, container.width - slot.minX - 16 + Self.margin), slot.width + 2 * Self.margin)
        let cardWidth = open ? openWidth : slot.width
        let panelShown = open ? panelHeight : 0
        let cardHeight = slot.height + 2 * margin + panelShown

        ZStack(alignment: .topLeading) {
            card(open: open)
                .frame(width: cardWidth, height: cardHeight)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { events.cardFrame = $0 }
            // Laid out even while closed (unseen, zero height shown) and always at the open width,
            // so the card knows the panel's height the moment it opens and grows to it in one
            // motion; the growing card uncovers the panel rather than reflowing it.
            SearchPanel(open: open)
                .frame(width: openWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                .frame(width: cardWidth, height: panelShown, alignment: .topLeading)
                .clipped()
                .offset(y: slot.height + 2 * margin)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
            field(open: open, width: open ? openWidth - 2 * Self.margin : slot.width)
                .frame(width: cardWidth - 2 * margin, height: slot.height, alignment: .leading)
                .clipShape(Capsule())
                .offset(x: margin, y: margin)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .offset(x: slot.minX - margin, y: slot.minY - margin)
        .animation(open ? Motion.searchOpen : Motion.searchClose, value: open)
        .animation(Motion.searchResize, value: panelHeight)
        .onChange(of: focused) { _, now in
            if now {
                // The box asked for the focus (a press, ⌘K) and is open already, or Tab brought
                // it here. Anything else is AppKit handing a window with nothing focused to its
                // first text field — this one, at the start of the header — when the window is
                // shown or made key: that is not a search, so the focus goes back.
                guard search.isActive || Self.isTabNavigation(NSApp.currentEvent) else {
                    focused = false
                    return
                }
                search.activate()
            } else if search.isActive {
                search.deactivate()
            }
        }
        .onChange(of: search.focusRequest) { focused = true }
        .onChange(of: search.isActive) { _, active in
            if active {
                events.install()
            } else {
                events.uninstall()
                if focused { focused = false }
            }
        }
        .onChange(of: search.text) { if search.isActive { search.textChanged() } }
        .onChange(of: model.currentEntry.id, initial: true) { search.routeChanged(model.route) }
        .onChange(of: model.player.showNowPlaying) { if model.player.showNowPlaying { search.deactivate() } }
        .onAppear {
            if search.isActive { events.install() }
            events.onOutsideClick = { search.deactivate() }
            events.onKey = { key in
                switch key {
                case .down: return search.moveHighlight(1)
                case .up: return search.moveHighlight(-1)
                case .escape:
                    search.deactivate()
                    return true
                }
            }
        }
        .onDisappear { events.uninstall() }
    }

    private static func isTabNavigation(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.keyCode == 48
    }

    private func card(open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.fieldHeight / 2 + (open ? Self.margin : 0), style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(theme.surfacePanel.opacity(theme.isDark ? 0.84 : 0.9)))
            .overlay(shape.strokeBorder(theme.onSurface.opacity(theme.isDark ? 0.09 : 0.07), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.42 : 0.14), radius: 26, y: 14)
            .opacity(open ? 1 : 0)
            // The surface is there at once; the spring only shapes it. Faded in on the spring, it
            // would stay faint for the first frames and the box would seem slow to answer the
            // click.
            .animation(.easeOut(duration: 0.12), value: open)
    }

    /// The field at `width`, the width it ends up at: only its capsule follows the card's spring,
    /// clipping what is wider. Resized on every frame of the spring, the focused text field would
    /// lay out its field editor each time; this way it is resized once.
    private func field(open: Bool, width: CGFloat) -> some View {
        let search = model.search
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? theme.onSurface.opacity(0.85) : theme.onSurfaceVariant)
                .frame(width: 16)
            ZStack(alignment: .leading) {
                if search.text.isEmpty {
                    // Gone at once when typing starts (fading, it would overlap the first
                    // characters), back with a fade when the text is cleared.
                    SearchHintText(open: open)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                TextField("", text: Bindable(search).text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.onSurface)
                    .textContentType(.search)
                    .focused($focused)
                    .onSubmit { search.commit() }
            }
            .frame(width: max(width - Self.fieldChrome, 0), alignment: .leading)
            .transaction(value: width) { $0.animation = nil }
            trailing(open: open)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.onSurface.opacity(fieldFill(open: open)), in: Capsule())
        .contentShape(Capsule())
        .overlay {
            // Closed, the whole capsule opens the box as the button goes down, rather than when
            // the text field's focus has come back to SwiftUI a few frames later; the field then
            // takes the focus with its text selected, as a search field does. The field itself
            // takes no click while closed (a focus the box did not ask for is refused, above).
            if !open {
                Capsule()
                    .fill(.clear)
                    .contentShape(Capsule())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        if !search.isActive { search.focus() }
                    })
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: search.text.isEmpty)
    }

    private static let fieldChrome: CGFloat = 12 + 16 + 8 + 8 + 24 + 6

    private func fieldFill(open: Bool) -> Double {
        if open { return theme.isDark ? 0.07 : 0.05 }
        return (theme.isDark ? 0.06 : 0.05) + (hovering ? 0.03 : 0)
    }

    @ViewBuilder private func trailing(open: Bool) -> some View {
        let search = model.search
        if !search.text.isEmpty, open {
            Button {
                search.setText("")
                search.focus()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("清除")
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
        } else if !open, search.text.isEmpty {
            Text("⌘K")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                .fixedSize()
                .padding(.trailing, 2)
                .transition(.opacity)
        }
    }
}

/// The empty box's hint (a source's suggested query, e.g. `明知故犯 - Max李玄`), pushed up by the
/// next one when it turns (a `Ticker`, so a turn does not render the shell every frame). Return
/// searches it.
private struct SearchHintText: View {
    var open: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let search = model.search
        Ticker(value: search.hint?.display ?? "搜索音乐、歌手、专辑、歌单", trigger: search.hintIndex, motion: .push(Motion.hint), interactive: false) { hint in
            Text(hint)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // On the line rather than in the text, so it dims on the box's own animation.
        .opacity(open ? 0.7 : 1)
        .allowsHitTesting(false)
    }
}

private struct SearchPanel: View {
    var open: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Namespace private var highlight

    var body: some View {
        let panel = model.search.panel
        VStack(alignment: .leading, spacing: 0) {
            if panel.query.isEmpty {
                discover(panel.items)
            } else {
                typed(panel)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in if !inside, model.search.isActive { model.search.highlighted = nil } }
        .animation(Motion.selection, value: model.search.highlighted)
    }

    @ViewBuilder private func discover(_ items: [SearchModel.Item]) -> some View {
        let search = model.search
        let recent = items.compactMap { item -> String? in
            if case .recent(let text) = item { return text }
            return nil
        }
        let trends = items.compactMap { item -> (Int, SearchTrend)? in
            if case .trend(let rank, let trend) = item { return (rank, trend) }
            return nil
        }
        if !recent.isEmpty {
            PanelHeader(title: "最近搜索", index: 0, open: open) {
                PanelTextButton(title: "清除") {
                    withAnimation(Motion.searchResize) { search.clearHistory() }
                }
            }
            ChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(Array(recent.enumerated()), id: \.element) { index, text in
                    RecentChip(text: text, highlighted: search.highlighted == SearchModel.Item.recent(text).id, namespace: highlight)
                        .panelReveal(open, index: 1 + index / 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
            .animation(Motion.searchResize, value: recent)
        }
        if !(trends.isEmpty && search.trendsState == .loaded) {
            PanelHeader(title: "热搜榜", index: 2, open: open) { EmptyView() }
        }
        if !trends.isEmpty {
            let half = (trends.count + 1) / 2
            HStack(alignment: .top, spacing: 2) {
                trendColumn(Array(trends.prefix(half)), revealBase: 3)
                trendColumn(Array(trends.dropFirst(half)), revealBase: 3)
            }
        } else if search.trendsState == .loading || search.trendsState == .idle {
            TrendSkeleton()
                .panelReveal(open, index: 3)
        } else if search.trendsState == .failed {
            Text("热搜暂时不可用")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .frame(height: 32)
        }
    }

    private func trendColumn(_ trends: [(Int, SearchTrend)], revealBase: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(trends.enumerated()), id: \.element.0) { row, entry in
                let item = SearchModel.Item.trend(rank: entry.0, entry.1)
                TrendRow(rank: entry.0, trend: entry.1, highlighted: model.search.highlighted == item.id, namespace: highlight) {
                    model.search.choose(item)
                } onHover: {
                    model.search.hover(item.id)
                }
                .zIndex(model.search.highlighted == item.id ? 1 : 0)
                .panelReveal(open, index: revealBase + row)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func typed(_ panel: SearchModel.Panel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(panel.items.enumerated()), id: \.element.id) { index, item in
                SuggestionRow(item: item, query: panel.query, highlighted: model.search.highlighted == item.id, namespace: highlight)
                    .zIndex(model.search.highlighted == item.id ? 1 : 0)
                    .panelReveal(open, index: index)
                    .transition(.opacity)
            }
            // Holds the room of the suggestions on their way, so the card does not shrink to the
            // one row and grow back when they come.
            if panel.pending {
                SuggestionSkeleton()
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .padding(.top, 2)
        .animation(.easeOut(duration: 0.14), value: panel.items.map(\.id))
        .animation(.easeOut(duration: 0.14), value: panel.pending)
    }
}

private struct HighlightFill: View {
    var shape: AnyShape
    var namespace: Namespace.ID
    @Environment(\.theme) private var theme

    var body: some View {
        shape
            .fill(theme.onSurface.opacity(theme.isDark ? 0.09 : 0.07))
            .matchedGeometryEffect(id: "search-highlight", in: namespace)
    }
}

private struct PanelHeader<Trailing: View>: View {
    var title: String
    var index: Int
    var open: Bool
    @ViewBuilder var trailing: Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(height: 32)
        .panelReveal(open, index: index)
    }
}

private struct PanelTextButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? theme.onSurface : theme.onSurfaceVariant)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

private struct RecentChip: View {
    var text: String
    var highlighted: Bool
    var namespace: Namespace.ID
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let item = SearchModel.Item.recent(text)
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.onSurface.opacity(0.9))
            .lineLimit(1)
            .frame(maxWidth: 180)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(theme.onSurface.opacity(theme.isDark ? 0.05 : 0.045), in: Capsule())
            .background {
                if highlighted { HighlightFill(shape: AnyShape(Capsule()), namespace: namespace) }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button {
                        withAnimation(Motion.searchResize) { model.search.forget(text) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(width: 15, height: 15)
                            .background(theme.surfaceBright, in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.85))
                    .offset(x: 4, y: -4)
                    .help("从最近搜索中移除")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .contentShape(Capsule())
            .onTapGesture { model.search.choose(item) }
            .onHover { inside in
                hovering = inside
                if inside { model.search.hover(item.id) }
            }
            .animation(Motion.hover, value: hovering)
    }
}

private struct TrendRow: View {
    var rank: Int
    var trend: SearchTrend
    var highlighted: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    var onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(rank <= 3 ? theme.accent : theme.onSurfaceVariant.opacity(0.7))
                .frame(width: 18)
            Text(trend.query)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
            if let badge = trend.badge { TrendBadge(badge: badge) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            if highlighted { HighlightFill(shape: AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)), namespace: namespace) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { if $0 { onHover() } }
    }
}

struct TrendBadge: View {
    var badge: SearchTrend.Badge
    @Environment(\.theme) private var theme

    private var color: Color {
        badge == .new ? Color(hex: theme.isDark ? "#3CC79A" : "#2FA57F") : Color(hex: theme.isDark ? "#F0625D" : "#DC3F3A")
    }

    var body: some View {
        Group {
            switch badge {
            case .hot: Text("热")
            case .new: Text("新")
            case .surging: Text("爆")
            case .rising: Image(systemName: "arrow.up")
            }
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(color)
        .frame(width: 15, height: 15)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct SuggestionRow: View {
    var item: SearchModel.Item
    var query: String
    var highlighted: Bool
    var namespace: Namespace.ID
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.85))
                .frame(width: 18)
            label
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background {
            if highlighted { HighlightFill(shape: AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)), namespace: namespace) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.search.choose(item) }
        .onHover { if $0 { model.search.hover(item.id) } }
    }

    private var symbol: String {
        switch item {
        case .recent: "clock.arrow.circlepath"
        default: "magnifyingglass"
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .query(let text):
            (Text("搜索 ").foregroundStyle(theme.onSurfaceVariant) + Text("“\(text)”").foregroundStyle(theme.onSurface).fontWeight(.semibold))
                .font(.system(size: 13.5))
        default:
            Text(Self.marked(item.text, query: query, base: theme.onSurface, mark: theme.accent))
                .font(.system(size: 13.5))
        }
    }

    @ViewBuilder private var accessory: some View {
        if highlighted {
            switch item {
            case .query:
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 24, height: 24)
                    .transition(.opacity)
            default:
                Button {
                    model.search.setText(item.text)
                    model.search.focus()
                } label: {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.85))
                .help("填入搜索框")
                .transition(.opacity)
            }
        }
    }

    static func marked(_ text: String, query: String, base: Color, mark: Color) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = base
        guard !query.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) else { return result }
        result[lower..<upper].foregroundColor = mark
        result[lower..<upper].font = .system(size: 13.5, weight: .medium)
        return result
    }
}

private struct SuggestionSkeleton: View {
    private static let widths: [CGFloat] = [120, 84, 150]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 10) {
                    SkeletonBar(width: 12, height: 10).frame(width: 18)
                    SkeletonBar(width: Self.widths[row], height: 10)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: 34)
            }
        }
        .shimmer()
    }
}

private struct TrendSkeleton: View {
    private static let widths: [CGFloat] = [96, 72, 120, 84, 64, 110, 80, 60, 100, 76]

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<2, id: \.self) { column in
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { row in
                        HStack(spacing: 8) {
                            SkeletonBar(width: 10, height: 10).frame(width: 18)
                            SkeletonBar(width: Self.widths[column * 5 + row], height: 10)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .shimmer()
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

private struct PanelReveal: ViewModifier {
    var open: Bool
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(open ? 1 : 0)
            .offset(y: open || reduceMotion ? 0 : -5)
            .animation(open ? Motion.reveal.delay(0.04 + Double(min(index, 12)) * 0.016) : .easeOut(duration: 0.1), value: open)
    }
}

private extension View {
    func panelReveal(_ open: Bool, index: Int) -> some View {
        modifier(PanelReveal(open: open, index: index))
    }
}

/// While the box is open: a click outside the card closes it (and still reaches what was
/// clicked), and ↑ / ↓ / Esc in the field move the highlight or close it. A local monitor
/// rather than key handlers on the field: the field editor takes arrow keys before SwiftUI sees
/// them. Keys an input method is composing with are left to it.
@MainActor
final class SearchBoxEvents {
    enum Key { case up, down, escape }

    /// The card, in the window's content coordinates (top-left origin).
    var cardFrame: CGRect = .zero
    var onOutsideClick: () -> Void = {}
    var onKey: (Key) -> Bool = { _ in false }
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Not in sheets, popovers or menus of their own.
        guard let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil, !(window is NSPanel), let content = window.contentView else { return false }
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
            guard modifiers.isEmpty else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            switch event.keyCode {
            case 125: return onKey(.down)
            case 126: return onKey(.up)
            case 53: return onKey(.escape)
            default: return false
            }
        }
        let location = event.locationInWindow
        if !cardFrame.contains(CGPoint(x: location.x, y: content.bounds.height - location.y)) {
            onOutsideClick()
        }
        return false
    }
}
