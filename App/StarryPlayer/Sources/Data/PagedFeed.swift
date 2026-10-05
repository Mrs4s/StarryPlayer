import MusicSources
import Observation
import StarryCore

/// The loaded pages of one list (an artist's songs in one order, their albums, one kind of search
/// result). The page owns it, so switching tabs away and back keeps what was loaded.
@MainActor @Observable
final class PagedFeed<Item: Identifiable> {
    typealias Fetch = @MainActor @Sendable (Page) async throws -> [Item]
    /// A page of items and where the next one starts (nil: the list ends), for sources that answer
    /// fewer items than asked for.
    typealias PageFetch = @MainActor @Sendable (Page) async throws -> (items: [Item], next: Page?)

    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    private(set) var items: [Item] = []
    private(set) var phase: Phase = .idle
    private(set) var hasMore = false
    /// The last request for more failed; the list offers a retry instead of asking again.
    private(set) var moreFailed = false
    let pageSize: Int
    @ObservationIgnored private var next: Page?
    @ObservationIgnored private var loadingMore = false

    init(pageSize: Int) {
        self.pageSize = pageSize
    }

    func loadIfNeeded(_ fetch: @escaping Fetch) async {
        await loadIfNeeded(pages: paged(fetch))
    }

    func load(_ fetch: @escaping Fetch) async {
        await load(pages: paged(fetch))
    }

    func loadMore(_ fetch: @escaping Fetch) async {
        await loadMore(pages: paged(fetch))
    }

    func loadIfNeeded(pages fetch: PageFetch) async {
        guard phase == .idle else { return }
        await load(pages: fetch)
    }

    func load(pages fetch: PageFetch) async {
        phase = .loading
        do {
            let page = try await fetch(Page(offset: 0, limit: pageSize))
            // Not animated: the list's height changes with it; the rows fade in themselves.
            items = Self.unique(page.items, after: [])
            next = page.next
            hasMore = page.next != nil
            moreFailed = false
            phase = .loaded
        } catch {
            phase = Task.isCancelled ? .idle : .failed(ErrorText.describe(error))
        }
    }

    func loadMore(pages fetch: PageFetch) async {
        guard phase == .loaded, hasMore, let next, !moreFailed, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            var page = try await fetch(next)
            var added = Self.unique(page.items, after: items)
            for _ in 0..<3 where added.isEmpty {
                guard let following = page.next else { break }
                page = try await fetch(following)
                added = Self.unique(page.items, after: items)
            }
            items += added
            self.next = page.next
            hasMore = page.next != nil && !added.isEmpty
        } catch {
            if !Task.isCancelled { moreFailed = true }
        }
    }

    func retryMore() {
        moreFailed = false
    }

    private func paged(_ fetch: @escaping Fetch) -> PageFetch {
        let size = pageSize
        return { page in
            let items = try await fetch(page)
            return (items, items.count >= size ? Page(offset: page.offset + size, limit: size) : nil)
        }
    }

    static func unique(_ page: [Item], after items: [Item]) -> [Item] {
        var seen = Set(items.map(\.id))
        return page.filter { seen.insert($0.id).inserted }
    }
}
