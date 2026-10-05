# Starry Player 插件开发

一个插件就是一个 JavaScript 文件，可以给播放器加一个**音源**（搜索、播放、歌手 / 专辑 / 歌单页、首页货架、登录与曲库、评论），也可以加一个**歌词源**，或者两者都加。完整的接口与类型定义在 [`starry.d.ts`](starry.d.ts)。

第一次开发插件，建议先阅读 [插件开发教程](../../docs/plugin-development.md)：从离线歌词示例开始，搭建 TypeScript 音源工程，再完成调试、测试和发布。本页保留接口与常用能力的简要参考。

## 最小的歌词源

```js
// @ts-check
/// <reference path="starry.d.ts" />

/** @type {import('./starry').Plugin} */
module.exports = {
  id: 'dev.example.lyrics',          // 反向域名，发布后不要改
  name: '示例歌词',
  version: '1.0.0',
  apiVersion: 1,
  permissions: { hosts: ['lyrics.example.com'] },  // 只能访问这里列出的域名

  lyrics: {
    async search(keyword) {
      const { body } = await starry.http.get('https://lyrics.example.com/search', { query: { q: keyword }, responseType: 'json' });
      return body.map((song) => ({ id: String(song.id), title: song.title, artists: [song.artist], duration: song.seconds }));
    },
    async fetch(song) {
      const { status, body } = await starry.http.get(`https://lyrics.example.com/lrc/${song.id}`);
      return status === 200 ? { format: 'lrc', body } : null;
    },
  },
};
```

“这首歌对应哪条搜索结果”由播放器按标题、歌手、时长判断，结果也由播放器缓存，插件只管搜和取。

平台的歌在 [AMLL TTML 歌词库](https://github.com/Steve-xmh/amll-ttml-db) 里有逐字歌词时，在 `lyrics` 里写上 `ttmlFolder`（库里的目录名，比如 `'ncm-lyrics'`）：播放器用匹配到的歌的 `id`（有 `mid` 时先用 `mid`），以及这个平台自己的歌的 id，到这个目录里查。

音源知道某首歌在 AMLL 库里的条目时（别的平台的 id、文件标签里存的 id），在这首歌上写 `ttml: [{ folder: 'am-lyrics', id: '…' }]`：这些条目按顺序最先查，随歌一起保存。都没有的歌（本地音乐、多数自建服务器）就靠歌词源匹配到的歌去查。

## 最小的音源

```js
module.exports = {
  id: 'dev.example.music',
  name: '示例音乐',
  version: '1.0.0',
  apiVersion: 1,
  permissions: { hosts: ['api.example.com'] },

  source: {
    async search(query, kind, page) {
      const { body } = await starry.http.get('https://api.example.com/search', { query: { q: query, offset: page.offset, limit: page.limit }, responseType: 'json' });
      return { songs: body.items.map((item) => ({ id: item.id, title: item.title, artists: [{ id: item.artistId, name: item.artist }], duration: item.seconds, artwork: item.cover })) };
    },
    async resolve(track) {
      const { body } = await starry.http.get(`https://api.example.com/play/${track.id}`, { responseType: 'json' });
      return { url: body.url, expiresIn: 600 };
    },
  },
};
```

导出了哪些函数，播放器就显示哪些功能：没有 `album` 就不会出现专辑页，没有 `search` 就不能在这个来源里搜索。

## 多文件工程

简单的插件写一个 `.js` 就够了。大一些的按 TypeScript 工程来写，用 esbuild 打成一个文件交给播放器，[`../netease`](../netease) 和 [`../jellyfin`](../jellyfin) 就是这样：

```
my-plugin/
  package.json     # devDependencies: esbuild, typescript
  tsconfig.json    # include: ["src", "<sdk>/starry.d.ts"]，lib 只要 ES2022（没有 DOM）
  src/index.ts     # export default { id, name, … } satisfies Plugin
  src/*.ts         # 按功能分模块，npm 包也可以直接 import
```

```bash
esbuild src/index.ts --bundle --format=cjs --platform=neutral --target=safari17 --outfile=dist/my-plugin.js
tsc --noEmit
```

- `export default` 打包后是 `module.exports.default`，播放器认得。
- 运行环境是 JavaScriptCore（macOS 14 起相当于 Safari 17），没有 Node 的模块；网络、加解密、压缩都走 `starry`。
- 不碰网络的逻辑（解析、加解密）可以在 Node 里测：给 `globalThis.starry` 做个模拟（见 `../common/test/starry-mock.ts`，它还能按地址伪造服务器），再用 `node --test` 跑。

## 登录、曲库、评论

- `account` 组（和 `source` 一起导出）：`refresh`、`logout` 必需；扫码（`beginQRLogin` / `pollQRLogin`，可以长轮询）、Cookie、账号密码、验证码按 `methods` 声明。会话由插件自己存在 `starry.storage`；每个登录函数返回资料 `{ userID, nickname, avatar?, isVIP? }`，`refresh` 返回资料或 null，会话失效时 `throw starry.error('loginExpired')`。要支持多账号切换，导出 `exportCredentials` / `restoreCredentials` / `signOutLocally` 并写 `multipleAccounts: true`。
- 自建服务器（Jellyfin、Subsonic 这类；两者共用的代码在 `../common`：地址补全、歌词转 TTML / LRC、私人 FM、音质档位）：
  - 写 `server: { placeholder }` 并导出 `connect(address)`，登录窗口就会先问服务器地址；
  - `passwordOptional: true` 允许空密码；
  - `methods` 里加 `'code'`，并写 `codeLogin: { title, hint }`、导出 `beginCodeLogin` / `pollCodeLogin`，就有“在已登录设备上输入验证码”的登录方式；
  - 资料里的 `detail` 写服务器名，多台服务器作为多个账号管理；
  - 服务器地址由用户填写，`permissions.hosts` 只能写 `['*']`。
- `source` 里的 `userPlaylists`、`likedTrackIDs`、`setLiked`、`setCollected`、`dailyRecommendations`、`personalFM`、`allMedia`（所有媒体，按页取，可以返回 `{ songs, total, hasMore, nextOffset }`）、`homeShelves`（首页上自己命名的货架）、`comments` / `commentThread` / `replies`、`reportPlayback`：导出了哪个，界面就有哪个功能。
- 资料库页（侧栏的专辑、歌手、流派，适合用户自己的曲库）：`libraryAlbums(sort, genre, page)`、`libraryArtists(page)`、`libraryGenres()`，导出哪个就有哪一页（流派要和专辑一起）；`albumSorts` 写支持的专辑排序（`'title'`、`'artist'`、`'year'`、`'recentlyAdded'`），第一个是默认。
- 音量均衡：`resolve` 的结果可以带 `gain: { trackGain?, trackPeak?, albumGain?, albumPeak? }`，即把歌曲或专辑调到 −18 LUFS 要加减的 dB（和 ReplayGain 2.0 一样），峰值以 1 为满幅、知道才给；用户打开音量均衡时，播放器按它调音量。
- 服务器边转码边发的流（没有长度、不支持 Range），`resolve` 返回时带上 `transcoded: true`：播放器会先下完再播。
- 个人主页：`user`（必需）、`playlistsOfUser`，再加 `listeningRanking`（听歌排行）、`follows` / `followers` / `setUserFollowed`（关注 / 粉丝）就有对应的 tab；`searchKinds` 里写 `'user'` 才能搜用户。对方不公开时抛 `starry.error('rankingHidden')` / `starry.error('followsHidden')`。
- `searchOverview`：一次给出综合页（最佳匹配和各类的前几条）；不写的话播放器分别搜四种拼出来。

## 加密的音频

平台给的是加密文件时，`resolve` 返回 `{ url, …, decrypt: { 解密要的参数 } }`，再导出 `source.decryptor(params)`，它返回 `(bytes, offset) => void`：原地解密一块数据，`offset` 是这块在文件里的位置。播放器边下载边调用它，存下来的是明文。这个函数在单独的 JS 环境里同步运行（没有网络、存储、定时器），要快：只用 typed array 和整数运算。

## 代替内置平台

`idNamespace: 'qqmusic'` 之类表示插件的 id 就是这个平台的 id：插件接管这个平台，之前为它保存的歌曲、账号、设置、歌词缓存都归插件。一个平台可以有一个音源和一个歌词源，来自同一个插件或两个插件：只导出 `lyrics` 的插件声明了平台，就只接管这个平台的歌词（来源顺序里的那一项，这个平台的歌按 id 直接取歌词），设置仍是它自己的。网易云（音源和歌词）、QQ音乐和酷狗（只有歌词）都由自带的插件声明，装一个同平台、同类的插件就替掉自带的。

## 安装与调试

- 安装：设置 › 插件 › 从文件安装 / 从网址安装（从网址装的以后可以一键更新）；或者把 `.js` 文件放进 `~/Library/Application Support/moe.mrs4s.starry-player/Plugins/`，再点“重新加载”。同 id 时它优先于播放器自带的插件。开关、移除也在这一页，都不用重启。
- 开发中的插件（设置 › 插件 › 开发者，打开高级设置后可见；下面两项也在那里）：添加插件所在的文件夹或单个 .js 文件，不用复制或安装；改了文件后点“重新加载”。这里的插件优先于已安装和自带的同 id 插件。
- 记录插件调用：每次调用的参数、耗时和结果写进系统日志（“控制台”里搜索 plugin），同时打印到 stderr（从终端启动 `StarryPlayer.app/Contents/MacOS/StarryPlayer` 时可见）。
- 允许调试插件：Safari › 开发 › 本机 里会列出“插件：<名字>”，可以下断点、看 `console.log`。
- 加载失败的原因写在系统日志里：`log stream --predicate 'subsystem == "moe.mrs4s.starry-player" AND category == "plugin"'`。
- 示例：[`examples/lrclib.js`](../examples/lrclib.js)（歌词）、[`examples/audius.js`](../examples/audius.js)（音源）；完整的工程：[`netease`](../netease)（音源 + 账号 + 个人主页 + 听歌上报 + 歌词）。

## 可以用什么

- `starry.http`：请求只能发往 `permissions.hosts` 里的域名（`*.example.com` 包括子域名），重定向也一样。HTTP 状态码不会抛错，网络失败才会（`code` 为 `network` / `timeout`）。每个插件有自己的 Cookie；`cookies: false` 时既不带也不存，响应的 `cookies` 是服务器设的值（删掉的 Cookie 是空字符串）。`proxy: 'socks5://主机:端口'` 让这次请求走代理。
- `starry.app`：播放器版本、系统版本、`arch`、机型 `model`、电脑名 `deviceName`、能播的格式 `formats`（有没有 `ogg`、`eac3`）。
- `starry.crypto`：md5 / sha1 / sha256 / sha512、HMAC、AES（ECB / CBC / GCM）、DES、3DES、RSA 公钥加密、随机字节。
- `starry.encoding`（utf8 / hex / base64）、`starry.zlib`（inflate / deflate）。
- `starry.storage`：按插件隔离、重启后还在的键值存储，值要能转成 JSON。
- `starry.setWebPages(pages)`：网页地址要连上服务器才知道时，用它换掉 `source.webPages`；`null` 恢复原样。这个设置不跨启动保存。
- `starry.settings`：插件在 `settings` 里声明的设置项的当前值；改动后会调用 `onSettingsChanged`。
- 标准对象：`console`、`setTimeout` / `setInterval`、`TextEncoder` / `TextDecoder`（含 gbk、big5）、`atob` / `btoa`、`URL`、`URLSearchParams`、`fetch`（子集）。
- 没有 `require`、文件系统和子进程。要用 npm 包，用 esbuild 打成一个文件：`esbuild src/index.ts --bundle --format=cjs --platform=neutral --outfile=my-plugin.js`。

## 出错时

用 `throw starry.error(code, message)` 告诉播放器发生了什么。`vipRequired`、`loginExpired`、`unavailableInRegion`、`trialOnly`、`sourceUnreachable` 会显示成播放器自己的提示；`rankingHidden`、`followsHidden` 让个人主页显示“不公开”；`notSupported` 表示这项功能没有；`network` / `timeout` / `rateLimited` 是网络问题。其他异常显示为“插件名：message”。每次调用最多 30 秒（扫码轮询 100 秒），一次同步执行最多 5 秒。
