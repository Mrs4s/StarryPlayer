import AppKit
import SwiftUI
import Testing
@testable import StarryPlayer

@MainActor
struct VisualPickerLayoutTests {
    private func picker(count: Int, size: CGSize) -> VisualPicker<Int> {
        VisualPicker(selection: .constant(0), options: (0..<count).map { index in
            .init(value: index, title: "样式\(index)") { _ in AnyView(Color.gray) }
        }, previewSize: size)
    }

    @Test func fourBackgroundStylesWrapIntoTwoCenteredRowsInTheNowPlayingPopover() {
        // The popover is 400 pt wide; a block row inside it leaves 344 pt for the picker.
        let size = CGSize(width: 92, height: 58)
        let host = NSHostingController(rootView: picker(count: 4, size: size).environment(\.settingsCompact, true))
        let fitted = host.sizeThatFits(in: CGSize(width: 344, height: 1000))
        let row = NSHostingController(rootView: picker(count: 2, size: size).environment(\.settingsCompact, true))
            .sizeThatFits(in: CGSize(width: 344, height: 1000))
        #expect(abs(fitted.width - 344) < 1, "\(fitted)")
        #expect(abs(fitted.height - (2 * row.height + 16)) < 1, "\(fitted), row: \(row)")
    }

    @Test func fourBackgroundStylesStayInOneRowWhenThereIsRoom() {
        let size = CGSize(width: 92, height: 58)
        let host = NSHostingController(rootView: picker(count: 4, size: size).environment(\.settingsCompact, true))
        let fitted = host.sizeThatFits(in: CGSize(width: 800, height: 1000))
        let row = NSHostingController(rootView: picker(count: 2, size: size).environment(\.settingsCompact, true))
            .sizeThatFits(in: CGSize(width: 800, height: 1000))
        #expect(abs(fitted.width - (4 * 99 + 3 * 10)) < 1, "\(fitted)")
        #expect(abs(fitted.height - row.height) < 1, "\(fitted), row: \(row)")
    }
}
