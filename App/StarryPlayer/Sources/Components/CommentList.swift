import MusicSources
import StarryCore
import SwiftUI

/// The loaded pages of one comment thread. The page showing the thread owns it, so switching
/// tabs away and back keeps what was loaded instead of fetching it again.
@MainActor @Observable
final class CommentFeed {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// The source the thread is in, and what it hangs off there.
    let source: SourceID
    let target: CommentTarget
    private(set) var hot: [Comment] = []
    private(set) var latest: [Comment] = []
    private(set) var total = 0
    private(set) var hasMore = false
    private(set) var phase: Phase = .idle
    private(set) var loadingMore = false
    private static let pageSize = 30

    init(source: SourceID, target: CommentTarget) {
        self.source = source
        self.target = target
    }

    func loadIfNeeded(from source: any CommentSource) async {
        switch phase {
        case .idle, .failed: await load(from: source)
        case .loading, .loaded: break
        }
    }

    func load(from source: any CommentSource) async {
        phase = .loading
        do {
            let page = try await source.comments(on: target, page: Page(offset: 0, limit: Self.pageSize))
            // Not animated: the thread's height changes with it, and a scroll view resizes
            // its document on every frame of an animated height. The rows fade in themselves.
            hot = page.hot
            latest = page.latest
            total = page.total
            hasMore = page.hasMore && !page.latest.isEmpty
            phase = .loaded
        } catch {
            phase = .failed(ErrorText.describe(error))
        }
    }

    /// Next page of the newest comments; errors end the paging instead of retrying on every scroll.
    func loadMore(from source: any CommentSource) async {
        guard phase == .loaded, hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await source.comments(on: target, page: Page(offset: latest.count, limit: Self.pageSize))
            let known = Set(latest.map(\.id))
            latest += page.latest.filter { !known.contains($0.id) }
            hasMore = page.hasMore && !page.latest.isEmpty
            total = max(total, page.total)
        } catch {
            hasMore = false
        }
    }

    func setLiked(_ id: String, _ liked: Bool) {
        func apply(_ list: inout [Comment]) {
            for i in list.indices where list[i].id == id && list[i].isLiked != liked {
                list[i].isLiked = liked
                list[i].likedCount = max(list[i].likedCount + (liked ? 1 : -1), 0)
            }
        }
        apply(&hot)
        apply(&latest)
    }
}

/// Paged comment rows with optimistic likes. Insert directly into the page's lazy stack
/// to avoid offset shifts from nested lazy stacks.
struct CommentThreadView: View {
    var feed: CommentFeed
    /// Disable in a hosted table row: all comments appear together, so the table handles paging.
    var autoLoadsMore = true
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var shown = false

    private var source: (any CommentSource)? { model.commentSource(feed.source) }

    var body: some View {
        switch feed.phase {
        case .idle, .loading:
            CommentSkeleton()
                .task {
                    guard let source else { return }
                    await feed.loadIfNeeded(from: source)
                }
        case .failed(let message):
            VStack(spacing: 14) {
                StateView(systemName: "exclamationmark.triangle", title: "评论加载失败", detail: message).frame(minHeight: 0)
                PillButton(title: "重试", systemName: "arrow.clockwise", variant: .tertiary) { reload() }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded:
            if feed.hot.isEmpty && feed.latest.isEmpty {
                StateView(systemName: "bubble.left.and.bubble.right", title: "还没有评论", detail: "来抢个沙发吧")
            } else {
                rows
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if !feed.hot.isEmpty {
            sectionTitle("精彩评论", count: nil)
                .staggeredReveal(shown, index: 0)
                .onAppear { if !shown { shown = true } }
            ForEach(Array(feed.hot.enumerated()), id: \.element.id) { index, comment in
                CommentRow(comment: comment, source: feed.source, canLike: source?.canLikeComments == true) { like(comment) }
                    .staggeredReveal(shown, index: index + 1)
            }
        }
        sectionTitle("最新评论", count: feed.total)
            .padding(.top, feed.hot.isEmpty ? 0 : 28)
            .staggeredReveal(shown, index: feed.hot.count + 1)
            .onAppear { if !shown { shown = true } }
        ForEach(Array(feed.latest.enumerated()), id: \.element.id) { index, comment in
            CommentRow(comment: comment, source: feed.source, canLike: source?.canLikeComments == true) { like(comment) }
                .staggeredReveal(shown, index: feed.hot.count + 2 + index)
                .onAppear {
                    if !shown { shown = true }
                    guard autoLoadsMore, comment.id == feed.latest.last?.id, let source else { return }
                    Task { await feed.loadMore(from: source) }
                }
        }
        if feed.loadingMore {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.onSurface)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private func reload() {
        guard let source else { return }
        Task { await feed.load(from: source) }
    }

    private func like(_ comment: Comment) {
        guard let source, source.canLikeComments else { return }
        guard model.accounts.isLoggedIn(feed.source) else {
            model.requestLogin(feed.source)
            return
        }
        let liked = !comment.isLiked
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { feed.setLiked(comment.id, liked) }
        Task {
            do {
                try await source.setCommentLiked(comment.id, on: feed.target, liked: liked)
            } catch {
                withAnimation { feed.setLiked(comment.id, !liked) }
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

/// One comment. The author's avatar and name open their page (the avatar lifts a little on
/// hover, the name underlines), and so does the name over the comment it answers.
struct CommentRow: View {
    var comment: Comment
    /// The thread's source, where the authors' pages are.
    var source: SourceID
    var canLike: Bool
    var onLike: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var avatarHovering = false

    private var canOpenAuthor: Bool { model.canShowUser(comment.userID, in: source) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                TextLink(text: comment.userName, color: theme.onSurfaceVariant, hoverColor: theme.onSurface, action: authorAction)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(comment.content)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(theme.onSurface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let quote = comment.replyTo {
                    quoteView(quote)
                }
                HStack {
                    Text([CommentTime.text(comment.time), comment.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
                    Spacer()
                    if canLike { likeButton }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.outlineVariant.opacity(0.7)).frame(height: 1).padding(.leading, 48)
        }
    }

    private var authorAction: (() -> Void)? {
        canOpenAuthor ? { openAuthor() } : nil
    }

    private func quoteView(_ quote: Comment.Quote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextLink(text: "@\(quote.userName)", color: theme.onSurfaceVariant, hoverColor: theme.onSurface, action: quoteAuthorAction(quote))
                .font(.system(size: 12.5, weight: .medium))
            Text(quote.content)
                .font(.system(size: 13))
                .foregroundStyle(theme.onSurface.opacity(0.75))
                .lineSpacing(3)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: Radius.menu, style: .continuous))
    }

    private func quoteAuthorAction(_ quote: Comment.Quote) -> (() -> Void)? {
        guard model.canShowUser(quote.userID, in: source), let id = quote.userID else { return nil }
        return { model.showUser(id: id, name: quote.userName, avatar: nil, in: source) }
    }

    @ViewBuilder private var avatar: some View {
        if canOpenAuthor {
            Button(action: openAuthor) {
                AvatarView(artwork: comment.avatar, size: 36)
                    .scaleEffect(avatarHovering ? 1.08 : 1)
                    .shadow(color: .black.opacity(avatarHovering ? 0.18 : 0), radius: 6, y: 2)
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))
            .onHover { avatarHovering = $0 }
            .animation(Motion.lift, value: avatarHovering)
            .linkPointer()
            .help("查看\(comment.userName)的主页")
        } else {
            AvatarView(artwork: comment.avatar, size: 36)
        }
    }

    private func openAuthor() {
        guard let id = comment.userID else { return }
        model.showUser(id: id, name: comment.userName, avatar: comment.avatar, in: source)
    }

    private var likeButton: some View {
        Button(action: onLike) {
            HStack(spacing: 4) {
                Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .symbolEffect(.bounce, value: comment.isLiked)
                if comment.likedCount > 0 {
                    Text(TimeFormatting.compactCount(comment.likedCount))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(comment.likedCount)))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(comment.isLiked ? Color(hex: "#FE7971") : theme.onSurfaceVariant)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(comment.isLiked ? "取消点赞" : "点赞")
    }
}

private struct CommentSkeleton: View {
    private static let widths: [(CGFloat, CGFloat)] = [(420, 260), (360, 0), (480, 320), (300, 0), (400, 220)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBar(width: 72, height: 12).padding(.top, 24).padding(.bottom, 8)
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                HStack(alignment: .top, spacing: 12) {
                    SkeletonBar(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonBar(width: 88, height: 10)
                        SkeletonBar(width: width.0, height: 11)
                        if width.1 > 0 { SkeletonBar(width: width.1, height: 11) }
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmer()
    }
}

enum CommentTime {
    static func text(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 \(clock)" }
        if calendar.component(.year, from: now) == c.year { return "\(c.month ?? 0)月\(c.day ?? 0)日" }
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}
