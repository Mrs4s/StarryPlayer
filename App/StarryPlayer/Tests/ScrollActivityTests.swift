import Foundation
import Testing
@testable import StarryPlayer

@Suite
@MainActor
struct ScrollActivityTests {
    @Test func firstOffsetIsNotAScroll() {
        let activity = ScrollActivity()
        activity.moved(to: 0)
        activity.moved(to: 0)
        #expect(!activity.isScrolling)
    }

    @Test func scrollsUntilTheOffsetSettles() async throws {
        // A longer settle than the app's, so a slow test machine's sleeps stay well inside it.
        let activity = ScrollActivity(settle: 0.3)
        activity.moved(to: 0)
        activity.moved(to: -14)
        #expect(activity.isScrolling)
        for step in 2...9 {
            try await Task.sleep(for: .milliseconds(60))
            #expect(activity.isScrolling)
            activity.moved(to: CGFloat(-14 * step))
        }
        try await Task.sleep(for: .seconds(activity.settle * 3))
        #expect(!activity.isScrolling)
    }
}
