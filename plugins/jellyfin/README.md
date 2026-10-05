# Jellyfin 插件

连接用户自己的 Jellyfin 服务器（10.9 及以上，按 12.1 实测）：曲库、专辑、歌手、资料库页（专辑、歌手、流派）、歌单、收藏、首页货架、私人 FM、播放、歌词和播放次数。作为 Starry Player 的插件（接口见 [`plugins/sdk`](../sdk/README.md)）。

随 App 打包：构建产物不入库：App 构建时由 `scripts/build-plugins.sh` 压缩打包进 `Resources/builtin`。不声明 `idNamespace`，歌曲落在来源 `plugin:moe.mrs4s.jellyfin` 下。服务器地址是用户填的，所以 `permissions.hosts` 是 `['*']`。

```bash
npm install          # 第一次
npm run build        # → build/plugins/jellyfin.js（仓库根目录下，压缩）
npm run watch        # 不压缩、改了就重建，开发调试用
npm run check        # 类型检查（../sdk/starry.d.ts）
npm test             # Node 里的单元测试（连同 ../common 的），服务器在 ../common/test/starry-mock.ts 里模拟
```

和 Subsonic 插件共用 [`../common`](../common) 里的代码（地址补全、歌词转换、私人 FM、音质档位）。构建产物不用提交，App 构建时会重新打包（`../common` 改了，两个插件都会重建）。宿主里的测试：`swift test --filter JellyfinPluginTests`（在 JSC 里跑打包后的插件，打桩一台 12.1 服务器）；联网测试连一台真服务器：

```bash
test/test-server.sh ~/jellyfin-test          # Docker 起一台 12.1 并建好测试曲库（需要 docker、ffmpeg）
JELLYFIN_LIVE=127.0.0.1:18096 JELLYFIN_USER=family JELLYFIN_PASSWORD=pw swift test --filter JellyfinPluginLive
JELLYFIN_LIVE=https://demo.jellyfin.org/stable swift test --filter "JellyfinPluginLive/(browses|lyrics)"   # 公开演示服务器，只读
```
