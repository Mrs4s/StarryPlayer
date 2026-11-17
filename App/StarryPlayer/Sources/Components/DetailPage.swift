import StarryCore
import SwiftUI

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
