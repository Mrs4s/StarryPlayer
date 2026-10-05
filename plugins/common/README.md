# 服务器插件共用的代码

[Jellyfin](../jellyfin) 和 [Subsonic](../subsonic) 两个插件共用的 TypeScript。这里不单独构建：各插件按相对路径 import，由 esbuild 打进各自的构建产物（`build/plugins/*.js`）。App 构建时两个插件都会重新打包。

| 文件 | 内容 |
|---|---|
| `server.ts` | 地址补全（去掉粘贴进来的网页路径；局域网地址先试 http）、版本比较、日期解析、歌单的剩余 id 和重排合并、限制并发的 map |
| `library.ts` | 音质档位（省流 / 极高 / 无损 / Hi-Res，按文件本身）、播放计数门槛（一半或 4 分钟）、私人 FM（混音、“不喜欢”、发完重来） |
| `lyrics.ts` | 带时间的行 → 逐字 TTML 或 LRC，翻译和罗马音作为单独的 LRC；读出写在行里的增强 LRC 时间（`<00:01.50>`） |
| `test/starry-mock.ts` | Node 里的 `starry`（和 prelude.js 同一套接口），服务器按地址伪造，请求记在 `sent` 里 |
| `test/common.test.ts` | 这些代码的测试，由两个插件的 `npm test` 一起跑 |
