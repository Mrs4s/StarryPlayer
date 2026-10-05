# 开发

Swift 6 / SwiftUI + AppKit / AVFoundation。工程由 XcodeGen 从 `project.yml` 生成，功能模块都在本地 SwiftPM 包 `Packages/StarryKit` 里，App 只是外壳。

## 构建

```bash
brew install xcodegen node # 一次性（Node.js 用来构建内置插件）
scripts/bootstrap.sh       # 生成 StarryPlayer.xcodeproj
open StarryPlayer.xcodeproj
scripts/test.sh            # 运行 StarryKit 单元测试（先构建内置插件）
scripts/build-plugins.sh   # 构建内置插件到 build/plugins/（压缩）
scripts/build.sh           # 命令行构建到 build/Debug/StarryPlayer.app
scripts/package.sh         # 分别构建 arm64 / x86_64 Release + ad-hoc 签名，输出 build/dist/StarryPlayer-<版本>-<架构>.zip/.dmg
```

`*.xcodeproj` 不入库，改动 `project.yml` 后重新生成。要加自己的设置（签名团队、额外的源码），在根目录放一个 `project.local.yml`（不入库）：`include: [project.yml]` 再写要加的部分，`scripts/bootstrap.sh` 会优先用它；打包脚本只用 `project.yml`。

## 人声分离模型

唱歌（人声消除）默认用内置分离模型 `starry-karaoke-zh`（针对中文歌曲微调过）。模型在 `App/StarryPlayer/Resources/Models/`，构建时整个目录复制到 `StarryPlayer.app/Contents/Resources/Models/`，保留 plist、MIL 与 `weights/` 的相对路径。也可以在 设置 › 播放 › 唱歌 › 分离模型 里另外指定一个 AUSoundIsolation 格式的音乐分离模型文件夹（plist + 网络文件 + weights）；都没有时退回系统的高质量人声隔离（macOS 15 起）。

## 测试

StarryKit 的单元测试用 `scripts/test.sh` 运行。应用层媒体控制联动测试位于 `App/StarryPlayer/Tests`，可在 Xcode 中用 `StarryPlayer` scheme 执行 Test（⌘U），或运行 `xcodebuild -project StarryPlayer.xcodeproj -scheme StarryPlayer -destination 'platform=macOS' test`。

本地曲库测试需要 PATH 中的 Python 3 和 ffmpeg（可用 `brew install python ffmpeg` 安装）。首次读取样本时会调用 `scripts/local-files/make-corpus.py`，在系统临时目录生成一组 1 秒合成音频，同一测试进程共用；仓库不保存这些音频，也不将它们声明为打包资源。单独运行：`swift test --package-path Packages/StarryKit --filter LocalLibraryTests`。

播放引擎的 Vorbis / Opus 测试同样在临时目录生成合成音频，需要 PATH 中的 ffmpeg（含 libvorbis 和 libopus 编码器），不附带音频资源。单独运行：`swift test --package-path Packages/StarryKit --filter 'OggVorbisTests|VorbisTranscodeEngineTests'`。

### 联网测试

```bash
cd Packages/StarryKit && LYRICS_LIVE=1 swift test --filter LyricsLive     # AMLL TTML 库命中与快速未命中
cd Packages/StarryKit && PLUGINS_LIVE=1 swift test --filter ExamplePluginLive    # 示例插件（LRCLIB、Audius）
```

Jellyfin、Subsonic 的联网测试和本地测试服务器见各自的 README。

## 插件

App 每次构建时由 `scripts/build-plugins.sh` 编译、压缩，打包进 `Resources/builtin`（需要 Node.js，第一次会自动 `npm ci`）。单独构建或检查一个插件：

```bash
cd plugins/netease && npm install   # 第一次（其他插件工程同理）
npm run build && npm run check      # → build/plugins/netease.js；Jellyfin、Subsonic 另有 npm test
npm run watch                       # 不压缩、改了就重建，在开发者设置里加载它调试
```

开发插件时，在 设置 › 插件 › 开发者（打开高级设置后可见）里添加插件所在的文件夹或 .js 文件，就能直接加载、在 Safari Web Inspector 里调试，并记录每次调用。从零开始的步骤、完整示例、测试与发布流程见 [插件开发教程](plugin-development.md)，接口简要参考见 [SDK 说明](../plugins/sdk/README.md)。
