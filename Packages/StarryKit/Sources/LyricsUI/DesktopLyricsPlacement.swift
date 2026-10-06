import CoreGraphics

/// Anchor at the top centre so resizing preserves placement. Screen clamping does not change
/// the saved anchor, allowing placement to recover when a disconnected display returns.
public enum DesktopLyricsPlacement {
    public struct Anchor: Codable, Equatable, Sendable {
        public var centerX: Double
        public var top: Double

        public init(centerX: Double, top: Double) {
            self.centerX = centerX
            self.top = top
        }

        public init(frame: CGRect) {
            self.init(centerX: frame.midX, top: frame.maxY)
        }

        func frame(size: CGSize) -> CGRect {
            CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        }
    }

    public struct Screen: Equatable, Sendable {
        public var frame: CGRect
        public var visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    public static let bottomMargin: CGFloat = 40

    public static func defaultAnchor(height: CGFloat, on screen: Screen) -> Anchor {
        Anchor(centerX: screen.visibleFrame.midX, top: screen.visibleFrame.minY + bottomMargin + height)
    }

    public static func frame(anchor: Anchor?, size: CGSize, screens: [Screen]) -> CGRect {
        guard let first = screens.first else { return (anchor?.frame(size: size) ?? CGRect(origin: .zero, size: size)).integral }
        let wanted = (anchor ?? defaultAnchor(height: size.height, on: first)).frame(size: size)
        let overlaps = screens.map { screen -> CGFloat in
            let overlap = screen.frame.intersection(wanted)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else {
            return clamp(defaultAnchor(height: size.height, on: first).frame(size: size), into: first.visibleFrame)
        }
        return clamp(wanted, into: screens[best].visibleFrame)
    }

    static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(frame.width, visible.width).rounded(.down)
        result.size.height = min(frame.height, visible.height).rounded(.down)
        result.origin.x = min(max(frame.minX, visible.minX), visible.maxX - result.width).rounded()
        result.origin.y = min(max(frame.minY, visible.minY), visible.maxY - result.height).rounded()
        return result
    }
}
