import AppKit
import StarryCore
import SwiftUI

struct ProgressSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var trackHeight: CGFloat = 3
    var thumbSize: CGFloat = 12
    var tint: Color? = nil
    var trackTint: Color? = nil
    var alwaysShowThumb = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var dragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(trackTint ?? theme.onSurface.opacity(0.15)).frame(height: trackHeight)
                Capsule().fill(tint ?? theme.primary).frame(width: max(x, trackHeight), height: trackHeight)
                Circle()
                    .fill(tint ?? theme.primary)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    // Scale before offsetting: scaling around the leading layout anchor after
                    // offsetting
                    // pushes the thumb ahead of the fill.
                    .scaleEffect(dragging ? 1.15 : 1)
                    .offset(x: x - thumbSize / 2)
                    .opacity(hovering || dragging || alwaysShowThumb ? 1 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let f = min(max(gesture.location.x / max(width, 1), 0), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: max(thumbSize, trackHeight) + 8)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: dragging)
    }
}

/// Page tabs animate independently; selection changes must not animate content height
/// or the scroll view will repeatedly clamp its offset.
struct PageTabs<Value: Hashable>: View {
    struct Item {
        var value: Value
        var title: String
        var count: Int? = nil
    }

    var items: [Item]
    @Binding var selection: Value
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 26) {
            ForEach(items, id: \.value) { item in
                PageTabButton(title: item.title, count: item.count, selected: selection == item.value, namespace: underline) {
                    guard selection != item.value else { return }
                    selection = item.value
                }
            }
        }
        .animation(Motion.tab, value: selection)
    }
}

private struct PageTabButton: View {
    var title: String
    var count: Int?
    var selected: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .overlay(alignment: .bottom) {
                        if selected {
                            Capsule().fill(theme.primary)
                                .frame(width: 16, height: 3)
                                .matchedGeometryEffect(id: "underline", in: namespace)
                                .offset(y: 9)
                        }
                    }
                if let count, count > 0 {
                    // Raised as it is drawn, not in the layout: a baseline offset made a tab with a
                    // count 3 pt taller than one without, and centred in the bar its title sat
                    // 1.5 pt lower than its neighbours'.
                    Text(TimeFormatting.compactCount(count))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                        .offset(y: -7)
                }
            }
            .foregroundStyle(selected ? theme.onSurface : theme.onSurfaceVariant.opacity(hovering ? 1 : 0.8))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.tab, value: selected)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索"
    var width: CGFloat = 160
    var focusedWidth: CGFloat = 224
    var onSubmit: () -> Void = {}
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? theme.onSurface.opacity(0.8) : theme.onSurfaceVariant)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .textContentType(.search)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清除")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: focused ? focusedWidth : width, height: 36)
        .background(theme.onSurface.opacity(fill), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.onSurface.opacity(focused ? 0.14 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
        .animation(Motion.searchResize, value: focused)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: text.isEmpty)
    }

    private var fill: Double {
        let base = theme.isDark ? 0.06 : 0.05
        if focused { return base + 0.025 }
        return base + (hovering ? 0.03 : 0)
    }
}

extension NSTextContentType {
    /// Marks a search field. With no content type, AppKit guesses on every focus whether a text
    /// field wants a one-time code or a password, and to offer one builds an AutoFill window; any
    /// content type skips that part.
    static let search = NSTextContentType(rawValue: "search")
    static let lyricOffset = NSTextContentType(rawValue: "lyricOffset")
}
