import StarryCore
import SwiftUI

enum TrackListRows {
    /// Between a page's tab bar and its first row. Kept in the bar's row: among the rows it
    /// would make the first taller than the rest.
    static let gapAbove: CGFloat = 8
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
    func settled(_ text: String, into settled: Binding<String>, delay: Duration = .milliseconds(150)) -> some View {
        task(id: text) {
            if !text.isEmpty { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            settled.wrappedValue = text
        }
    }
}
