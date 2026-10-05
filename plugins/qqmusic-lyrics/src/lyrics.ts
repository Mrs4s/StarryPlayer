// Lyric bodies are encrypted hex plus zlib. Search results use numeric IDs;
// QQ tracks use mids. `qrc_t` distinguishes QRC from LRC.

import type { Lyrics, LyricsSong } from '../../sdk/starry';
import { lyric, songSearch } from './cgi';
import { call } from './client';
import { qrcText } from './qrc';
import { array, compact, int, num, str, text } from './util';

export async function search(keyword: string): Promise<LyricsSong[]> {
  const answer = await call(songSearch(keyword, 1, 20), { signed: true });
  return compact(
    array(answer.body?.song?.list).map((song): LyricsSong | null => {
      const id = str(song?.id);
      const title = text(song?.title) ?? text(song?.name);
      if (!id || !title) return null;
      return {
        id,
        mid: text(song.mid),
        title,
        artists: compact(array(song.singer).map((singer) => text(singer?.title) ?? text(singer?.name))),
        album: text(song.album?.title) ?? text(song.album?.name),
        duration: num(song.interval),
      };
    }),
  );
}

export async function fetch(song: { id: string; mid?: string; title?: string; duration?: number }): Promise<Lyrics | null> {
  const numeric = /^\d+$/.test(song.id) ? Number(song.id) : undefined;
  const mid = song.mid ?? (numeric === undefined ? song.id : undefined);
  if (numeric === undefined && !mid) return null;
  const answer = await call(lyric(mid ?? '', numeric ?? 0, song.title ?? '', Math.trunc(song.duration ?? 0)));
  const body = qrcText(str(answer.lyric));
  if (!body) return null;
  return {
    format: (int(answer.qrc_t) ?? 0) !== 0 || body.includes('LyricContent=') ? 'qrc' : 'lrc',
    body,
    translation: qrcText(str(answer.trans)) ?? undefined,
    romanization: qrcText(str(answer.roma)) ?? undefined,
  };
}
