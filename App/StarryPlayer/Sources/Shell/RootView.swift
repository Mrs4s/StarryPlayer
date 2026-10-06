import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model
        let theme = model.theme(for: colorScheme)
        // The barrier sits inside RootView, not around it in the App: the window's frame
        // autosave name is derived from the root view's type.
        LayoutBarrier(minSize: Metrics.windowMinSize) {
            ZStack {
                theme.surface.ignoresSafeArea()
                // No `allowsHitTesting` here: the host refuses clicks itself while covered.
                // Toggling it on a platform view makes SwiftUI add that view to the window
                // again, and AppKit then rebuilds the key view loop through the whole shell
                // (every page's focusable views) on each open or close.
                MainShellHost(model: model, covered: model.player.showNowPlaying)
                // Mounted from opening until its own closing animation ends; it animates itself
                // (the cover flies from the player bar), so it comes and goes without a transition.
                if model.player.nowPlayingMounted {
                    NowPlayingView()
                        .transition(.identity)
                        .zIndex(2)
                }
                if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.onSurface)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .glassPanel(radius: 20)
                        .padding(.bottom, model.player.showNowPlaying ? 96 : (model.player.current != nil ? Metrics.playerBarInset + 4 : 24))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(4)
                        .allowsHitTesting(false)
                }
            }
        }
        .environment(\.theme, theme)
        .animation(Motion.nowPlaying, value: model.player.showNowPlaying)
        .animation(Motion.popover, value: model.toast == nil)
        .ignoresSafeArea(.container, edges: .top)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
        }
        .modifier(MouseNavigationButtons(model: model))
    }
}

/// Answer layout queries from the proposal without measuring content, preventing
/// playback ticks from repeatedly probing every page's lazy stack.
struct LayoutBarrier: Layout {
    var minSize: CGSize = .zero

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? minSize.width, minSize.width), height: max(proposal.height ?? minSize.height, minSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// Host the shell separately and animate its layers, avoiding SwiftUI layout
/// updates across all retained pages during Now Playing transitions.
struct MainShellHost: NSViewRepresentable {
    var model: AppModel
    var covered: Bool

    func makeNSView(context: Context) -> CoverableHostView {
        let view = CoverableHostView(rootView: MainShell().environment(model))
        view.setCovered(covered, animated: false)
        return view
    }

    func updateNSView(_ view: CoverableHostView, context: Context) {
        let transaction = context.transaction
        view.setCovered(covered, animated: transaction.animation != nil && !transaction.disablesAnimations)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoverableHostView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MainLayout()
            .environment(\.theme, model.theme(for: colorScheme))
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// Scale via the container's `sublayerTransform`; AppKit owns the hosting layer's geometry.
/// Hide the covered view after fading to stop compositing it.
final class CoverableHostView: NSView {
    static let coveredScale: CGFloat = 0.95

    private let host: NSHostingView<AnyView>
    private var covered = false
    /// Bumped by every change, so the end of a superseded fade does not hide the content.
    private var generation = 0

    init<Content: View>(rootView: Content) {
        host = NSHostingView(rootView: AnyView(rootView))
        // Sized by this view: asking the content for its size would lay out every page.
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        host.frame = bounds
        if covered {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayerTransform = transform(covered: true)
            CATransaction.commit()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        covered ? nil : super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportColorSpace()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportColorSpace()
    }

    private func reportColorSpace() {
        guard let space = window?.colorSpace?.cgColorSpace else { return }
        ImageStore.shared.colorSpace = space
    }

    private func transform(covered: Bool) -> CATransform3D {
        guard covered, let layer else { return CATransform3DIdentity }
        let bounds = layer.bounds
        let pivot = CGPoint(x: bounds.midX - (bounds.minX + layer.anchorPoint.x * bounds.width),
                            y: bounds.midY - (bounds.minY + layer.anchorPoint.y * bounds.height))
        let scale = Self.coveredScale
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(pivot.x, pivot.y, 0), scale, scale, 1), -pivot.x, -pivot.y, 0)
    }

    func setCovered(_ value: Bool, animated: Bool) {
        guard value != covered || generation == 0 else { return }
        covered = value
        generation += 1
        guard let layer, let hostLayer = host.layer else { return }
        let target = transform(covered: value)
        let opacity: Float = value ? 0 : 1
        let fromTransform = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        let fromOpacity = hostLayer.presentation()?.opacity ?? hostLayer.opacity
        host.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = target
        host.alphaValue = CGFloat(opacity)
        if animated {
            let generation = generation
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == generation, self.covered else { return }
                self.host.isHidden = true
            }
            let scale = CABasicAnimation(keyPath: "sublayerTransform")
            scale.fromValue = NSValue(caTransform3D: fromTransform)
            scale.toValue = NSValue(caTransform3D: target)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = opacity
            for (animation, animatedLayer) in [(scale, layer), (fade, hostLayer)] {
                animation.duration = Motion.nowPlayingDuration
                animation.timingFunction = Motion.nowPlayingTiming
                animatedLayer.add(animation, forKey: "cover")
            }
        } else {
            layer.removeAnimation(forKey: "cover")
            hostLayer.removeAnimation(forKey: "cover")
            host.isHidden = value
        }
        CATransaction.commit()
    }
}

/// The mouse's back side button (3) drives `AppModel.back()`, except inside sheets (login) and the
/// settings window. There is no forward, so button 4 passes through.
private struct MouseNavigationButtons: ViewModifier {
    var model: AppModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [model] event in
                    guard event.buttonNumber == 3, event.window?.isSheet != true, event.window?.identifier != SettingsWindowController.identifier else { return event }
                    MainActor.assumeIsolated { model.back() }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Header + routed content, with the sidebar over their leading edge (`SidebarContainer`) and
/// the player bar floating over the bottom of the content column; the pages scroll beneath the
/// bar, so the sidebar runs the full height of the window.
struct MainLayout: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var backdrops = PageBackdrops()
    @Namespace private var switcherSpace
    @State private var switcherEvents = AccountSwitcherEvents()

    var body: some View {
        let hasBar = model.player.current != nil
        let glassBar = model.playerBarUsesGlass
        let sidebarInset = model.sidebarInset
        LayoutBarrier {
            VStack(spacing: 0) {
                NavHeader(switcherSpace: switcherSpace, switcherEvents: switcherEvents)
                ContentRouter(backdrops: backdrops)
            }
            .padding(.leading, sidebarInset)
            .background { CurrentPageBackdrop(backdrops: backdrops) }
        }
        // An overlay keeps frequent playback updates from invalidating the pages' layout.
        .overlay(alignment: .bottomLeading) {
            if hasBar {
                // The page fades into the window colour around the bar, so what scrolls beneath
                // it (and shows in the gap below it) stays quiet. The glass bar keeps more of the
                // page behind it: seeing it through the glass is the point.
                LinearGradient(stops: [
                    .init(color: theme.surface.opacity(0), location: 0),
                    .init(color: theme.surface.opacity(glassBar ? 0.35 : 0.8), location: 0.55),
                    .init(color: theme.surface, location: 0.86),
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.playerBarInset + 20)
                    .padding(.leading, sidebarInset)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
                PlayerBar()
                    .frame(maxWidth: Metrics.playerBarMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, sidebarInset + Metrics.playerBarMargin)
                    .padding([.trailing, .bottom], Metrics.playerBarMargin)
                    .transition(glassBar ? .playerBarGlass : .playerBar)
            }
        }
        // The search box over its room in the header: above the pages, so its panel overhangs
        // them, and as an overlay it lays out nothing else while it opens and resizes.
        .overlayPreferenceValue(SearchSlotKey.self, alignment: .topLeading) { SearchBoxLayer(slot: $0) }
        .overlayPreferenceValue(AccountChipKey.self, alignment: .topLeading) {
            AccountSwitcherLayer(chip: $0, namespace: switcherSpace, events: switcherEvents)
        }
        // Over the bar: the hidden sidebar comes out over everything in the shell. As an overlay
        // its width, inset and sliding never lay out the pages; only their inset does.
        .overlay(alignment: .topLeading) { SidebarContainer() }
        .background(theme.surface)
    }
}

/// Retain nearby history pages in separate hosting views. Hidden views stay out
/// of hit testing and accessibility traversal, keeping navigation cost bounded.
struct ContentRouter: View {
    var backdrops: PageBackdrops
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.currentEntry.id
        PageHosts(model: model, backdrops: backdrops, pages: model.livePages, current: current)
            // A text field on a page that is now hidden must not keep taking keystrokes.
            .onChange(of: current) { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

@MainActor @Observable
final class PageBackdrops {
    fileprivate(set) var pages: [UUID: PageBackdrop] = [:]

    fileprivate func set(_ backdrop: PageBackdrop?, for page: UUID) {
        if pages[page] !== backdrop { pages[page] = backdrop }
    }

    fileprivate func keep(_ live: Set<UUID>) {
        if pages.keys.contains(where: { !live.contains($0) }) { pages = pages.filter { live.contains($0.key) } }
    }
}

private struct CurrentPageBackdrop: View {
    var backdrops: PageBackdrops
    @Environment(AppModel.self) private var model

    var body: some View {
        PageBackdropLayer(backdrop: backdrops.pages[model.currentEntry.id])
    }
}

private struct PageHosts: NSViewRepresentable {
    var model: AppModel
    var backdrops: PageBackdrops
    var pages: [HistoryEntry]
    var current: UUID

    func makeNSView(context: Context) -> PageHostsView {
        PageHostsView(model: model, backdrops: backdrops)
    }

    func updateNSView(_ view: PageHostsView, context: Context) {
        view.show(pages, current: current)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageHostsView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// History-page hosts preserve hidden pages' sizes; resize them only when shown again.
final class PageHostsView: NSView {
    private let model: AppModel
    private let backdrops: PageBackdrops
    private var hosts: [UUID: PageHostingView] = [:]
    private var current: UUID?

    init(model: AppModel, backdrops: PageBackdrops) {
        self.model = model
        self.backdrops = backdrops
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        for host in hosts.values where !host.isHidden {
            host.frame = bounds
        }
    }

    func show(_ pages: [HistoryEntry], current: UUID) {
        let live = Set(pages.map(\.id))
        backdrops.keep(live)
        for (id, host) in hosts where !live.contains(id) {
            hosts[id] = nil
            if id == self.current {
                setShown(host, false, animated: true, removing: true)
            } else {
                host.removeFromSuperview()
            }
        }
        for entry in pages where hosts[entry.id] == nil {
            let host = PageHostingView(rootView: PageRoot(entry: entry, model: model, backdrops: backdrops))
            // Sized by this view: asking a page for its size would lay all of it out.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.isHidden = true
            host.frame = bounds
            hosts[entry.id] = host
            addSubview(host)
        }
        guard current != self.current else { return }
        let animated = self.current != nil
        if let previous = self.current.flatMap({ hosts[$0] }) {
            setShown(previous, false, animated: animated)
        }
        self.current = current
        if let host = hosts[current] {
            setShown(host, true, animated: animated)
        }
    }

    private func setShown(_ host: PageHostingView, _ shown: Bool, animated: Bool, removing: Bool = false) {
        host.fadeGeneration += 1
        let generation = host.fadeGeneration
        host.isInteractive = shown
        host.layer?.zPosition = shown ? 1 : 0
        if shown {
            host.isHidden = false
            host.frame = bounds
        }
        let finish = { [weak host] in
            guard let host, host.fadeGeneration == generation, !shown else { return }
            if removing { host.removeFromSuperview() } else { host.isHidden = true }
        }
        guard let layer = host.layer else {
            host.alphaValue = shown ? 1 : 0
            finish()
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.alphaValue = shown ? 1 : 0
        if animated {
            CATransaction.setCompletionBlock(finish)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = shown ? 1 : 0
            fade.duration = Motion.routeFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "route")
        } else {
            layer.removeAnimation(forKey: "route")
            finish()
        }
        CATransaction.commit()
    }
}

final class PageHostingView: NSHostingView<PageRoot> {
    fileprivate var isInteractive = false
    fileprivate var fadeGeneration = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}

/// A history page at the root of its hosting view, given what it would inherit from the shell.
struct PageRoot: View {
    let entry: HistoryEntry
    let model: AppModel
    let backdrops: PageBackdrops

    var body: some View {
        PageContent(entry: entry, backdrops: backdrops)
            .environment(model)
    }
}

private struct PageContent: View {
    let entry: HistoryEntry
    let backdrops: PageBackdrops
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let active = model.currentEntry.id == entry.id
        page(for: entry.route)
            .environment(\.theme, model.theme(for: colorScheme))
            .environment(\.isPageActive, active && !model.player.showNowPlaying)
            // Keeps the end of each page clear of the bar while the scroll views still run
            // beneath it (a safe-area inset would shorten them and cut the content off at the
            // bar's top). The pages scroll only vertically.
            .contentMargins(.bottom, model.player.current != nil ? Metrics.playerBarInset : 0, for: .scrollContent)
            .onPreferenceChange(PageBackdropKey.self) { [backdrops, id = entry.id] backdrop in
                MainActor.assumeIsolated { backdrops.set(backdrop, for: id) }
            }
    }

    @ViewBuilder
    private func page(for route: Route) -> some View {
        switch route {
        case .home: HomePage(cached: model.cachedHome())
        case .liked: LikedPage()
        case .history: HistoryPage()
        case .daily: DailyPage()
        case .allMedia: AllMediaPage()
        case .collection(let playlist): PlaylistPage(playlist: playlist)
        case .album(let album): AlbumPage(album: album)
        case .artist(let artist): ArtistPage(artist: artist)
        case .search(let query): SearchResultsPage(query: query)
        case .user(let user): ProfilePage(user: user)
        case .libraryAlbums(let genre): LibraryAlbumsPage(genre: genre)
        case .libraryArtists: LibraryArtistsPage()
        case .libraryGenres: LibraryGenresPage()
        case .libraryFolder(let path): LibraryFolderView(path: path)
        }
    }
}

struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = .infinity
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.pageContent)
                .pausesHitTestingWhileScrolling()
        }
        .scrollIndicators(.automatic)
    }
}
