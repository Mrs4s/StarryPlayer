import type { Plugin } from '../../sdk/starry';
import * as lyrics from './lyrics';

const plugin: Plugin = {
  id: 'moe.mrs4s.kugou-lyrics',
  name: '酷狗音乐歌词',
  version: '1.1.0',
  apiVersion: 1,
  author: 'mrs4s',
  description: '酷狗音乐的逐字歌词，含翻译与音译',
  icon: 'text.quote',
  // Its songs are Kugou's (file hashes): the provider is the platform's (`kugou`, where the source
  // order, lyric matches and the lyrics cache keep it), and Kugou tracks are fetched by their hash.
  idNamespace: 'kugou',
  permissions: { hosts: ['mobilecdn.kugou.com', 'lyrics.kugou.com'] },

  lyrics: {
    detail: 'KRC 逐字，含翻译与音译',
    search: lyrics.search,
    fetch: lyrics.fetch,
  },
};

export default plugin;
