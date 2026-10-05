import AppKit
import LyricsCore
import LyricsUI
import MusicSources
import StarryCore
import SwiftUI

struct CommentsPanel: View {
    var thread: SongCommentThread
    var tint: Color
    var k: CGFloat
    /// Leading inset, so the heading lines up with the lyrics' text.
    var leading: CGFloat
    var onShowLyrics: () -> Void
    @Environment(AppModel.self) private var model
    @State private var sortDirection = 1

    private var source: (any CommentSource)? { model.commentSource(thread.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, leading)
                .padding(.trailing, 8 * k)
            if let lyrics = model.player.lyrics, !lyrics.isEmpty {
                NowSingingStrip(tint: tint, k: k, action: onShowLyrics)
                    .padding(.leading, leading - 10 * k)
                    .padding(.top, 10 * k)
            }
            ZStack(alignment: .top) {
                CommentListView(thread: thread, listing: thread.listing(thread.sort), tint: tint, k: k, leading: leading)
                    .id(thread.sort)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24 * CGFloat(sortDirection))),
                        removal: .opacity.combined(with: .offset(x: -16 * CGFloat(sortDirection)))
                    ))
            }
            .frame(maxHeight: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "starry-seek", let seconds = Double(url.absoluteString.dropFirst("starry-seek:".count)) else { return .systemAction }
            model.player.seek(to: seconds)
            return .handled
        })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * k) {
            Text("评论")
                .font(.system(size: 26 * k, weight: .bold))
                .foregroundStyle(tint)

            if let total = thread.total, total > 0 {
                Text(total.formatted())
                    .font(.system(size: 14 * k, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint.opacity(0.5))
                    .contentTransition(.numericText(value: Double(total)))
            }
            Spacer(minLength: 12 * k)
            let sorts = source?.commentSorts ?? []
            if sorts.count > 1 {
                CommentSortPicker(sorts: sorts, selection: thread.sort, tint: tint, k: k) { sort in
                    guard sort != thread.sort, let to = sorts.firstIndex(of: sort), let from = sorts.firstIndex(of: thread.sort) else { return }
                    sortDirection = to > from ? 1 : -1
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { thread.sort = sort }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 * k }
            }
        }
        .animation(Motion.hover, value: thread.total)
    }
}

private struct CommentSortPicker: View {
    var sorts: [CommentSort]
    var selection: CommentSort
    var tint: Color
    var k: CGFloat
    var select: (CommentSort) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2 * k) {
            ForEach(sorts, id: \.self) { sort in
                let selected = sort == selection
                Button { select(sort) } label: {
                    Text(sort.title)
                        .font(.system(size: 12.5 * k, weight: .semibold))
                        .foregroundStyle(selected ? tint : tint.opacity(0.5))
                        .padding(.horizontal, 11 * k)
                        .frame(height: 26 * k)
                        .background {
                            if selected {
                                Capsule().fill(tint.opacity(0.16)).matchedGeometryEffect(id: "sort", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(NowPlayingPressStyle())
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: selection)
    }
}

extension CommentSort {
    var title: String {
        switch self {
        case .recommended: "推荐"
        case .hot: "最热"
        case .latest: "最新"
        }
    }
}

/// One order of the thread, paging in as it scrolls; the rows settle in with a stagger the
/// first time a page of them shows.
private struct CommentListView: View {
    var thread: SongCommentThread
    var listing: SongCommentThread.Listing
    var tint: Color
    var k: CGFloat
    var leading: CGFloat
    @Environment(AppModel.self) private var model
    @State private var shown = false

    private var source: (any CommentSource)? { model.commentSource(thread.source) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch listing.phase {
                case .idle, .loading:
                    CommentPanelSkeleton(tint: tint, k: k)
                case .failed(let message):
                    stateView(systemName: "exclamationmark.triangle", title: "评论加载失败", detail: message, retry: true)
                case .loaded:
                    if listing.comments.isEmpty {
                        stateView(systemName: "bubble.left.and.bubble.right", title: "还没有评论", detail: "这首歌还没有人留言", retry: false)
                    } else {
                        rows
                    }
                }
            }
            .padding(.leading, leading - 12 * k)
            .padding(.trailing, 8 * k)
            .padding(.top, 14 * k)
            .padding(.bottom, 20 * k)
        }
        .scrollIndicators(.automatic)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .task(id: listing.sort) {
            guard let source else { return }
            await thread.loadIfNeeded(listing.sort, from: source)
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(Array(listing.comments.enumerated()), id: \.element.id) { index, comment in
            CommentCell(comment: comment, thread: thread, tint: tint, k: k)
                .staggeredReveal(shown, index: index, distance: 10)
                .onAppear {
                    if !shown { shown = true }
                    guard comment.id == listing.comments.last?.id, let source else { return }
                    Task { await thread.loadMore(listing.sort, from: source) }
                }
        }
        footer
    }

    @ViewBuilder private var footer: some View {
        Group {
            if listing.loadingMore {
                ProgressView().controlSize(.small)
            } else if listing.moreFailed {
                Button("加载失败，点按重试") {
                    guard let source else { return }
                    Task { await thread.loadMore(listing.sort, from: source) }
                }
                .buttonStyle(.plain)
            } else if listing.next == nil {
                Text("没有更多评论了")
            }
        }
        .font(.system(size: 12 * k))
        .foregroundStyle(tint.opacity(0.4))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18 * k)
    }

    private func stateView(systemName: String, title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 10 * k) {
            Image(systemName: systemName).font(.system(size: 30 * k, weight: .light))
            Text(title).font(.system(size: 15 * k, weight: .semibold))
            Text(detail).font(.system(size: 12.5 * k)).opacity(0.6).multilineTextAlignment(.center)
            if retry {
                Button("重试") {
                    guard let source else { return }
                    Task { await thread.load(listing.sort, from: source) }
                }
                .buttonStyle(NowPlayingPressStyle())
                .font(.system(size: 13 * k, weight: .semibold))
                .padding(.horizontal, 16 * k)
                .frame(height: 30 * k)
                .background(Capsule().fill(tint.opacity(0.14)))
                .padding(.top, 4 * k)
            }
        }
        .foregroundStyle(tint.opacity(0.75))
        .frame(maxWidth: .infinity)
        .padding(.top, 90 * k)
    }
}

private struct CommentCell: View {
    var comment: Comment
    var thread: SongCommentThread
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var source: (any CommentSource)? { model.commentSource(thread.source) }

    var body: some View {
        let expanded = thread.isExpanded(comment.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12 * k) {
                CommentAvatar(comment: comment, source: thread.source, size: 34 * k)
                VStack(alignment: .leading, spacing: 6 * k) {
                    HStack(alignment: .center, spacing: 8 * k) {
                        CommentAuthor(comment: comment, source: thread.source, tint: tint, size: 13 * k)
                        Spacer(minLength: 8 * k)
                        CommentLikeButton(comment: comment, thread: thread, tint: tint, k: k)
                    }
                    CommentBody(text: comment.content, tint: tint, size: 15 * k)
                    if let quote = comment.replyTo {
                        quoteView(quote)
                    }
                    meta(expanded: expanded)
                }
            }
            if expanded, let replies = thread.replies(of: comment.id) {
                RepliesBlock(parent: comment, replies: replies, thread: thread, tint: tint, k: k)
                    .padding(.leading, 46 * k)
                    .padding(.top, 10 * k)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 12 * k)
        .padding(.vertical, 12 * k)
        .background(
            RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                .fill(tint.opacity(hovering ? 0.055 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contextMenu { CommentMenu(comment: comment, source: thread.source) }
    }

    private func meta(expanded: Bool) -> some View {
        HStack(spacing: 14 * k) {
            Text([CommentTime.text(comment.time), comment.location].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(tint.opacity(0.42))
            if comment.replyCount > 0 {
                Button {
                    guard let source else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { thread.toggleReplies(of: comment, from: source) }
                } label: {
                    HStack(spacing: 3 * k) {
                        Text(expanded ? "收起回复" : "\(comment.replyCount.formatted()) 条回复")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5 * k, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .buttonStyle(CommentTextButtonStyle(tint: tint, emphasized: true))
            }
        }
        .font(.system(size: 12 * k, weight: .medium))
        .padding(.top, 1)
    }

    private func quoteView(_ quote: Comment.Quote) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule().fill(tint.opacity(0.3)).frame(width: 2.5 * k)
            VStack(alignment: .leading, spacing: 3 * k) {
                Text("@\(quote.userName)")
                    .font(.system(size: 12 * k, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.6))
                Text(quote.content)
                    .font(.system(size: 13 * k))
                    .foregroundStyle(tint.opacity(0.62))
                    .lineSpacing(2 * k)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, 10 * k)
        }
        .padding(.vertical, 2 * k)
    }
}

private struct RepliesBlock: View {
    var parent: Comment
    var replies: SongCommentThread.Replies
    var thread: SongCommentThread
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * k) {
            ForEach(replies.comments) { reply in
                ReplyRow(reply: reply, thread: thread, tint: tint, k: k)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            HStack(spacing: 14 * k) {
                if replies.loading {
                    ProgressView().controlSize(.mini)
                } else if replies.failed {
                    Button("加载失败，重试") { more() }
                        .buttonStyle(CommentTextButtonStyle(tint: tint, emphasized: true))
                } else if replies.next != nil {
                    Button("展开更多回复（\(max(replies.total - replies.comments.count, 0).formatted())）") { more() }
                        .buttonStyle(CommentTextButtonStyle(tint: tint, emphasized: true))
                }
                Button("收起") {
                    guard let source = model.commentSource(thread.source) else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { thread.toggleReplies(of: parent, from: source) }
                }
                .buttonStyle(CommentTextButtonStyle(tint: tint))
            }
            .font(.system(size: 12 * k, weight: .medium))
        }
        .padding(.leading, 14 * k)
        .overlay(alignment: .leading) {
            Capsule().fill(tint.opacity(0.14)).frame(width: 2 * k)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: replies.comments.count)
    }

    private func more() {
        guard let source = model.commentSource(thread.source) else { return }
        Task { await thread.loadReplies(of: parent.id, from: source) }
    }
}

private struct ReplyRow: View {
    var reply: Comment
    var thread: SongCommentThread
    var tint: Color
    var k: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 9 * k) {
            CommentAvatar(comment: reply, source: thread.source, size: 24 * k)
            VStack(alignment: .leading, spacing: 4 * k) {
                HStack(alignment: .center, spacing: 6 * k) {
                    CommentAuthor(comment: reply, source: thread.source, tint: tint, size: 12 * k)
                    if let quote = reply.replyTo {
                        Text("回复 @\(quote.userName)")
                            .font(.system(size: 12 * k, weight: .medium))
                            .foregroundStyle(tint.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6 * k)
                    CommentLikeButton(comment: reply, thread: thread, tint: tint, k: k * 0.92)
                }
                CommentBody(text: reply.content, tint: tint, size: 14 * k)
                Text([CommentTime.text(reply.time), reply.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5 * k, weight: .medium))
                    .foregroundStyle(tint.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .contextMenu { CommentMenu(comment: reply, source: thread.source) }
    }
}

private struct CommentMenu: View {
    var comment: Comment
    var source: SourceID
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("拷贝评论", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(comment.content, forType: .string)
            model.showToast("评论已拷贝")
        }
        if model.canShowUser(comment.userID, in: source), let id = comment.userID {
            Divider()
            Button("查看\(comment.userName)的主页", systemImage: "person.crop.circle") {
                model.showUser(id: id, name: comment.userName, avatar: comment.avatar, in: source)
            }
        }
    }
}

private struct CommentAvatar: View {
    var comment: Comment
    var source: SourceID
    var size: CGFloat
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        if model.canShowUser(comment.userID, in: source), let id = comment.userID {
            Button { model.showUser(id: id, name: comment.userName, avatar: comment.avatar, in: source) } label: {
                AvatarView(artwork: comment.avatar, size: size)
                    .scaleEffect(hovering ? 1.08 : 1)
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))
            .onHover { hovering = $0 }
            .animation(Motion.lift, value: hovering)
            .linkPointer()
            .help("查看\(comment.userName)的主页")
        } else {
            AvatarView(artwork: comment.avatar, size: size)
        }
    }
}

private struct CommentAuthor: View {
    var comment: Comment
    var source: SourceID
    var tint: Color
    var size: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let action: (() -> Void)? = model.canShowUser(comment.userID, in: source) ? {
            model.showUser(id: comment.userID!, name: comment.userName, avatar: comment.avatar, in: source)
        } : nil
        TextLink(text: comment.userName, color: tint.opacity(0.66), hoverColor: tint, action: action)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
    }
}

private struct CommentBody: View {
    var text: String
    var tint: Color
    var size: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(CommentTimeLinks.attributed(text, duration: model.player.duration))
            .font(.system(size: size))
            .lineSpacing(size * 0.3)
            .foregroundStyle(tint.opacity(0.94))
            .tint(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 600, alignment: .leading)
    }
}

enum CommentTimeLinks {
    static func attributed(_ text: String, duration: TimeInterval) -> AttributedString {
        var result = AttributedString()
        var rest = text[...]
        func joins(_ c: Character?) -> Bool { c.map { $0.isNumber || ":：.".contains($0) } ?? false }
        for match in text.matches(of: #/(\d{1,2})[:：]([0-5]\d)/#) {
            let before = match.range.lowerBound > text.startIndex ? text[text.index(before: match.range.lowerBound)] : nil
            let after = match.range.upperBound < text.endIndex ? text[match.range.upperBound] : nil
            guard match.range.lowerBound >= rest.startIndex, !joins(before), !joins(after),
                  let minutes = Int(match.1), let seconds = Int(match.2) else { continue }
            let time = minutes * 60 + seconds
            guard duration <= 0 || Double(time) <= duration + 1, let url = URL(string: "starry-seek:\(time)") else { continue }
            result += AttributedString(text[rest.startIndex..<match.range.lowerBound])
            var link = AttributedString(text[match.range])
            link.link = url
            link.underlineStyle = Text.LineStyle.single
            link.inlinePresentationIntent = InlinePresentationIntent.stronglyEmphasized
            result += link
            rest = text[match.range.upperBound...]
        }
        result += AttributedString(rest)
        return result
    }

    /// The seconds of each link in `text` (tests).
    static func times(in text: String, duration: TimeInterval) -> [Int] {
        attributed(text, duration: duration).runs.compactMap { run in
            run.link.flatMap { Int($0.absoluteString.dropFirst("starry-seek:".count)) }
        }
    }
}

/// Thumb and count; liking is optimistic and rolls back if the source refuses. Not shown for a
/// source that takes no likes.
private struct CommentLikeButton: View {
    var comment: Comment
    var thread: SongCommentThread
    var tint: Color
    var k: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.commentSource(thread.source)?.canLikeComments == true { button }
    }

    private var button: some View {
        Button(action: like) {
            HStack(spacing: 4 * k) {
                Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .symbolEffect(.bounce.up, value: comment.isLiked)
                if comment.likedCount > 0 {
                    Text(TimeFormatting.compactCount(comment.likedCount))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(comment.likedCount)))
                }
            }
            .font(.system(size: 12 * k, weight: .medium))
            .foregroundStyle(tint.opacity(comment.isLiked ? 1 : 0.5))
            .padding(.horizontal, 6 * k)
            .frame(height: 22 * k)
            .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressStyle())
        .help(comment.isLiked ? "取消点赞" : "点赞")
    }

    private func like() {
        guard let source = model.commentSource(thread.source) else { return }
        guard model.accounts.isLoggedIn(thread.source) else {
            model.requestLogin(thread.source)
            return
        }
        let liked = !comment.isLiked
        let id = comment.id
        withAnimation(.spring(duration: 0.3, bounce: 0.35)) { thread.setLiked(id, liked) }
        Task {
            do {
                try await source.setCommentLiked(id, on: thread.target, liked: liked)
            } catch {
                withAnimation { thread.setLiked(id, !liked) }
                model.showToast(ErrorText.describe(error))
            }
        }
    }
}

private struct CommentTextButtonStyle: ButtonStyle {
    var tint: Color
    var emphasized = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint.opacity(hovering || configuration.isPressed ? 0.95 : (emphasized ? 0.72 : 0.5)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}

private struct CommentPanelSkeleton: View {
    var tint: Color
    var k: CGFloat
    private static let widths: [(CGFloat, CGFloat)] = [(0.9, 0.55), (0.7, 0), (0.95, 0.7), (0.6, 0), (0.85, 0.4), (0.75, 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                HStack(alignment: .top, spacing: 12 * k) {
                    Circle().fill(tint.opacity(0.1)).frame(width: 34 * k, height: 34 * k)
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 9 * k) {
                            bar(width: 90 * k, height: 10 * k)
                            bar(width: geo.size.width * width.0, height: 12 * k)
                            if width.1 > 0 { bar(width: geo.size.width * width.1, height: 12 * k) }
                        }
                    }
                    .frame(height: 60 * k)
                }
                .padding(.horizontal, 12 * k)
                .padding(.vertical, 12 * k)
            }
        }
        .shimmer()
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(tint.opacity(0.1)).frame(width: width, height: height)
    }
}

/// The line being sung, lit syllable by syllable, over the comments; clicking it shows the
/// lyrics. The menu bar's one-line view, so nothing in the app runs per frame for it.
private struct NowSingingStrip: View {
    var tint: Color
    var k: CGFloat
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * k) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 11 * k, weight: .bold))
                    .foregroundStyle(tint.opacity(0.5))
                GeometryReader { geo in
                    OneLineLyrics(tint: tint, fontSize: 14 * k, width: geo.size.width)
                }
                .frame(height: 22 * k)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3 * k) {
                    Text("歌词")
                    Image(systemName: "chevron.right").font(.system(size: 9 * k, weight: .bold))
                }
                .font(.system(size: 12 * k, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 0.9 : 0.45))
            }
            .padding(.horizontal, 12 * k)
            .frame(height: 38 * k)
            .background(Capsule().fill(tint.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("回到歌词")
    }
}

private struct OneLineLyrics: NSViewRepresentable {
    var tint: Color
    var fontSize: CGFloat
    var width: CGFloat
    @Environment(AppModel.self) private var model

    @MainActor final class Coordinator: NSObject {
        weak var view: MenuBarLyricsView?
        var timer: Timer?

        @objc func tick() { view?.sync() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuBarLyricsView {
        let view = MenuBarLyricsView(frame: .zero)
        let player = model.player
        view.timeSource = { [player] in player.preciseClock() }
        context.coordinator.view = view
        context.coordinator.timer = Timer.scheduledTimer(timeInterval: 2, target: context.coordinator, selector: #selector(Coordinator.tick), userInfo: nil, repeats: true)
        return view
    }

    func updateNSView(_ view: MenuBarLyricsView, context: Context) {
        let player = model.player
        let track = player.current
        view.font = .systemFont(ofSize: fontSize, weight: .semibold)
        view.textColor = NSColor(tint)
        view.maxTextWidth = max(width - 4, 60)
        view.timeOffset = -player.lyricOffset
        view.content = MenuBarLyricsView.Content(document: player.lyrics, duration: player.duration, title: track?.title ?? "", artist: track?.artistText ?? "")
        _ = player.isPlaying
        _ = player.seekSerial
        view.sync()
    }

    static func dismantleNSView(_ view: MenuBarLyricsView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }
}
