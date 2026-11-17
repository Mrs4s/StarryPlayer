import AppKit
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

struct SongRowsSpec {
    var list: TrackListLoader?
    var fixed: [Track] = []
    /// Positions in `tracks`; nil includes all tracks.
    var matches: [Int]?
    var query: String
    var context: PlaybackContext
    var onRemove: (@MainActor (Track) -> Void)? = nil
    /// `to` is the insertion boundary in the original list, before removing `from`.
    var onMove: (@MainActor (_ from: Int, _ to: Int) -> Void)? = nil
    var locator: TrackListLocator? = nil
    var animatesEdits = true
    var columns = SongRowColumns()
    var numbersByTrack = false
    var headers: [Int: SongSectionHeader] = [:]
    var trailing: [String?] = []
    /// Normalized scores (0…1), indexed by track position.
    var scores: [Double] = []
    var scoreTint: Color = .clear

    @MainActor var tracks: [Track] { list?.tracks ?? fixed }

    @MainActor func number(at position: Int) -> Int {
        numbersByTrack ? tracks[position].trackNumber ?? position + 1 : position + 1
    }

    func trailingText(at position: Int) -> String? {
        trailing.indices.contains(position) ? trailing[position] : nil
    }

    func score(at position: Int) -> Double? {
        scores.indices.contains(position) ? scores[position] : nil
    }

    @MainActor func play(from position: Int, on player: PlayerController) {
        if let list {
            list.play(startAt: position, on: player, context: context)
        } else {
            player.play(fixed, startAt: position, context: context)
        }
    }
}

extension SongRowsSpec {
    init(tracks: [Track], matches: [Int]? = nil, query: String = "", context: PlaybackContext) {
        self.init(list: nil, fixed: tracks, matches: matches, query: query, context: context)
    }
}

/// Hosted rows released offscreen and animated with the list's stagger.
struct HostedListRow {
    /// Rows with the same kind share the last measured height as their estimate.
    var heightKind: String? = nil
    var estimatedHeight: CGFloat? = nil
}

struct DetailTableRow {
    enum Kind {
        case songs(SongRowsSpec)
        /// `nearEnd` fires at most once per measured row height.
        case hosted(AnyView, nearEnd: (@MainActor () -> Void)? = nil, listRow: HostedListRow? = nil)
    }

    var id: String
    var kind: Kind
}

extension DetailTableRow {
    static func hosted<Content: View>(_ id: String, nearEnd: (@MainActor () -> Void)? = nil, listRow: HostedListRow? = nil, @ViewBuilder content: () -> Content) -> DetailTableRow {
        DetailTableRow(id: id, kind: .hosted(AnyView(content().padding(.horizontal, Metrics.pagePadding)), nearEnd: nearEnd, listRow: listRow))
    }
}

enum DetailTableArrival {
    case edited
    /// Replaces content with a list stagger or directional tab transition.
    case swapped
    case instant
}

enum DetailTableChrome {
    /// A header that recedes as the page scrolls past it, then a tab bar that stays at the top.
    case detail
    /// A header that scrolls away with the rows, and no tab bar.
    case plain
}

extension DetailTableRow {
    /// Includes the loaded count in the row ID so each page triggers a new near-end request.
    @MainActor static func more<Item: Identifiable, Placeholder: View>(_ id: String, of feed: PagedFeed<Item>, load: @escaping @MainActor () async -> Void, @ViewBuilder placeholder: () -> Placeholder) -> DetailTableRow {
        if feed.moreFailed {
            return .hosted("\(id)-retry") {
                PillButton(title: "加载失败，重试", systemName: "arrow.clockwise", variant: .tertiary) { feed.retryMore() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        return .hosted("\(id)-more-\(feed.items.count)", nearEnd: { Task { await load() } }, content: placeholder)
    }
}

extension EnvironmentValues {
    @Entry var detailBarPinned: Bool? = nil
}

struct DetailTablePage<Tab: RawRepresentable & Hashable>: NSViewRepresentable where Tab.RawValue == Int {
    @Binding var tab: Tab
    var backdrop: PageBackdrop
    var model: AppModel
    var hero: AnyView
    var bar: AnyView
    var barBottomPadding: CGFloat
    var rows: [DetailTableRow]
    var bottomInset: CGFloat
    var arrival: DetailTableArrival = .edited
    var chrome: DetailTableChrome = .detail

    func makeCoordinator() -> DetailTableCoordinator { DetailTableCoordinator() }

    func makeNSView(context: Context) -> DetailTableContainer {
        let view = DetailTableContainer()
        context.coordinator.attach(to: view)
        context.coordinator.update(configuration(context))
        return view
    }

    func updateNSView(_ view: DetailTableContainer, context: Context) {
        context.coordinator.update(configuration(context))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DetailTableContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private func configuration(_ context: Context) -> DetailTableCoordinator.Configuration {
        DetailTableCoordinator.Configuration(tab: tab.rawValue, backdrop: backdrop, model: model, hero: hero, bar: bar, barBottomPadding: barBottomPadding, rows: rows, bottomInset: bottomInset, arrival: arrival, chrome: chrome, environment: context.environment)
    }
}

enum PlainPageTab: Int {
    case only
}

extension DetailTablePage where Tab == PlainPageTab {
    init(model: AppModel, header: AnyView, rows: [DetailTableRow], bottomInset: CGFloat, arrival: DetailTableArrival = .instant) {
        self.init(tab: .constant(.only), backdrop: PageBackdrop(), model: model, hero: header, bar: AnyView(EmptyView()), barBottomPadding: 0, rows: rows, bottomInset: bottomInset, arrival: arrival, chrome: .plain)
    }
}

extension View {
    func plainPageHeader(gap: CGFloat) -> some View {
        padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, gap)
    }
}

extension DetailTableRow {
    @MainActor static func songList(_ tracks: [Track], context: PlaybackContext, gapAbove: CGFloat = 0) -> [DetailTableRow] {
        [
            .hosted("columns") { SongListHeader().padding(.top, gapAbove) },
            DetailTableRow(id: "songs", kind: .songs(SongRowsSpec(tracks: tracks, context: context))),
        ]
    }
}

final class DetailTableContainer: NSView {
    let scroll = NSScrollView()
    let pinned = NSView()

    init() {
        super.init(frame: .zero)
        addSubview(scroll)
        pinned.isHidden = true
        addSubview(pinned)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        pinned.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.detailTabBarHeight)
        pinned.subviews.first?.frame = pinned.bounds
    }
}

struct DetailTableLayout: Equatable {
    enum Kind: Equatable {
        case hero, bar
        case song(position: Int)
        /// A heading above the song at `position`; `leads` when nothing but the bar is above it.
        case header(position: Int, leads: Bool)
        case hosted
        case listRow
        case filler
    }

    struct Row: Equatable {
        var id: String
        var kind: Kind
    }

    var rows: [Row]
    var rowByPosition: [Int: Int] = [:]
    var hostedRows: [String: Int] = [:]
    var hasListRows = false
    var firstContentRow = 2
    var barRow: Int? { firstContentRow == 2 ? 1 : nil }
    var hasSongs: Bool { !rowByPosition.isEmpty }
    var isList: Bool { hasSongs || hasListRows }
    var ids: [String] { rows.map(\.id) }

    static let heroID = "hero"
    static let barID = "bar"
    static let fillerID = "filler"

    @MainActor static func make(_ content: [DetailTableRow], bar: Bool = true) -> DetailTableLayout {
        var rows = [Row(id: heroID, kind: .hero)]
        if bar { rows.append(Row(id: barID, kind: .bar)) }
        let firstContentRow = rows.count
        var rowByPosition: [Int: Int] = [:]
        var hostedRows: [String: Int] = [:]
        var hasListRows = false
        var seen: Set<String> = []
        for row in content {
            switch row.kind {
            case .songs(let spec):
                let tracks = spec.tracks
                for position in spec.matches ?? Array(tracks.indices) where tracks.indices.contains(position) {
                    if let header = spec.headers[position] {
                        var id = "header:\(header.title)"
                        if !seen.insert(id).inserted { id += "#\(position)" }
                        rows.append(Row(id: id, kind: .header(position: position, leads: rows.count == firstContentRow)))
                    }
                    var id = "song:\(tracks[position].id.source.key)/\(tracks[position].id.id)"
                    if !seen.insert(id).inserted { id += "#\(position)" }
                    rowByPosition[position] = rows.count
                    rows.append(Row(id: id, kind: .song(position: position)))
                }
            case .hosted(_, _, let listRow):
                let id = "hosted:\(row.id)"
                hostedRows[id] = rows.count
                if listRow != nil { hasListRows = true }
                rows.append(Row(id: id, kind: listRow == nil ? .hosted : .listRow))
            }
        }
        rows.append(Row(id: fillerID, kind: .filler))
        return DetailTableLayout(rows: rows, rowByPosition: rowByPosition, hostedRows: hostedRows, hasListRows: hasListRows, firstContentRow: firstContentRow)
    }

    func position(ofRow row: Int) -> Int? {
        guard rows.indices.contains(row), case .song(let position) = rows[row].kind else { return nil }
        return position
    }
}

enum DetailTableChange: Equatable {
    case none
    case reload
    /// Removal indexes refer to the old rows; insertion indexes refer to the new rows.
    case edit(removals: IndexSet, insertions: IndexSet)

    static func plan(from old: [String], to new: [String]) -> DetailTableChange {
        guard old != new else { return .none }
        guard !old.isEmpty else { return .reload }
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        return .edit(removals: removals, insertions: insertions)
    }

    static let animatedLimit = 24
}

@MainActor @Observable
final class HeroMotion {
    var t: Double = 0
}

/// A list row's content, deaf to the pointer while the page scrolls: the rows passing under a
/// resting pointer would each light up otherwise.
private struct QuietWhileScrolling: View {
    var activity: ScrollActivity
    var content: AnyView

    var body: some View {
        content.allowsHitTesting(!activity.isScrolling)
    }
}

private struct HeroMotionView: View {
    var motion: HeroMotion
    var hero: AnyView

    var body: some View {
        hero
            .opacity(1 - motion.t * 0.9)
            .scaleEffect(1 - motion.t * 0.03, anchor: .top)
    }
}

final class SongTableView: NSTableView {
    var onPointer: ((NSPoint?) -> Void)?
    var onMenu: ((NSPoint) -> NSMenu?)?
    var onDragLeft: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(convert(event.locationInWindow, from: nil))
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragLeft?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragLeft?()
    }
}

final class BarRowCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("BarRowCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        subviews.first?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.detailTabBarHeight)
    }
}

@MainActor
final class DetailTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Configuration {
        struct Hosted {
            var view: AnyView
            var nearEnd: (@MainActor () -> Void)?
            var listRow: HostedListRow?
        }

        var tab: Int
        var backdrop: PageBackdrop
        var model: AppModel
        var hero: AnyView
        var bar: AnyView
        var barBottomPadding: CGFloat
        var rows: [DetailTableRow]
        var bottomInset: CGFloat
        var arrival: DetailTableArrival
        var chrome: DetailTableChrome
        var environment: EnvironmentValues
        private(set) var songs: SongRowsSpec?
        private(set) var nearEndIDs: [String] = []
        private var hostedRows: [String: Hosted] = [:]

        init(tab: Int, backdrop: PageBackdrop, model: AppModel, hero: AnyView, bar: AnyView, barBottomPadding: CGFloat, rows: [DetailTableRow], bottomInset: CGFloat, arrival: DetailTableArrival, chrome: DetailTableChrome, environment: EnvironmentValues) {
            self.tab = tab
            self.backdrop = backdrop
            self.model = model
            self.hero = hero
            self.bar = bar
            self.barBottomPadding = barBottomPadding
            self.rows = rows
            self.bottomInset = bottomInset
            self.arrival = arrival
            self.chrome = chrome
            self.environment = environment
            for row in rows {
                switch row.kind {
                case .songs(let spec):
                    if songs == nil { songs = spec }
                case .hosted(let view, let nearEnd, let listRow):
                    let id = "hosted:\(row.id)"
                    hostedRows[id] = Hosted(view: view, nearEnd: nearEnd, listRow: listRow)
                    if nearEnd != nil { nearEndIDs.append(id) }
                }
            }
        }

        var theme: Theme { environment.theme }
        var pageActive: Bool { environment.isPageActive }
        var reduceMotion: Bool { environment.accessibilityReduceMotion }

        func hosted(_ id: String) -> Hosted? { hostedRows[id] }
    }

    private weak var container: DetailTableContainer?
    private weak var scroll: NSScrollView?
    private let table = SongTableView()
    private let heroHost = HostedRowView()
    private let barHost = HostedRowView()
    private let heroMotion = HeroMotion()
    private let insertionLine = InsertionLineView()
    private var hosted: [String: HostedRowView] = [:]
    private var heights: [String: CGFloat] = [:]
    private var kindHeights: [String: CGFloat] = [:]
    private var songRowHeight = Metrics.songRowHeight
    private var scoreTint = NSColor.clear
    private var layout = DetailTableLayout(rows: [])
    private var configuration: Configuration?
    private var palette = SongTablePalette(theme: .darkBase)
    private var shownTab: Int?
    private var shownQuery: String?
    private var floor: CGFloat = 0
    private var hoveredRow: Int?
    private var pinned = false
    private let activity = ScrollActivity()
    private var observingPlayer = false
    private var observingActivity = false
    private var observedLocator: TrackListLocator?
    private var entering: (direction: CGFloat, until: CFTimeInterval)?
    private var sliding: (direction: CGFloat, until: CFTimeInterval)?
    private var veiled = false
    private var dropLanding: Int?
    private var nearEndNotified: [String: CGFloat] = [:]

    private static let heroGuess: CGFloat = 280
    private static let hostedGuess: CGFloat = 120
    private var bottomPadding: CGFloat { configuration?.chrome == .plain ? 32 : 40 }
    private static let songType = NSPasteboard.PasteboardType(UTType.starryTracks.identifier)

    // MARK: Setup

    func attach(to container: DetailTableContainer) {
        self.container = container
        let scroll = container.scroll
        self.scroll = scroll
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.gridStyleMask = []
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = Metrics.songRowHeight
        table.autoresizingMask = [.width]
        table.draggingDestinationFeedbackStyle = .none
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onPointer = { [weak self] point in self?.pointer(at: point) }
        table.onMenu = { [weak self] point in self?.menu(at: point) }
        table.onDragLeft = { [weak self] in self?.showInsertionLine(at: nil) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        heroHost.onHeight = { [weak self] height in self?.heightChanged(DetailTableLayout.heroID, to: height) }
        observeActivity()
    }

    func update(_ configuration: Configuration) {
        let previous = self.configuration
        self.configuration = configuration
        let palette = SongTablePalette(theme: configuration.theme)
        if palette != self.palette {
            self.palette = palette
            insertionLine.palette = palette
        }
        if configuration.chrome == .detail {
            heroHost.show(AnyView(HeroMotionView(motion: heroMotion, hero: configuration.hero)), environment: hostedEnvironment)
            showBar()
        } else {
            heroHost.show(configuration.hero, environment: hostedEnvironment)
        }
        if let scroll {
            let bottom = bottomPadding + configuration.bottomInset
            if scroll.contentInsets.bottom != bottom { scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0) }
        }
        if previous?.barBottomPadding != configuration.barBottomPadding, !layout.rows.isEmpty, let bar = layout.barRow {
            Self.unanimated { table.noteHeightOfRows(withIndexesChanged: [bar, layout.rows.count - 1]) }
        }
        scoreTint = configuration.songs.map { NSColor($0.scoreTint) } ?? .clear
        let rowHeight = configuration.songs?.columns.rowHeight ?? Metrics.songRowHeight
        if rowHeight != songRowHeight {
            songRowHeight = rowHeight
            if layout.hasSongs {
                Self.unanimated { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<layout.rows.count)) }
            }
        }
        applyRows(configuration)
        for (id, view) in hosted {
            if let row = configuration.hosted(id) { view.show(content(of: row), environment: hostedEnvironment) }
        }
        if let spec = configuration.songs {
            if spec.onMove != nil { table.registerForDraggedTypes([Self.songType]) } else { table.unregisterDraggedTypes() }
            if let locator = spec.locator {
                locator.scrollView = scroll
                locator.exactRowOrigin = { [weak self] position in self?.rowOrigin(ofPosition: position) }
                if observedLocator !== locator {
                    observedLocator = locator
                    observeLocator(locator)
                }
            }
        }
        if !observingPlayer { observePlayer() }
        refreshVisible()
    }

    private var hostedEnvironment: EnvironmentValues {
        var environment = configuration?.environment ?? EnvironmentValues()
        environment.pinnedTopInset = configuration?.chrome == .plain ? 0 : Metrics.detailTabBarHeight
        environment.detailBarPinned = pinned
        return environment
    }

    private func content(of row: Configuration.Hosted) -> AnyView {
        row.listRow == nil ? row.view : AnyView(QuietWhileScrolling(activity: activity, content: row.view))
    }

    private func showBar() {
        guard let configuration else { return }
        barHost.show(configuration.bar, environment: hostedEnvironment)
    }

    // MARK: Rows

    private func applyRows(_ configuration: Configuration) {
        let new = DetailTableLayout.make(configuration.rows, bar: configuration.chrome == .detail)
        let old = layout
        let tabChanged = shownTab != nil && shownTab != configuration.tab
        let queryChanged = shownQuery != configuration.songs?.query
        let direction: CGFloat = tabChanged ? (configuration.tab > (shownTab ?? 0) ? 1 : -1) : 0
        shownTab = configuration.tab
        shownQuery = configuration.songs?.query
        var change: DetailTableChange = tabChanged || queryChanged ? (old.ids == new.ids ? .none : .reload) : .plan(from: old.ids, to: new.ids)
        // A list that takes the place of something else (its skeleton) comes in as a whole.
        if configuration.arrival == .swapped, change != .none, new.isList, !old.isList { change = .reload }
        if tabChanged { switchTabs() }
        guard change != .none else { return }
        layout = new
        hosted = hosted.filter { new.hostedRows[$0.key] != nil }
        nearEndNotified = nearEndNotified.filter { new.hostedRows[$0.key] != nil }
        switch change {
        case .none:
            break
        case .reload:
            Self.unanimated { table.reloadData() }
            if !configuration.reduceMotion, configuration.arrival != .instant {
                let until = CACurrentMediaTime() + 0.1
                if new.isList, !old.isList || tabChanged { entering = (direction, until) }
                if tabChanged, configuration.arrival == .swapped { sliding = (direction, until) }
            }
        case .edit(let removals, let insertions):
            let lists = removals.contains { old.rows[$0].kind == .listRow } || insertions.contains { new.rows[$0].kind == .listRow }
            let animated = configuration.arrival == .edited && !lists && (configuration.songs?.animatesEdits ?? true) && removals.count + insertions.count <= DetailTableChange.animatedLimit
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.4 : 0
                table.beginUpdates()
                table.removeRows(at: removals, withAnimation: animated ? [.effectFade, .slideUp] : [])
                table.insertRows(at: insertions, withAnimation: animated ? [.effectFade, .slideDown] : [])
                table.endUpdates()
            }
            refreshVisible()
        }
        Self.unanimated { table.noteHeightOfRows(withIndexesChanged: [layout.rows.count - 1]) }
    }

    private func switchTabs() {
        guard let scroll else { return }
        let clip = scroll.contentView
        let offset = clip.bounds.origin.y
        let hero = heroHeight
        floor = min(max(offset, 0), hero) + clip.bounds.height
        if offset > hero + 0.5 {
            Self.unanimated {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: hero))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    private var heroHeight: CGFloat { heights[DetailTableLayout.heroID] ?? Self.heroGuess }

    private func height(of row: DetailTableLayout.Row) -> CGFloat {
        switch row.kind {
        case .hero: heroHeight
        case .bar: Metrics.detailTabBarHeight + (configuration?.barBottomPadding ?? 0)
        case .song: songRowHeight
        case .header(_, let leads): SongSectionHeaderCell.height(leading: leads)
        case .hosted: heights[row.id] ?? Self.hostedGuess
        case .listRow: heights[row.id] ?? estimatedHeight(ofListRow: row.id)
        case .filler: fillerHeight
        }
    }

    private func estimatedHeight(ofListRow id: String) -> CGFloat {
        guard let listRow = configuration?.hosted(id)?.listRow else { return Self.hostedGuess }
        return listRow.estimatedHeight ?? listRow.heightKind.flatMap { kindHeights[$0] } ?? Self.hostedGuess
    }

    private var fillerHeight: CGFloat {
        let content = layout.rows.filter { $0.kind != .filler }.map(height(of:)).reduce(0, +) + bottomPadding
        // NSTableView requires positive row heights.
        return max(floor - content, 1)
    }

    private func heightChanged(_ id: String, to height: CGFloat) {
        guard heights[id] != height, let scroll else { return }
        heights[id] = height
        guard !layout.rows.isEmpty, let row = id == DetailTableLayout.heroID ? 0 : layout.hostedRows[id] else { return }
        var changed: IndexSet = [row, layout.rows.count - 1]
        if let kind = configuration?.hosted(id)?.listRow?.heightKind, kindHeights[kind] != height {
            kindHeights[kind] = height
            for (other, index) in layout.hostedRows where other != id && configuration?.hosted(other)?.listRow?.heightKind == kind {
                // The rows that are not shown were measured at another width, if at all.
                if hosted[other] == nil { heights[other] = nil }
                changed.insert(index)
            }
        }
        let clip = scroll.contentView
        let atTop = clip.bounds.origin.y < 1
        Self.unanimated {
            table.noteHeightOfRows(withIndexesChanged: changed)
            if atTop {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
                scroll.reflectScrolledClipView(clip)
            }
        }
        if id == DetailTableLayout.heroID { scrolled() }
        checkNearEnd()
    }

    // Disable inherited SwiftUI animations to avoid stale table-frame targets as rows arrive.
    private static func unanimated(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        changes()
        NSAnimationContext.endGrouping()
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { layout.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard layout.rows.indices.contains(row) else { return songRowHeight }
        return height(of: layout.rows[row])
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        // A list's hosted rows do not outlive their time on screen: a long list would keep a
        // hosting view for every row scrolled past.
        guard let view = rowView.view(atColumn: 0) as? HostedRowView, let id = view.rowID, hosted[id] === view,
              configuration?.hosted(id)?.listRow != nil else { return }
        hosted[id] = nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: PlainRowView.identifier, owner: nil) as? PlainRowView ?? PlainRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let configuration, layout.rows.indices.contains(row) else { return nil }
        let entry = layout.rows[row]
        switch entry.kind {
        case .hero:
            return heroHost
        case .bar:
            let cell = tableView.makeView(withIdentifier: BarRowCell.identifier, owner: nil) as? BarRowCell ?? BarRowCell()
            if !pinned { cell.addSubview(barHost) }
            return cell
        case .song(let position):
            guard let spec = configuration.songs, spec.tracks.indices.contains(position) else { return nil }
            let cell = tableView.makeView(withIdentifier: SongCellView.identifier, owner: nil) as? SongCellView ?? SongCellView()
            configure(cell, position: position, row: row, spec: spec)
            cell.alphaValue = veiled ? 0 : 1
            if let entering, CACurrentMediaTime() < entering.until, let layer = cell.layer {
                let index = min(row - layout.firstContentRow, Motion.staggerLimit)
                SongRowDrawing.enter(layer, direction: entering.direction, delay: Double(index) * Motion.staggerStep)
                if let score = spec.score(at: position) {
                    cell.setScore(score, tint: scoreTint, growingAfter: 0.12 + Double(index) * 0.04)
                }
            }
            if let located = spec.locator?.located, located.id == spec.tracks[position].id, CACurrentMediaTime() - located.time < 0.5 {
                glow(cell)
            }
            spec.list?.prefetch(near: position)
            return cell
        case .header(let position, _):
            let cell = tableView.makeView(withIdentifier: SongSectionHeaderCell.identifier, owner: nil) as? SongSectionHeaderCell ?? SongSectionHeaderCell()
            cell.palette = palette
            cell.header = configuration.songs?.headers[position]
            cell.layer?.removeAllAnimations()
            if let entering, CACurrentMediaTime() < entering.until, let layer = cell.layer {
                let index = min(row - layout.firstContentRow, Motion.staggerLimit)
                SongRowDrawing.enter(layer, direction: entering.direction, delay: Double(index) * Motion.staggerStep)
            }
            return cell
        case .hosted, .listRow:
            if let view = hosted[entry.id] { return view }
            guard let hostedRow = configuration.hosted(entry.id) else { return nil }
            let view = HostedRowView()
            view.rowID = entry.id
            view.onHeight = { [weak self] height in self?.heightChanged(entry.id, to: height) }
            view.show(content(of: hostedRow), environment: hostedEnvironment)
            hosted[entry.id] = view
            let now = CACurrentMediaTime()
            if entry.kind == .listRow, let entering, now < entering.until {
                view.wantsLayer = true
                let index = min(row - layout.firstContentRow, Motion.staggerLimit)
                if let layer = view.layer { SongRowDrawing.enter(layer, direction: entering.direction, delay: Double(index) * Motion.staggerStep) }
            } else if entry.kind == .hosted, let sliding, now < sliding.until {
                view.wantsLayer = true
                if let layer = view.layer { SongRowDrawing.slideIn(layer, direction: sliding.direction) }
            }
            return view
        case .filler:
            return tableView.makeView(withIdentifier: Self.fillerIdentifier, owner: nil) ?? {
                let view = NSView()
                view.identifier = Self.fillerIdentifier
                return view
            }()
        }
    }

    private static let fillerIdentifier = NSUserInterfaceItemIdentifier("FillerCell")

    private func configure(_ cell: SongCellView, position: Int, row: Int, spec: SongRowsSpec) {
        guard let configuration else { return }
        let track = spec.tracks[position]
        let model = configuration.model
        let actions = SongCellView.Actions(
            play: { [weak self] in self?.play(position) },
            toggleLike: { withAnimation(.spring(duration: 0.3, bounce: 0.4)) { model.toggleLike(track) } },
            showArtist: { model.showArtist($0, of: track) },
            showAlbum: { model.showAlbum(of: track) }
        )
        cell.palette = palette
        cell.columns = spec.columns
        cell.show(track, index: spec.number(at: position), tags: tags(of: track, model: model), trailing: spec.trailingText(at: position), state: state(of: track, row: row), actions: actions)
        cell.setScore(spec.score(at: position), tint: scoreTint)
    }

    private func tags(of track: Track, model: AppModel) -> [SongTagSpec] {
        var tags: [SongTagSpec] = []
        let tiers = model.availableTiers(of: track)
        if let badge = tiers.last(where: { !$0.isSpatial && $0.badge != nil })?.badge { tags.append(SongTagSpec(text: badge, style: .amber)) }
        for tier in tiers where tier.isSpatial {
            if let badge = tier.badge { tags.append(SongTagSpec(text: badge, style: .amber)) }
        }
        if track.fee == .vip { tags.append(SongTagSpec(text: "VIP", style: .red)) }
        else if track.fee == .purchase { tags.append(SongTagSpec(text: "EP", style: .red)) }
        if track.hasVideo { tags.append(SongTagSpec(text: "MV", style: .neutral)) }
        return tags
    }

    private func state(of track: Track, row: Int) -> SongCellView.State {
        guard let configuration else { return SongCellView.State() }
        let player = configuration.model.player
        let current = player.current?.id == track.id
        return SongCellView.State(
            isCurrent: current,
            isPlaying: current && player.isPlaying,
            barsAnimate: configuration.pageActive && !configuration.reduceMotion,
            hovered: row == hoveredRow,
            liked: player.isLiked(track),
            canLike: configuration.model.canLike(track)
        )
    }

    private func refreshVisible() {
        guard let spec = configuration?.songs else { return }
        table.enumerateAvailableRowViews { [self] rowView, row in
            if let cell = rowView.view(atColumn: 0) as? SongSectionHeaderCell {
                cell.palette = palette
                if layout.rows.indices.contains(row), case .header(let position, _) = layout.rows[row].kind { cell.header = spec.headers[position] }
                return
            }
            guard let cell = rowView.view(atColumn: 0) as? SongCellView, let position = layout.position(ofRow: row), spec.tracks.indices.contains(position) else { return }
            let track = spec.tracks[position]
            if cell.track?.id != track.id || cell.columns != spec.columns {
                configure(cell, position: position, row: row, spec: spec)
            } else {
                cell.palette = palette
                cell.setIndex(spec.number(at: position))
                cell.setTrailing(spec.trailingText(at: position))
                cell.setScore(spec.score(at: position), tint: scoreTint)
                cell.apply(state(of: track, row: row))
            }
        }
    }

    private func songCell(at row: Int) -> SongCellView? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SongCellView
    }

    private func play(_ position: Int) {
        guard let configuration, let spec = configuration.songs else { return }
        spec.play(from: position, on: configuration.model.player)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let position = layout.position(ofRow: table.clickedRow) else { return }
        play(position)
    }

    private func menu(at point: NSPoint) -> NSMenu? {
        guard let configuration, let spec = configuration.songs, let position = layout.position(ofRow: table.row(at: point)), spec.tracks.indices.contains(position) else { return nil }
        let track = spec.tracks[position]
        var removeFromPlaylist: (@MainActor () -> Void)?
        if let remove = spec.onRemove { removeFromPlaylist = { remove(track) } }
        return SongRowMenu.make(for: track, model: configuration.model, play: { [weak self] in self?.play(position) }, removeFromPlaylist: removeFromPlaylist)
    }

    // MARK: Observation

    private func observePlayer() {
        guard let player = configuration?.model.player else { return }
        observingPlayer = true
        withObservationTracking {
            _ = player.current
            _ = player.isPlaying
            _ = player.liked
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observingPlayer = false
                refreshVisible()
                observePlayer()
            }
        }
    }

    private func observeActivity() {
        observingActivity = true
        withObservationTracking {
            _ = activity.isScrolling
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                observingActivity = false
                if activity.isScrolling {
                    setHover(nil, at: nil)
                } else if let window = table.window {
                    pointer(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                }
                observeActivity()
            }
        }
    }

    private func observeLocator(_ locator: TrackListLocator) {
        withObservationTracking {
            _ = locator.veiled
            _ = locator.located
        } onChange: { [weak self, weak locator] in
            Task { @MainActor [weak self] in
                guard let self, let locator, observedLocator === locator else { return }
                locatorChanged(locator)
                observeLocator(locator)
            }
        }
    }

    private func locatorChanged(_ locator: TrackListLocator) {
        if locator.veiled != veiled {
            veiled = locator.veiled
            let animated = !(configuration?.reduceMotion ?? false)
            NSAnimationContext.runAnimationGroup { [self] context in
                context.duration = animated ? (veiled ? 0.12 : 0.3) : 0
                context.timingFunction = CAMediaTimingFunction(name: veiled ? .easeIn : .easeOut)
                table.enumerateAvailableRowViews { rowView, _ in
                    guard let cell = rowView.view(atColumn: 0) as? SongCellView else { return }
                    cell.animator().alphaValue = veiled ? 0 : 1
                }
            }
        }
        if let located = locator.located, CACurrentMediaTime() - located.time < 0.5, let spec = configuration?.songs,
           case .loaded(let position)? = spec.list?.place(of: located.id), let row = layout.rowByPosition[position], let cell = songCell(at: row) {
            glow(cell)
        }
    }

    private func glow(_ cell: SongCellView) {
        Task { @MainActor [weak cell] in
            try? await Task.sleep(for: .milliseconds(200))
            cell?.glowOnce()
        }
    }

    // MARK: Scrolling

    @objc private func scrolled() {
        guard let scroll, let configuration else { return }
        let offset = scroll.contentView.bounds.origin.y
        activity.moved(to: offset)
        guard configuration.chrome == .detail else { return checkNearEnd() }
        let hero = heroHeight
        let t = min(max(offset / max(hero, 1), 0), 1)
        let fade = (Double(t) * 60).rounded() / 60
        if configuration.backdrop.fade != fade { configuration.backdrop.fade = fade }
        let motion = (Double(t) * 120).rounded() / 120
        if heroMotion.t != motion { heroMotion.t = motion }
        setPinned(offset >= hero - 0.5)
        checkNearEnd()
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != self.pinned, let container else { return }
        self.pinned = pinned
        if pinned {
            container.pinned.addSubview(barHost)
            barHost.frame = container.pinned.bounds
            container.pinned.isHidden = false
        } else {
            container.pinned.isHidden = true
            if let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? BarRowCell {
                cell.addSubview(barHost)
                cell.needsLayout = true
            } else {
                barHost.removeFromSuperview()
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { showBar() }
    }

    private func checkNearEnd() {
        guard let scroll, let configuration, !configuration.nearEndIDs.isEmpty else { return }
        let clip = scroll.contentView
        let visibleBottom = clip.bounds.origin.y + clip.bounds.height
        for id in configuration.nearEndIDs {
            guard let row = layout.hostedRows[id], let nearEnd = configuration.hosted(id)?.nearEnd else { continue }
            let rect = table.rect(ofRow: row)
            guard rect.maxY - visibleBottom < clip.bounds.height * 1.5, nearEndNotified[id] != rect.height else { continue }
            nearEndNotified[id] = rect.height
            nearEnd()
        }
    }

    private func rowOrigin(ofPosition position: Int) -> CGFloat? {
        guard let row = layout.rowByPosition[position] else { return nil }
        return table.rect(ofRow: row).minY
    }

    // MARK: Hover

    private func pointer(at point: NSPoint?) {
        guard !activity.isScrolling else { return }
        guard let point, table.visibleRect.contains(point), !underPinnedBar(point), let row = Optional(table.row(at: point)), layout.position(ofRow: row) != nil else {
            setHover(nil, at: nil)
            return
        }
        setHover(row, at: point)
    }

    private func underPinnedBar(_ point: NSPoint) -> Bool {
        guard pinned, let container else { return false }
        return container.pinned.frame.contains(table.convert(point, to: container))
    }

    private func setHover(_ row: Int?, at point: NSPoint?) {
        if row != hoveredRow {
            let was = hoveredRow
            hoveredRow = row
            if let was, let cell = songCell(at: was) {
                cell.pointerMoved(to: nil)
                if let state = cellState(at: was) { cell.apply(state) }
            }
            if let row, let cell = songCell(at: row), let state = cellState(at: row) { cell.apply(state) }
        }
        if let row, let point, let cell = songCell(at: row) {
            cell.pointerMoved(to: cell.convert(point, from: table))
        }
    }

    private func cellState(at row: Int) -> SongCellView.State? {
        guard let spec = configuration?.songs, let position = layout.position(ofRow: row), spec.tracks.indices.contains(position) else { return nil }
        return state(of: spec.tracks[position], row: row)
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let spec = configuration?.songs, let position = layout.position(ofRow: row), spec.tracks.indices.contains(position) else { return nil }
        let track = spec.tracks[position]
        let item = NSPasteboardItem()
        item.setString(([track.title] + [track.artists.map(\.name).joined(separator: " / ")].filter { !$0.isEmpty }).joined(separator: " - "), forType: .string)
        item.setData(Data(track.id.id.utf8), forType: Self.songType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let configuration, let spec = configuration.songs, let row = rowIndexes.first, let position = layout.position(ofRow: row), spec.tracks.indices.contains(position) else { return }
        let track = spec.tracks[position]
        configuration.model.draggedTracks = [track]
        let image = SongDragImage.make(for: track, palette: palette)
        let point = table.convert(table.window?.convertPoint(fromScreen: screenPoint) ?? .zero, from: nil)
        session.enumerateDraggingItems(options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.draggingFrame = NSRect(x: point.x - 14, y: point.y - image.size.height / 2, width: image.size.width, height: image.size.height)
            item.imageComponentsProvider = {
                let component = NSDraggingImageComponent(key: .icon)
                component.contents = image
                component.frame = NSRect(origin: .zero, size: image.size)
                return [component]
            }
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        showInsertionLine(at: nil)
    }

    private func landing(for info: any NSDraggingInfo) -> (from: Int, landing: Int?)? {
        guard let configuration, let spec = configuration.songs, spec.onMove != nil, spec.matches == nil,
              info.draggingPasteboard.types?.contains(Self.songType) == true else { return nil }
        let tracks = configuration.model.draggedTracks
        guard tracks.count == 1, let track = tracks.first, let from = spec.tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        let point = table.convert(info.draggingLocation, from: nil)
        let row = table.row(at: point)
        guard let position = layout.position(ofRow: row) else { return nil }
        let target = point.y - table.rect(ofRow: row).minY < songRowHeight / 2 ? position : position + 1
        return (from, target == from || target == from + 1 ? nil : target)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let (_, landing) = landing(for: info) else {
            showInsertionLine(at: nil)
            return []
        }
        showInsertionLine(at: landing)
        tableView.setDropRow(-1, dropOperation: .on)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let landing = dropLanding
        showInsertionLine(at: nil)
        guard let (from, _) = self.landing(for: info), let landing, let onMove = configuration?.songs?.onMove else { return false }
        onMove(from, landing)
        return true
    }

    private func showInsertionLine(at landing: Int?) {
        guard landing != dropLanding else { return }
        dropLanding = landing
        guard let landing, let spec = configuration?.songs else {
            insertionLine.removeFromSuperview()
            return
        }
        let count = spec.tracks.count
        let y: CGFloat
        if landing < count, let row = layout.rowByPosition[landing] {
            y = table.rect(ofRow: row).minY - 1.5
        } else if landing == count, let row = layout.rowByPosition[count - 1] {
            y = table.rect(ofRow: row).maxY + 1.5
        } else {
            insertionLine.removeFromSuperview()
            return
        }
        let width = max(table.bounds.width - Metrics.pagePadding * 2 - 8, 0)
        insertionLine.frame = NSRect(x: Metrics.pagePadding + 4, y: y - InsertionLineView.height / 2, width: width, height: InsertionLineView.height)
        if insertionLine.superview == nil {
            table.addSubview(insertionLine, positioned: .above, relativeTo: nil)
            insertionLine.wantsLayer = true
            let scale = CABasicAnimation(keyPath: "transform.scale.x")
            scale.fromValue = 0.6
            scale.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.18
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            insertionLine.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
            insertionLine.layer?.add(group, forKey: "appear")
        }
    }
}

@MainActor
enum SongDragImage {
    static func make(for track: Track, palette: SongTablePalette) -> NSImage {
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let artistFont = NSFont.systemFont(ofSize: 11)
        let title = SongTextLine(track.title, font: titleFont, color: palette.onSurface)
        let artists = SongTextLine(track.artists.map(\.name).joined(separator: " / "), font: artistFont, color: palette.onSurfaceVariant)
        let textWidth = min(max(title.width, artists.width), 200)
        let size = NSSize(width: 5 + 30 + 8 + textWidth + 5 + 7, height: 40)
        let image = NSImage(size: size, flipped: true) { rect in
            let card = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            palette.surface.withAlphaComponent(0.92).setFill()
            card.fill()
            palette.outlineVariant.setStroke()
            card.lineWidth = 1
            card.stroke()
            let cover = NSRect(x: 5, y: 5, width: 30, height: 30)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: cover, xRadius: 5, yRadius: 5).addClip()
            if let url = track.artwork?.sized(120), let picture = ImageStore.shared.image(for: url, maxPixelSize: 120) {
                let scale = max(cover.width / max(picture.size.width, 1), cover.height / max(picture.size.height, 1))
                let drawn = NSRect(x: cover.midX - picture.size.width * scale / 2, y: cover.midY - picture.size.height * scale / 2, width: picture.size.width * scale, height: picture.size.height * scale)
                picture.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSGradient(colors: PlaceholderArt.colors(for: track.artwork?.seed ?? "starry").map { NSColor($0) })?.draw(in: cover, angle: -45)
            }
            NSGraphicsContext.restoreGraphicsState()
            title.draw(in: NSRect(x: 43, y: 6, width: textWidth, height: 15), centred: false)
            artists.draw(in: NSRect(x: 43, y: 21, width: textWidth, height: 14), centred: false)
            return true
        }
        return image
    }
}
