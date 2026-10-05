import AppKit
import Foundation

/// Lengths are points at scale 1; `scaled()` applies the display scale.
public struct LyricsSpecs: Sendable, Equatable {
    public enum Preset: String, Sendable, Codable, CaseIterable, Identifiable {
        case windowed, fullscreen
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .windowed: "窗口"
            case .fullscreen: "全屏"
            }
        }
        public var referenceHeight: CGFloat {
            switch self {
            case .windowed: 834
            case .fullscreen: 1080
            }
        }
    }

    public enum SelectedLinePosition: Sendable, Equatable {
        case top(offset: CGFloat)
        case topRelative(percentage: CGFloat)
        /// The selected line is centred on `rect` (view coordinates), or on the view when nil
        /// (offset = min(line.minY, line.minY − (rect.h − line.h)/2 − rect.minY)). The full-screen
        /// preset uses the view; the Now Playing page passes the cover's frame, so the line lines
        /// up with the cover.
        case center(rect: CGRect?)

        public static var center: SelectedLinePosition { .center(rect: nil) }
    }

    public struct Spring: Sendable, Equatable {
        public var mass: Double
        public var stiffness: Double
        public var damping: Double
        public init(mass: Double, stiffness: Double, damping: Double) {
            self.mass = mass
            self.stiffness = stiffness
            self.damping = damping
        }
        /// Damping ratio ζ = c / (2√(km)).
        public var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

        /// Spring with unit mass from a damping ratio and a response (period of the undamped
        /// oscillation): k = (2π / response)², c = ζ·2√k.
        public init(dampingRatio: Double, response: Double) {
            let omega = 2 * Double.pi / max(response, 0.01)
            let stiffness = omega * omega
            self.init(mass: 1, stiffness: stiffness, damping: dampingRatio * 2 * stiffness.squareRoot())
        }
    }

    public struct Blur: Sendable, Equatable {
        public enum Mode: String, Sendable, Codable, CaseIterable { case off, upcoming, both }
        public var mode: Mode = .both
        public var radius: CGFloat = 3
        public var step: CGFloat = 1
        public var maximum: CGFloat = 4
        public init() {}
    }

    public var preset: Preset = .windowed
    public var scale: CGFloat = 1
    public var fontSize: CGFloat = 48
    public var fontWeight: NSFont.Weight = .bold
    public var backgroundVocalsFontSize: CGFloat = 32
    public var translationFontSize: CGFloat = 22
    public var translationBackgroundVocalsFontSize: CGFloat = 15
    public var romanizationFontSize: CGFloat = 28
    public var romanizationBackgroundVocalsFontSize: CGFloat = 20
    public var romanizationLineHeightAdjustment: CGFloat = 5
    public var romanizationMinWordSpacing: CGFloat = 5
    public var fontLeading: CGFloat? = 52
    public var lineSpacing: CGFloat = 40
    public var paragraphSpacing: CGFloat = 39
    public var backgroundVocalsTopSpacing: CGFloat = 30
    public var translationSpacing: CGFloat = 7
    public var translationBottomPadding: CGFloat = 4
    public var firstLineStartingPosition: CGFloat = 60
    public var selectedLinePosition: SelectedLinePosition = .topRelative(percentage: 20)
    /// Distance from the view's left / right edges to the text. The view clips to its bounds,
    /// so it never uses less than `highlightViewMargin`: the hover highlight, glow and blur
    /// spill past the text and would otherwise be cut off at the edge.
    public var horizontalInset: CGFloat = 0
    /// Width of every line when the lyrics have more than one vocalist, as a fraction of the
    /// available width, so left / right voices read apart.
    public var vocalGroupWidthCoefficient: CGFloat = 0.85

    public var lineDelay: TimeInterval = 0.05
    public var animationHeadstart: TimeInterval = 0.1
    public var lineFinishProgressAnimationDuration: TimeInterval = 0.25
    public var lineTapProgressFreezeDuration: TimeInterval = 0.1
    public var maxEndTimeOffset: TimeInterval = 0.5
    /// Shortest time a line change is squeezed into when its line gives way before the spring
    /// would settle. Quicker, a move of a line height or more reads as a jump.
    public var minimumLineChangeDuration: TimeInterval = 0.35
    public var lineChangeSpring = Spring(mass: 1, stiffness: 100, damping: 18)
    public var tapLineChangeSpring = Spring(mass: 2, stiffness: 260, damping: 50)
    public var touchDownSpring = Spring(mass: 1, stiffness: 322, damping: 24)
    public var touchUpSpring = Spring(mass: 2, stiffness: 300, damping: 50)
    public var backgroundVocalsSelectSpring = Spring(mass: 1, stiffness: 30, damping: 9)
    public var backgroundVocalsDeselectSpring = Spring(dampingRatio: 1, response: 0.2)
    public var showTranslationSpring = Spring(mass: 1, stiffness: 150, damping: 30)
    public var hideTranslationSpring = Spring(mass: 1, stiffness: 130, damping: 30)
    public var translationRevealOffset: CGFloat = 20
    public var deselectedScale: CGFloat = 0.98
    public var touchDownScale: CGFloat = 0.95
    public var backgroundVocalsDeselectedScale: CGFloat = 0.90

    public var perSyllableEnabled = true
    public var springEnabled = true
    public var syllableLiftEnabled = true
    public var syllableLift: CGFloat = 2
    public var syllableLiftSpring = Spring(mass: 1, stiffness: 14, damping: 7)
    public var emphasisEnabled = true
    public var emphasizingScaleRange: ClosedRange<Double> = 1.0...1.14
    public var glowEnabled = true
    public var glowRadius: CGFloat = 5
    public var glowRange: ClosedRange<Double> = 0.0...0.4
    public var lineProgressionGradientFeather: CGFloat = 30
    public var blur = Blur()

    public var lineProgressionAlpha: CGFloat = 1
    public var selectedUpcomingTextAlpha: CGFloat = 0.35
    public var deselectedTextAlpha: CGFloat = 0.175
    public var deselectedScrollTextAlpha: CGFloat = 0.4
    public var lineProgressionBackgroundVocalsAlpha: CGFloat = 0.175
    public var selectedUpcomingBackgroundVocalsAlpha: CGFloat = 0.175
    public var translationAlpha: CGFloat = 0.5
    public var highlightViewAlpha: CGFloat = 0.08
    public var highlightViewCornerRadius: CGFloat = 16
    public var highlightViewMargin: CGFloat = 16
    public var hoverHighlightEnabled = true

    public var instrumentalBreakMinimumGap: TimeInterval = 7
    public var instrumentalBreakCountdownDotCount = 3
    public var instrumentalBreakViewHeight: CGFloat = 40
    public var instrumentalBreakDotLength: CGFloat = 12
    public var instrumentalBreakDotMargin: CGFloat = 8

    public var showTranslation = true
    public var showRomanization = false

    public init() {}

    public static var windowed: LyricsSpecs { LyricsSpecs() }

    public static var fullscreen: LyricsSpecs {
        var s = LyricsSpecs()
        s.preset = .fullscreen
        s.fontSize = 28
        s.backgroundVocalsFontSize = 24
        s.translationFontSize = 18
        s.translationBackgroundVocalsFontSize = 14
        s.romanizationFontSize = 18
        s.romanizationBackgroundVocalsFontSize = 15
        s.fontLeading = nil
        s.lineSpacing = 25
        s.backgroundVocalsTopSpacing = 15
        s.selectedLinePosition = .center
        return s
    }

    public static func preset(_ preset: Preset) -> LyricsSpecs {
        switch preset {
        case .windowed: .windowed
        case .fullscreen: .fullscreen
        }
    }

    public func scaled() -> LyricsSpecs {
        guard scale != 1 else { return self }
        var s = self
        let k = scale
        s.scale = 1
        s.fontSize *= k
        s.backgroundVocalsFontSize *= k
        s.translationFontSize *= k
        s.translationBackgroundVocalsFontSize *= k
        s.romanizationFontSize *= k
        s.romanizationBackgroundVocalsFontSize *= k
        s.romanizationLineHeightAdjustment *= k
        s.romanizationMinWordSpacing *= k
        s.fontLeading = fontLeading.map { $0 * k }
        s.lineSpacing *= k
        s.paragraphSpacing *= k
        s.backgroundVocalsTopSpacing *= k
        s.translationSpacing *= k
        s.translationBottomPadding *= k
        s.translationRevealOffset *= k
        s.firstLineStartingPosition *= k
        if case .top(let offset) = selectedLinePosition { s.selectedLinePosition = .top(offset: offset * k) }
        s.syllableLift *= k
        s.glowRadius *= k
        s.lineProgressionGradientFeather *= k
        s.blur.radius *= k
        s.blur.step *= k
        s.blur.maximum *= k
        s.highlightViewCornerRadius *= k
        s.highlightViewMargin *= k
        s.instrumentalBreakViewHeight *= k
        s.instrumentalBreakDotLength *= k
        s.instrumentalBreakDotMargin *= k
        return s
    }

    public func wordSyncedLineChangeSpring(gap: TimeInterval?) -> Spring {
        guard let gap else { return lineChangeSpring }
        let p = gap < 0.2 ? 0 : (min(gap, 0.75) - 0.2) / 0.55
        return Spring(dampingRatio: (1 - p) * 0.12 + 0.78, response: p * 0.27 + 0.48)
    }

    /// Distance from the top of a view `viewHeight` high to the selected line's top for the top
    /// positions (the scroll view's top content inset); nil when centred.
    public func selectedLineTop(viewHeight: CGFloat) -> CGFloat? {
        switch selectedLinePosition {
        case .top(let offset): offset
        case .topRelative(let percentage): viewHeight * percentage / 100 - font.ascender
        case .center: nil
        }
    }

    public var font: NSFont { .systemFont(ofSize: fontSize, weight: fontWeight) }
    public var backgroundVocalsFont: NSFont { .systemFont(ofSize: backgroundVocalsFontSize, weight: fontWeight) }
    public var translationFont: NSFont { .systemFont(ofSize: translationFontSize, weight: .semibold) }
    public var translationBackgroundVocalsFont: NSFont { .systemFont(ofSize: translationBackgroundVocalsFontSize, weight: .semibold) }
    public var romanizationFont: NSFont { .systemFont(ofSize: romanizationFontSize, weight: .bold) }
    public var romanizationBackgroundVocalsFont: NSFont { .systemFont(ofSize: romanizationBackgroundVocalsFontSize, weight: .bold) }

    public func blurRadius(distance: Int, beforeFirstLine: Bool = false) -> CGFloat {
        guard blur.mode != .off else { return 0 }
        let r: CGFloat
        if beforeFirstLine {
            r = distance <= 1 ? blur.radius : blur.maximum
        } else if distance <= 0 {
            guard blur.mode == .both else { return 0 }
            r = blur.radius
        } else {
            r = blur.radius + CGFloat(distance - 2) * blur.step
        }
        return max(0, min(blur.maximum, r))
    }
}
