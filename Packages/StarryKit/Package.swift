// swift-tools-version: 6.0
// Shared modules for Starry Player.
import PackageDescription

let package = Package(
    name: "StarryKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StarryCore", targets: ["StarryCore"]),
        .library(name: "MusicSources", targets: ["MusicSources"]),
        .library(name: "PlaybackEngine", targets: ["PlaybackEngine"]),
        .library(name: "AudioProcessing", targets: ["AudioProcessing"]),
        .library(name: "LyricsCore", targets: ["LyricsCore"]),
        .library(name: "LyricsProviders", targets: ["LyricsProviders"]),
        .library(name: "PluginHost", targets: ["PluginHost"]),
        .library(name: "LyricsSync", targets: ["LyricsSync"]),
        .library(name: "LyricsUI", targets: ["LyricsUI"]),
        .library(name: "Backdrop", targets: ["Backdrop"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "LocalLibrary", targets: ["LocalLibrary"]),
    ],
    targets: [
        .target(name: "StarryCore"),
        .target(name: "MusicSources", dependencies: ["StarryCore"]),
        .target(name: "PlaybackEngine", dependencies: ["StarryCore", "AudioProcessing"]),
        .target(name: "AudioProcessing"),
        .target(name: "LyricsCore", dependencies: ["StarryCore"]),
        .target(name: "LyricsProviders", dependencies: ["StarryCore", "MusicSources", "LyricsCore"]),
        .target(name: "PluginHost", dependencies: ["StarryCore", "MusicSources", "LyricsProviders"], resources: [.copy("Resources/prelude.js")]),
        .target(name: "LyricsSync", dependencies: ["AudioProcessing", "LyricsCore"]),
        .target(name: "LyricsUI", dependencies: ["LyricsCore"]),
        .target(name: "Backdrop"),
        .target(name: "Library", dependencies: ["StarryCore"]),
        .target(name: "LocalLibrary", dependencies: ["StarryCore", "MusicSources", "LyricsCore", "LyricsProviders"], linkerSettings: [.linkedLibrary("sqlite3")]),

        .testTarget(name: "StarryCoreTests", dependencies: ["StarryCore"]),
        .testTarget(name: "MusicSourcesTests", dependencies: ["MusicSources"]),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
        .testTarget(name: "LyricsProvidersTests", dependencies: ["LyricsProviders"]),
        .testTarget(name: "PluginHostTests", dependencies: ["PluginHost", "LyricsProviders", "LyricsCore", "MusicSources", "StarryCore", "PlaybackEngine"]),
        .testTarget(name: "LyricsSyncTests", dependencies: ["LyricsSync", "AudioProcessing", "LyricsCore"]),
        .testTarget(name: "LyricsUITests", dependencies: ["LyricsUI"]),
        .testTarget(name: "AudioProcessingTests", dependencies: ["AudioProcessing"]),
        .testTarget(name: "PlaybackEngineTests", dependencies: ["PlaybackEngine"]),
        .testTarget(name: "BackdropTests", dependencies: ["Backdrop"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "LocalLibraryTests", dependencies: ["LocalLibrary", "MusicSources", "StarryCore"]),
    ],
    swiftLanguageModes: [.v6]
)
