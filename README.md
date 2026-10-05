<div align="center">

<img src="App/StarryPlayer/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" alt="Starry Player">

# Starry Player

高性能原生全特效 macOS 音乐播放器

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

</div>

## 特性

- 🎤 **逐字歌词**：随演唱逐字点亮，带翻译和注音，歌词自动匹配，也能放到菜单栏
- 🎯 **歌词校准**：歌词和演唱对不上时，一键分析人声自动校准偏移，每首歌单独记住
- 🌌 **律动背景**：流动的封面背景，跟着音乐节奏起伏
- 🎵 **多种来源**：网易云音乐、Jellyfin、Subsonic / Navidrome、本地音乐
- 🧩 **插件**：灵活的插件系统, 开发者可以实现任意自定义音源的接入.
- 🎧 **播放**：无缝播放、交叉淡化、ReplayGain、十段均衡器
- 🎙️ **唱歌模式**：消去原唱人声，跟着伴奏唱
- ⚡ **高性能**：Swift 原生开发，动画流畅、占用低

## 性能

目前大多数 Apple Music 风格的播放器都基于 Web 技术实现，全特效下相当吃性能，在 MacBook 上即使插着电也常常让风扇狂转。

Starry Player 使用 Swift 原生开发，针对 macOS 深度优化。以下为歌词页全特效稳定播放时，相对空闲状态增加的整机功耗：

| 实现 | 设备 | 稳态功耗增量 |
| --- | --- | --- |
| **Starry Player** | M4 Mac mini | **约 +0.8 W** |
| **Starry Player** | M5 Max（40 核 GPU） | **约 +2 ~ 4 W** ¹ |
| 网易云音乐 | M5 Max（40 核 GPU） | 约 +2 ~ 3 W |
| Apple Music | M5 Max（40 核 GPU） | 约 +5 W |
| Web 技术实现 | M5 Max（40 核 GPU） | 约 +15 ~ 25 W |

¹ M5 Max 的外围部件(比如更多统一内存)功耗更高，因此增量高于 M4。

同时播放页的CPU占用也比所有常用播放器更低

| 实现 | 设备 | 平均CPU占用 ¹ |
| --- | --- | --- |
| **Starry Player** | M5 Max（18 核 CPU） | 0.5% | 
| Apple Music | M5 Max（18 核 CPU）| 1% |
| 网易云音乐 | M5 Max（18 核 CPU）| 2% |
| Web 技术实现 | M5 Max（18 核 CPU）| 5% |

¹ 根据歌词换行频率不同, 不同歌曲可能会有波动

同样开满特效，功耗只有 Web 实现的几分之一，离电使用也不必关掉特效。

## 安装

需要 macOS 14 及以上。

安装包是 ad-hoc 签名，没有经过公证，第一次打开会被系统拦下：在 Finder 里右键 App 选“打开”，或者到 系统设置 › 隐私与安全性 里点“仍要打开”。

## 开发

```bash
brew install xcodegen node
scripts/bootstrap.sh       # 生成 StarryPlayer.xcodeproj
open StarryPlayer.xcodeproj
```

项目结构、测试和打包见 [开发文档](docs/development.md)，写插件见 [插件开发教程](docs/plugin-development.md) 和 [SDK 参考](plugins/sdk/README.md)。

## 致谢

- [AMLL TTML 歌词库](https://github.com/Steve-xmh/amll-ttml-db): 逐字歌词来源
- [SPlayer-Next](https://github.com/SPlayer-Dev/SPlayer-Next): 部分功能和逻辑参考

## 声明

本项目与音乐平台没有任何关联，各平台内容的版权归其所有者所有。

## 许可证

本项目采用 [GNU Affero General Public License v3.0（AGPL-3.0）](LICENSE) 许可证。
