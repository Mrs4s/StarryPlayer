import type { Page, RankedTrack, User, UserPage, UserPlaylists } from '../../sdk/starry';
import { businessError, loginRequired, request, type NeteaseError } from './client';
import { PlayRecord, User as UserAPI } from './endpoints';
import { userPlaylistPage } from './library';
import * as map from './mapping';
import { currentUserID } from './state';
import { array, bool, compact, int, str } from './util';

// Anonymous `personal/page/info` can return 404; its failure must not discard user details.
export async function user(id: string): Promise<User> {
  const me = currentUserID();
  const personal = request(UserAPI.personalPage, { userId: id }).catch(() => undefined);
  const json = await request(UserAPI.detail(id), { all: true, userId: id });
  const profile = map.userProfile(json, id === me, me !== undefined, (await personal)?.data?.userRelationDTO);
  if (!profile) throw starry.error('invalidResponse', '网易云的用户响应缺少 profile');
  return profile;
}

/** The user's playlists: pages of 1000 until `more` is false; the lists the user owns are theirs (the liked list first), the rest collected. */
export async function playlistsOfUser(id: string): Promise<UserPlaylists> {
  const me = currentUserID();
  let raw: any[] = [];
  for (let page = 0; page < 10; page++) {
    const json = await userPlaylistPage(id, page);
    raw = raw.concat(array(json?.playlist));
    if (bool(json?.more) !== true) break;
  }
  const lists: Required<UserPlaylists> = { created: [], subscribed: [] };
  for (const item of raw) {
    const playlist = map.playlist(item, me);
    if (!playlist) continue;
    (playlist.creatorID === id ? lists.created : lists.subscribed).push(playlist);
  }
  return lists;
}

const neteaseCode = (error: unknown) => (error as NeteaseError)?.neteaseCode;

/** `v1/play/record` with `limit` 120; code -2 (`无权限访问`) is a hidden ranking. */
export async function listeningRanking(id: string, period: 'week' | 'allTime'): Promise<RankedTrack[]> {
  let json: any;
  try {
    json = await request(PlayRecord.ranking, { offset: 0, total: true, limit: 120, uid: id, type: period === 'week' ? 1 : 0 });
  } catch (error) {
    if (neteaseCode(error) === -2) throw starry.error('rankingHidden', '对方没有公开听歌排行');
    throw error;
  }
  return map.rankedTracks(period === 'week' ? json?.weekData : json?.allData);
}

async function userList(key: string, call: () => Promise<any>): Promise<any> {
  let json: any;
  try {
    json = await call();
  } catch (error) {
    if (neteaseCode(error) === -2) throw followsHidden();
    throw error;
  }
  if (json?.[key] == null && int(json?.code) === 400) throw followsHidden();
  return json;
}

const followsHidden = () => starry.error('followsHidden', '对方没有公开关注和粉丝');

export function userPage(items: unknown, more: unknown, total: unknown, page: Page, signedIn: boolean): UserPage {
  const raw = array(items);
  return {
    users: compact(raw.map((json) => map.userSummary(json, signedIn))),
    total: int(total),
    nextOffset: bool(more) === true && raw.length > 0 ? page.offset + raw.length : undefined,
  };
}

export async function follows(id: string, page: Page): Promise<UserPage> {
  const signedIn = currentUserID() !== undefined;
  const json = await userList('follow', () => request(UserAPI.follows(id), { offset: page.offset, limit: page.limit, getcounts: true }));
  return userPage(json.follow, json.more, json.size, page, signedIn);
}

export async function followers(id: string, page: Page): Promise<UserPage> {
  const signedIn = currentUserID() !== undefined;
  const json = await userList('followeds', () => request(UserAPI.followers, { userId: id, time: 0, getcounts: true, offset: page.offset, limit: page.limit }));
  return userPage(json.followeds, json.more, json.size, page, signedIn);
}

/** 200 / 201 is success; 320 is the follow limit, 316 a blacklist. */
export async function setUserFollowed(id: string, followed: boolean): Promise<void> {
  if (currentUserID() === undefined) throw loginRequired();
  const json = await request(followed ? UserAPI.follow(id) : UserAPI.unfollow(id));
  const code = int(json?.code);
  if (code !== 200 && code !== 201) throw businessError(code ?? -1, str(json?.message));
}
