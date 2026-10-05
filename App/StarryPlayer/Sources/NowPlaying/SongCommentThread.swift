import MusicSources
import StarryCore
import SwiftUI

/// The playing song's comment thread for the Now Playing panel: one listing per order
/// (recommended / hottest / newest, each loaded when first shown and kept) and the replies
/// opened under comments. The model outlives the page (`AppModel` keeps the last few songs'), so
/// closing and reopening Now Playing finds the thread as it was left.
@MainActor @Observable
final class SongCommentThread {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// One order of the thread, paged in as it scrolls.
    @MainActor @Observable
    final class Listing {
        let sort: CommentSort
        fileprivate(set) var comments: [Comment] = []
        fileprivate(set) var next: String?
        fileprivate(set) var phase: Phase = .idle
        fileprivate(set) var loadingMore = false
        fileprivate(set) var moreFailed = false
        /// Bumped by every first-page load, so a next page still in flight for the old list is dropped.
        fileprivate var generation = 0

        init(sort: CommentSort) { self.sort = sort }
    }

    @MainActor @Observable
    final class Replies {
        fileprivate(set) var comments: [Comment] = []
        fileprivate(set) var next: String?
        fileprivate(set) var total: Int
        fileprivate(set) var loading = false
        fileprivate(set) var failed = false
        fileprivate(set) var started = false

        init(total: Int) { self.total = total }
    }

    /// The song's source, and the thread there.
    let source: SourceID
    let target: CommentTarget
    var sort: CommentSort
    /// Comments in the thread, once any page has said.
    private(set) var total: Int?
    private(set) var expanded: [String] = []

    @ObservationIgnored private var listings: [CommentSort: Listing] = [:]
    @ObservationIgnored private var replyLists: [String: Replies] = [:]
    private static let pageSize = 20
    private static let replyPageSize = 10

    init(source: SourceID, target: CommentTarget, sort: CommentSort) {
        self.source = source
        self.target = target
        self.sort = sort
    }

    func listing(_ sort: CommentSort) -> Listing {
        if let listing = listings[sort] { return listing }
        let listing = Listing(sort: sort)
        listings[sort] = listing
        return listing
    }

    func replies(of id: String) -> Replies? { replyLists[id] }

    func loadIfNeeded(_ sort: CommentSort, from source: any CommentSource) async {
        let listing = listing(sort)
        switch listing.phase {
        case .idle, .failed: await load(sort, from: source)
        case .loading, .loaded: break
        }
    }

    func load(_ sort: CommentSort, from source: any CommentSource) async {
        let listing = listing(sort)
        guard listing.phase != .loading else { return }
        listing.phase = .loading
        listing.generation += 1
        let generation = listing.generation
        do {
            let slice = try await source.comments(on: target, sort: sort, cursor: nil, limit: Self.pageSize)
            guard generation == listing.generation else { return }
            listing.comments = slice.comments
            listing.next = slice.next
            listing.moreFailed = false
            listing.phase = .loaded
            if slice.total > 0 { total = slice.total }
        } catch {
            guard generation == listing.generation else { return }
            listing.phase = .failed(ErrorText.describe(error))
        }
    }

    func loadMore(_ sort: CommentSort, from source: any CommentSource) async {
        let listing = listing(sort)
        guard listing.phase == .loaded, var cursor = listing.next, !listing.loadingMore else { return }
        listing.loadingMore = true
        listing.moreFailed = false
        defer { listing.loadingMore = false }
        let generation = listing.generation
        do {
            // A page of comments already listed adds no row, so no row appears to ask for the
            // next one: fetch on, a few pages at most.
            for _ in 0..<3 {
                let slice = try await source.comments(on: target, sort: sort, cursor: cursor, limit: Self.pageSize)
                guard generation == listing.generation else { return }
                let known = Set(listing.comments.map(\.id))
                let added = slice.comments.filter { !known.contains($0.id) }
                listing.comments += added
                listing.next = slice.next
                guard added.isEmpty, let next = slice.next else { break }
                cursor = next
            }
        } catch {
            guard generation == listing.generation else { return }
            listing.moreFailed = true
        }
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    func toggleReplies(of comment: Comment, from source: any CommentSource) {
        if let index = expanded.firstIndex(of: comment.id) {
            expanded.remove(at: index)
            return
        }
        expanded.append(comment.id)
        let replies = replyLists[comment.id] ?? Replies(total: comment.replyCount)
        replyLists[comment.id] = replies
        guard !replies.started, !replies.loading else { return }
        Task { await loadReplies(of: comment.id, from: source) }
    }

    func loadReplies(of id: String, from source: any CommentSource) async {
        guard let replies = replyLists[id], !replies.loading else { return }
        let cursor = replies.next
        guard cursor != nil || !replies.started else { return }
        replies.loading = true
        replies.failed = false
        defer { replies.loading = false }
        do {
            let slice = try await source.replies(to: id, on: target, cursor: cursor, limit: Self.replyPageSize)
            let known = Set(replies.comments.map(\.id))
            replies.comments += slice.comments.filter { !known.contains($0.id) }
            replies.next = slice.next
            replies.started = true
            if slice.total > 0 { replies.total = slice.total }
        } catch {
            replies.failed = true
        }
    }

    func setLiked(_ id: String, _ liked: Bool) {
        func apply(_ list: inout [Comment]) {
            for i in list.indices where list[i].id == id && list[i].isLiked != liked {
                list[i].isLiked = liked
                list[i].likedCount = max(list[i].likedCount + (liked ? 1 : -1), 0)
            }
        }
        for listing in listings.values { apply(&listing.comments) }
        for replies in replyLists.values { apply(&replies.comments) }
    }
}
