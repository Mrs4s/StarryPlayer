import type { Plugin } from '../../sdk/starry';
import * as lyrics from './lyrics';

const plugin: Plugin = {
  id: 'moe.mrs4s.qqmusic-lyrics',
  name: 'QQ音乐歌词',
  version: '1.0.0',
  apiVersion: 1,
  author: 'mrs4s',
  description: 'QQ音乐的逐字歌词，含翻译与音译',
  icon: 'text.quote',
  idNamespace: 'qqmusic',
  permissions: { hosts: ['u6.y.qq.com'] },

  lyrics: {
    detail: 'QRC 逐字，含翻译与音译',
    ttmlFolder: 'qq-lyrics',
    search: lyrics.search,
    fetch: lyrics.fetch,
  },
};

export default plugin;
