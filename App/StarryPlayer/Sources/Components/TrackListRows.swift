import QuartzCore
import StarryCore
import SwiftUI

/// Paged song rows inserted directly into a detail page's lazy stack.
/// Rows reference list positions to avoid copying large track arrays.
struct TrackListRows: View {
    var list: TrackListLoader
    /// Positions of the songs to show; nil for all of them.
    var matches: [Int]?
    var context: PlaybackContext
    var onRemove: ((Track) -> Void)? = nil
    /// A row dragged within the list moves there (`from`, to stand before the row at `to`): a
    /// line shows where it would land. Off while a search filters the list.
    var onMove: ((_ from: Int, _ to: Int) -> Void)? = nil
    var locator: TrackListLocator? = nil
    @Environment(AppModel.self) private var model
    @State private var shown = false
    /// Where a dragged row would land (before the row at this position), and the row under the pointer.
    @State private var insertion: Int?
    @State private var hoveredRow: Int?

    /// Keep this gap in the header: a spacer among rows skews lazy-stack height estimates
    /// and breaks distant song positioning.
    static let gapAbove: CGFloat = 8

    var body: some View {
        let tracks = list.tracks
        let arrival = list.arrival
        let located = locator?.located
        let veiled = locator?.veiled ?? false
        let moves = onMove != nil && matches == nil
        ForEach(Rows(tracks: tracks, positions: matches), id: \.id) { row in
            let track = tracks[row.position]
            SongRow(track: track, index: row.position + 1, removeFromPlaylist: onRemove.map { remove in { remove(track) } }) {
                list.play(startAt: row.position, on: model.player, context: context)
            }
            .staggeredReveal(shown, index: row.position)
            .modifier(ArrivalFade(arriving: arrival.map { $0.id == row.id && CACurrentMediaTime() - $0.time < 0.5 } ?? false))
            .modifier(LocatedGlow(time: located.flatMap { $0.id == row.id ? $0.time : nil }))
            .opacity(veiled ? 0 : 1)
            .overlay(alignment: .top) {
                if moves, insertion == row.position { InsertionLine().offset(y: -1.5) }
            }
            .overlay(alignment: .bottom) {
                if moves, insertion == tracks.count, row.position == tracks.count - 1 { InsertionLine().offset(y: 1.5) }
            }
            .onDrop(of: [.starryTracks], delegate: RowDrop(position: row.position, enabled: moves, list: list, model: model, insertion: $insertion, hoveredRow: $hoveredRow) { from, to in
                onMove?(from, to)
            })
            .modifier(RowPlace(position: row.position, locator: locator))
            .onAppear {
                if !shown { shown = true }
                list.prefetch(near: row.position)
            }
        }
    }

    struct Row {
        var position: Int
        var id: TrackRef
    }

    struct Rows: RandomAccessCollection {
        var tracks: [Track]
        var positions: [Int]?

        var startIndex: Int { 0 }
        var endIndex: Int { positions?.count ?? tracks.count }

        subscript(offset: Int) -> Row {
            let position = positions?[offset] ?? offset
            return Row(position: position, id: tracks[position].id)
        }
    }
}

/// Where a dragged row would land: a line of the accent colour between two rows, with a ring at
/// its start, as Finder draws it.
private struct InsertionLine: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(theme.accent, lineWidth: 2).frame(width: 9, height: 9)
            Capsule().fill(theme.accent).frame(height: 3)
        }
        .padding(.horizontal, 4)
        .frame(height: 9)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
    }
}

private struct RowDrop: DropDelegate {
    let position: Int
    let enabled: Bool
    let list: TrackListLoader
    let model: AppModel
    @Binding var insertion: Int?
    @Binding var hoveredRow: Int?
    let move: (Int, Int) -> Void

    @MainActor private func dragged(_ info: DropInfo) -> Int? {
        guard enabled else { return nil }
        let tracks = model.draggedTracks(in: info)
        guard tracks.count == 1, let track = tracks.first else { return nil }
        return list.tracks.firstIndex { $0.id == track.id }
    }

    func validateDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { dragged(info) != nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard let from = dragged(info) else { return DropProposal(operation: .forbidden) }
            let target = info.location.y < Metrics.songRowHeight / 2 ? position : position + 1
            let landing: Int? = target == from || target == from + 1 ? nil : target
            hoveredRow = position
            if landing != insertion {
                withAnimation(.snappy(duration: 0.18)) { insertion = landing }
            }
            return DropProposal(operation: .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            guard hoveredRow == position else { return }
            hoveredRow = nil
            withAnimation(.easeOut(duration: 0.12)) { insertion = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let landing = insertion
            insertion = nil
            hoveredRow = nil
            guard let from = dragged(info), let landing else { return false }
            move(from, landing)
            return true
        }
    }
}

/// Tells the locator where the row is in the page's content, when it appears and when it moves
/// there (not as the page scrolls). `onGeometryChange` alone missed rows laid out where they
/// stay: it reports changes only.
private struct RowPlace: ViewModifier {
    var position: Int
    var locator: TrackListLocator?

    func body(content: Content) -> some View {
        if let locator {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { locator.rowTops[position] = geometry.frame(in: .pageContent).minY }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .pageContent).minY } action: { top in
                    locator.rowTops[position] = top
                }
                .onDisappear { locator.rowTops[position] = nil }
        } else {
            content
        }
    }
}

private struct ArrivalFade: ViewModifier {
    var arriving: Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(arriving && !visible ? 0 : 1)
            .onAppear {
                guard arriving else { return }
                withAnimation(.easeOut(duration: 0.24).delay(0.14)) { visible = true }
            }
    }
}

struct TrackListEnd<Footer: View>: View {
    var list: TrackListLoader
    var footer: Footer

    init(list: TrackListLoader, @ViewBuilder footer: () -> Footer) {
        self.list = list
        self.footer = footer()
    }

    var body: some View {
        if list.failure != nil {
            PillButton(title: "加载失败，重试", systemName: "arrow.clockwise", variant: .tertiary) {
                Task { await list.loadNext(retrying: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else if !list.isComplete {
            TrackSkeleton(count: 3, artwork: true)
                .task(id: list.tracks.count) { await list.loadNext() }
        } else {
            footer
        }
    }
}

extension View {
    /// Copies `text` into `settled` once typing pauses for `delay` (at once when cleared): a
    /// long list refilters once a pause instead of on every keystroke, as replacing the rows on
    /// screen is costly whatever the list's length.
    func settled(_ text: String, into settled: Binding<String>, delay: Duration = .milliseconds(150)) -> some View {
        task(id: text) {
            if !text.isEmpty { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            settled.wrappedValue = text
        }
    }
}
