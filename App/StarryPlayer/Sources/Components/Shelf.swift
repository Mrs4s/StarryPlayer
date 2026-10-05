import AppKit
import StarryCore
import SwiftUI

/// Paged card shelf, laid out at full width with its own page insets.
/// Index-based placement avoids NSScrollView updates during shell animations; only nearby cards
/// exist.
struct Shelf<Item: Identifiable, Card: View>: View {
    var title: String
    var items: [Item]
    var minCardWidth: CGFloat = 156
    var spacing: CGFloat = 18
    var moreAction: (() -> Void)? = nil
    @ViewBuilder var card: (Item) -> Card
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns = 5
    @State private var start = 0
    @State private var drag: CGFloat = 0
    @State private var hovering = false
    @State private var router = ShelfScrollRouter()

    /// Room above and below the cards, inside the row's clip, for a hovered card's lift and
    /// shadow. Taken back outside, so it does not add to the layout.
    private static var bleed: CGFloat { 14 }

    private var maxStart: Int { max(items.count - columns, 0) }

    var body: some View {
        let padding = Metrics.pagePadding, minWidth = minCardWidth, gap = spacing
        let lower = max(start - columns - 1, 0), upper = min(start + 2 * columns + 1, items.count)
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title, moreAction: moreAction, paging: paging, showsPaging: hovering)
                .padding(.horizontal, padding)
            ShelfRow(columns: columns, spacing: spacing, inset: padding, start: start, offset: displayedDrag) {
                ForEach(Array(items[lower..<upper].enumerated()), id: \.element.id) { offset, item in
                    let index = lower + offset
                    card(item)
                        .allowsHitTesting(index >= start && index < start + columns)
                        .transition(.identity)
                        .layoutValue(key: ShelfRow.Index.self, value: index)
                }
            }
            .padding(.vertical, Self.bleed)
            .clipped()
            .padding(.vertical, -Self.bleed)
        }
        .onGeometryChange(for: Int.self) { geo in
            max(2, Int((geo.size.width - 2 * padding + gap) / (minWidth + gap)))
        } action: { value in
            columns = value
            start = min(start, max(items.count - value, 0))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { router.frame = $0 }
        .onHover { hovering = $0 }
        .onChange(of: pageActive, initial: true) { router.active = pageActive }
        .onAppear {
            wireRouter()
            router.install()
        }
        .onChange(of: items.count) { wireRouter() }
        .onDisappear { router.uninstall() }
    }

    private func wireRouter() {
        router.onDrag = { delta in drag += delta }
        router.onEnd = { velocity in settle(velocity: velocity) }
        router.onStep = { direction in page(direction) }
    }

    private var displayedDrag: CGFloat {
        let pastStart = start == 0 && drag > 0
        let pastEnd = start >= maxStart && drag < 0
        guard pastStart || pastEnd else { return drag }
        return drag / (1 + abs(drag) / 120)
    }

    private var paging: ShelfHeader.Paging? {
        guard items.count > columns else { return nil }
        return ShelfHeader.Paging(canBack: start > 0, canForward: start < maxStart, back: { page(-1) }, forward: { page(1) })
    }

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : Motion.shelf }

    private func page(_ direction: Int) {
        let target = min(max(start + direction * columns, 0), maxStart)
        withAnimation(animation) {
            start = target
            drag = 0
        }
    }

    private func settle(velocity: CGFloat) {
        let width = router.frame.width
        let step = max((width - 2 * Metrics.pagePadding - CGFloat(columns - 1) * spacing) / CGFloat(columns) + spacing, 1)
        var target = start - Int((drag / step).rounded())
        if abs(velocity) > 12 {
            target = velocity < 0 ? max(target, start + columns) : min(target, start - columns)
        }
        withAnimation(animation) {
            start = min(max(target, 0), maxStart)
            drag = 0
        }
    }
}

/// Places a shelf's cards side by side at `columns` to the width, the card with index `start`
/// at the leading inset, shifted by `offset`. Each card carries its index (`Index`), so the
/// shelf can hand over only the cards near the visible ones.
private struct ShelfRow: Layout {
    var columns: Int
    var spacing: CGFloat
    var inset: CGFloat
    var start: Int
    var offset: CGFloat

    struct Index: LayoutValueKey {
        static let defaultValue = 0
    }

    struct Cache {
        var cardWidth: CGFloat?
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    private func cardWidth(_ width: CGFloat) -> CGFloat {
        max((width - 2 * inset - CGFloat(columns - 1) * spacing) / CGFloat(max(columns, 1)), 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 800
        let card = cardWidth(width)
        if cache.cardWidth != card {
            cache.cardWidth = card
            cache.height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: card, height: nil)).height }.max() ?? 0
        }
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let card = cardWidth(bounds.width)
        for subview in subviews {
            let x = bounds.minX + inset + CGFloat(subview[Index.self] - start) * (card + spacing) + offset
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: card, height: nil))
        }
    }
}

/// Hands horizontal scrolls over a shelf to it and lets everything else through to the page:
/// a trackpad gesture locks to an axis on its first movement; a horizontal one drags the shelf,
/// and its momentum is swallowed; shift + mouse wheel pages. Holds the shelf's frame in window
/// coordinates without making it view state, so moving the shelf re-renders nothing.
@MainActor
private final class ShelfScrollRouter {
    /// In the hosting view's (SwiftUI global) coordinates, top-left origin.
    var frame: CGRect = .zero
    var active = true
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }

    private enum Lock {
        case undecided, horizontal, vertical
    }

    private var monitor: Any?
    private var tracking = false
    private var lock = Lock.undecided
    private var travel = CGSize.zero
    private var lastDelta: CGFloat = 0
    private var lastWheelStep: TimeInterval = 0

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard active, let window = event.window, window.sheetParent == nil, !(window is NSPanel), let view = window.contentView else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        return frame.contains(CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y))
    }

    /// Handles `event` if it is the shelf's; true when the page must not see it.
    private func consumes(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            guard lock == .horizontal else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { lock = .undecided }
            return true
        }
        if event.phase.isEmpty {
            guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), contains(event) else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastWheelStep > 0.35 {
                lastWheelStep = now
                onStep(event.scrollingDeltaX < 0 ? 1 : -1)
            }
            return true
        }
        if event.phase.contains(.began) {
            tracking = contains(event)
            lock = .undecided
            travel = .zero
            lastDelta = 0
            return false
        }
        guard tracking else { return false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            tracking = false
            if lock == .horizontal { onEnd(lastDelta) } else { lock = .undecided }
            return false
        }
        if lock == .undecided {
            travel.width += abs(event.scrollingDeltaX)
            travel.height += abs(event.scrollingDeltaY)
            if max(travel.width, travel.height) > 3 {
                lock = travel.width > travel.height ? .horizontal : .vertical
            }
        }
        guard lock == .horizontal else { return false }
        lastDelta = event.scrollingDeltaX
        onDrag(event.scrollingDeltaX)
        return true
    }
}

struct ShelfHeader: View {
    struct Paging {
        var canBack: Bool
        var canForward: Bool
        var back: () -> Void
        var forward: () -> Void
    }

    var title: String
    var moreAction: (() -> Void)? = nil
    var paging: Paging? = nil
    var showsPaging = false
    @Environment(\.theme) private var theme
    @State private var titleHovering = false

    var body: some View {
        HStack(spacing: 6) {
            titleView
            Spacer(minLength: 0)
            if let paging {
                HStack(spacing: 6) {
                    arrow("chevron.left", enabled: paging.canBack, action: paging.back)
                    arrow("chevron.right", enabled: paging.canForward, action: paging.forward)
                }
                .opacity(showsPaging ? 1 : 0)
                .offset(x: showsPaging ? 0 : 6)
                .allowsHitTesting(showsPaging)
                .animation(Motion.hover, value: showsPaging)
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var titleView: some View {
        let text = Text(title)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(theme.onSurface)
        if let moreAction {
            Button(action: moreAction) {
                HStack(spacing: 5) {
                    text
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .offset(x: titleHovering ? 3 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { titleHovering = $0 }
            .animation(Motion.lift, value: titleHovering)
        } else {
            text
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.onSurface.opacity(enabled ? 0.85 : 0.3))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(VariantButtonStyle(variant: .tertiary, isCircle: true))
        .disabled(!enabled)
    }
}

struct TrackShelf: View {
    var title: String
    var tracks: [Track]
    var rows = 3
    var context: PlaybackContext? = nil
    var moreAction: (() -> Void)? = nil
    @Environment(AppModel.self) private var model

    private struct Column: Identifiable {
        var id: Int
        var tracks: [Track]
    }

    private var columns: [Column] {
        stride(from: 0, to: tracks.count, by: rows).map { Column(id: $0, tracks: Array(tracks[$0..<min($0 + rows, tracks.count)])) }
    }

    var body: some View {
        Shelf(title: title, items: columns, minCardWidth: 280, spacing: 20, moreAction: moreAction) { column in
            VStack(spacing: 0) {
                ForEach(Array(column.tracks.enumerated()), id: \.offset) { offset, track in
                    TrackTile(track: track, separator: offset < column.tracks.count - 1) {
                        model.player.play(tracks, startAt: column.id + offset, context: context)
                    }
                }
            }
        }
    }
}

struct TrackTile: View {
    var track: Track
    var separator = true
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isCurrent: Bool { model.player.current?.id == track.id }

    var body: some View {
        let playing = isCurrent && model.player.isPlaying
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artwork, radius: 6, pixelSize: 120)
                .frame(width: 46, height: 46)
                .overlay { coverOverlay(playing: playing) }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isCurrent ? theme.accent : theme.onSurface)
                    .lineLimit(1)
                Text(track.artistText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(TimeFormatting.clock(track.duration))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .frame(height: 62)
        .background(theme.onSurface.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottom) {
            if separator {
                Rectangle()
                    .fill(theme.outlineVariant.opacity(0.7))
                    .frame(height: 0.5)
                    .padding(.leading, 66)
                    .padding(.trailing, 8)
                    .opacity(hovering ? 0 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isCurrent ? model.player.togglePlayPause() : onPlay() }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isCurrent)
    }

    @ViewBuilder
    private func coverOverlay(playing: Bool) -> some View {
        if hovering || isCurrent {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.4))
                if hovering {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    PlayingBars(color: .white, animating: playing && pageActive && !reduceMotion)
                        .frame(width: 14, height: 13)
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
        }
    }
}
