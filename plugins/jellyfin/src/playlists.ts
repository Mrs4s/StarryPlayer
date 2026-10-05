// Description and cover edits require admin rights, so expose only name and visibility.
// Write complete song lists for compatibility with Jellyfin 10.9 entry IDs.

import { mergeOrder } from '../../common/server';
import type { Playlist, PlaylistDraft } from '../../sdk/starry';
import { api, locate, noteHome, requireSession, type Server } from './client';
import * as model from './models';

const IDS_PER_REQUEST = 100;

interface PlaylistInfo {
  OpenAccess?: boolean;
  ItemIds?: string[];
}

const path = (id: string) => `/Playlists/${encodeURIComponent(id)}`;
const entries = (info: PlaylistInfo | undefined) => (Array.isArray(info?.ItemIds) ? info!.ItemIds.filter((id) => typeof id === 'string') : []);

/** The playlist's entries in order, as `server`'s user. */
export const playlistInfo = (server: Server, id: string) => api<PlaylistInfo>(server, path(id));

export async function createPlaylist(draft: PlaylistDraft): Promise<Playlist> {
  const server = requireSession();
  const created = await api<{ Id?: string }>(server, '/Playlists', {
    json: { Name: draft.name, UserId: server.userId, MediaType: 'Audio', IsPublic: draft.isPrivate === false, Ids: [] },
  });
  if (typeof created?.Id !== 'string') throw starry.error('invalidResponse', '服务器没有返回新歌单');
  noteHome(created.Id, server);
  return { ...model.playlist(server, { Id: created.Id, Name: draft.name, Type: 'Playlist' }), trackCount: 0, isPrivate: draft.isPrivate !== false };
}

export async function editPlaylist(id: string, changes: Partial<PlaylistDraft>): Promise<void> {
  const json: Record<string, unknown> = {};
  if (changes.name !== undefined) json.Name = changes.name;
  if (changes.isPrivate !== undefined) json.IsPublic = !changes.isPrivate;
  if (Object.keys(json).length === 0) return;
  await locate(id, (server) => api(server, path(id), { json }));
}

export async function deletePlaylist(id: string): Promise<void> {
  await locate(id, (server) => api(server, `/Items/${encodeURIComponent(id)}`, { method: 'DELETE' }));
}

/** Songs already in are skipped; the count is what the server's list grew by (it ignores ids it does not have). */
export async function addToPlaylist(id: string, trackIDs: string[]): Promise<number> {
  const { server, value: before } = await locate(id, (server) => playlistInfo(server, id));
  const present = new Set(entries(before));
  const fresh = [...new Set(trackIDs)].filter((song) => !present.has(song));
  if (fresh.length === 0) return 0;
  for (let start = 0; start < fresh.length; start += IDS_PER_REQUEST) {
    await api(server, `${path(id)}/Items`, { method: 'POST', query: { ids: fresh.slice(start, start + IDS_PER_REQUEST).join(','), userId: server.userId } });
  }
  const after = await playlistInfo(server, id).catch(() => undefined);
  return after ? Math.max(entries(after).length - present.size, 0) : fresh.length;
}

export async function removeFromPlaylist(id: string, trackIDs: string[]): Promise<void> {
  const { server, value } = await locate(id, (server) => playlistInfo(server, id));
  const gone = new Set(trackIDs);
  const now = entries(value);
  const kept = now.filter((song) => !gone.has(song));
  if (kept.length === now.length) return;
  await api(server, path(id), { json: { Ids: kept } });
}

export async function reorderPlaylist(id: string, trackIDs: string[]): Promise<void> {
  const { server, value } = await locate(id, (server) => playlistInfo(server, id));
  const now = entries(value);
  const order = mergeOrder(trackIDs, now);
  if (order.every((song, index) => song === now[index])) return;
  await api(server, path(id), { json: { Ids: order } });
}
