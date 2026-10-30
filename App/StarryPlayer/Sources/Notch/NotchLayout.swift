import AppKit
import SwiftUI

/// Where the notch player hangs: under the camera housing of a screen with a notch, or in the
/// middle of the menu bar of one without (as tall as the menu bar, with no width of its own).
struct NotchGeometry: Equatable {
    /// The middle of the notch's top edge (the screen's, without one), in screen coordinates.
    var top: CGPoint
    /// The camera housing; zero wide on a screen without a notch.
    var notch: CGSize

    var hasNotch: Bool { notch.width > 0 }
    var height: CGFloat { notch.height }

    /// The menu bar's height when it hides itself (the visible frame then reaches the top).
    static let fallbackHeight: CGFloat = 24

    init(top: CGPoint, notch: CGSize) {
        self.top = top
        self.notch = notch
    }

    /// `leftArea` and `rightArea`: how wide the menu bar is either side of the notch
    /// (`NSScreen.auxiliaryTopLeftArea`, `auxiliaryTopRightArea`); nil on a screen without one.
    init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, leftArea: CGFloat?, rightArea: CGFloat?) {
        if safeAreaTop > 0, let leftArea, let rightArea, frame.width - leftArea - rightArea > 0 {
            let width = frame.width - leftArea - rightArea
            top = CGPoint(x: frame.minX + leftArea + width / 2, y: frame.maxY)
            notch = CGSize(width: width, height: safeAreaTop)
        } else {
            let menuBar = frame.maxY - visibleFrame.maxY
            top = CGPoint(x: frame.midX, y: frame.maxY)
            notch = CGSize(width: 0, height: menuBar > 0 ? menuBar : Self.fallbackHeight)
        }
    }

    @MainActor
    init(screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                  leftArea: screen.auxiliaryTopLeftArea?.width, rightArea: screen.auxiliaryTopRightArea?.width)
    }

    static func screen<Screen>(among screens: [Screen], notchedOnly: Bool, hasNotch: (Screen) -> Bool) -> Screen? {
        screens.first(where: hasNotch) ?? (notchedOnly ? nil : screens.first)
    }
}

/// Island layout in local coordinates with a top-left origin.
struct NotchLayout: Equatable {
    enum Phase: Equatable {
        case hidden
        case compact
        case expanded
    }

    var phase: Phase
    var size: CGSize
    var offset: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var cover: CGRect
    var coverRadius: CGFloat
    var bars: CGRect
    var lyric: CGRect?
    var controls: CGRect?

    static let lyricsMaxWidth: CGFloat = 220
    static let lyricGap: CGFloat = 8
    static let expandedWidth: CGFloat = 440
    static let expandedCover: CGFloat = 58
    /// Room left in the window for the open island's shadow, at the sides and below.
    static let shadowMargin: CGFloat = 28

    init(phase: Phase, geometry: NotchGeometry, lyricWidth: CGFloat?) {
        self.phase = phase
        let h = geometry.height
        let notch = geometry.notch.width
        let flare = (h * 0.19).rounded()
        let side = max(((h - h * 0.68) / 2).rounded(), 6)
        let c = max((h * 0.68).rounded(), 14)
        let leftEar = flare + side + c + side
        let barsHeight = (c * 0.72).rounded()

        switch phase {
        case .hidden:
            let width = geometry.hasNotch ? notch : c * 2
            size = CGSize(width: width, height: h)
            offset = 0
            topRadius = min(flare, 4)
            bottomRadius = (h * 0.3).rounded()
            let mid = CGPoint(x: width / 2, y: h / 2)
            cover = CGRect(x: mid.x - c / 4, y: mid.y - c / 4, width: c / 2, height: c / 2)
            coverRadius = 3
            bars = CGRect(x: mid.x - c / 4, y: mid.y - barsHeight / 4, width: c / 2, height: barsHeight / 2)
            lyric = nil
            controls = nil

        case .compact:
            let lead = geometry.hasNotch ? side : 0
            let line = lyricWidth.map { min($0, Self.lyricsMaxWidth) }
            let right = lead + (line.map { $0 + Self.lyricGap } ?? 0) + c + side + flare
            let width = leftEar + notch + right
            size = CGSize(width: width, height: h)
            offset = geometry.hasNotch ? (right - leftEar) / 2 : 0
            topRadius = flare
            bottomRadius = (h * 0.42).rounded()
            cover = CGRect(x: flare + side, y: (h - c) / 2, width: c, height: c)
            coverRadius = (c * 0.24).rounded()
            bars = CGRect(x: width - flare - side - c, y: (h - barsHeight) / 2, width: c, height: barsHeight)
            lyric = line.map { CGRect(x: leftEar + notch + lead, y: 0, width: $0, height: h) }
            controls = nil

        case .expanded:
            let width = max(Self.expandedWidth, notch + leftEar * 2 + 40)
            let top = geometry.hasNotch ? h : 0
            let edge: CGFloat = 14
            let pad = edge + 16
            let row = top + 14
            let height = row + Self.expandedCover + 12 + 18 + 4 + 38 + 14
            size = CGSize(width: width, height: height)
            offset = 0
            topRadius = edge
            bottomRadius = 30
            cover = CGRect(x: pad, y: row, width: Self.expandedCover, height: Self.expandedCover)
            coverRadius = 12
            bars = CGRect(x: width - pad - 24, y: row + 2, width: 24, height: 18)
            lyric = nil
            controls = CGRect(x: pad, y: row, width: width - pad * 2, height: height - row - 14)
        }
    }

    /// The panel around the island on `geometry`'s screen. It is centred on the notch, so the
    /// island, centred in it, keeps its place as the panel grows and shrinks; it lines up with
    /// whole points.
    func windowFrame(on geometry: NotchGeometry) -> CGRect {
        let margin = phase == .expanded ? Self.shadowMargin : 0
        let fraction = geometry.top.x - geometry.top.x.rounded(.down)
        let half = (size.width / 2 + abs(offset) + margin).rounded(.up) + fraction
        let height = (size.height + margin).rounded(.up)
        return CGRect(x: geometry.top.x - half, y: geometry.top.y - height, width: half * 2, height: height)
    }

    func islandFrame(on geometry: NotchGeometry) -> CGRect {
        CGRect(x: geometry.top.x + offset - size.width / 2, y: geometry.top.y - size.height, width: size.width, height: size.height)
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(min(topRadius, rect.width / 4, rect.height / 2), 0)
        let bottom = max(min(bottomRadius, (rect.width - top * 2) / 2, rect.height - top), 0)
        // Control points of a cubic that bends like a quarter circle.
        let k: CGFloat = 1 - 0.5523
        let left = rect.minX + top
        let right = rect.maxX - top
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: CGPoint(x: left, y: rect.minY + top),
                      control1: CGPoint(x: left - top * k, y: rect.minY),
                      control2: CGPoint(x: left, y: rect.minY + top * k))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addCurve(to: CGPoint(x: left + bottom, y: rect.maxY),
                      control1: CGPoint(x: left, y: rect.maxY - bottom * k),
                      control2: CGPoint(x: left + bottom * k, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addCurve(to: CGPoint(x: right, y: rect.maxY - bottom),
                      control1: CGPoint(x: right - bottom * k, y: rect.maxY),
                      control2: CGPoint(x: right, y: rect.maxY - bottom * k))
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                      control1: CGPoint(x: right, y: rect.minY + top * k),
                      control2: CGPoint(x: right + top * k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
