import Foundation
import Library
import LyricsProviders
import MusicSources
import StarryCore
import Testing
@testable import StarryPlayer

private typealias Comment = MusicSources.Comment

struct CommentTimeLinkTests {
    @Test func linksTimesInsideTheSong() {
        #expect(CommentTimeLinks.times(in: "1:12 那一下鼓点进来的时候", duration: 240) == [72])
        #expect(CommentTimeLinks.times(in: "从2：45到03:10都是高潮", duration: 240) == [165, 190])
        #expect(CommentTimeLinks.times(in: "10:00-10:30 这段", duration: 900) == [600, 630])
    }

    @Test func leavesOtherNumbersAlone() {
        // Past the end of the song, part of a clock or a longer number, not a time at all.
        #expect(CommentTimeLinks.times(in: "4:59 结束后还有彩蛋", duration: 240).isEmpty)
        #expect(CommentTimeLinks.times(in: "凌晨 12:30:45 还在听", duration: 3_600).isEmpty)
        #expect(CommentTimeLinks.times(in: "123:45", duration: 10_000).isEmpty)
        #expect(CommentTimeLinks.times(in: "1.5:00 倍速", duration: 600).isEmpty)
        #expect(CommentTimeLinks.times(in: "比分 3:7", duration: 600).isEmpty)
    }

    @Test func keepsTheTextAround() {
        let text = "前奏 0:58 吉他这一下"
        #expect(String(CommentTimeLinks.attributed(text, duration: 200).characters) == text)
    }
}

struct LyricOffsetTextTests {
    @Test func readsTypedOffsets() {
        #expect(LyricOffsetText.seconds(from: "-1.25") == -1.25)
        #expect(LyricOffsetText.seconds(from: "+0.3s") == 0.3)
        #expect(LyricOffsetText.seconds(from: " 300 ms") == 0.3)
        #expect(LyricOffsetText.seconds(from: "−0.5") == -0.5)
        #expect(LyricOffsetText.seconds(from: "－８００毫秒") == -0.8)
        #expect(LyricOffsetText.seconds(from: "1。5秒") == 1.5)
        #expect(LyricOffsetText.seconds(from: "abc") == nil)
        #expect(LyricOffsetText.seconds(from: "") == nil)
        #expect(LyricOffsetText.seconds(from: "nan") == nil)
    }

    @Test func showsTenthsUnlessCalibrated() {
        #expect(LyricOffsetText.label(0) == "+0.0s")
        #expect(LyricOffsetText.label(-0.1 - 0.1 - 0.1) == "-0.3s")
        #expect(LyricOffsetText.label(0.37) == "+0.37s")
        #expect(LyricOffsetText.draft(0) == "0")
        #expect(LyricOffsetText.draft(-1.2) == "-1.2")
        #expect(LyricOffsetText.draft(0.37) == "0.37")
    }
}

struct NowPlayingLayoutTests {
    @Test(arguments: [CGSize(width: 1024, height: 680), CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 1800, height: 700)])
    func groupFits(_ size: CGSize) {
        let layout = NowPlayingLayout(size: size)
        #expect(layout.groupTop >= layout.topBar)
        #expect(layout.groupTop + layout.side + layout.gap + layout.infoHeight <= size.height - layout.bottomBar)
        #expect(layout.artworkFrame.minX >= 0)
        #expect(layout.artworkFrame.maxX <= layout.columnWidth)
        #expect(layout.side >= 160)
    }
}

/// A thread of `count` comments with two replies under every third one, paged by offset.
private final class FakeCommentSource: CommentSource, @unchecked Sendable {
    let id: SourceID = .example
    let displayName = "fake"
    let commentSorts: [CommentSort] = [.recommended, .hot, .latest]
    let count: Int
    var failNextPage = false
    /// The page at this offset repeats the first page (a shifted thread).
    var repeatAt: Int?

    init(count: Int) { self.count = count }

    func resolvePlayableAsset(_ track: Track, tier: QualityTier) async throws -> PlayableAsset {
        throw SimulatedPlayback()
    }

    private func comment(_ i: Int, sort: CommentSort) -> Comment {
        Comment(id: "\(sort)-\(i)", userName: "u\(i)", content: "c\(i)", time: Date(timeIntervalSince1970: Double(i)), likedCount: i, replyCount: i % 3 == 0 ? 2 : 0)
    }

    func comments(on target: CommentTarget, page: Page) async throws -> CommentPage { CommentPage() }

    func comments(on target: CommentTarget, sort: CommentSort, cursor: String?, limit: Int) async throws -> CommentSlice {
        if failNextPage, cursor != nil { throw SourceError.invalidResponse("page") }
        let start = cursor.flatMap(Int.init) ?? 0
        if start == repeatAt {
            return CommentSlice(comments: (0..<limit).map { comment($0, sort: sort) }, total: count, next: String(start + limit))
        }
        let from = max(start - (start > 0 ? 1 : 0), 0)
        let end = min(start + limit, count)
        return CommentSlice(comments: (from..<end).map { comment($0, sort: sort) }, total: count, next: end < count ? String(end) : nil)
    }

    func replies(to commentID: String, on target: CommentTarget, cursor: String?, limit: Int) async throws -> CommentSlice {
        let start = cursor.flatMap(Int.init) ?? 0
        let all = (0..<2).map { Comment(id: "\(commentID)-r\($0)", userName: "r\($0)", content: "reply", time: .now) }
        let slice = Array(all.dropFirst(start).prefix(limit))
        return CommentSlice(comments: slice, total: all.count, next: start + limit < all.count ? String(start + limit) : nil)
    }

    func setCommentLiked(_ commentID: String, on target: CommentTarget, liked: Bool) async throws {}
}

@MainActor
struct SongCommentThreadTests {
    @Test func pagesWithoutDuplicatesUntilTheEnd() async {
        let source = FakeCommentSource(count: 45)
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.hot, from: source)
        await thread.loadMore(.hot, from: source)
        await thread.loadMore(.hot, from: source)
        await thread.loadMore(.hot, from: source)
        let listing = thread.listing(.hot)
        #expect(listing.comments.map(\.id) == (0..<45).map { "hot-\($0)" })
        #expect(listing.next == nil)
        #expect(thread.total == 45)
    }

    /// A page with nothing new adds no row to ask for the next one, so paging goes on by itself.
    @Test func pagesPastARepeatedPage() async {
        let source = FakeCommentSource(count: 60)
        source.repeatAt = 20
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.latest, from: source)
        await thread.loadMore(.latest, from: source)
        #expect(thread.listing(.latest).comments.last?.id == "latest-59")
        #expect(thread.listing(.latest).next == nil)
    }

    @Test func eachOrderKeepsItsOwnPages() async {
        let source = FakeCommentSource(count: 30)
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.recommended, from: source)
        await thread.loadMore(.recommended, from: source)
        await thread.loadIfNeeded(.latest, from: source)
        #expect(thread.listing(.recommended).comments.count == 30)
        #expect(thread.listing(.latest).comments.count == 20)
        #expect(thread.listing(.hot).phase == .idle)
    }

    @Test func aFailedPageStopsPagingUntilRetried() async {
        let source = FakeCommentSource(count: 45)
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.latest, from: source)
        source.failNextPage = true
        await thread.loadMore(.latest, from: source)
        #expect(thread.listing(.latest).moreFailed)
        #expect(thread.listing(.latest).comments.count == 20)
        source.failNextPage = false
        await thread.loadMore(.latest, from: source)
        #expect(!thread.listing(.latest).moreFailed)
        #expect(thread.listing(.latest).comments.count == 40)
    }

    @Test func repliesOpenLoadAndClose() async throws {
        let source = FakeCommentSource(count: 10)
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.recommended, from: source)
        let parent = try #require(thread.listing(.recommended).comments.first { $0.replyCount > 0 })
        thread.toggleReplies(of: parent, from: source)
        #expect(thread.isExpanded(parent.id))
        await thread.loadReplies(of: parent.id, from: source)
        #expect(thread.replies(of: parent.id)?.comments.count == 2)
        thread.toggleReplies(of: parent, from: source)
        #expect(!thread.isExpanded(parent.id))
        thread.toggleReplies(of: parent, from: source)
        #expect(thread.replies(of: parent.id)?.comments.count == 2)
    }

    @Test func likesUpdateEveryCopy() async throws {
        let source = FakeCommentSource(count: 10)
        let thread = SongCommentThread(source: .example, target: .song("1"), sort: .recommended)
        await thread.load(.recommended, from: source)
        let comment = try #require(thread.listing(.recommended).comments.first)
        thread.setLiked(comment.id, true)
        thread.setLiked(comment.id, true)
        let liked = try #require(thread.listing(.recommended).comments.first)
        #expect(liked.isLiked)
        #expect(liked.likedCount == comment.likedCount + 1)
    }
}

private extension LyricsProviderID {
    static let exampleLyrics = LyricsProviderID(plugin: "example.lyrics")
    static let otherLyrics = LyricsProviderID(plugin: "other.lyrics")
}

@MainActor
struct LyricSourcePinTests {
    private let track = TrackRef(source: .example, id: "1001")

    @Test func pinsPersist() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "starry-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = LyricsSearchResult(provider: .exampleLyrics, song: LyricsSongRef(id: "ABC123", title: "明知故犯 (新加坡版)", duration: 260), title: "明知故犯 (新加坡版)", artists: ["许美静"], album: "静听精彩十三首", duration: 260)
        let file = LyricsFile(name: "明知故犯.lrc", text: "[00:01.00]为何要落泪")
        let others = [TrackRef(source: .example, id: "2"), TrackRef(source: .example, id: "3")]
        let pins = LyricSourcePins(directory: DataDirectory(url: folder))
        pins.set(.song(song), for: track)
        pins.set(.file(file), for: others[0])
        pins.set(.source(.provider(.otherLyrics)), for: others[1])

        let reopened = LyricSourcePins(directory: DataDirectory(url: folder))
        #expect(reopened.pin(for: track) == .song(song))
        #expect(reopened.pin(for: others[0]) == .file(file))
        #expect(reopened.pin(for: others[1]) == .source(.provider(.otherLyrics)))
        reopened.set(nil, for: track)
        #expect(LyricSourcePins(directory: DataDirectory(url: folder)).pin(for: track) == nil)
    }

    @Test func readsSourceOnlyPins() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "starry-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = #"{"plugin:example:1001": {"savedAt": 781000000, "source": "provider:plugin:example.lyrics"}, "plugin:example:2": {"savedAt": 781000000, "source": "nope"}}"#
        try Data(saved.utf8).write(to: DataDirectory(url: folder).fileURL("lyric-sources"))
        let pins = LyricSourcePins(directory: DataDirectory(url: folder))
        #expect(pins.pin(for: track) == .source(.provider(.exampleLyrics)))
        #expect(pins.pin(for: TrackRef(source: .example, id: "2")) == nil)
    }
}
