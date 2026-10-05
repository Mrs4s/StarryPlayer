// Use the HTTP mobile search endpoint: HTTPS song search often returns no results.
// Lyric lookup requires hash, title and duration in seconds.

import type { Lyrics, LyricsSong } from '../../sdk/starry';
import { krcText } from './krc';
import { array, clean, compact, int, num, str, text } from './util';

const LYRIC_HEADERS = {
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
};

export async function search(keyword: string): Promise<LyricsSong[]> {
  const answer = await kugouJSON('http://mobilecdn.kugou.com/api/v3/search/song', { keyword, page: 1, pagesize: 20, format: 'json', showtype: 1 });
  if (int(answer?.status) !== 1) throw starry.error('api', `酷狗搜索失败${text(answer?.error) ? `：${answer.error}` : ''}`);
  return compact(
    array(answer.data?.info).map((song): LyricsSong | null => {
      const hash = text(song?.hash);
      const title = str(song?.songname);
      if (!hash || title === undefined) return null;
      const album = text(song.album_name);
      return {
        // Use uppercase hashes consistently for matches, pins and cache keys.
        id: hash.toUpperCase(),
        title: clean(title),
        artists: compact((str(song.singername) ?? '').split('、').map((name) => clean(name) || null)),
        album: album === undefined ? undefined : clean(album),
        duration: int(song.duration),
      };
    }),
  );
}

/** A song by its file hash, with the title and duration the lyric search needs. */
export async function fetch(song: { id: string; title?: string; duration?: number }): Promise<Lyrics | null> {
  const found = await kugouJSON(
    'https://lyrics.kugou.com/search',
    { ver: 1, man: 'yes', client: 'pc', lrctxt: 1, keyword: song.title ?? '', hash: song.id, timelength: Math.trunc(song.duration ?? 0) },
    LYRIC_HEADERS,
  );
  const candidate = array(found?.candidates)[0];
  const id = str(candidate?.id);
  const accessKey = str(candidate?.accesskey);
  if (id === undefined || accessKey === undefined) return null;
  const perCharacter = num(candidate.krctype) === 1 && num(candidate.contenttype) !== 1;

  const file = await kugouJSON(
    'https://lyrics.kugou.com/download',
    { ver: 1, client: 'pc', charset: 'utf8', id, accesskey: accessKey, fmt: perCharacter ? 'krc' : 'lrc' },
    LYRIC_HEADERS,
  );
  const content = text(file?.content);
  if (!content) return null;
  if (file.fmt === 'krc') return { format: 'krc', body: krcText(content) };
  const lrc = starry.encoding.utf8.decode(starry.encoding.base64.decode(content));
  return lrc.trim() ? { format: 'lrc', body: lrc } : null;
}

async function kugouJSON(url: string, query: Record<string, string | number>, headers: Record<string, string> = {}): Promise<any> {
  const response = await starry.http.get<string>(url, { query, headers });
  if (response.status !== 200) throw starry.error('network', `酷狗返回 HTTP ${response.status}`);
  const body = String(response.body).replace(/<!--KG_TAG_RES_(START|END)-->/g, '').trim();
  try {
    return JSON.parse(body);
  } catch {
    throw starry.error('api', '酷狗的响应解析失败');
  }
}
