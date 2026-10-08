import CoreGraphics
import Testing
@testable import StarryPlayer

struct PopMenuItemTests {
    @Test func tidyKeepsDividersOnlyBetweenRows() {
        let items = PopMenuItem.tidy([
            .divider,
            .button("下一首播放") {},
            .divider,
            .divider,
            .empty,
            .button("复制链接") {},
            .empty,
            .divider,
        ])
        #expect(items.map(\.title) == ["下一首播放", "", "复制链接"])
        #expect(items.map(\.isDivider) == [false, true, false])
    }

    @Test func submenuWithNothingInItIsDisabled() {
        let submenu = PopMenuItem.submenu("加入歌单") {
            PopMenuItem.divider
            PopMenuItem.empty
        }
        #expect(submenu.isDisabled)
        #expect(!submenu.isSelectable)
        #expect(PopMenuItem.submenu("加入歌单") { PopMenuItem.button("新建歌单…") {} }.isSelectable)
    }

    @Test func onlyEnabledCommandsTakeTheHighlight() {
        #expect(PopMenuItem.button("重新扫描") {}.isSelectable)
        #expect(!PopMenuItem.button("在访达中显示", disabled: true) {}.isSelectable)
        #expect(PopMenuItem.option("浅色", selected: true) {}.isSelectable)
        #expect(!PopMenuItem.header("外观").isSelectable)
        #expect(!PopMenuItem.info("来源", "网易云音乐").isSelectable)
        #expect(!PopMenuItem.divider.isSelectable)
    }
}

struct PopMenuLayoutTests {
    /// A 1920 × 1080 screen under a 25 pt menu bar, and a 1280 × 800 window on it (top-left
    /// coordinates, as the layout takes them).
    private let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    private let window = CGRect(x: 320, y: 140, width: 1280, height: 800)
    private let menu = CGSize(width: 200, height: 150)

    private func layout(_ anchor: CGRect, placement: PopMenuPlacement = .below, largest: CGSize? = nil, minWidth: CGFloat = PopMenuMetrics.minWidth) -> PopMenuLayout {
        PopMenuLayout(anchor: anchor, bounds: screen, window: window, root: menu, largest: largest ?? menu, placement: placement, minWidth: minWidth)
    }

    @Test func opensUnderTheButtonLinedUpWithItsLeadingEdge() {
        let layout = layout(CGRect(x: 400, y: 300, width: 38, height: 38))
        #expect(!layout.opensUpward)
        #expect(layout.leading)
        #expect(layout.frame.minX == 400)
        #expect(layout.frame.minY == 338 + PopMenuMetrics.gap)
        #expect(layout.cardAlignment == .topLeading)
        #expect(layout.unfoldAnchor.y == 0)
    }

    @Test func opensAboveWhenItDoesNotFitUnderInTheWindow() {
        // Room under the button on the screen, but not in the window.
        let layout = layout(CGRect(x: 400, y: 880, width: 38, height: 38))
        #expect(layout.opensUpward)
        #expect(layout.frame.maxY == 880 - PopMenuMetrics.gap)
        #expect(layout.cardAlignment == .bottomLeading)
        #expect(layout.unfoldAnchor.y == 1)
    }

    @Test func opensAboveWhenAskedAndThereIsRoom() {
        #expect(layout(CGRect(x: 350, y: 850, width: 34, height: 34), placement: .above).opensUpward)
        // Not enough room above in the window: under it.
        #expect(!layout(CGRect(x: 350, y: 180, width: 34, height: 34), placement: .above).opensUpward)
    }

    @Test func linesUpWithTheTrailingEdgeOnTheRightOfTheWindow() {
        let layout = layout(CGRect(x: 1540, y: 160, width: 40, height: 40))
        #expect(!layout.leading)
        #expect(layout.frame.maxX == 1580)
        #expect(layout.cardAlignment == .topTrailing)
    }

    @Test func besideGoesToTheSideWithRoomInTheWindow() {
        // A row in a panel at the window's right edge: no room after it in the window, so the
        // menu opens before it, its first row level with the button.
        let row = CGRect(x: 1290, y: 500, width: 270, height: 32)
        let layout = layout(row, placement: .beside)
        #expect(!layout.leading)
        #expect(layout.frame.maxX < row.minX)
        #expect(layout.frame.minY == row.minY - PopMenuMetrics.inset)
        #expect(layout.unfoldAnchor.x == 1)

        let left = self.layout(CGRect(x: 400, y: 500, width: 200, height: 32), placement: .beside)
        #expect(left.leading)
        #expect(left.frame.minX > 600)
    }

    @Test func aLongMenuIsCappedAndScrolls() {
        let layout = layout(CGRect(x: 400, y: 300, width: 38, height: 38), largest: CGSize(width: 260, height: 2_000))
        #expect(layout.maxHeight <= PopMenuMetrics.maxHeight)
        #expect(layout.frame.height == layout.maxHeight)
        #expect(layout.frame.width == 260)
    }

    @Test func aPopUpButtonsMenuIsAtLeastAsWideAsTheButton() {
        let layout = layout(CGRect(x: 400, y: 300, width: 250, height: 28), minWidth: 250)
        #expect(layout.minWidth == 250)
        #expect(layout.frame.width == 250)
    }
}
