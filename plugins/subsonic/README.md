# Subsonic 插件

连接用户自己的 Subsonic / OpenSubsonic 服务器：Navidrome、gonic、LMS、Airsonic-Advanced、Ampache、Nextcloud Music 等。功能包括曲库、专辑、歌手、资料库页（专辑、歌手、流派）、歌单、收藏、首页货架、私人 FM、播放、歌词和播放次数。

它是 Starry Player 的插件（接口见 [`plugins/sdk`](../sdk/README.md)）。

随 App 打包：
- 构建产物不入库：App 构建时由 `scripts/build-plugins.sh` 压缩打包进 `Resources/builtin`。
- 不声明 `idNamespace`，歌曲落在来源 `plugin:moe.mrs4s.subsonic` 下。
- 服务器地址是用户填的，所以 `permissions.hosts` 是 `['*']`。
- 和 Jellyfin 插件共用 [`../common`](../common) 里的代码。

```bash
npm install          # 第一次
npm run build        # → build/plugins/subsonic.js（仓库根目录下，压缩）
npm run watch        # 不压缩、改了就重建，开发调试用
npm run check        # 类型检查（../sdk/starry.d.ts）
npm test             # Node 里的单元测试（连同 ../common 的），服务器在 ../common/test/starry-mock.ts 里模拟
```

构建产物不用提交，App 构建时会重新打包（`../common` 改了，两个插件都会重建）。

宿主里的测试：`swift test --filter SubsonicPluginTests`，在 JSC 里跑打包后的插件，打桩一台 Navidrome。

联网测试连真服务器：

```bash
test/test-servers.sh ~/subsonic-test          # Docker 起 Navidrome、gonic、Airsonic-Advanced、LMS，并生成测试曲库（需要 docker、ffmpeg、python3）
SUBSONIC_LIVE=127.0.0.1:14533 SUBSONIC_USER=family SUBSONIC_PASSWORD=pw swift test --filter SubsonicPluginLive
SUBSONIC_WRITE=1 …                            # 再加上编辑歌单（建一个测试歌单，最后删掉）
SUBSONIC_LIVE=https://demo.navidrome.org swift test --filter "SubsonicPluginLiveTests/(browses|lyrics)"   # 公开演示服务器 demo / demo，只读
```
