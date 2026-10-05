import type { AlbumDetail, Artist, ArtistDetail, CommentPage, CommentSlice, CommentSort, CommentTarget, Page, Playlist, PlaylistDetail, SearchKind, SearchOverview, SearchResult, Track } from '../../sdk/starry';
import { businessError, ep, request } from './client';
import { Album, Artist as ArtistAPI, Comment, Discovery, Playlist as PlaylistAPI, Search, Song } from './endpoints';
import * as map from './mapping';
import { TRIAL_MODE } from './playback';
import { currentUserID, likedPlaylistIDOf, ownPlaylistIDs } from './state';
import { array, bool, compact, int, nonEmpty, orderedJSON, str, unique, uniqueBy } from './util';

export async function search(query: string, kind: SearchKind, page: Page): Promise<SearchResult> {
  const result: SearchResult = {};
  let count = 0;
  let hasMore: boolean;
  const typed = { s: query, limit: page.limit, offset: page.offset, queryCorrect: true };
  switch (kind) {
    case 'song': {
      const data = (await request(Search.songs, { keyword: query, scene: 'normal', limit: page.limit, offset: page.offset, needCorrect: true, channel: 'typing' }))?.data;
      result.songs = compact(array(data?.resources).map((r) => (r?.baseInfo?.simpleSongData ? map.trackWithPrivilege(r.baseInfo.simpleSongData) : undefined)));
      result.total = int(data?.totalCount);
      count = result.songs.length;
      hasMore = bool(data?.hasMore) ?? (result.total ?? 0) > page.offset + count;
      break;
    }
    case 'album': {
      const data = (await request(Search.albums, typed))?.result;
      result.albums = compact(array(data?.albums).map(map.album));
      result.total = int(data?.albumCount);
      count = result.albums.length;
      hasMore = (result.total ?? 0) > page.offset + count;
      break;
    }
    case 'artist': {
      const data = (await request(Search.artists, typed))?.result;
      result.artists = compact(array(data?.artists).map(map.artist));
      result.total = int(data?.artistCount);
      count = result.artists.length;
      hasMore = (result.total ?? 0) > page.offset + count;
      break;
    }
    case 'playlist': {
      const uid = currentUserID();
      const data = (await request(Search.playlists, typed))?.result;
      result.playlists = compact(array(data?.playlists).map((json) => map.playlist(json, uid)));
      result.total = int(data?.playlistCount);
      count = result.playlists.length;
      hasMore = (result.total ?? 0) > page.offset + count;
      break;
    }
    case 'user': {
      const signedIn = currentUserID() !== undefined;
      const data = (await request(Search.users, typed))?.result;
      result.users = compact(array(data?.userprofiles).map((json) => map.userSummary(json, signedIn)));
      result.total = int(data?.userprofileCount);
      count = result.users.length;
      hasMore = (result.total ?? 0) > page.offset + count;
      break;
    }
    default:
      throw starry.error('notSupported', `不支持的搜索种类：${kind}`);
  }
  // Song search returns 20 results regardless of the requested limit; advance by the returned
  // count.
  result.hasMore = hasMore && count > 0;
  return result;
}

export async function searchSuggestions(prefix: string): Promise<string[]> {
  const data = (await request(Search.suggest, { keyword: prefix }))?.data;
  const words = [...array(data?.suggests), ...array(data?.recs)].map((item) => str(item?.keyword) ?? str(item?.name));
  return unique(compact(words).filter((word) => word.length > 0));
}

// Partial combined-search responses return 599; fall back to typed searches.
export async function searchOverview(query: string): Promise<SearchOverview> {
  let json: any;
  try {
    json = await request(Search.complex, { keyword: query, scene: 'normal', needCorrect: true, channel: 'typing' });
  } catch {
    return composedOverview(query);
  }
  return map.searchOverview(json?.data?.blocks, currentUserID());
}

async function composedOverview(query: string): Promise<SearchOverview> {
  const page = { offset: 0, limit: 10 };
  const [artists, albums, playlists] = await Promise.all((['artist', 'album', 'playlist'] as const).map((kind) => search(query, kind, page).catch(() => undefined)));
  const songs = (await search(query, 'song', page)).songs ?? [];
  return { songs, artists: artists?.artists ?? [], albums: albums?.albums ?? [], playlists: playlists?.playlists ?? [] };
}

export async function trendingSearches() {
  const data = (await request(Search.hotCharts))?.data;
  const chart = str(array(data?.tabInfo?.list)[0]?.id) ?? 'HOT_SEARCH_SONG#@#';
  let items = array(data?.items?.[chart]);
  if (!items.length) items = array((await request(Search.hotChartDetail, { id: chart }))?.data?.itemList);
  return map.trends(items);
}

export async function searchHints() {
  const keywords = array((await request(Search.defaultKeyword))?.data?.keywords);
  return compact(
    keywords.map((item) => {
      const query = nonEmpty(item?.realkeyword);
      return query ? { display: nonEmpty(item.showKeyword) ?? query, query } : undefined;
    }),
  );
}

/** `songs[]` + `privileges[]` for up to 500 ids (`c = [{"id":"…","v":0}]`). */
function songDetail(ids: string[], trialMode: number = TRIAL_MODE.default): Promise<any> {
  return request(Song.detail, { c: JSON.stringify(ids.map((id) => ({ id, v: 0 }))), trialMode });
}

/** Like `songDetail`, in 500-id chunks (asked for together) and merged. */
export async function songDetails(ids: string[]): Promise<{ songs: any[]; privileges: any[] }> {
  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += 500) chunks.push(ids.slice(i, i + 500));
  const answers = await Promise.all(chunks.map((chunk) => songDetail(chunk)));
  return { songs: answers.flatMap((a) => array(a?.songs)), privileges: answers.flatMap((a) => array(a?.privileges)) };
}

export async function songs(ids: string[]): Promise<Track[]> {
  if (!ids.length) return [];
  const { songs, privileges } = await songDetails(ids);
  const byID = new Map(map.tracks(songs, privileges).map((t) => [t.id, t]));
  return compact(ids.map((id) => byID.get(id)));
}

/** v3 detail (`album` with `album.info`, `songs[]`), v4 when it fails. */
async function albumDetail(id: string): Promise<any> {
  try {
    return await request(Album.detailV3, { id });
  } catch (error) {
    if ((error as { code?: string }).code === 'loginRequired') throw error;
    return request(Album.detailV4, { id });
  }
}

export async function album(id: string): Promise<AlbumDetail> {
  const privileges = request(Album.privilege, { id }).catch(() => undefined);
  const dynamic = request(Album.detailDynamic, { id }).catch(() => undefined);
  const json = await albumDetail(id);
  const mapped = json?.album ? map.album(json.album) : undefined;
  if (!mapped) throw starry.error('invalidResponse', '网易云的专辑响应缺少 album');
  const tracks = map.tracks(json.songs, (await privileges)?.data);
  for (const track of tracks) {
    if (track.artwork) continue;
    track.artwork = mapped.artwork;
    if (track.album) track.album.artwork = mapped.artwork;
  }
  if (!mapped.trackCount) mapped.trackCount = tracks.length;
  const counters = await dynamic;
  return {
    album: mapped,
    tracks,
    subscribedCount: int(counters?.subCount),
    commentCount: int(counters?.commentCount) ?? int(json.info?.commentCount),
    isSubscribed: bool(counters?.isSub),
  };
}

/** The v3 detail (top 50 songs), with the follow state from `detail/dynamic` and the introduction; those two may fail without failing the page. */
export async function artist(id: string): Promise<ArtistDetail> {
  const dynamic = request(ArtistAPI.detailDynamic, { id }).catch(() => undefined);
  const introduction = request(ArtistAPI.introduction, { id }).catch(() => undefined);
  const json = await request(ArtistAPI.detailV3, { id, top: 50 });
  const detail = map.artistDetail(json, await dynamic, await introduction);
  if (!detail) throw starry.error('invalidResponse', '网易云的歌手响应缺少 artist');
  return detail;
}

export async function artistSongs(id: string, order: 'hot' | 'time', page: Page): Promise<Track[]> {
  const json = await request(ArtistAPI.songs, { id, limit: page.limit, offset: page.offset, order });
  return map.tracks(json?.songs);
}

export async function artistAlbums(id: string, page: Page) {
  const json = await request(ArtistAPI.albums(id), { limit: page.limit, offset: page.offset });
  return compact(array(json?.hotAlbums).map(map.album));
}

export async function similarArtists(id: string): Promise<Artist[]> {
  const json = await request(ArtistAPI.similar, { artistid: id, limit: 20, offset: 0, total: true });
  return compact(array(json?.artists).map(map.artist));
}

// `trialMode` 43 identifies the liked playlist; `n = 0` requests its track IDs only.
export function playlistDetailV6(id: string, trackCount = 500, trialMode?: number): Promise<any> {
  const body: Record<string, unknown> = { id, n: trackCount, s: 0, newStyle: true };
  if (trialMode) body.trialMode = trialMode;
  return request(PlaylistAPI.detailV6, body);
}

export async function playlist(id: string): Promise<PlaylistDetail> {
  const uid = currentUserID();
  const isOwn = ownPlaylistIDs(uid).has(id);
  const isLiked = likedPlaylistIDOf(uid) === id;
  let json: any;
  let dynamic: any;
  if (isOwn || isLiked) {
    json = await playlistDetailV6(id, 500, isLiked ? TRIAL_MODE.likePlaylist : undefined);
  } else {
    const dynamicAnswer = request(PlaylistAPI.detailDynamic, { id }).catch(() => undefined);
    json = await request(PlaylistAPI.detailV4, { id, n: 0, s: 0 });
    dynamic = await dynamicAnswer;
  }
  const playlistJSON = json?.playlist;
  const mapped = playlistJSON ? map.playlist(playlistJSON, uid) : undefined;
  if (!mapped) throw starry.error('invalidResponse', '网易云的歌单响应缺少 playlist');
  const playCount = int(dynamic?.playCount);
  if (playCount !== undefined) mapped.playCount = playCount;
  const trackIDs = compact(array(playlistJSON.trackIds).map((item) => str(item?.id)));
  if (trackIDs.length) mapped.trackCount = trackIDs.length;
  let tracks = map.tracks(playlistJSON.tracks, json.privileges);
  if (!tracks.length && trackIDs.length) tracks = await songs(trackIDs.slice(0, 500));
  const loaded = new Set(tracks.map((t) => t.id));
  const counters = map.playlistCounters(playlistJSON, dynamic);
  return {
    playlist: mapped,
    tracks,
    pendingTrackIDs: trackIDs.filter((trackID) => !loaded.has(trackID)),
    subscribedCount: counters.subscribed,
    commentCount: counters.comments,
    isSubscribed: counters.isSubscribed,
  };
}

const HOMEPAGE_EXT_INFO = '{"abInfo":{"hp-new-homepageV3.1":"t3"}}';

function homeBlocks(codes: string[]): Promise<any> {
  const cursor = orderedJSON([
    ['offset', 0],
    ['blockCodeOrderList', codes],
  ]);
  return request(ep(Discovery.homeBlocks, { cache: 60 }), { cursor, extInfo: HOMEPAGE_EXT_INFO, newStyle: true });
}

export async function recommendedPlaylists(): Promise<Playlist[]> {
  const json = await homeBlocks(['HOMEPAGE_BLOCK_PLAYLIST_RCMD']);
  const block = array(json?.data?.blocks).find((b) => str(b?.blockCode) === 'HOMEPAGE_BLOCK_PLAYLIST_RCMD');
  return compact(array(block?.creatives).map(map.creativePlaylist));
}

export async function newSongs(): Promise<Track[]> {
  const json = await request(Discovery.personalizedNewSongs, { limit: 12, areaId: 0 });
  return compact(array(json?.result).map((item) => map.track(item?.song ?? item, item?.song?.privilege)));
}

export async function newAlbums(page: Page) {
  const now = new Date();
  const json = await request(Album.newByArea, { area: 'ALL', year: now.getFullYear(), month: now.getMonth() + 1, limit: page.limit, offset: page.offset, rcmd: false });
  const week = page.offset === 0 ? array(json?.weekData) : [];
  return uniqueBy(compact([...week, ...array(json?.monthData)].map(map.album)), (a) => a.id);
}

/** The artist list, hot artists (`initial` -1). */
export async function topArtists(page: Page): Promise<Artist[]> {
  const json = await request(ArtistAPI.list, { area: -1, type: -1, initial: -1, limit: page.limit, offset: page.offset });
  return compact(array(json?.artists).map(map.artist));
}

/** Comment thread ids: the prefix encodes the resource type. */
export function threadID(target: CommentTarget): string {
  switch (target.kind) {
    case 'song':
      return `R_SO_4_${target.id}`;
    case 'album':
      return `R_AL_3_${target.id}`;
    case 'playlist':
      return `A_PL_0_${target.id}`;
  }
}

export async function comments(target: CommentTarget, page: Page): Promise<CommentPage> {
  const json = await request(Comment.list(threadID(target)), {
    limit: page.limit,
    offset: page.offset,
    beforeTime: 0,
    compareUserLocation: false,
    composeConcert: false,
    markReplied: false,
    forceFlatComment: false,
    showInner: false,
    commentId: '0',
  });
  return {
    hot: page.offset === 0 ? compact(array(json?.hotComments).map(map.comment)) : [],
    latest: compact(array(json?.comments).map(map.comment)),
    total: int(json?.total) ?? 0,
    hasMore: bool(json?.more) ?? false,
  };
}

export function splitCursor(cursor: string | null | undefined): { pageNo: number; sortType?: number; cursor: string } {
  const parts = cursor ? cursor.split('|') : [];
  if (parts.length < 3) return { pageNo: 1, cursor: '0' };
  const pageNo = int(parts[0]);
  const sortType = int(parts[1]);
  if (pageNo === undefined || sortType === undefined) return { pageNo: 1, cursor: '0' };
  return { pageNo, sortType, cursor: parts.slice(2).join('|') };
}

// Recommended comments need sortType 1 or 99 depending on the thread. Retry with 99
// on rejection; preserve page, accepted sortType and server cursor for paging.
export async function commentThread(target: CommentTarget, sort: CommentSort, cursor: string | null, limit: number): Promise<CommentSlice> {
  const page = splitCursor(cursor);
  const sortTypes = page.sortType !== undefined ? [page.sortType] : sort === 'recommended' ? [1, 99] : sort === 'hot' ? [2] : [3];
  for (const sortType of sortTypes) {
    const json = await request(Comment.sorted, { threadId: threadID(target), sortType, pageNo: page.pageNo, pageSize: limit, cursor: page.cursor, showInner: false });
    if (int(json?.code) !== 200) continue;
    const data = json.data;
    const list = compact(array(data?.comments).map(map.comment));
    const more = (bool(data?.hasMore) ?? false) && list.length > 0;
    return { comments: list, total: int(data?.totalCount) ?? 0, next: more ? `${page.pageNo + 1}|${sortType}|${str(data?.cursor) ?? '0'}` : null };
  }
  return { comments: [], total: 0, next: null };
}

/**
 * Replies under a comment (`/api/resource/comment/floor/get`), oldest first; the cursor is the server's `time`. A
 * reply that answers the comment itself loses its quote (the floor already shows whom).
 */
export async function replies(commentID: string, target: CommentTarget, cursor: string | null, limit: number): Promise<CommentSlice> {
  const json = await request(Comment.floor, { parentCommentId: commentID, threadId: threadID(target), time: int(cursor) ?? -1, limit });
  // As with the thread: what the server will not list reads as no replies.
  if (int(json?.code) !== 200) return { comments: [], total: 0, next: null };
  const data = json.data;
  const list = compact(array(data?.comments).map(map.comment)).map((reply) => (reply.replyTo?.commentID === commentID ? { ...reply, replyTo: undefined } : reply));
  const more = (bool(data?.hasMore) ?? false) && list.length > 0;
  return { comments: list, total: int(data?.totalCount) ?? 0, next: more ? (str(data?.time) ?? null) : null };
}

export async function setCommentLiked(commentID: string, target: CommentTarget, liked: boolean): Promise<void> {
  if (currentUserID() === undefined) throw starry.error('loginRequired', '需要登录');
  const json = await request(liked ? Comment.like : Comment.unlike, { threadId: threadID(target), commentId: commentID });
  if (int(json?.code) !== 200) throw businessError(int(json?.code) ?? -1, str(json?.message));
}
