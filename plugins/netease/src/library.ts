import type { Page, Playlist, Track } from '../../sdk/starry';
import { businessError, loginRequired, request } from './client';
import { Album, Artist, Cloud, Discovery, FM, Playlist as PlaylistAPI, Song } from './endpoints';
import * as map from './mapping';
import { playlistDetailV6 } from './catalog';
import { algorithm, currentUserID, likedPlaylistIDOf, rememberAlgorithms, rememberLibrary } from './state';
import { array, bool, compact, int, str } from './util';

function requireUID(): string {
  const uid = currentUserID();
  if (uid === undefined) throw loginRequired();
  return uid;
}

function expect(json: any, success: number[] = [200]): void {
  const code = int(json?.code);
  if (code === undefined || !success.includes(code)) throw businessError(code ?? -1, str(json?.message));
}

/** `playlist[]`, `more`: pages with `limit` 1000 and `offset = 1000 · page`. */
export const userPlaylistPage = (uid: string, page: number) => request(PlaylistAPI.userPlaylists, { uid, offset: 1000 * page, limit: 1000 });

export async function userPlaylists(): Promise<Playlist[]> {
  const uid = requireUID();
  let raw: any[] = [];
  for (let page = 0; ; page++) {
    const json = await userPlaylistPage(uid, page);
    raw = raw.concat(array(json?.playlist));
    if (bool(json?.more) !== true || page >= 20) break;
  }
  try {
    const top = array((await request(PlaylistAPI.userTopPlaylists, { userId: uid, offset: 0, limit: 1000 }))?.data?.topItemList);
    const seen = new Set(compact(raw.map((p) => str(p?.id))));
    const pinned = top.filter((p) => {
      const id = str(p?.id);
      return id !== undefined && !seen.has(id);
    });
    raw.splice(Math.min(1, raw.length), 0, ...pinned);
  } catch {
  }
  const own = new Set(compact(raw.filter((p) => str(p?.userId) === uid || str(p?.creator?.userId) === uid).map((p) => str(p?.id))));
  const liked = str(raw.find((p) => int(p?.specialType) === 5)?.id);
  rememberLibrary(uid, own, liked);
  return compact(raw.map((p) => map.playlist(p, uid)));
}

/** The account's liked songs playlist (`specialType` 5), from its playlist list. */
export async function likedPlaylistID(): Promise<string | null> {
  const uid = requireUID();
  const known = likedPlaylistIDOf(uid);
  if (known) return known;
  await userPlaylists();
  return likedPlaylistIDOf(uid) ?? null;
}

// There is no like-list endpoint; read the liked playlist's track IDs.
export async function likedTrackIDs(): Promise<string[]> {
  const likedID = await likedPlaylistID();
  if (!likedID) return [];
  const json = await playlistDetailV6(likedID, 0);
  return compact(array(json?.playlist?.trackIds).map((item) => str(item?.id)));
}

/** Like / unlike; `alg` only for recommended songs. Codes: 502 ignored, 505 liked list full. */
export async function setLiked(trackID: string, liked: boolean): Promise<void> {
  const uid = requireUID();
  const body: Record<string, unknown> = { trackId: trackID, userid: uid, like: liked };
  const alg = algorithm(trackID);
  if (alg) body.alg = alg;
  expect(await request(Song.like, body));
}

/** Collect a playlist or album, follow an artist; following answers 200 or 201. */
export async function setCollected(kind: 'playlist' | 'album' | 'artist', id: string, collected: boolean): Promise<void> {
  requireUID();
  switch (kind) {
    case 'playlist':
      expect(await request(collected ? PlaylistAPI.subscribe : PlaylistAPI.unsubscribe, { id }));
      break;
    case 'album':
      expect(await request(collected ? Album.subscribe : Album.unsubscribe, { id }));
      break;
    case 'artist':
      expect(await request(collected ? Artist.subscribe : Artist.unsubscribe, collected ? { artistId: id } : { artistIds: `[${id}]` }), [200, 201]);
      break;
  }
}

/** v3 (`data.dailySongs`), v1 (`recommend`) as the fallback group. */
export async function dailyRecommendations(): Promise<Track[]> {
  requireUID();
  try {
    const songs = array((await request(Discovery.dailySongs, { limit: 30 }))?.data?.dailySongs);
    if (songs.length) return compact(songs.map(map.trackWithPrivilege));
  } catch {
    // v1 below.
  }
  const json = await request(Discovery.dailySongsV1, { limit: 30 });
  return compact(array(json?.recommend).map(map.trackWithPrivilege));
}

export async function dailyPlaylists(): Promise<Playlist[]> {
  requireUID();
  const json = await request(Discovery.personalPlaylistRecommend);
  return compact(array(json?.data?.blockData?.creatives).map(map.creativePlaylist));
}

export const FM_MODES: Record<string, string | undefined> = {
  default: undefined,
  familiar: 'FAMILIAR',
  explore: 'EXPLORE',
  scene: 'SCENE_RCMD',
  puzzle: 'PUZZLE_MODE_RCMD',
};

/** `radio/get` hands out three new songs a call (with `imageFm` 1 only on a session's first). */
export async function personalFM(mode: string, firstFetch: boolean): Promise<Track[]> {
  const body: Record<string, unknown> = { imageFm: firstFetch ? 1 : 0 };
  const name = FM_MODES[mode];
  if (name) body.mode = name;
  const json = await request(FM.personal, body);
  expect(json);
  const items = array(json.data);
  rememberAlgorithms(compact(items.map((item): [string, string] | undefined => {
    const id = str(item?.id);
    const alg = str(item?.alg);
    return id !== undefined && alg !== undefined ? [id, alg] : undefined;
  })));
  return compact(items.map(map.trackWithPrivilege));
}

/** A manual "next" in personal FM; `time` is the seconds played. */
export async function skipFM(trackID: string, playedSeconds: number): Promise<void> {
  await request(FM.skip, { alg: algorithm(trackID) ?? '', songId: trackID, time: Math.trunc(playedSeconds) });
}

export async function trashFM(trackID: string, playedSeconds: number): Promise<void> {
  expect(await request(FM.trash, { alg: algorithm(trackID) ?? '', songId: trackID, time: Math.trunc(playedSeconds) }));
}

// Cloud pages can contain fewer songs than `limit` after unmatched uploads are filtered.
export async function allMedia(page: Page): Promise<{ songs: Track[]; total?: number; hasMore: boolean; nextOffset: number }> {
  requireUID();
  const json = await request(Cloud.list, { limit: page.limit, offset: page.offset });
  const items = array(json?.data);
  const total = typeof json?.count === 'number' ? json.count : undefined;
  const hasMore = typeof json?.hasMore === 'boolean' ? json.hasMore : total !== undefined ? page.offset + items.length < total : items.length >= page.limit;
  const songs = compact(
    items.map((item) => {
      const song = item?.simpleSong ? map.track(item.simpleSong) : undefined;
      if (!song) return undefined;
      if (!song.title) song.title = str(item.songName) ?? str(item.fileName) ?? '';
      const artist = str(item.artist);
      if (!song.artists?.length && artist !== undefined) song.artists = [{ id: '', name: artist }];
      return song;
    }),
  );
  return { songs, total, hasMore, nextOffset: page.offset + items.length };
}
