import AppKit
import Library
import LyricsCore
import LyricsUI
import SwiftUI

/// Hosts the AppKit `LyricsView` and drives it from the playback clock.
struct LyricsHost: NSViewRepresentable {
    var document: LyricsDocument
    var specs: LyricsSpecs
    /// Playback rate, 0 while paused: the one clock value that comes through SwiftUI. A change
    /// wakes the display link, which pauses itself after two seconds at rate 0. The position
    /// itself comes from `clock`, asked every frame, so the 4 Hz `currentTime` updates never
    /// re-run this view (each would diff the whole page and could push the lyrics' frame late).
    var rate: Double
    var color: Color
    var timeOffset: TimeInterval
    /// Player time under the progress slider while the user drags it, nil otherwise.
    var scrubTime: TimeInterval?
    var alignment: NSTextAlignment = .left
    var clock: () -> (time: TimeInterval, rate: Double)
    var onSeek: (TimeInterval) -> Void

    func makeNSView(context: Context) -> LyricsView {
        let view = LyricsView(frame: .zero)
        view.timeSource = clock
        view.timeOffset = timeOffset
        view.document = document
        view.specs = specs
        view.tintColor = NSColor(color)
        view.onSeek = onSeek
        return view
    }

    func updateNSView(_ view: LyricsView, context: Context) {
        if view.document != document { view.document = document }
        if view.specs != specs { view.specs = specs }
        let tint = NSColor(color)
        if view.tintColor != tint { view.tintColor = tint }
        if view.textAlignment != alignment { view.textAlignment = alignment }
        view.timeOffset = timeOffset
        view.timeSource = clock
        view.onSeek = onSeek
        // Before the clock sample: a drag that just ended must leave tracking mode first.
        if scrubTime != nil || view.isScrubbing { view.scrub(to: scrubTime) }
        let sample = clock()
        view.update(time: sample.time, rate: sample.rate)
    }
}

extension LyricsSpecs {
    /// Build windowed or full-screen lyric specs from settings.
    /// `artworkRect` is in lyrics-view coordinates and determines the selected line's anchor.
    static func make(from settings: AppSettings.Lyrics, fullscreen: Bool, viewHeight: CGFloat, artworkRect: CGRect? = nil) -> LyricsSpecs {
        let preset: LyricsSpecs.Preset = fullscreen ? .fullscreen : .windowed
        var specs = LyricsSpecs.preset(preset)
        var scale = CGFloat(fullscreen ? settings.fullscreenScale : settings.windowedScale)
        if settings.autoScale, viewHeight > 0 {
            scale *= min(max(viewHeight / preset.referenceHeight, 0.6), 1.6)
        }
        specs.scale = scale
        if settings.fontSize > 0 {
            let ratio = CGFloat(settings.fontSize) / specs.fontSize
            specs.fontSize = CGFloat(settings.fontSize)
            specs.backgroundVocalsFontSize *= ratio
            specs.translationFontSize *= ratio
            specs.romanizationFontSize *= ratio
            specs.romanizationBackgroundVocalsFontSize *= ratio
            specs.fontLeading = specs.fontLeading.map { $0 * ratio }
        }
        if settings.lineSpacing > 0 { specs.lineSpacing = CGFloat(settings.lineSpacing) }
        switch settings.anchor {
        case .preset: if let artworkRect { specs.selectedLinePosition = .center(rect: artworkRect) }
        case .top: specs.selectedLinePosition = .topRelative(percentage: 20)
        case .center: specs.selectedLinePosition = .center
        }
        specs.perSyllableEnabled = settings.perSyllable
        specs.springEnabled = settings.spring
        specs.syllableLiftEnabled = settings.lift
        specs.emphasisEnabled = settings.emphasis
        specs.glowEnabled = settings.glow
        specs.blur.mode = switch settings.blurMode {
        case .off: .off
        case .upcoming: .upcoming
        case .both: .both
        }
        specs.blur.radius = CGFloat(settings.blurRadius)
        specs.blur.maximum = CGFloat(max(settings.blurMax, settings.blurRadius))
        specs.showTranslation = settings.showTranslation
        specs.showRomanization = settings.showRomanization
        specs.hoverHighlightEnabled = settings.hoverHighlight
        if settings.inactiveOpacity > 0 {
            specs.deselectedTextAlpha = CGFloat(settings.inactiveOpacity)
            specs.deselectedScrollTextAlpha = max(CGFloat(settings.inactiveOpacity), 0.4)
        }
        return specs
    }
}
