// Making a private playlist public is irreversible through this API.
// Reverse added track IDs to preserve their order at the top; 502 means all already exist.

import type { Playlist, PlaylistDraft } from '../../sdk/starry';
import { batch, businessError, loginRequired, request } from './client';
import { playlistDetailV6 } from './catalog';
import { Playlist as PlaylistAPI } from './endpoints';
import * as map from './mapping';
import { currentUserID, likedPlaylistIDOf, ownPlaylistIDs, rememberLibrary } from './state';
import { array, compact, int, str } from './util';

const IDS_PER_CALL = 1000;

function requireUID(): string {
  const uid = currentUserID();
  if (uid === undefined) throw loginRequired();
  return uid;
}

function expect(json: any, success: number[] = [200]): number {
  const code = int(json?.code);
  if (code === 521) throw starry.error('api', '网易云要求先绑定手机号，才能新建歌单');
  if (code === undefined || !success.includes(code)) throw businessError(code ?? -1, str(json?.message) ?? str(json?.msg));
  return code;
}

/** The playlist's song ids in its order (v6 detail with no songs). */
async function songIDs(id: string): Promise<string[]> {
  const json = await playlistDetailV6(id, 0);
  return compact(array(json?.playlist?.trackIds).map((item) => str(item?.id)));
}

const manipulate = (op: 'add' | 'del' | 'update', pid: string, ids: string[]) =>
  request(PlaylistAPI.manipulateTracks, { op, pid, trackIds: JSON.stringify(ids) });

export async function createPlaylist(draft: PlaylistDraft): Promise<Playlist> {
  const uid = requireUID();
  const json = await request(PlaylistAPI.create, { uid, name: draft.name, privacy: draft.isPrivate ? 10 : 0 });
  expect(json);
  const id = str(json?.id) ?? str(json?.playlist?.id);
  if (id === undefined) throw starry.error('invalidResponse', '网易云没有返回新歌单');
  // v6 detail is for the account's own lists.
  rememberLibrary(uid, new Set([...ownPlaylistIDs(uid), id]), likedPlaylistIDOf(uid));
  let description: string | undefined;
  if (draft.description) {
    await editPlaylist(id, { description: draft.description });
    description = draft.description;
  }
  const made = map.playlist({ ...json?.playlist, id, name: str(json?.playlist?.name) ?? draft.name, userId: uid }, uid);
  return { ...made!, trackCount: 0, description, isOwned: true, isPrivate: draft.isPrivate === true };
}

export async function editPlaylist(id: string, changes: Partial<PlaylistDraft>): Promise<void> {
  requireUID();
  if (changes.isPrivate === true) throw starry.error('notSupported', '网易云不能把公开的歌单改回隐私');
  const calls: [string, Record<string, unknown>][] = [];
  if (changes.name !== undefined) calls.push([PlaylistAPI.updateName, { id, name: changes.name }]);
  if (changes.description !== undefined) calls.push([PlaylistAPI.updateDescription, { id, desc: changes.description }]);
  if (calls.length) {
    const answers = await batch(calls);
    for (const [path] of calls) {
      const code = int(answers[path]?.code);
      if (code !== 200) {
        const what = path === PlaylistAPI.updateName ? '歌单名' : '介绍';
        throw businessError(code ?? -1, str(answers[path]?.message) ?? `保存${what}失败`);
      }
    }
  }
  if (changes.isPrivate === false) expect(await request(PlaylistAPI.updatePrivacy, { id, privacy: 0 }));
}

export async function deletePlaylist(id: string): Promise<void> {
  requireUID();
  expect(await request(PlaylistAPI.delete, { pid: id }));
}

export async function addToPlaylist(id: string, trackIDs: string[]): Promise<number> {
  requireUID();
  const present = new Set(await songIDs(id));
  const fresh = [...new Set(trackIDs)].filter((song) => !present.has(song));
  if (fresh.length === 0) return 0;
  // Each call puts its songs on top: the last chunk first, so the first song ends up first.
  let added = 0;
  for (let end = fresh.length; end > 0; end -= IDS_PER_CALL) {
    const chunk = fresh.slice(Math.max(end - IDS_PER_CALL, 0), end);
    const code = expect(await manipulate('add', id, [...chunk].reverse()), [200, 502]);
    if (code === 200) added += chunk.length;
  }
  return added;
}

export async function removeFromPlaylist(id: string, trackIDs: string[]): Promise<void> {
  requireUID();
  const ids = [...new Set(trackIDs)];
  for (let start = 0; start < ids.length; start += IDS_PER_CALL) {
    expect(await manipulate('del', id, ids.slice(start, start + IDS_PER_CALL)));
  }
}

export function mergeOrder(order: string[], now: string[]): string[] {
  const present = new Set(now);
  const ordered = [...new Set(order)].filter((song) => present.has(song));
  const placed = new Set(ordered);
  return [...ordered, ...now.filter((song) => !placed.has(song))];
}

export async function reorderPlaylist(id: string, trackIDs: string[]): Promise<void> {
  requireUID();
  const now = await songIDs(id);
  const order = mergeOrder(trackIDs, now);
  if (order.every((song, index) => song === now[index])) return;
  expect(await manipulate('update', id, order));
}
