// Replace whole playlists: indexed removal is unreliable on Airsonic-Advanced
// and invalid indices can crash gonic. Report when a server ignores requested ordering.

import { mergeOrder } from '../../common/server';
import type { Playlist, PlaylistDraft } from '../../sdk/starry';
import { call, list, locate, rawOn, requireSession, type Server } from './client';
import * as model from './models';

/** Ids sent in one request (an address gets long where the server takes no form). */
const IDS_PER_REQUEST = 200;

/** The playlist's songs in order, as the server's own ids. */
async function entries(server: Server, id: string): Promise<string[]> {
  const item = (await call(server, 'getPlaylist', { id }))?.playlist;
  return list(item?.entry).map((song) => String(song?.id ?? '')).filter(Boolean);
}

// To clear a playlist, remove every entry: Navidrome treats an empty `createPlaylist` as no
// change.
async function writeBack(server: Server, id: string, songs: string[]): Promise<string[]> {
  const info = (await call(server, 'getPlaylist', { id }))?.playlist;
  await call(server, 'createPlaylist', { playlistId: id, songId: songs }, { post: true });
  let after = (await call(server, 'getPlaylist', { id }).catch(() => undefined))?.playlist;
  const count = list(after?.entry).length;
  if (songs.length === 0 && count > 0) {
    await call(server, 'updatePlaylist', { playlistId: id, songIndexToRemove: Array.from({ length: count }, (_, index) => count - 1 - index) }, { post: true });
    after = (await call(server, 'getPlaylist', { id }).catch(() => undefined))?.playlist;
  }
  if (!info || !after) return songs;
  // A server that drops the rest when it overwrites (none seen yet): put them back.
  const restore: Record<string, string | boolean> = {};
  if (typeof info.name === 'string' && after.name !== info.name) restore.name = info.name;
  if (typeof info.comment === 'string' && info.comment && after.comment !== info.comment) restore.comment = info.comment;
  if (info.public === true && after.public !== true) restore.public = true;
  if (Object.keys(restore).length > 0) await call(server, 'updatePlaylist', { playlistId: id, ...restore });
  return list(after.entry).map((song) => String(song?.id ?? ''));
}

export async function createPlaylist(draft: PlaylistDraft): Promise<Playlist> {
  const server = requireSession();
  let item = (await call(server, 'createPlaylist', { name: draft.name }))?.playlist;
  // Before 1.14 (Airsonic-Advanced) the new playlist does not come back: the newest of that name.
  if (!item) {
    const named = list((await call(server, 'getPlaylists'))?.playlists?.playlist).filter((playlist) => playlist?.name === draft.name && playlist?.owner === server.user);
    item = named.sort((a, b) => String(b.created ?? '').localeCompare(String(a.created ?? '')) || Number(b.id) - Number(a.id))[0];
  }
  if (!item?.id) throw starry.error('invalidResponse', '服务器没有返回新歌单');
  const changes: Record<string, string | boolean> = {};
  if (draft.description) changes.comment = draft.description;
  if (draft.isPrivate === false) changes.public = true;
  if (Object.keys(changes).length > 0) await call(server, 'updatePlaylist', { playlistId: item.id, ...changes });
  return { ...model.playlist(server, { ...item, comment: draft.description, public: draft.isPrivate === false }), trackCount: 0, isOwned: true };
}

export async function editPlaylist(id: string, changes: Partial<PlaylistDraft>): Promise<void> {
  const { server, id: raw } = locate(id);
  const params: Record<string, string | boolean> = {};
  if (changes.name !== undefined) params.name = changes.name;
  if (changes.description !== undefined) params.comment = changes.description;
  if (changes.isPrivate !== undefined) params.public = !changes.isPrivate;
  if (Object.keys(params).length === 0) return;
  await call(server, 'updatePlaylist', { playlistId: raw, ...params });
}

export async function deletePlaylist(id: string): Promise<void> {
  const { server, id: raw } = locate(id);
  await call(server, 'deletePlaylist', { id: raw });
}

/** Songs already in are skipped, and so are songs of other servers; the count is what the list grew by. */
export async function addToPlaylist(id: string, trackIDs: string[]): Promise<number> {
  const { server, id: raw } = locate(id);
  const before = await entries(server, raw);
  const present = new Set(before);
  const fresh = [...new Set(trackIDs.flatMap((track) => rawOn(server, track) ?? []))].filter((song) => !present.has(song));
  if (fresh.length === 0) return 0;
  for (let start = 0; start < fresh.length; start += IDS_PER_REQUEST) {
    await call(server, 'updatePlaylist', { playlistId: raw, songIdToAdd: fresh.slice(start, start + IDS_PER_REQUEST) }, { post: true });
  }
  const after = await entries(server, raw).catch(() => undefined);
  return after ? Math.max(after.length - before.length, 0) : fresh.length;
}

export async function removeFromPlaylist(id: string, trackIDs: string[]): Promise<void> {
  const { server, id: raw } = locate(id);
  const gone = new Set(trackIDs.flatMap((track) => rawOn(server, track) ?? []));
  const now = await entries(server, raw);
  const kept = now.filter((song) => !gone.has(song));
  if (kept.length !== now.length) await writeBack(server, raw, kept);
}

export async function reorderPlaylist(id: string, trackIDs: string[]): Promise<void> {
  const { server, id: raw } = locate(id);
  const now = await entries(server, raw);
  const order = mergeOrder(trackIDs.flatMap((track) => rawOn(server, track) ?? []), now);
  if (order.every((song, index) => song === now[index])) return;
  const kept = await writeBack(server, raw, order);
  // Airsonic-Advanced keeps a playlist in an order of its own, whatever it is sent.
  if (!kept.every((song, index) => song === order[index])) throw starry.error('server', '服务器没有按这个顺序保存歌单');
}
