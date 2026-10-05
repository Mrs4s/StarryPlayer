import type { Lyrics, LyricsSong } from '../../sdk/starry';
import { request } from './client';
import { Song } from './endpoints';
import { search as searchCatalog } from './catalog';
import { str } from './util';

export async function search(keyword: string): Promise<LyricsSong[]> {
  const page = await searchCatalog(keyword, 'song', { offset: 0, limit: 20 });
  return (page.songs ?? []).map((song) => ({
    id: song.id,
    title: song.title,
    artists: (song.artists ?? []).map((artist) => artist.name),
    album: song.album?.name,
    duration: song.duration,
  }));
}

/** Every block version -1 (nothing cached). `ytlrc` / `yromalrc` go with YRC. */
export async function fetch(song: { id: string }): Promise<Lyrics | null> {
  const json = await request(Song.lyric, { id: song.id, lv: -1, tv: -1, rv: -1, yv: -1 });
  const block = (name: string) => str(json?.[name]?.lyric);
  const translation = block('ytlrc') ?? block('tlyric');
  const romanization = block('yromalrc') ?? block('romalrc');
  const yrc = block('yrc');
  if (yrc?.trim()) return { format: 'yrc', body: yrc, translation, romanization };
  const lrc = block('lrc');
  if (lrc?.trim()) return { format: 'lrc', body: lrc, translation, romanization };
  return null;
}
