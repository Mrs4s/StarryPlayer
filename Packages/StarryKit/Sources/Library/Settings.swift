import Foundation
import Observation
import StarryCore

public struct AppSettings: Codable, Sendable, Equatable {
    public struct Transition: Codable, Sendable, Equatable {
        public var gapless = false
        public var crossfade = false
        public var crossfadeSeconds: Double = 5
        public var albumsWithoutFade = true

        public init() {}

        public var isEnabled: Bool { gapless || crossfade }

        public func mode(sameAlbum: Bool = false) -> TransitionMode {
            if crossfade, !(sameAlbum && albumsWithoutFade) {
                let range = TransitionMode.crossfadeRange
                return .crossfade(seconds: min(max(crossfadeSeconds, range.lowerBound), range.upperBound))
            }
            return isEnabled ? .gapless : .none
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Transition()
            gapless = try c.decodeIfPresent(Bool.self, forKey: .gapless) ?? d.gapless
            crossfade = try c.decodeIfPresent(Bool.self, forKey: .crossfade) ?? d.crossfade
            crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? d.crossfadeSeconds
            albumsWithoutFade = try c.decodeIfPresent(Bool.self, forKey: .albumsWithoutFade) ?? d.albumsWithoutFade
        }

        private enum CodingKeys: String, CodingKey {
            case gapless, crossfade, crossfadeSeconds, albumsWithoutFade
        }
    }

    public struct Scrobble: Codable, Sendable, Equatable {
        public var enabled = true
        public init() {}
    }

    public struct Plugins: Codable, Sendable, Equatable {
        /// Ids of the plugins turned off: still listed, not loaded as sources or lyric platforms.
        public var disabled: [String] = []
        public var addresses: [String: String] = [:]
        public var inspectable = false
        public var developmentFolders: [String] = []
        public var logsCalls = false
        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
            addresses = try c.decodeIfPresent([String: String].self, forKey: .addresses) ?? [:]
            inspectable = try c.decodeIfPresent(Bool.self, forKey: .inspectable) ?? false
            developmentFolders = try c.decodeIfPresent([String].self, forKey: .developmentFolders) ?? []
            logsCalls = try c.decodeIfPresent(Bool.self, forKey: .logsCalls) ?? false
        }
    }

    public struct Cache: Codable, Sendable, Equatable {
        public var enabled = true
        public var sizeLimitGB: Double = 4
        public var directory: String?
        public init() {}
    }

    public struct OutputDevice: Codable, Sendable, Equatable {
        public var uid: String
        /// Shown while the device is not connected.
        public var name: String
        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    public enum Appearance: String, Codable, Sendable, CaseIterable { case system, light, dark }
    public enum ThemeColorMode: String, Codable, Sendable, CaseIterable { case `default`, cover, custom }
    /// The player bar's look: the frosted bar, or the system's Liquid Glass (macOS 26+; older
    /// systems keep the classic bar).
    public enum PlayerBarStyle: String, Codable, Sendable, CaseIterable {
        case classic, glass

        /// The default: Liquid Glass where the system has it (macOS 26+), else the classic bar.
        public static var systemDefault: PlayerBarStyle {
            if #available(macOS 26, *) { return .glass }
            return .classic
        }
    }

    public enum SidebarMode: String, Codable, Sendable, CaseIterable { case docked, floating, autoHide }

    public struct Lyrics: Codable, Sendable, Equatable {
        public enum BlurMode: String, Codable, Sendable, CaseIterable { case off, upcoming, both }
        public enum Alignment: String, Codable, Sendable, CaseIterable { case leading, center }
        public enum Anchor: String, Codable, Sendable, CaseIterable { case preset, top, center }

        public var windowedScale: Double = 1
        public var fullscreenScale: Double = 1.75
        public var autoScale = true
        /// 0 uses the preset value.
        public var fontSize: Double = 0
        /// 0 uses the preset value.
        public var lineSpacing: Double = 0
        public var anchor: Anchor = .preset
        public var alignment: Alignment = .leading
        public var perSyllable = true
        public var spring = true
        public var lift = true
        public var emphasis = true
        public var glow = true
        public var blurMode: BlurMode = .both
        public var blurRadius: Double = 3
        public var blurMax: Double = 4
        public var showTranslation = true
        public var showRomanization = false
        public var hoverHighlight = true
        /// 0 uses the preset value.
        public var inactiveOpacity: Double = 0
        public init() {}
    }

    public struct MenuBarLyrics: Codable, Sendable, Equatable {
        public var enabled = false
        public var perSyllable = true
        public var maxWidth: Double = 300
        public init() {}

        private enum CodingKeys: String, CodingKey { case enabled, perSyllable, maxWidth }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = MenuBarLyrics()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            perSyllable = try c.decodeIfPresent(Bool.self, forKey: .perSyllable) ?? d.perSyllable
            maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? d.maxWidth
        }
    }

    public struct DesktopLyrics: Codable, Sendable, Equatable {
        public enum Palette: String, Codable, Sendable, CaseIterable { case cover, white, blue, green, pink, gold }
        public enum Background: String, Codable, Sendable, CaseIterable { case transparent, card }

        public var enabled = false
        public var locked = false
        public var perSyllable = true
        public var showTranslation = true
        public var fontSize: Double = 30
        public var width: Double = 900
        public var palette: Palette = .cover
        public var background: Background = .transparent
        public var hidesWhenPaused = false
        public var hidesFromCapture = false
        public init() {}

        private enum CodingKeys: String, CodingKey { case enabled, locked, perSyllable, showTranslation, fontSize, width, palette, background, hidesWhenPaused, hidesFromCapture }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = DesktopLyrics()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? d.locked
            perSyllable = try c.decodeIfPresent(Bool.self, forKey: .perSyllable) ?? d.perSyllable
            showTranslation = try c.decodeIfPresent(Bool.self, forKey: .showTranslation) ?? d.showTranslation
            fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
            palette = (try? c.decodeIfPresent(Palette.self, forKey: .palette)) ?? d.palette
            background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? d.background
            hidesWhenPaused = try c.decodeIfPresent(Bool.self, forKey: .hidesWhenPaused) ?? d.hidesWhenPaused
            hidesFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hidesFromCapture) ?? d.hidesFromCapture
        }
    }

    /// The player in the notch: the song beside it while it plays, the controls when the pointer
    /// rests on it. A screen without a notch gets an island in the middle of its menu bar.
    public struct Notch: Codable, Sendable, Equatable {
        public var enabled = false
        /// The line being sung, beside the notch (in the island, without one).
        public var showsLyrics = true
        /// Opens when the pointer rests on it; off, on a click.
        public var expandsOnHover = true
        /// None on a screen without a notch (a Mac without one, an external display).
        public var notchedScreensOnly = false
        public init() {}

        private enum CodingKeys: String, CodingKey { case enabled, showsLyrics, expandsOnHover, notchedScreensOnly }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Notch()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            showsLyrics = try c.decodeIfPresent(Bool.self, forKey: .showsLyrics) ?? d.showsLyrics
            expandsOnHover = try c.decodeIfPresent(Bool.self, forKey: .expandsOnHover) ?? d.expandsOnHover
            notchedScreensOnly = try c.decodeIfPresent(Bool.self, forKey: .notchedScreensOnly) ?? d.notchedScreensOnly
        }
    }

    public struct Background: Codable, Sendable, Equatable {
        public enum Style: String, Codable, Sendable, CaseIterable { case artwork, blur, gradient }
        /// Spectrum intensity: auto = lively while the page shows lyrics (`isBehindLyrics`), calm
        /// otherwise.
        public enum Motion: String, Codable, Sendable, CaseIterable { case auto, calm, lively }
        public var style: Style = .artwork
        public var motion: Motion = .auto
        public var speed: Double = 1
        public var blurScale: Double = 1
        public var saturationScale: Double = 1
        public var brightness: Double = 1
        public var scrim: Double = 0.5
        /// White scrim before the colour grade (default 0.1).
        public var whiteScrim: Double = 0.1
        public var audioReactivity: Double = 1
        /// Mesh warp amplitude while lively, 0…1 (1 = the grids as authored, the most they take
        /// without folding; 0 = off).
        public var pinchStrength: Double = 1
        public var colorGrade: Bool = true
        public var framesPerSecond: Int = 30
        public var fullscreenFramesPerSecond: Int = 60
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case style, motion, speed, blurScale, saturationScale, brightness, scrim, whiteScrim, audioReactivity, pinchStrength, colorGrade, framesPerSecond, fullscreenFramesPerSecond
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Background()
            style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style
            motion = (try? c.decodeIfPresent(Motion.self, forKey: .motion)) ?? d.motion
            speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
            blurScale = try c.decodeIfPresent(Double.self, forKey: .blurScale) ?? d.blurScale
            saturationScale = try c.decodeIfPresent(Double.self, forKey: .saturationScale) ?? d.saturationScale
            brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
            scrim = try c.decodeIfPresent(Double.self, forKey: .scrim) ?? d.scrim
            whiteScrim = try c.decodeIfPresent(Double.self, forKey: .whiteScrim) ?? d.whiteScrim
            audioReactivity = try c.decodeIfPresent(Double.self, forKey: .audioReactivity) ?? d.audioReactivity
            pinchStrength = min(1, try c.decodeIfPresent(Double.self, forKey: .pinchStrength) ?? d.pinchStrength)
            colorGrade = try c.decodeIfPresent(Bool.self, forKey: .colorGrade) ?? d.colorGrade
            framesPerSecond = try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? d.framesPerSecond
            fullscreenFramesPerSecond = try c.decodeIfPresent(Int.self, forKey: .fullscreenFramesPerSecond) ?? d.fullscreenFramesPerSecond
        }
    }

    public var preferredQuality: AudioQuality = .default
    public var sourceQualities: [String: String] = [:]
    public var allowTrialPlay = false
    /// nil plays through the system output, and follows it when it changes.
    public var outputDevice: OutputDevice?
    public var restorePlayback = true
    public var showAdvancedSettings = false
    public var preloadNextTrack = true
    public var transition = Transition()
    public var loudness = Loudness()
    public var lyricPreferTrackPlatform = true
    public var lyricSourceOrder: [String] = ["qqmusic", "kugou", "netease"]
    /// Plugin lyric providers already offered: one joins the end of `lyricSourceOrder` the first
    /// time it loads and is left alone after that, so turning it off sticks.
    public var knownLyricPlugins: [String] = []
    /// Ask every provider at once instead of one after another (faster, more requests); the
    /// lyrics chosen are the same.
    public var lyricRaceProviders = false
    public var amllDbEnabled = true
    /// AMLL TTML DB base URL or `%p` / `%s` template.
    public var amllDbServer = "https://amlldb.bikonoo.com"
    /// Folder of TTML files that wins over online lyrics; nil = off.
    public var localLyricRepository: String?
    public var stripLyricCredits = true
    public var sources: [String: SourceSettingValues] = [:]
    public var scrobble = Scrobble()
    public var plugins = Plugins()
    public var cache = Cache()
    /// Folder holding a side-loaded vocal separation model (sing-along mode); nil = the default folder in the
    /// data directory. The vocal switch and level live outside the settings, like the volume.
    public var vocalModelDirectory: String?
    public var visualizerEnabled = true
    public var appearance: Appearance = .system
    public var themeColorMode: ThemeColorMode = .cover
    public var customThemeColorHex = "#FE7971"
    public var sidebarCollapsed = false
    public var sidebarMode: SidebarMode = .floating
    public var playerBarStyle: PlayerBarStyle = .systemDefault
    public var lyrics = Lyrics()
    public var background = Background()
    public var menuBarLyrics = MenuBarLyrics()
    public var desktopLyrics = DesktopLyrics()
    public var notch = Notch()
    /// Look for a newer release on launch and once a day, and say when there is one.
    public var checksForUpdates = true

    public init() {}

    public func sourceSettings(_ id: SourceID) -> SourceSettingValues {
        sources[id.key] ?? SourceSettingValues()
    }

    public mutating func setSourceSettings(_ values: SourceSettingValues, for id: SourceID) {
        sources[id.key] = values.isEmpty ? nil : values
    }

    // Tolerant decoding so settings saved by older builds keep working when fields are added.
    private enum CodingKeys: String, CodingKey {
        case lyricSourceOrder, knownLyricPlugins, preferredQuality, sourceQualities, allowTrialPlay, outputDevice, restorePlayback, showAdvancedSettings, preloadNextTrack, transition, loudness, lyricPreferTrackPlatform, lyricRaceProviders, amllDbEnabled, amllDbServer, localLyricRepository, stripLyricCredits, sources, scrobble, plugins, cache, vocalModelDirectory, visualizerEnabled, appearance, themeColorMode, customThemeColorHex, sidebarCollapsed, sidebarMode, playerBarStyle, lyrics, background, menuBarLyrics, desktopLyrics, notch, checksForUpdates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        preferredQuality = (try? c.decodeIfPresent(AudioQuality.self, forKey: .preferredQuality)) ?? d.preferredQuality
        sourceQualities = try c.decodeIfPresent([String: String].self, forKey: .sourceQualities) ?? d.sourceQualities
        allowTrialPlay = try c.decodeIfPresent(Bool.self, forKey: .allowTrialPlay) ?? d.allowTrialPlay
        outputDevice = try? c.decodeIfPresent(OutputDevice.self, forKey: .outputDevice)
        restorePlayback = try c.decodeIfPresent(Bool.self, forKey: .restorePlayback) ?? d.restorePlayback
        showAdvancedSettings = try c.decodeIfPresent(Bool.self, forKey: .showAdvancedSettings) ?? d.showAdvancedSettings
        preloadNextTrack = try c.decodeIfPresent(Bool.self, forKey: .preloadNextTrack) ?? d.preloadNextTrack
        transition = try c.decodeIfPresent(Transition.self, forKey: .transition) ?? d.transition
        loudness = (try? c.decodeIfPresent(Loudness.self, forKey: .loudness)) ?? d.loudness
        lyricPreferTrackPlatform = try c.decodeIfPresent(Bool.self, forKey: .lyricPreferTrackPlatform) ?? d.lyricPreferTrackPlatform
        lyricSourceOrder = try c.decodeIfPresent([String].self, forKey: .lyricSourceOrder) ?? d.lyricSourceOrder
        knownLyricPlugins = try c.decodeIfPresent([String].self, forKey: .knownLyricPlugins) ?? d.knownLyricPlugins
        lyricRaceProviders = try c.decodeIfPresent(Bool.self, forKey: .lyricRaceProviders) ?? d.lyricRaceProviders
        amllDbEnabled = try c.decodeIfPresent(Bool.self, forKey: .amllDbEnabled) ?? d.amllDbEnabled
        amllDbServer = try c.decodeIfPresent(String.self, forKey: .amllDbServer) ?? d.amllDbServer
        localLyricRepository = try c.decodeIfPresent(String.self, forKey: .localLyricRepository)
        stripLyricCredits = try c.decodeIfPresent(Bool.self, forKey: .stripLyricCredits) ?? d.stripLyricCredits
        sources = (try? c.decodeIfPresent([String: SourceSettingValues].self, forKey: .sources)) ?? d.sources
        scrobble = try c.decodeIfPresent(Scrobble.self, forKey: .scrobble) ?? d.scrobble
        plugins = try c.decodeIfPresent(Plugins.self, forKey: .plugins) ?? d.plugins
        cache = try c.decodeIfPresent(Cache.self, forKey: .cache) ?? d.cache
        vocalModelDirectory = try c.decodeIfPresent(String.self, forKey: .vocalModelDirectory)
        visualizerEnabled = try c.decodeIfPresent(Bool.self, forKey: .visualizerEnabled) ?? d.visualizerEnabled
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        themeColorMode = try c.decodeIfPresent(ThemeColorMode.self, forKey: .themeColorMode) ?? d.themeColorMode
        customThemeColorHex = try c.decodeIfPresent(String.self, forKey: .customThemeColorHex) ?? d.customThemeColorHex
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? d.sidebarCollapsed
        sidebarMode = (try? c.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode)) ?? d.sidebarMode
        playerBarStyle = (try? c.decodeIfPresent(PlayerBarStyle.self, forKey: .playerBarStyle)) ?? d.playerBarStyle
        lyrics = (try? c.decodeIfPresent(Lyrics.self, forKey: .lyrics)) ?? d.lyrics
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? d.background
        menuBarLyrics = (try? c.decodeIfPresent(MenuBarLyrics.self, forKey: .menuBarLyrics)) ?? d.menuBarLyrics
        desktopLyrics = (try? c.decodeIfPresent(DesktopLyrics.self, forKey: .desktopLyrics)) ?? d.desktopLyrics
        notch = (try? c.decodeIfPresent(Notch.self, forKey: .notch)) ?? d.notch
        checksForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? d.checksForUpdates
    }
}

@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet { persist() }
    }

    /// Where the settings are saved; nil keeps them in memory.
    private let defaults: UserDefaults?
    private let key = "starry.settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    /// Settings that start as `settings` and are never saved.
    public init(inMemory settings: AppSettings) {
        defaults = nil
        self.settings = settings
    }

    private func persist() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
