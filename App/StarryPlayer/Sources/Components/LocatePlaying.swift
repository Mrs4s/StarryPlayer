import AppKit
import QuartzCore
import StarryCore
import SwiftUI

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    static var pageContent: Self { .named("pageContent") }
}

extension EnvironmentValues {
    @Entry var pinnedTopInset: CGFloat = 0
}

/// Locates a song using measured rows, then a short glide. Avoid `scrollTo` across
/// thousands of lazy rows: it misestimates positions or lays out the entire intervening list.
@MainActor @Observable
final class TrackListLocator {
    private(set) var located: (id: TrackRef, time: CFTimeInterval)?
    private(set) var isLoading = false
    private(set) var veiled = false
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored var rowTops: [Int: CGFloat] = [:]
    @ObservationIgnored private var run: Task<Void, Never>?

    static let glide = 8
    private static let steps = 40

    /// Locates `track` in `list`, whose rows show the matches of `query`; `clearSearch` empties
    /// the page's search field and the query its rows show, `failed` tells why the list could
    /// not load as far as the song. `topInset`: what pins over the top of the scroll view.
    func locate(_ track: Track, in list: TrackListLoader, query: String, topInset: CGFloat, animated: Bool, clearSearch: @escaping () -> Void, failed: @escaping (String) -> Void) {
        run?.cancel()
        run = Task {
            let loaded = if case .loaded? = list.place(of: track.id) { true } else { false }
            if !loaded {
                isLoading = true
                await list.load(through: track.id.id)
                isLoading = false
                guard !Task.isCancelled else { return }
                await Self.nextFrame()
            }
            guard case .loaded(var position)? = list.place(of: track.id) else {
                if let failure = list.failure { failed(failure) }
                return
            }
            var matches = list.matches(query)
            if let shown = matches, Self.offset(of: position, in: shown) == nil {
                clearSearch()
                matches = nil
                await Self.nextFrame()
                guard !Task.isCancelled, case .loaded(let now)? = list.place(of: track.id) else { return }
                position = now
            }
            guard let scrollView, await rowsLaidOut() else { return }
            let clip = scrollView.contentView
            let glide = CGFloat(Self.glide) * Metrics.songRowHeight
            defer { if veiled { withAnimation(animated ? .easeOut(duration: 0.3) : nil) { veiled = false } } }
            var walking = false
            var away: Int?
            for step in 0..<Self.steps {
                guard let (goal, rowsAway) = reckon(position, among: matches, in: scrollView, topInset: topInset) else { return }
                let now = clip.bounds.origin.y
                if abs(goal - now) <= (step == 0 ? max(clip.bounds.height * 1.5, glide * 1.5) : glide * 1.5) { break }
                // Walks the rest once a jump did not bring the song at least twice as close (the
                // lazy stack's estimate had changed as it laid out more rows): two screens at a
                // time, onto rows next to the ones laid out, which it places exactly.
                let reach = clip.bounds.height * 2
                if let away, rowsAway * 2 > away { walking = true }
                away = rowsAway
                if !veiled {
                    withAnimation(animated ? .easeIn(duration: 0.12) : nil) { veiled = true }
                    if animated { try? await Task.sleep(for: .milliseconds(120)) }
                }
                let start = animated ? goal + (goal > now ? -glide : glide) : goal
                Self.scroll(scrollView, to: walking ? now + min(max(start - now, -reach), reach) : start, animated: false)
                await Self.nextFrame()
                guard !Task.isCancelled else { return }
            }
            located = (track.id, CACurrentMediaTime())
            if veiled { withAnimation(animated ? .easeOut(duration: 0.3) : nil) { veiled = false } }
            if let (goal, _) = reckon(position, among: matches, in: scrollView, topInset: topInset) {
                Self.scroll(scrollView, to: goal, animated: animated)
            }
        }
    }

    /// Estimate the scroll origin that centres `position` from the nearest laid-out row.
    /// Returns nil when no row has been laid out.
    private func reckon(_ position: Int, among matches: [Int]?, in scrollView: NSScrollView, topInset: CGFloat) -> (origin: CGFloat, rowsAway: Int)? {
        let rows = matches ?? []
        func offset(_ position: Int) -> Int? { matches == nil ? position : Self.offset(of: position, in: rows) }
        guard let target = offset(position),
              let nearest = rowTops.keys.compactMap({ key in offset(key).map { (key, $0) } }).min(by: { abs($0.1 - target) < abs($1.1 - target) }),
              let top = rowTops[nearest.0]
        else { return nil }
        let center = top + CGFloat(target - nearest.1) * Metrics.songRowHeight + Metrics.songRowHeight / 2
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let middle = (topInset + clip.bounds.height - insets.bottom) / 2
        let highest = (scrollView.documentView?.frame.height ?? 0) + insets.bottom - clip.bounds.height
        return (min(max(center - middle, -insets.top), max(highest, -insets.top)), abs(target - nearest.1))
    }

    private static func scroll(_ scrollView: NSScrollView, to y: CGFloat, animated: Bool) {
        let clip = scrollView.contentView
        let point = NSPoint(x: clip.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(point)
            }
        } else {
            clip.scroll(to: point)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private static func offset(of position: Int, in rows: [Int]) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle] < position { low = middle + 1 } else { high = middle }
        }
        return low < rows.count && rows[low] == position ? low : nil
    }

    /// After SwiftUI's next update and the lazy stack's layout for it.
    private static func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Waits a little for rows to be laid out (just after the search was cleared, the rows that
    /// replace the matches have not told where they are yet); false if none are.
    private func rowsLaidOut() async -> Bool {
        for _ in 0..<15 where rowTops.isEmpty {
            await Self.nextFrame()
        }
        return !rowTops.isEmpty && !Task.isCancelled
    }
}

private struct ScrollViewFinder: NSViewRepresentable {
    var found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.found = found
    }

    final class FinderView: NSView {
        var found: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollView = enclosingScrollView { found?(scrollView) }
        }
    }
}

struct LocatePlayingButton: View {
    var list: TrackListLoader?
    var locator: TrackListLocator
    var context: PlaybackContext
    var query: String
    var gap: CGFloat = 8
    var clearSearch: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.pinnedTopInset) private var topInset
    @Environment(\.isPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        // Never empty, so the shortcut's handler stays while the button is hidden; the gap to
        // the search field comes and goes with the button.
        ZStack {
            if locatable != nil {
                button
                    .padding(.trailing, gap)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: locatable != nil)
        .background(ScrollViewFinder { [locator] in locator.scrollView = $0 })
        .onChange(of: model.locateRequest) {
            guard pageActive else { return }
            if !locate() { model.showToast("正在播放的歌曲不在这个列表里") }
        }
    }

    private var button: some View {
        Button { locate() } label: {
            ZStack {
                if locator.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "scope")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolEffect(.bounce, value: taps)
                }
            }
            .foregroundStyle(hovering ? theme.onSurface.opacity(0.85) : theme.onSurfaceVariant)
            .frame(width: 36, height: 36)
            .background(theme.onSurface.opacity((theme.isDark ? 0.06 : 0.05) + (hovering ? 0.03 : 0)), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("定位到正在播放的歌曲（⌥⌘L）")
    }

    private var locatable: Track? {
        guard let list, let track = model.player.current, track.id.source == context.source else { return nil }
        if list.place(of: track.id) != nil { return track }
        if !list.isComplete, model.player.isQueue(from: context) { return track }
        return nil
    }

    @discardableResult private func locate() -> Bool {
        guard let list, let track = locatable else { return false }
        taps += 1
        locator.locate(track, in: list, query: query, topInset: topInset, animated: !reduceMotion, clearSearch: clearSearch) { [model] failure in
            model.showToast("定位失败：\(failure)")
        }
        return true
    }
}

struct LocatedGlow: ViewModifier {
    /// When the row was located; nil if it was not.
    var time: CFTimeInterval?
    @Environment(\.theme) private var theme
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Radius.menu, style: .continuous)
                    .fill(theme.primary.opacity(0.14))
                    .strokeBorder(theme.primary.opacity(0.45), lineWidth: 1)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear(perform: glow)
            .onChange(of: time) { glow() }
    }

    private func glow() {
        // A row built after it was located (scrolled to) glows too, not one scrolled back to later.
        guard let time, CACurrentMediaTime() - time < 0.5 else { return }
        withAnimation(.easeOut(duration: 0.2).delay(0.2)) {
            lit = true
        } completion: {
            withAnimation(.easeInOut(duration: 0.9).delay(0.7)) { lit = false }
        }
    }
}
