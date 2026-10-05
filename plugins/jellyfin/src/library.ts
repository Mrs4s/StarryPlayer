// The account's own: playlists, favourites (liking, collecting and following all map to the
// server's favourites), personal FM from instant mixes, and plays counted on the server.

import { countsAsPlay, nextRadioSongs, stopRadio, trashRadioSong } from '../../common/library';
import type { Playlist, PlaybackReport, Track } from '../../sdk/starry';
import { api, locate, requireSession, type Server } from './client';
import { items, songItems } from './catalog';
import * as model from './models';

const accountKey = (server: Server) => `${server.serverId}:${server.userId}`;

export function clearAccountState(): void {
  stopRadio();
}

export async function userPlaylists(): Promise<Playlist[]> {
  const server = requireSession();
  const result = await items(server, { IncludeItemTypes: 'Playlist', SortBy: 'SortName', Fields: 'ChildCount' });
  const playlists = (result?.Items ?? []).filter(model.isMusicPlaylist);
  const owned = await Promise.all(playlists.map((playlist) =>
    api(server, `/Items/${encodeURIComponent(playlist.Id)}`, { query: { userId: server.userId } }).then((item) => item?.CanDelete !== false, () => true)));
  return playlists.map((playlist, index) => ({ ...model.playlist(server, playlist), isOwned: owned[index] }));
}

/** When songs were liked here, per account: the server does not keep it. */
type LikeTimes = Record<string, Record<string, number>>;
const LIKES_KEPT = 5000;

/**
 * Liked songs newest first: those liked here by when, then the rest as the server lists them
 * (newest in the library first). Times of songs no longer liked are dropped.
 */
export function orderLikes(ids: string[], times: Record<string, number>): { ids: string[]; times: Record<string, number> } {
  const kept: Record<string, number> = {};
  for (const id of ids) if (typeof times[id] === 'number') kept[id] = times[id];
  const timed = ids.filter((id) => id in kept).sort((a, b) => kept[b] - kept[a]);
  return { ids: [...new Set([...timed, ...ids])], times: kept };
}

export async function likedTrackIDs(): Promise<string[]> {
  const server = requireSession();
  const result = await items(server, {
    IncludeItemTypes: 'Audio',
    Filters: 'IsFavorite',
    SortBy: 'DateCreated,SortName',
    SortOrder: 'Descending,Ascending',
    EnableImages: false,
  });
  const ids = (result?.Items ?? []).map((item) => item?.Id).filter((id): id is string => typeof id === 'string');
  const all = starry.storage.get<LikeTimes>('likedAt') ?? {};
  const ordered = orderLikes(ids, all[accountKey(server)] ?? {});
  all[accountKey(server)] = ordered.times;
  starry.storage.set('likedAt', all);
  return ordered.ids;
}

/** On the server the item lives on, as its user there. */
async function setFavourite(id: string, favourite: boolean): Promise<Server> {
  const { server } = await locate(id, (server) =>
    api(server, `/UserFavoriteItems/${encodeURIComponent(id)}`, { method: favourite ? 'POST' : 'DELETE', query: { userId: server.userId } }),
  );
  return server;
}

export async function setLiked(trackID: string, liked: boolean): Promise<void> {
  const server = await setFavourite(trackID, liked);
  const all = starry.storage.get<LikeTimes>('likedAt') ?? {};
  const times = { ...(all[accountKey(server)] ?? {}) };
  if (liked) times[trackID] = Date.now();
  else delete times[trackID];
  const newest = Object.entries(times).sort((a, b) => b[1] - a[1]).slice(0, LIKES_KEPT);
  all[accountKey(server)] = Object.fromEntries(newest);
  starry.storage.set('likedAt', all);
}

export async function setCollected(_kind: 'playlist' | 'album' | 'artist', id: string, collected: boolean): Promise<void> {
  await setFavourite(id, collected);
}

const MIX_SIZE = 30;

async function randomSeed(server: Server): Promise<string | undefined> {
  const favourite = await items(server, { IncludeItemTypes: 'Audio', Filters: 'IsFavorite', SortBy: 'Random', Limit: 1 });
  const pick = favourite?.Items?.[0] ?? (await items(server, { IncludeItemTypes: 'Audio', SortBy: 'Random', Limit: 1 }))?.Items?.[0];
  return typeof pick?.Id === 'string' ? pick.Id : undefined;
}

export async function personalFM(_mode: string, firstFetch: boolean): Promise<Track[]> {
  const server = requireSession();
  return nextRadioSongs({
    account: accountKey(server),
    seed: () => randomSeed(server),
    mix: async (seed) => {
      const mix = await api(server, `/Items/${encodeURIComponent(seed)}/InstantMix`, {
        query: { userId: server.userId, Limit: MIX_SIZE, Fields: model.SONG_FIELDS, EnableImageTypes: 'Primary', ImageTypeLimit: 1, EnableUserData: false },
      });
      return (mix?.Items ?? []).filter((item: any) => item?.Type === 'Audio').map((item: any) => model.track(server, item));
    },
    random: async () => ((await songItems(server, { SortBy: 'Random', Limit: MIX_SIZE }))?.Items ?? []).map((item) => model.track(server, item)),
  }, firstFetch);
}

/** Dislike: never on this account's radio again. */
export async function trashFM(trackID: string): Promise<void> {
  trashRadioSong(accountKey(requireSession()), trackID);
}

/**
 * A play that ended, counted on the server it was played from: PlayCount +1 and the time
 * it was played, which the server's most played and recently played lists read.
 */
export async function reportPlayback(report: PlaybackReport): Promise<void> {
  if (!countsAsPlay(report)) return;
  const played = new Date(report.endedAt).toISOString();
  await locate(report.trackID, (server) =>
    api(server, `/UserPlayedItems/${encodeURIComponent(report.trackID)}`, { method: 'POST', query: { userId: server.userId, datePlayed: played } }),
  );
}
