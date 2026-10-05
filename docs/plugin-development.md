# 插件开发教程

Starry Player 的插件是一个 JavaScript 文件，由播放器的 JavaScriptCore 执行。插件可以提供音源、歌词源，也可以同时提供两者；界面、播放队列、音频下载和歌词匹配由播放器负责，插件负责把平台接口转换成播放器认识的数据。

本文从一个不需要联网的歌词插件开始，再搭建可构建、可测试的 TypeScript 音源工程。接口以当前 **API version 1** 为准，完整签名见 [`plugins/sdk/starry.d.ts`](../plugins/sdk/starry.d.ts)，简要参考见 [SDK 说明](../plugins/sdk/README.md)。

## 目录

- [1. 运行环境与插件结构](#1-运行环境与插件结构)
- [2. 第一个插件：离线歌词源](#2-第一个插件离线歌词源)
- [3. 创建 TypeScript 工程](#3-创建-typescript-工程)
- [4. 接入搜索与播放](#4-接入搜索与播放)
- [5. 网络请求与权限](#5-网络请求与权限)
- [6. 歌词接入与逐字歌词](#6-歌词接入与逐字歌词)
- [7. 设置、存储与生命周期](#7-设置存储与生命周期)
- [8. 登录与多账号](#8-登录与多账号)
- [9. 扩展音源功能](#9-扩展音源功能)
- [10. 高级播放能力](#10-高级播放能力)
- [11. 调试与错误处理](#11-调试与错误处理)
- [12. 自动化验证](#12-自动化验证)
- [13. 打包、安装与更新](#13-打包安装与更新)
- [14. 继续阅读](#14-继续阅读)

## 1. 运行环境与插件结构

### 1.1 先确定要实现什么

| 插件类型 | 导出的分组 | 必需函数 | 典型用途 |
| --- | --- | --- | --- |
| 音源 | `source` | `resolve` | 搜索音乐并取得播放地址 |
| 歌词源 | `lyrics` | `search`、`fetch` | 为各个音源的歌曲匹配歌词 |
| 带登录的音源 | `source`、`account` | 上述音源函数，以及 `refresh`、`logout` | 自建服务器、登录后访问收藏 |
| 音源及歌词源 | `source`、`lyrics`，可加 `account` | 各分组的必需函数 | 完整接入一个音乐平台 |

`account` 不能单独导出，必须搭配 `source`。不支持的可选功能直接省略，不要为了占位导出空函数：播放器会根据函数和相关声明决定开放哪些功能。

### 1.2 插件清单

清单就是导出对象上的字段，不需要额外的 `manifest.json`。

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定、唯一的标识，推荐反向域名，如 `dev.example.music`。只能用小写字母、数字及分隔符 `. _ -`，分隔符不能连续或出现在首尾，长度 1～100；发布后不要改 |
| `name` | 在播放器里显示的名称，不能为空 |
| `version` | 非空版本字符串，推荐使用 `1.0.0` 形式；与 npm 工程版本保持一致 |
| `apiVersion` | 当前填写数字 `1` |
| `permissions.hosts` | 插件 HTTP 请求允许访问的域名；不联网时写 `[]` |
| `author`、`description`、`homepage` | 可选的作者、介绍、项目主页 |
| `icon` | 可选的 SF Symbol 名称，如 `music.note`、`text.quote`、`server.rack` |
| `idNamespace` | 可选的平台身份，仅支持 `netease`、`qqmusic`、`kugou`，详见[发布章节](#133-插件-id-与平台身份) |
| `settings`、`onSettingsChanged` | 可选的设置声明及变更回调 |

### 1.3 JavaScriptCore 和 Node.js 的区别

宿主提供 `Promise`、typed array 等 JavaScript 标准能力，以及 `console`、定时器、`TextEncoder` / `TextDecoder`、`URL` / `URLSearchParams`、`Headers`、`atob` / `btoa` 和 `fetch` 子集。网络、持久化、加密与压缩通过全局 `starry` 对象访问。

插件里没有 DOM、Node.js 的 `require`、`process`、`Buffer`、文件系统或子进程。Node.js 只是本地的构建和测试工具。npm 依赖必须能在此环境中运行，并被打包进最终文件；打包成功并不代表依赖需要的运行时 API 都存在。

普通 JavaScript 使用 `module.exports = { ... }`。TypeScript 工程可以使用 `import` / `export default`，再打包成 CommonJS；宿主也识别打包后的 `module.exports.default`。不要直接加载 `.ts` 或仍然包含外部模块依赖的产物。

## 2. 第一个插件：离线歌词源

先用固定数据验证“加载 → 搜索 → 获取歌词”，避免一开始就受远端接口影响。

在仓库根目录执行：

```bash
mkdir -p plugins/tutorial-lyrics
```

创建 `plugins/tutorial-lyrics/demo.js`：

```js
// @ts-check
/// <reference path="../sdk/starry.d.ts" />

/** @type {import('../sdk/starry').Plugin} */
module.exports = {
  id: 'dev.example.tutorial-lyrics',
  name: '教程歌词',
  version: '1.0.0',
  apiVersion: 1,
  description: '用于验证插件调用的离线示例',
  icon: 'text.quote',
  permissions: { hosts: [] },

  lyrics: {
    detail: '离线 LRC 示例',
    async search(keyword) {
      if (!keyword.includes('星光练习曲')) return [];
      return [{
        id: 'demo-1',
        title: '星光练习曲',
        artists: ['示例歌手'],
        duration: 20,
      }];
    },
    async fetch(song) {
      if (song.id !== 'demo-1') return null;
      return {
        format: 'lrc',
        body: '[00:00.00]星光落在窗前\n[00:05.00]音乐慢慢响起\n[00:10.00]让这一刻继续',
      };
    },
  },
};
```

打开播放器设置并开启高级设置，在 **设置 › 插件 › 开发者 › 开发中的插件** 添加 `demo.js`，或添加它所在的 `tutorial-lyrics` 文件夹。插件列表中应出现“教程歌词”，歌词来源设置中也会出现它。

播放一首标题为“星光练习曲”、歌手为“示例歌手”、时长约 20 秒的测试音频，并在歌词来源设置中启用此源，即可验证自动匹配。没有这样的音频时，也可以先在调试器中直接调用 `module.exports.lyrics.search('星光练习曲')` 和 `module.exports.lyrics.fetch({ id: 'demo-1' })`，确认候选结果和 LRC 文本。

开发文件夹只扫描**当前层级的 `.js` 文件**，不会递归进入 `src`、`dist`。修改文件后需要点击“重新加载”；播放器没有自动监听文件变化。

## 3. 创建 TypeScript 工程

以下路径均以本仓库为基础。若插件放在独立仓库，将 SDK 的 `starry.d.ts` 复制到自己的 `sdk/`，并相应修改 `include` 和类型导入路径即可；它只是类型声明，不是需要安装的运行时库。

### 3.1 目录与依赖

在仓库根目录执行：

```bash
mkdir -p plugins/tutorial-source/src plugins/tutorial-source/test
cd plugins/tutorial-source
npm init -y
npm install --save-dev esbuild typescript
```

工程结构：

```text
plugins/tutorial-source/
  package.json
  package-lock.json
  tsconfig.json
  src/
    models.ts       # 平台数据转为 SDK 模型
    index.ts        # 清单、搜索和播放
  test/
    plugin.test.cjs  # 用模拟接口验证构建产物
  dist/
    tutorial.js     # 最终交给播放器的文件
```

保留 npm 写入的 `devDependencies`，将 `package.json` 中的 `scripts` 替换为：

```json
{
  "bundle": "esbuild src/index.ts --bundle --format=cjs --platform=neutral --target=safari17 --charset=utf8 --outfile=dist/tutorial.js",
  "build": "npm run bundle -- --minify",
  "watch": "npm run bundle -- --watch",
  "check": "tsc --noEmit",
  "test": "npm run build && node --test test/plugin.test.cjs"
}
```

这里展示的是 `scripts` 的值，不是完整的 `package.json`。最终产物始终是单文件；`watch` 使用未压缩代码，便于下断点。

### 3.2 TypeScript 配置

创建 `tsconfig.json`：

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": [],
    "strict": true,
    "noUnusedLocals": true,
    "noImplicitReturns": true,
    "isolatedModules": true,
    "skipLibCheck": false,
    "noEmit": true
  },
  "include": ["src", "../sdk/starry.d.ts"]
}
```

不要添加 `DOM` 或 Node 类型来消除插件源码的报错，否则容易误用宿主没有的 API。测试文件在 Node 中运行，不放进这份插件源码的 `include`。

## 4. 接入搜索与播放

本节的 `https://api.example.com` 是**接口占位符，不是真实音乐服务**。示例假定搜索接口返回 `{ items, total, hasMore, nextOffset }`，播放接口返回 `{ url, expiresIn }`。你可以先用[自动化验证](#12-自动化验证)中的模拟响应跑通工程，再替换为目标平台的地址、字段和认证逻辑。

### 4.1 数据映射

创建 `src/models.ts`：

```ts
import type { Track } from '../../sdk/starry';

export interface APISong {
  id: string | number;
  title: string;
  artist: { id: string | number; name: string };
  durationMs: number;
  cover?: string;
}

export function toTrack(item: APISong): Track {
  return {
    id: String(item.id),
    title: item.title,
    artists: [{ id: String(item.artist.id), name: item.artist.name }],
    duration: item.durationMs / 1000,
    artwork: item.cover,
    tiers: ['standard'],
  };
}
```

模型中的歌曲、歌手、专辑、歌单 ID 都应转换成稳定的字符串。`Track.duration` 使用**秒**，不要直接传平台的毫秒值；`DateValue` 则是 Unix 毫秒时间戳或 ISO 8601 字符串。

`Track.id` 必须足以在重启后重新找到歌曲。队列、收藏和歌词绑定会保存这个 ID，不能依赖某次搜索留下的内存对象来播放。封面 `artwork` 可以是 URL 字符串，也可以是带 `url`、`sizedTemplate`、`sizeSteps` 的对象；模板用 `{width}`、`{height}` 表示尺寸。

### 4.2 导出完整音源

创建 `src/index.ts`：

```ts
import type { HttpRequest, Plugin } from '../../sdk/starry';
import { toTrack, type APISong } from './models';

const API = 'https://api.example.com';

async function getJSON<T>(path: string, query?: HttpRequest['query']): Promise<T> {
  const response = await starry.http.get<T>(`${API}${path}`, {
    query,
    responseType: 'json',
    timeout: 10,
  });
  if (response.status === 401) throw starry.error('loginExpired');
  if (response.status === 429) throw starry.error('rateLimited', '请求过于频繁，请稍后重试');
  if (response.status < 200 || response.status >= 300) {
    throw starry.error('network', `接口返回 HTTP ${response.status}`);
  }
  return response.body;
}

interface SearchResponse {
  items: APISong[];
  total: number;
  hasMore: boolean;
  nextOffset?: number;
}

const plugin = {
  id: 'dev.example.tutorial-source',
  name: '教程音源',
  version: '1.0.0',
  apiVersion: 1,
  icon: 'music.note',
  permissions: { hosts: ['api.example.com'] },

  source: {
    searchKinds: ['song'],
    qualityTiers: [{ id: 'standard', name: '标准', level: 'sq' }],

    async search(query, kind, page) {
      if (kind !== 'song') return {};
      const result = await getJSON<SearchResponse>('/songs', {
        q: query,
        offset: page.offset,
        limit: page.limit,
      });
      return {
        songs: result.items.map(toTrack),
        total: result.total,
        hasMore: result.hasMore,
        nextOffset: result.nextOffset,
      };
    },

    async resolve(track, tier) {
      const result = await getJSON<{ url: string; expiresIn: number }>(
        `/songs/${encodeURIComponent(track.id)}/stream`,
        { quality: tier.id },
      );
      if (!result.url) throw starry.error('notSupported', '这首歌没有可用的播放地址');
      return {
        url: result.url,
        container: 'mp3',
        tier: 'standard',
        expiresIn: result.expiresIn,
      };
    },
  },
} satisfies Plugin;

export default plugin;
```

在 `plugins/tutorial-source` 中运行：

```bash
npm run check
npm run build
npm run watch
```

`watch` 会持续运行。将 **`dist/tutorial.js` 或 `dist/`** 添加到播放器的开发插件路径，不要添加工程根目录。后续每次保存源文件，先等 esbuild 完成，再在播放器中重新加载。

泛型 `getJSON<T>` 只提供编译时类型，不会校验远端 JSON。实际接入时要在映射层检查响应形状，处理字段缺失、不可播放项目和服务端返回的业务错误；不要把所有 403 都当成会员限制，应根据平台的业务码区分原因。

### 4.3 搜索与分页约定

`source.search(query, kind, page)` 中，`kind` 是 `song`、`album`、`artist`、`playlist` 或 `user`；`page` 是 `{ offset, limit }`，`offset` 从 0 开始。返回对应的 `songs`、`albums`、`artists`、`playlists`、`users` 字段，并用 `searchKinds` 声明实际支持的类别。搜索用户还需要实现 `source.user`。

如果接口使用页码，需要把 `offset` 转成平台的分页参数。如果接口返回 20 条原始数据，你过滤后只留下 12 条，下一页仍应从原始数据的下一位置开始；显式返回 `nextOffset`，不要用过滤后的数组长度推进。`hasMore` 和 `total` 也应按接口真实语义填写，结束时返回 `hasMore: false`。

### 4.4 播放地址与音质

`resolve(track, tier)` 在需要播放地址时调用，返回 `PlayableAsset`：

| 字段 | 用法 |
| --- | --- |
| `url` | 音频的 HTTP(S) 地址；应尽可能在此时获取新鲜的签名 URL |
| `headers` | 下载音频需要的请求头，如 `Authorization`、`Referer`；解析接口用的请求头不会自动成为这里的请求头 |
| `container` | 实际容器，如 `mp3`、`flac`、`mp4`、`hls`；缺省时尝试从 URL 后缀判断 |
| `tier` | 实际返回的音质档位 ID；发生降级时也要准确返回 |
| `expiresIn` | 地址从现在起的有效秒数，未提供时为 1200 秒，当前宿主会将最小缓存有效期设为 30 秒；不要填写 Unix 时间戳 |
| `trial` | 是否只有试听片段 |
| `info` | 可选的码率、采样率、位深、声道数、文件大小；例如 `bitrate: 320000`，单位为 bit/s |
| `supportsOverlap` | 是否允许与下一首重叠播放 |

`qualityTiers[].level` 使用 `lq`、`sq`、`hq`、`lossless`、`hi-res`，用于把用户全局音质偏好映射到平台档位。`Track.tiers` 填当前歌曲可用的档位 ID。上面的例子只有一个 MP3 档位；实际平台支持多种格式时，应一并调整 `container` 和音质映射。

## 5. 网络请求与权限

### 5.1 允许访问哪些地址

`starry.http` 和宿主的 `fetch` 子集都受 `permissions.hosts` 限制，重定向的目标域名也会检查。

| 声明 | 范围 |
| --- | --- |
| `api.example.com` | 仅此主机，不包括其子域名 |
| `*.example.com` | `example.com` 本身及其子域名 |
| `*` | 任意 HTTP(S) 主机，适用于用户自行填写地址的服务器插件 |
| `[]` | 不允许插件发起网络请求 |

这里写主机名，不写协议、路径或端口。把插件请求及其重定向真正用到的主机列出来。仅向用户提供一个 `url` 与插件主动通过 `starry.http` 请求它是不同的调用路径：音频 URL 交给播放器下载；插件自己请求媒体信息或歌词下载地址时，仍需相应的主机权限。

### 5.2 请求与响应

推荐优先使用 `starry.http`，它提供查询参数、JSON、表单、Cookie 和代理选项：

```ts
// JSON 请求；body 为普通对象时，post 自动按 JSON 发送。
const login = await starry.http.post('https://api.example.com/login', {
  username: 'demo',
  password: '从登录函数的参数取得',
}, { responseType: 'json' });

// 表单请求。
const formResponse = await starry.http.request({
  url: 'https://api.example.com/form',
  method: 'POST',
  form: { key: 'value' },
  responseType: 'text',
});

// 二进制响应可交给编码、解密或解压接口。
const binary = await starry.http.get<Uint8Array>('https://api.example.com/lyrics', {
  responseType: 'bytes',
  cookies: false,
});
```

这些是独立的调用片段，应放进相应函数，不要在模块顶层执行。`responseType` 默认为 `text`；响应包含 `status`、小写键名的 `headers`、`cookies`、重定向后的 `url` 和 `body`。HTTP 404、401、500 等状态不会自动抛错，要显式检查；网络连接失败或超时则会抛错。

每个插件有独立的 Cookie 环境。`cookies: false` 表示仅发送显式给出的 `Cookie` 头，并且不保存响应 Cookie；`response.cookies` 是本次服务器设置的值，删除的 Cookie 对应空字符串。需要跨重启或多账号恢复的会话由插件显式存储，不要只依赖内存中的 Cookie 状态。

`timeout` 以秒为单位，默认 15。单次插件调用还有整体超时，不能靠增大 HTTP 超时无限延长调用。`proxy` 可按请求指定 `http://主机:端口` 或 `socks5://主机:端口`；`redirect: 'manual'` 可用于自行处理跳转。

## 6. 歌词接入与逐字歌词

### 6.1 搜索和获取是两个独立步骤

`lyrics.search(keyword)` 返回 `LyricsSong[]`，与音源的 `Track[]` 不同：

| 字段 | 类型与用途 |
| --- | --- |
| `id` | 字符串 ID，用于下一步获取歌词 |
| `mid` | 可选的第二种平台 ID；AMLL 查询优先用它 |
| `title` | 歌曲标题 |
| `artists` | **字符串数组**，不是音源的 `{ id, name }[]` |
| `album` | 可选的专辑名字符串 |
| `duration` | 可选的时长，单位秒 |

播放器根据标题、歌手、时长匹配候选并缓存结果，插件只需返回真实、可辨认的数据。`fetch(song)` 必须能仅凭 `id`（以及平台需要时的 `mid`）获取歌词：同平台歌曲可能按 ID 直接获取，重启后也可能不再先调用 `search`。可缓存搜索结果来减少请求，但缓存未命中时必须能再次请求。

没有歌词时返回 `null`，搜索没有结果时返回 `[]`。网络失败应抛错，不要伪装成“没有歌词”，否则不利于区分无结果和服务故障。

### 6.2 返回格式

`fetch` 返回 `{ format, body, translation?, romanization? }`：

- `format` 支持 `lrc`、`ttml`、`yrc`、`qrc`、`krc`。
- `body` 是明文字符串。加密的 QRC、KRC 要先解密、解压，再交给宿主解析。
- `translation`、`romanization` 可携带独立的歌词文本；普通 LRC 接入可传带时间戳的翻译或罗马音 LRC。
- 只有没有时间戳的纯文本时，不要假装成同步歌词；可返回 `null` 让播放器继续尝试其他来源。

服务端提供逐行或逐字结构化数据时，可以参考 [`plugins/common/lyrics.ts`](../plugins/common/lyrics.ts) 将它转换为 LRC / TTML。完整联网歌词插件可参考 [LRCLIB 示例](../plugins/examples/lrclib.js)。

### 6.3 AMLL TTML 歌词库

平台 ID 与 AMLL TTML 数据库一致时，在 `lyrics` 上声明 `ttmlFolder`，例如 `ncm-lyrics`。播放器会用匹配结果的 `mid`（优先）或 `id`，以及平台自己的歌曲 ID 查询该目录。

如果音源知道某首歌对应的其他平台条目，可在 `Track` 上返回 `ttml: [{ folder: 'am-lyrics', id: '对应条目 ID' }]`。这些条目随歌曲保存，并按顺序优先尝试。不要填未经确认的 ID，也不必为了这个能力把本地文件或自建服务器伪装成某个内置平台。

## 7. 设置、存储与生命周期

### 7.1 声明设置

在插件导出对象中增加 `settings`，例如：

```ts
import type { SettingsSection } from '../../sdk/starry';

const settings: SettingsSection[] = [{
  id: 'general',
  title: '接口选项',
  settings: [
    { key: 'includeTranslation', title: '加载翻译', type: 'toggle', default: true },
    { key: 'token', title: '访问令牌', type: 'text', secure: true, default: '' },
    {
      key: 'region', title: '区域', type: 'choice', default: 'global',
      choices: [{ value: 'global', title: '全球' }, { value: 'local', title: '本地' }],
    },
  ],
}];
```

把这个变量赋给插件的 `settings` 字段。在请求函数里读取 `starry.settings.includeTranslation` 等值；宿主已填入默认值，值类型是字符串或布尔值。`advanced: true` 可用于设置项或整个分组，使它们只在高级设置开启时显示。

需要使缓存失效或重建客户端时，实现 `onSettingsChanged(values)`。回调执行时 `starry.settings` 已更新，不要写入这个只读对象，也不要在模块顶层把它复制成永不更新的常量。`secure: true` 用来隐藏输入显示，不能将它理解为持久化加密承诺。

### 7.2 保存会话和缓存

`starry.storage.get<T>(key)`、`set(key, value)`、`remove(key)`、`keys()`、`clear()` 提供按插件隔离的持久化键值存储。值必须能序列化为 JSON；`Map`、函数、循环引用和 typed array 不适合直接作为存储格式，需要先转换。会话格式升级时可以在值里保存一个自己的版本号，读取旧格式后迁移。

存储当前落在应用数据目录的 `PluginData/<插件 id>.json`，不是 Keychain。账号插件应优先保存可恢复的会话凭据，并在退出时清理相应键。移除插件会保留它的登录信息和设置，重新安装仍可读取。

### 7.3 顶层代码只做定义

加载时宿主先执行文件、读取并验证清单，随后才配置网络权限、插件信息和持久化存储，再应用设置。因此模块顶层适合声明常量、函数和导出对象；不要在顶层发请求、读取会话作为固定快照，或依赖尚未就绪的 `starry.plugin` / `starry.settings`。

把会话恢复放在 `account.current` / `refresh` 或需要时读取存储。重新加载会创建新的运行时，内存缓存和定时器状态不能作为持久化机制。`starry.setWebPages(pages)` 也不跨启动保存，恢复会话后需要重新设置，传 `null` 则恢复 `source.webPages` 的默认模板。

## 8. 登录与多账号

### 8.1 选择登录方式

在顶层导出 `account`，用 `methods` 声明实际支持的登录方式，并实现对应函数：

| `methods` 值 | 函数 | 返回值与说明 |
| --- | --- | --- |
| `password` | `loginWithPassword(username, password)` | 成功后保存会话并返回 `Profile`；允许空密码时声明 `passwordOptional: true` |
| `cookie` | `loginWithCookie(text)` | 校验输入、保存有效 Cookie 并返回 `Profile`；`cookieHint` 解释要粘贴什么 |
| `phoneCode` | `sendPhoneCode(phone, countryCode)`、`loginWithPhoneCode(phone, countryCode, code)` | 发送验证码返回 `void`，验证成功返回 `Profile` |
| `qrCode` | `beginQRLogin(kind?)`、`pollQRLogin(session)` | 开始返回 `{ key, url?, image?, kind? }`；轮询返回状态 |
| `code` | `beginCodeLogin()`、`pollCodeLogin(session)` | 在此处显示验证码，让用户去已登录设备输入；需要 `codeLogin: { title, hint? }` |

`Profile` 至少包含 `{ userID, nickname }`，可带 `avatar`、`isVIP`、`detail`。它描述用户，不包含登录令牌；令牌由插件保存并在后续请求中携带。

扫码轮询返回 `'waiting'`、`'scanned'`、`'expired'` 或 `{ status: 'confirmed', profile }`。设备验证码登录开始时返回 `{ key, code }`，轮询没有 `'scanned'` 状态。确认登录时必须先保存可用会话再返回成功。

### 8.2 会话生命周期

每个账号插件都要实现：

1. `refresh()`：读取本地会话并向服务端验证；从未登录或本地没有会话时返回 `null`，会话过期时抛 `starry.error('loginExpired')`，成功时返回资料。
2. `logout()`：按平台协议结束远端会话，并清理本地会话及与该用户相关的缓存。
3. 可选的 `current()`：只用本地数据返回 `Profile` 或 `null`，供刷新前先显示资料，不发网络请求。

搜索、收藏、解析播放地址等函数也要通过同一套会话读取逻辑取得认证信息，避免某些接口仍使用旧令牌。可以将会话读写、请求头和统一错误处理集中在 `client.ts`，如 [Jellyfin 客户端实现](../plugins/jellyfin/src/client.ts)。

### 8.3 自建服务器

声明 `account.server: { placeholder: 'https://music.example.com' }` 并实现 `connect(address)`，登录界面就会先询问服务器地址。`connect` 应规范化地址、验证服务器、保存后续登录所需的地址，并返回 `{ address, name?, version?, methods? }`；`methods` 可缩小到该服务器实际启用的登录方式。

用户可以输入任意服务器地址时，权限通常需要 `hosts: ['*']`。应保留服务器部署所需的路径前缀，不能一律截成域名。公共的地址处理工具见 [`plugins/common/server.ts`](../plugins/common/server.ts)，完整流程见 [Jellyfin 账号实现](../plugins/jellyfin/src/account.ts)。

### 8.4 多账号切换

声明 `multipleAccounts: true`，并实现 `exportCredentials()`、`restoreCredentials(credentials)`、`signOutLocally()`：

- 导出的凭据必须是可序列化、足以恢复当前账号的快照；多服务器账号还需要包含服务器地址及身份信息。
- `restoreCredentials` 恢复会话、更新相关客户端状态并返回资料。
- `signOutLocally` 只清理本地当前会话，不能注销远端令牌，否则切回时凭据已失效；用户真正退出账号才走 `logout`。
- 切换时清理用户相关的缓存，包括收藏、歌单、服务器网页模板和显式维护的 Cookie，避免混用上一账号的数据。

## 9. 扩展音源功能

搜索和播放可用后，再按平台能力逐项扩展。详细返回类型见 SDK，现成实现见 [网易云](../plugins/netease/src/index.ts)、[Jellyfin](../plugins/jellyfin/src/index.ts) 和 [Subsonic](../plugins/subsonic/src/index.ts)。

| 功能 | 主要接口或声明 | 接入要点 |
| --- | --- | --- |
| 批量歌曲详情 | `songs(ids)` | 返回 `Track[]`，用于根据持久化 ID 再次取详情 |
| 专辑、歌手、歌单页 | `album`、`artist`、`playlist` | 分别返回 `AlbumDetail`、`ArtistDetail`、`PlaylistDetail`，不是裸数组 |
| 歌手分页内容 | `artistSongs`、`artistAlbums`、`similarArtists` | `artistSongOrders` 声明支持 `hot` / `time` 排序 |
| 综合搜索 | `searchOverview` | 返回最佳匹配及各类前几项；不实现时由宿主组合分类搜索 |
| 搜索辅助 | `searchSuggestions`、`trendingSearches`、`searchHints` | 按前缀建议、热搜、搜索提示分别提供 |
| 首页内容 | `homeShelves`、`recommendedPlaylists`、`newSongs`、`newAlbums`、`topArtists` | 每个自定义货架只能含一种数据：歌曲、专辑、歌手或歌单；空货架不显示 |
| 喜欢和收藏 | `likedTrackIDs`、`setLiked`、`setCollected` | 喜欢的歌曲按最新在前返回；收藏类型由 `collectableKinds` 声明 |
| 用户歌单 | `userPlaylists`、`likedPlaylistID` | 自己创建的列表标 `isOwned`，有喜欢歌单时将其放在前面 |
| 歌单编辑 | `createPlaylist`、`editPlaylist`、`deletePlaylist`、`addToPlaylist`、`removeFromPlaylist`、`reorderPlaylist` | `playlistOptions` 声明描述、隐私、名字长度等能力 |
| 每日推荐与电台 | `dailyRecommendations`、`dailyPlaylists`、`personalFM`、`skipFM`、`trashFM` | `personalFM` 每次返回少量歌曲，注意 `firstFetch` 的新会话语义 |
| 全部歌曲 | `allMedia(page)` | 可返回数组或 `{ songs, total, hasMore, nextOffset }`；过滤后要正确推进原始分页位置 |
| 资料库网格 | `libraryAlbums`、`libraryArtists`、`libraryGenres` | 适合自建曲库；流派页要求同时有专辑页，`albumSorts` 第一项为默认排序 |
| 用户主页 | `user`、`playlistsOfUser`、`listeningRanking`、`follows`、`followers`、`setUserFollowed` | 先实现 `user`，关注列表能力需要 `follows` 和 `followers`；隐私状态用专门错误码 |
| 评论 | `comments` 或 `commentThread`，以及 `replies`、`setCommentLiked` | 游标接口结束时 `next: null`；点赞还需 `canLikeComments: true`，排序由 `commentSorts` 声明 |
| 听歌上报 | `reportPlayback(report)` | `playedSeconds` / `duration` 为秒，`startedAt` / `endedAt` 为 Unix 毫秒；按平台规则判断是否记一次播放 |
| 打开平台网页 | `webPages` | 模板中使用 `{id}`，可配置歌曲、专辑、歌手、歌单、用户链接 |

歌单编辑有额外的返回约定：`createPlaylist` 返回创建后的空歌单，`addToPlaylist` 跳过已存在的歌曲并返回实际新增数，`removeFromPlaylist` 删除指定歌曲的所有条目。`reorderPlaylist` 接收完整顺序，如果服务器里同时新增了不在参数中的歌曲，应保留并放在末尾；详情里的 `pendingTrackIDs` 也属于需要考虑的歌曲 ID。

不要把所有分页方法都视为一种结构：搜索与 `allMedia` 支持 `nextOffset`，资料库专辑 / 歌手分页使用各自数组及 `total` / `hasMore`，评论则可以使用游标。按各方法的类型实现终止条件。

## 10. 高级播放能力

### 10.1 能力探测、转码与音量均衡

`starry.app` 提供播放器版本、macOS 版本、架构、机型、设备名及可播放格式 `formats`。格式兼容性应优先根据它判断；[Jellyfin 播放实现](../plugins/jellyfin/src/stream.ts) 展示了原始格式与转码选择。

服务器边生成边发送、没有内容长度且不支持 Range 的转码流，在 `resolve` 结果中返回 `transcoded: true`；播放器会先下载完整文件再播放，使后续 seek 可用。

ReplayGain 数据放在 `gain: { trackGain?, trackPeak?, albumGain?, albumPeak? }`。增益是达到 −18 LUFS 所需的 dB，峰值以 1 为满幅；不知道就省略，不要填估计值。空间音频档位可声明 `spatial: true`，此类播放由系统渲染，对应均衡器、频谱和唱歌模式不会启用。

### 10.2 加密音频

`resolve` 返回 `decrypt` 参数，并提供 `source.decryptor(params)`。后者返回 `(bytes: Uint8Array, offset: number) => void`，原地修改每块音频数据；`offset` 是这块数据在文件中的绝对字节位置，不是固定块序号。

解密器在单独的插件副本中同步运行，不能依赖主运行时的网络、存储、定时器或内存会话。所需密钥等参数都应通过 `decrypt` 传入，并保证分块大小变化时仍然正确。播放器边下载边调用解密器，保存的是明文音频。

### 10.3 编码、密码算法和压缩

`starry.encoding` 提供 UTF-8、hex、base64；`starry.crypto` 提供 MD5、SHA 系列、HMAC、AES、DES、3DES、RSA 公钥加密和随机字节；`starry.zlib` 提供压缩、解压。具体参数见 SDK 的 `Starry`、`CipherOptions`。

字符串输入按 UTF-8 解释，十六进制或 base64 密钥需要先解码成字节。AES-GCM 的输入 / 输出末尾包含 16 字节认证标签；`zlib.inflate` 能按头识别 zlib、gzip 或 raw deflate。不要因为 Node 测试里有 `Buffer` / `node:crypto`，就在生产插件里直接导入它们。

## 11. 调试与错误处理

### 11.1 本地开发循环

1. 在插件工程中运行 `npm run watch`，确认输出文件已生成。
2. 在高级设置中添加输出 `.js` 或它所在的目录。
3. 修改代码，等待构建完成，点击插件页“重新加载”。
4. 在播放器中触发搜索、播放、歌词或登录流程，观察结果。
5. 需要断点时打开“允许调试插件”，在 Safari 的“开发”菜单选择本机下的“插件：<名称>”。

“记录插件调用”会把参数、耗时、结果写入系统日志，并在从终端启动播放器时打印到 stderr。可以查看日志：

```bash
log stream --predicate 'subsystem == "moe.mrs4s.starry-player" AND category == "plugin"'
```

记录可能包含登录参数和响应中的会话信息，分享日志前应去除凭据。普通 `console.log` 适合记录阶段、条数、状态码；避免输出密码、Cookie 或令牌。

### 11.2 错误码与时间限制

用 `throw starry.error(code, message?)` 表达可识别的业务状态：

| 错误码 | 含义 |
| --- | --- |
| `vipRequired`、`trialOnly` | 需要会员、只有试听 |
| `loginExpired` | 需要重新登录 |
| `unavailableInRegion`、`sourceUnreachable` | 地区限制、来源不可达 |
| `notSupported` | 该操作或资源不支持 |
| `network`、`timeout`、`rateLimited` | 网络失败、超时、限流 |
| `rankingHidden`、`followsHidden` | 用户未公开排行、关注 / 粉丝列表 |

其他异常会显示插件名和错误信息，可用简短中文说明具体失败原因。不要吞掉所有异常并返回空列表，否则界面只会像“没有内容”。

普通调用默认最多 **30 秒**；扫码和设备验证码轮询为 **100 秒**；同步执行的默认 CPU 时间限制为 **5 秒**，宿主会尽力中止超限代码，但不能将其视为所有死循环都能被强制终止的保证。HTTP 请求默认超时为 **15 秒**。避免无限轮询、无界重试和同步处理超大数据；轮询函数返回当前状态，由宿主安排后续调用。

### 11.3 常见问题

| 现象 | 优先检查 |
| --- | --- |
| 加载列表没有插件 | 是否添加了真正的 `.js` 文件；目录扫描不递归；是否已经重新加载 |
| 修改没有生效 | 构建是否完成；加载的是 `dist` 还是旧产物；是否有同 ID 的开发副本覆盖安装副本 |
| “缺少 resolve” / “需要 search 和 fetch” | 对应分组必需函数是否存在；是否正确导出 `module.exports` / `default` |
| `require is not defined` / `Buffer is not defined` | 是否忘记 bundle，或使用了 Node 专用依赖 |
| `hostNotAllowed` | 清单是否包含请求主机及跳转后的主机；顶层是否过早发起请求 |
| “返回了无法识别的结果” | 是否返回了正确的对象层级；ID、数组、日期与数字类型是否符合 SDK |
| 搜索结果重复 / 提前结束 | `offset`、`limit`、`hasMore`、过滤后的 `nextOffset` 是否正确 |
| 搜得到但播不了 | `resolve` 是否能仅凭歌曲 ID 工作；URL 是否过期，下载请求头、容器是否正确 |
| 歌词时间错位 | 音源时长是否误用毫秒；歌词格式、时间单位、歌曲版本是否正确 |
| 重启后未登录 | 是否只存了内存变量；是否在顶层过早读取持久化状态；是否实现会话恢复 |
| 功能入口不出现 | 函数和附加声明是否齐全，如 `collectableKinds`、`searchKinds`、`user` |

## 12. 自动化验证

### 12.1 对教程音源执行离线测试

类型检查只能发现接口形状问题，下面的测试直接执行打包产物，验证单位换算、分页参数、ID 编码、播放地址和 HTTP 错误映射。它不会访问真实服务。

在第 3 节的工程创建 `test/plugin.test.cjs`：

```js
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = readFileSync(path.join(__dirname, '../dist/tutorial.js'), 'utf8');

function loadPlugin(get) {
  const context = vm.createContext({
    module: { exports: {} },
    starry: {
      http: { get },
      error: (code, message = code) => Object.assign(new Error(message), { code }),
    },
  });
  vm.runInContext(code, context);
  return context.module.exports.default ?? context.module.exports;
}

test('搜索映射时长和 ID，并保留服务端分页位置', async () => {
  const plugin = loadPlugin(async (url, options) => {
    assert.equal(url, 'https://api.example.com/songs');
    assert.equal(options.query.q, '星光');
    assert.equal(options.query.offset, 20);
    assert.equal(options.query.limit, 20);
    return { status: 200, body: {
      items: [{ id: 42, title: '星光', artist: { id: 7, name: '示例歌手' }, durationMs: 180000 }],
      total: 41, hasMore: true, nextOffset: 40,
    } };
  });
  const result = await plugin.source.search('星光', 'song', { offset: 20, limit: 20 });
  assert.equal(result.songs[0].id, '42');
  assert.equal(result.songs[0].artists[0].id, '7');
  assert.equal(result.songs[0].duration, 180);
  assert.equal(result.hasMore, true);
  assert.equal(result.nextOffset, 40);
});

test('播放根据 ID 获取新地址', async () => {
  const plugin = loadPlugin(async (url, options) => {
    assert.equal(url, 'https://api.example.com/songs/a%2Fb/stream');
    assert.equal(options.query.quality, 'standard');
    return { status: 200, body: { url: 'https://media.example.com/test.mp3', expiresIn: 600 } };
  });
  const asset = await plugin.source.resolve(
    { id: 'a/b', title: '星光', duration: 180 },
    { id: 'standard', name: '标准', level: 'sq' },
  );
  assert.equal(asset.url, 'https://media.example.com/test.mp3');
  assert.equal(asset.expiresIn, 600);
  assert.equal(asset.tier, 'standard');
});

test('会话失效不伪装成空搜索结果', async () => {
  const plugin = loadPlugin(async () => ({ status: 401, body: {} }));
  await assert.rejects(
    plugin.source.search('星光', 'song', { offset: 0, limit: 20 }),
    { code: 'loginExpired' },
  );
});
```

运行：

```bash
npm run check
npm test
```

这套模拟只实现示例用到的宿主方法，不验证 JavaScriptCore 兼容性、网络权限、Cookie 或播放器 UI，仍需按上一节在播放器中联调。实际项目应继续覆盖空结果、过滤后的分页、歌词缓存未命中、过期凭据和账号切换等边界。

### 12.2 使用仓库现有测试设施

Jellyfin 和 Subsonic 的 Node 测试可作为更完整的参考。共用的 [`starry-mock.ts`](../plugins/common/test/starry-mock.ts) 提供模拟服务器、存储和部分密码算法；它不是完整宿主，例如当前主要提供 `http.request`，使用 `get` / `post` 等方法时需要补充相应模拟。

在仓库根目录运行宿主测试：

```bash
scripts/test.sh --filter PluginHostTests
```

脚本先构建内置插件，再运行 Swift 测试。新插件不会仅因放入 `plugins/` 自动成为内置插件或被测试加载；需要为它增加相应测试。宿主测试可通过 [`PluginTestSupport.swift`](../Packages/StarryKit/Tests/PluginHostTests/PluginTestSupport.swift) 的 `Fixture`、`StubProtocol` 模拟 HTTP，验证真实 JavaScriptCore、序列化及 Swift 适配行为。

已有 LRCLIB / Audius 示例的联网测试需显式开启，在仓库根目录执行：

```bash
cd Packages/StarryKit
PLUGINS_LIVE=1 swift test --filter ExamplePluginLive
```

Jellyfin、Subsonic 的本地服务器与联网测试步骤见各自 README。联网测试受外部服务状态影响，应与可重复的离线测试分开执行。

## 13. 打包、安装与更新

### 13.1 发布单文件

在插件工程中先执行 `npm run check` 和测试，再用 `npm run build` 生成压缩产物。分发 `dist/tutorial.js` 即可，不需要分发 `node_modules` 或让用户安装 npm。保留源码和锁文件，便于复现构建。

文件应为 UTF-8 文本，通过文件或网址安装时最大为 **10 MiB**。从网址安装要提供直接返回 JavaScript 文件内容的 HTTP(S) 链接，不是代码托管网站的 HTML 页面。更新插件导出对象中的 `version`，不要只修改 `package.json`。

### 13.2 安装位置与加载优先级

用户可以在 **设置 › 插件** 中选择“从文件安装”或“从网址安装”，也可以将 `.js` 放到：

```text
~/Library/Application Support/moe.mrs4s.starry-player/Plugins/
```

然后点击“重新加载”。从网址安装会记录该地址，之后可以在插件页触发更新；`homepage` 只是介绍链接，不是更新地址。

同一个插件 ID 的优先级为：**开发路径 > 已安装插件 > App 自带插件**。这不是按版本号选择最新版；开发路径里残留的旧副本也会覆盖已安装的新版本。发布验证时移除对应开发路径，再按普通安装流程检查一次。

仓库内置插件由 [`scripts/build-plugins.sh`](../scripts/build-plugins.sh) 的 `PLUGINS` 列表显式构建，输出 `build/plugins/<名称>.js`，App 构建时复制到 `Resources/builtin`。新建插件目录并不会自动加入列表。该脚本每次会重建整个 `build/plugins/`，教程工程使用自己的 `dist/`，避免将手工产物放进这个会被清空的目录。

### 13.3 插件 ID 与平台身份

`id` 决定插件身份与存储文件；随意改名会让宿主把它视为另一插件。修改展示名使用 `name`，升级使用 `version`。

`idNamespace` 则表示歌曲等资源沿用一个已知平台的 ID，只接受 `netease`、`qqmusic`、`kugou`。它会接管该平台对应的来源身份、已保存歌曲和相关设置 / 歌词匹配，因此只能在 ID 确实属于该平台时声明。

同一平台可以各有一个音源和一个歌词源，来自一个插件或两个不同插件。只导出 `lyrics` 的插件声明平台时仅接管歌词，设置仍属于该插件自己；重复的平台角色会被判定冲突。开发或已安装的插件可按加载顺序替代自带平台实现，不能靠随意填写 `idNamespace` 新增一个任意平台名。

### 13.4 交付前核对

- 在干净的安装流程中加载最终 `.js`，确认没有遗漏依赖、缺失清单或重复身份。
- 搜索第一页、下一页、空结果和播放成功；签名地址失效后能重新解析。
- 歌词没有结果时正常回退，有结果时时间单位正确。
- 带账号的插件验证登录、重启恢复、退出、过期及多账号切换。
- 权限包含真实请求和重定向主机，发布文件和日志中没有个人凭据。
- README 写清支持的服务、登录方式、限制和兼容版本，并提供单文件下载链接。

## 14. 继续阅读

| 路径 | 适合参考的内容 |
| --- | --- |
| [SDK 类型定义](../plugins/sdk/starry.d.ts) | 所有字段、签名、单位和返回类型 |
| [LRCLIB 示例](../plugins/examples/lrclib.js) | 单文件歌词源、搜索缓存与按 ID 回源 |
| [Audius 示例](../plugins/examples/audius.js) | 单文件音源、搜索分类、歌手和歌单详情 |
| [网易云插件](../plugins/netease/README.md) | 音源、账号、用户主页、歌词与听歌上报 |
| [Jellyfin 插件](../plugins/jellyfin/README.md) | 自建服务器、多账号、快速连接、转码选择 |
| [Subsonic 插件](../plugins/subsonic/README.md) | Subsonic / Navidrome 曲库、接口兼容与歌词 |
| [QQ 音乐歌词插件](../plugins/qqmusic-lyrics/README.md)、[酷狗歌词插件](../plugins/kugou-lyrics/README.md) | 歌词格式与解密流程 |
| [服务器共用模块](../plugins/common/README.md) | 地址处理、分页辅助、歌词转换、模拟测试 |
| [PluginHost 实现](../Packages/StarryKit/Sources/PluginHost) | 加载校验、HTTP 权限、运行时和 Swift 适配 |
| [项目开发文档](development.md) | App 构建、测试及打包 |
