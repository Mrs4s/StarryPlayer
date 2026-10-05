import AppKit
import SwiftUI

struct Theme: Equatable {
    var isDark: Bool
    var primary: Color
    var primaryContainer: Color
    var onPrimary: Color
    var secondary: Color
    var surface: Color
    var surfaceAlt: Color
    var surfacePanel: Color
    var surfaceBright: Color
    var onSurface: Color
    var onSurfaceVariant: Color
    var outline: Color
    var outlineVariant: Color
    var accent: Color

    static let darkBase = Theme(
        isDark: true,
        primary: .rgb(244, 244, 245), primaryContainer: .rgb(63, 63, 70), onPrimary: .rgb(24, 24, 27),
        secondary: .rgb(161, 161, 170),
        surface: .rgb(16, 16, 20), surfaceAlt: .rgb(39, 39, 42), surfacePanel: .rgb(24, 24, 28), surfaceBright: .rgb(72, 72, 78),
        onSurface: .rgb(228, 228, 231), onSurfaceVariant: .rgb(161, 161, 170),
        outline: .rgb(82, 82, 91), outlineVariant: .rgb(46, 46, 51),
        accent: .rgb(244, 244, 245)
    )

    static let lightBase = Theme(
        isDark: false,
        primary: .rgb(24, 24, 27), primaryContainer: .rgb(228, 228, 231), onPrimary: .rgb(255, 255, 255),
        secondary: .rgb(82, 82, 91),
        surface: .rgb(246, 246, 246), surfaceAlt: .rgb(250, 250, 251), surfacePanel: .rgb(255, 255, 255), surfaceBright: .rgb(255, 255, 255),
        onSurface: .rgb(24, 24, 27), onSurfaceVariant: .rgb(113, 113, 122),
        outline: .rgb(212, 212, 216), outlineVariant: .rgb(228, 228, 231),
        accent: .rgb(24, 24, 27)
    )

    /// Build a palette from a seed. `tintSurfaces` washes the surfaces with the seed too, so the
    /// pages take on the cover's colour.
    static func make(seed: Color?, dark: Bool, tintSurfaces: Bool) -> Theme {
        var theme = dark ? darkBase : lightBase
        guard let seed, let hsb = seed.hsb, hsb.saturation > 0.05 else { return theme }
        let h = hsb.hue
        let chroma = min(hsb.saturation, 0.7) / 0.7  // 0…1 how colourful the seed is
        if dark {
            theme.primary = .hsb(h, 0.18 * chroma + 0.04, 0.96)
            theme.primaryContainer = .hsb(h, 0.38 * chroma + 0.05, 0.36)
            theme.onPrimary = .hsb(h, 0.30, 0.12)
            theme.secondary = .hsb(h, 0.10, 0.68)
            theme.accent = .hsb(h, 0.5 * chroma + 0.12, 0.93)
            if tintSurfaces {
                theme.surface = .hsb(h, 0.16 * chroma, 0.075)
                theme.surfacePanel = .hsb(h, 0.15 * chroma, 0.105)
                theme.surfaceAlt = .hsb(h, 0.12 * chroma, 0.15)
                theme.surfaceBright = .hsb(h, 0.10 * chroma, 0.29)
                theme.onSurface = .hsb(h, 0.04, 0.91)
                theme.onSurfaceVariant = .hsb(h, 0.07, 0.66)
                theme.outline = .hsb(h, 0.10, 0.36)
                theme.outlineVariant = .hsb(h, 0.10, 0.19)
            }
        } else {
            theme.primary = .hsb(h, 0.42 * chroma + 0.05, 0.18)
            theme.primaryContainer = .hsb(h, 0.20 * chroma + 0.02, 0.92)
            theme.onPrimary = .white
            theme.secondary = .hsb(h, 0.12, 0.38)
            theme.accent = .hsb(h, 0.6 * chroma + 0.15, 0.78)
            if tintSurfaces {
                theme.surface = .hsb(h, 0.05 * chroma, 0.965)
                theme.surfacePanel = .hsb(h, 0.02 * chroma, 0.995)
                theme.surfaceAlt = .hsb(h, 0.03 * chroma, 0.985)
                theme.onSurface = .hsb(h, 0.22, 0.12)
                theme.onSurfaceVariant = .hsb(h, 0.10, 0.47)
                theme.outline = .hsb(h, 0.08, 0.84)
                theme.outlineVariant = .hsb(h, 0.05, 0.91)
            }
        }
        return theme
    }
}

enum Radius {
    static let button: CGFloat = 6
    static let menu: CGFloat = 8
    static let card: CGFloat = 12
    static let large: CGFloat = 16
    static let cover: CGFloat = 32
}

enum Metrics {
    static let windowMinSize = CGSize(width: 1024, height: 680)
    static let sidebarWidth: CGFloat = 232
    /// Leave room for all traffic lights: a 64 pt rail clips the zoom button on macOS 26.
    static let sidebarCollapsedWidth: CGFloat = 78
    static let floatingSidebarInset: CGFloat = 8
    static let floatingSidebarRadius: CGFloat = 12
    static let sidebarRowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 64
    static let playerBarHeight: CGFloat = 64
    static let playerBarMargin: CGFloat = 14
    /// The bar's widest: past it the bar centres in the content column instead of stretching,
    /// so its three groups do not drift apart across a wide window (at 1280 pt the stretched
    /// bar was ~1000 pt wide with ~200 pt of empty glass either side of the transport).
    static let playerBarMaxWidth: CGFloat = 800
    static let playerBarInset: CGFloat = playerBarHeight + playerBarMargin + 10
    static let songRowHeight: CGFloat = 60
    static let detailTabBarHeight: CGFloat = 52
    static let pagePadding: CGFloat = 24
    static let pageMaxWidth: CGFloat = 1400
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .darkBase
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

enum Motion {
    static let popover = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.2)
    static let nowPlaying = Animation.timingCurve(0.7, 0, 0.3, 1, duration: 0.5)
    static var nowPlayingTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.7, 0, 0.3, 1) }
    static let nowPlayingDuration: CFTimeInterval = 0.5
    /// Sidebar width (collapse / expand): a quick ease-out with a bounded length. The content
    /// column is laid out again on every frame of it, so a spring's long settling tail costs
    /// frames for movement no one sees.
    static let sidebar = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
    static let sidebarPeek = Animation.spring(response: 0.21, dampingFraction: 0.82)
    static let sidebarUnpeek = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15)
    static let selection = Animation.spring(response: 0.36, dampingFraction: 0.8)
    static let fold = Animation.spring(response: 0.34, dampingFraction: 0.88)
    static let shelf = Animation.spring(response: 0.55, dampingFraction: 0.9)
    static let routeFadeDuration: CFTimeInterval = 0.15
    static let hover = Animation.easeOut(duration: 0.18)
    static let reveal = Animation.spring(response: 0.55, dampingFraction: 0.86)
    static let staggerStep = 0.028
    static let staggerLimit = 14
    static let tab = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
    static let lift = Animation.spring(response: 0.35, dampingFraction: 0.78)
    static let deal = Animation.spring(response: 0.5, dampingFraction: 0.78)
    static let listEdit = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let pause = Animation.spring(response: 0.45, dampingFraction: 0.62)
    /// The cover colour (`PlayerController.accentColor`) moving to a new song's: slow enough to
    /// read as the light changing, not a switch.
    static let accent = Animation.easeInOut(duration: 0.8)
    /// The search box lifting from its capsule into the card with the panel, and settling back.
    /// Closing is quicker and does not overshoot: the pages are what the user went back to.
    static let searchOpen = Animation.spring(response: 0.38, dampingFraction: 0.84)
    static let searchClose = Animation.spring(response: 0.26, dampingFraction: 1)
    static let searchResize = Animation.spring(response: 0.3, dampingFraction: 0.9)
    static let hint = Spring(response: 0.6, dampingRatio: 0.9)
    static let switcherOpen = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let switcherClose = Animation.spring(response: 0.22, dampingFraction: 1)
    static let switcherPick = Animation.spring(response: 0.38, dampingFraction: 0.82)
}
