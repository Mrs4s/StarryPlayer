import StarryCore
import SwiftUI

/// Detail-page scroll layout with a pinned tab bar. Keep tab rows in one lazy stack
/// and the header outside it to avoid offset shifts from estimated heights.
struct DetailPageScroll<Tab: RawRepresentable & Hashable, Hero: View, Bar: View, Rows: View>: View where Tab.RawValue == Int {
    @Binding var tab: Tab
    var backdrop: PageBackdrop
    var hero: (Binding<Tab>) -> Hero
    var bar: (Binding<Tab>) -> Bar
    /// The selected tab as rows of the page's lazy stack (several views, not one container),
    /// given the same binding as the bar (a "show all" link on one tab switching to another).
    var rows: (Binding<Tab>) -> Rows

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 enters from the right, −1 from the left, 0 disables sliding.
    @State private var tabDirection: CGFloat = 0
    @State private var heroHeight: CGFloat = 280
    @State private var scroll = ScrollMetrics()
    /// Least height of the scroll document, set on a tab switch so the new tab keeps the
    /// scroll position (see `tabBinding`).
    @State private var documentFloor: CGFloat = 0
    @State private var contentHidden = false

    private let tabsAnchor = "detail-tabs"

    /// The scroll view's offset and height, written on every scroll frame. Deliberately not
    /// observable: nothing re-renders from it; only a tab switch reads it.
    private final class ScrollMetrics {
        var offset: CGFloat = 0
        var viewport: CGFloat = 0
        var pendingTab: Tab?
    }

    init(tab: Binding<Tab>, backdrop: PageBackdrop, @ViewBuilder hero: () -> Hero, @ViewBuilder bar: @escaping (Binding<Tab>) -> Bar, @ViewBuilder rows: () -> Rows) {
        let built = rows()
        self.init(tab: tab, backdrop: backdrop, hero: hero, bar: bar) { _ in built }
    }

    init(tab: Binding<Tab>, backdrop: PageBackdrop, @ViewBuilder hero: () -> Hero, @ViewBuilder bar: @escaping (Binding<Tab>) -> Bar, @ViewBuilder rows: @escaping (Binding<Tab>) -> Rows) {
        let built = hero()
        self.init(tab: tab, backdrop: backdrop, switchingHero: { _ in built }, bar: bar, rows: rows)
    }

    init(tab: Binding<Tab>, backdrop: PageBackdrop, @ViewBuilder switchingHero hero: @escaping (Binding<Tab>) -> Hero, @ViewBuilder bar: @escaping (Binding<Tab>) -> Bar, @ViewBuilder rows: @escaping (Binding<Tab>) -> Rows) {
        _tab = tab
        self.backdrop = backdrop
        self.hero = hero
        self.bar = bar
        self.rows = rows
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                let fadeDistance = heroHeight
                VStack(alignment: .leading, spacing: 0) {
                    hero(tabBinding(scroller))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
                        .visualEffect { content, geo in
                            let scrolled = max(-geo.frame(in: .scrollView).minY, 0)
                            let t = min(scrolled / max(geo.size.height, 1), 1)
                            return content
                                .opacity(1 - t * 0.9)
                                .scaleEffect(1 - t * 0.03, anchor: .top)
                        }
                    Color.clear.frame(height: 0).id(tabsAnchor)
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            rows(tabBinding(scroller))
                                .padding(.horizontal, Metrics.pagePadding)
                                .opacity(contentHidden ? 0 : 1)
                                .transition(tabTransition)
                        } header: {
                            bar(tabBinding(scroller))
                        }
                    }
                    .padding(.bottom, 40)
                }
                .frame(minHeight: documentFloor, alignment: .top)
                .coordinateSpace(.pageContent)
                .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { offset in
                    scroll.offset = offset
                    // The wash fades over the header's height, so it is gone when the tabs pin.
                    let fade = (Double(min(max(offset / max(fadeDistance, 1), 0), 1)) * 60).rounded() / 60
                    if backdrop.fade != fade { backdrop.fade = fade }
                }
                .pausesHitTestingWhileScrolling()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.viewport = $0 }
            .environment(\.pinnedTopInset, Metrics.detailTabBarHeight)
        }
        .preference(key: PageBackdropKey.self, value: backdrop)
    }

    /// Swap content without animating its height. When scrolled past the tabs, scroll to
    /// the pinned point before replacing rows; doing both together can leave the lazy stack blank.
    private func tabBinding(_ scroller: ScrollViewProxy) -> Binding<Tab> {
        Binding {
            tab
        } set: { new in
            guard new != tab || scroll.pendingTab != nil else { return }
            let offset = scroll.offset
            let floor = min(max(offset, 0), heroHeight) + scroll.viewport
            let direction: CGFloat = new.rawValue > tab.rawValue ? 1 : -1
            guard offset > heroHeight + 0.5 else {
                withTransaction(Transaction(animation: nil)) {
                    scroll.pendingTab = nil
                    contentHidden = false
                    tabDirection = direction
                    documentFloor = floor
                    tab = new
                }
                settleDirection()
                return
            }
            let first = scroll.pendingTab == nil
            scroll.pendingTab = new
            guard first else { return }
            withTransaction(Transaction(animation: nil)) {
                contentHidden = true
                documentFloor = floor
                scroller.scrollTo(tabsAnchor, anchor: .top)
            }
            Task { @MainActor in
                guard let target = scroll.pendingTab else { return }
                scroll.pendingTab = nil
                withTransaction(Transaction(animation: nil)) {
                    tabDirection = target.rawValue > tab.rawValue ? 1 : -1
                    tab = target
                    contentHidden = false
                }
                settleDirection()
            }
        }
    }

    private func settleDirection() {
        Task { @MainActor in tabDirection = 0 }
    }

    /// Rows come in fading and sliding from the tab's side; the outgoing tab leaves at once, so
    /// the two never stack up in the layout. Outside a tab switch a row taken out in an
    /// animated change (a song unliked on the liked songs page) fades quickly, mostly gone before the
    /// rows below slide over it.
    private var tabTransition: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(x: reduceMotion ? 0 : 28 * tabDirection)).animation(Motion.tab),
            removal: tabDirection == 0 ? AnyTransition.opacity.animation(.easeOut(duration: 0.14)) : .identity
        )
    }
}

/// Pinned under the header bar. Transparent while it scrolls with the page; once pinned it
/// takes the surface colour and a full-width hairline, so rows slide under it cleanly.
struct DetailTabBar<Tab: Hashable, Accessory: View>: View {
    @Binding var tab: Tab
    var items: [PageTabs<Tab>.Item]
    var accessory: Accessory
    @Environment(\.theme) private var theme
    @Environment(\.detailBarPinned) private var pinnedOverride
    @State private var pinned = false

    init(tab: Binding<Tab>, items: [PageTabs<Tab>.Item], @ViewBuilder accessory: () -> Accessory) {
        _tab = tab
        self.items = items
        self.accessory = accessory()
    }

    var body: some View {
        let isPinned = pinnedOverride ?? pinned
        HStack(spacing: 16) {
            PageTabs(items: items, selection: $tab)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Metrics.detailTabBarHeight)
        .background {
            theme.surface
                .opacity(isPinned ? 1 : 0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.outlineVariant)
                        .frame(height: 1)
                        .padding(.horizontal, isPinned ? 0 : Metrics.pagePadding)
                }
        }
        .animation(Motion.tab, value: tab)
        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < 0.5 } action: { value in
            withAnimation(.easeOut(duration: 0.2)) { pinned = value }
        }
    }
}

extension DetailTabBar where Accessory == DetailTabSearch {
    /// With a search field while `search` is non-nil.
    init(tab: Binding<Tab>, items: [PageTabs<Tab>.Item], search: Binding<String>?, searchPlaceholder: String = "搜索") {
        self.init(tab: tab, items: items) { DetailTabSearch(text: search, placeholder: searchPlaceholder) }
    }
}

struct DetailTabSearch: View {
    var text: Binding<String>?
    var placeholder: String

    var body: some View {
        if let text {
            SearchField(text: text, placeholder: placeholder, width: 168, focusedWidth: 220)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        }
    }
}

struct SegmentSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @Environment(\.theme) private var theme
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                option(options[index].value, options[index].title)
            }
        }
        .padding(3)
        .background(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.05), in: Capsule())
        .animation(Motion.tab, value: selection)
    }

    private func option(_ value: Value, _ title: String) -> some View {
        let selected = selection == value
        return Button {
            if !selected { selection = value }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? theme.onSurface : theme.onSurfaceVariant)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if selected {
                        Capsule()
                            .fill(theme.surfaceBright.opacity(theme.isDark ? 0.8 : 1))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct CoverPlayButton: View {
    var isPlaying: Bool
    var visible: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.25), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .padding(12)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.8)
        .help(isPlaying ? "暂停" : "播放")
    }
}

/// A detail page's description in two lines. Hovering brightens it and nudges its chevron; a click opens
/// all of it with the tags in a popover, so the header keeps its height.
struct DescriptionPeek: View {
    var title: String
    var text: String
    var tags: [String] = []
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Self.oneParagraph(text))
                    .lineLimit(2)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(hovering ? 1 : 0.5)
                    .offset(x: hovering ? 2 : 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? theme.onSurface.opacity(0.9) : theme.onSurfaceVariant)
            .frame(maxWidth: 560, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("查看完整介绍")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            DescriptionPopover(title: title, text: text, tags: tags)
        }
    }

    static func oneParagraph(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct DescriptionPopover: View {
    var title: String
    var text: String
    var tags: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onSurface)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(6)
                .foregroundStyle(theme.onSurface.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.onSurface)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(theme.onSurface.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        // A scroller only for long ones: a popover sizes to its content, which a scroll view
        // does not report.
        if Self.estimatedLines(text) > 16 {
            ScrollView { content }.frame(height: 400)
        } else {
            content
        }
    }

    static func estimatedLines(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { lines, paragraph in
            let width = paragraph.reduce(0.0) { $0 + ($1.isASCII ? 0.5 : 1) }
            return lines + max(1, Int((width / 29).rounded(.up)))
        }
    }
}

extension Theme {
    func coverShadow(_ glow: Color?) -> Color {
        guard let glow, let hsb = glow.hsb else { return .black.opacity(isDark ? 0.45 : 0.18) }
        return Color.hsb(hsb.hue, min(hsb.saturation, 0.7), isDark ? 0.25 : 0.45).opacity(isDark ? 0.7 : 0.35)
    }
}

struct TrackSkeleton: View {
    var count: Int
    var artwork = false
    @Environment(\.theme) private var theme
    private static let titleWidths: [CGFloat] = [180, 132, 220, 156, 196, 120, 170, 210, 144, 186]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 16) {
                    SkeletonBar(width: 16, height: 10).frame(width: SongColumns.indexWidth)
                    HStack(spacing: 12) {
                        if artwork {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.onSurface.opacity(theme.isDark ? 0.07 : 0.08))
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBar(width: Self.titleWidths[index % Self.titleWidths.count], height: 11)
                            SkeletonBar(width: 84, height: 9)
                        }
                    }
                    Spacer()
                    SkeletonBar(width: 34, height: 10)
                }
                .padding(.horizontal, 12)
                .frame(height: artwork ? Metrics.songRowHeight : 56)
            }
        }
        .padding(.top, 8)
        .shimmer()
    }
}

enum DetailFormat {
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }

    static func longDate(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func dayText(_ date: Date, now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard c.year == calendar.component(.year, from: now) else { return longDate(date, calendar: calendar) }
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}
