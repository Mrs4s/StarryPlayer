<div align="center">

<img src="App/StarryPlayer/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" alt="Starry Player">

# Starry Player

A high-performance native macOS music player with rich visual effects

[简体中文](README.md) · [English](README.en.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

</div>

## Screenshots

<p align="center">
  <img src="screenshots/screen-1.webp" width="800" alt="Home page">
  <img src="screenshots/screen-2.webp" width="800" alt="Lyrics page">
</p>

## Features

- 🎤 **Word-by-word lyrics**: Highlight each word as it is sung, with translations, pronunciation guides, and automatic lyric matching. Lyrics can also appear in the menu bar, around the notch, or on the desktop
- 🎯 **Lyric alignment**: Analyze vocals to automatically correct lyric timing with one click, and remember the offset for each song
- 🌌 **Animated backgrounds**: Flowing cover-art backgrounds that pulse with the music
- 🎵 **Multiple sources**: NetEase Cloud Music, Jellyfin, Subsonic / Navidrome, and local music
- 🧩 **Plugins**: A flexible plugin system lets developers add custom music sources
- 🎧 **Playback**: Gapless playback, crossfade, ReplayGain, and 10-band and parametric equalizers with support for importing AutoEQ and Equalizer APO settings
- 🎙️ **Sing-along mode**: Remove the original vocals and sing along to the accompaniment
- ⚡ **High performance**: Built natively in Swift for smooth animations and low resource usage

## Performance

Most players with Apple Music-style visuals are built with web technologies, which can demand substantial resources with all effects enabled. On a MacBook, this can often send the fans spinning even while plugged in.

Starry Player is built natively in Swift and optimized for macOS. The following measurements show the increase in total system power consumption over idle during steady playback on the lyrics page with all effects enabled:

| Player | Device | Steady-state power increase |
| --- | --- | --- |
| **Starry Player** | M4 Mac mini | **Approx. +0.8 W** |
| **Starry Player** | M5 Max (40-core GPU) | **Approx. +2–4 W** ¹ |
| NetEase Cloud Music | M5 Max (40-core GPU) | Approx. +2–3 W |
| Apple Music | M5 Max (40-core GPU) | Approx. +5 W |

¹ Components in the M5 Max system, such as its larger unified memory configuration, consume more power, resulting in a larger increase than on the M4.

CPU usage on the playback page is also lower than that of other popular players:

| Player | Device | Average CPU usage ¹ |
| --- | --- | --- |
| **Starry Player** | M5 Max (18-core CPU) | 0.5% |
| Apple Music | M5 Max (18-core CPU) | 1% |
| NetEase Cloud Music | M5 Max (18-core CPU) | 2% |

¹ Results may vary between songs depending on how frequently the lyrics advance to a new line.

## Installation

Requires macOS 14 or later.

The app is ad-hoc signed and has not been notarized, so macOS may block it the first time you open it. Right-click the app in Finder and choose **Open**, or go to **System Settings › Privacy & Security** and click **Open Anyway**.

## Development

```bash
brew install xcodegen node
scripts/bootstrap.sh       # Generate StarryPlayer.xcodeproj
open StarryPlayer.xcodeproj
```

For project structure, testing, and packaging, see the [development guide](docs/development.md) (Chinese). To write plugins, see the [plugin development tutorial](docs/plugin-development.md) (Chinese) and [SDK reference](plugins/sdk/README.md) (Chinese).

## Acknowledgments

- [AMLL TTML Lyrics Database](https://github.com/Steve-xmh/amll-ttml-db): A source of word-by-word lyrics
- [SPlayer-Next](https://github.com/SPlayer-Dev/SPlayer-Next): A reference for some features and implementation logic

## Disclaimer

This project is not affiliated with any music platform. Copyright in each platform's content belongs to its respective owners.

## License

This project is licensed under the [GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE).
