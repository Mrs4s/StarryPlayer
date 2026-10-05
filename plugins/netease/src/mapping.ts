// NetEase JSON → the plugin interface's models. Songs come in the v3 shape (`ar` / `al` / `dt`) and
// the legacy one (`artists` / `album` / `duration`).

import type { Album, AlbumRef, Artist, ArtistDetail, ArtistRef, Artwork, Comment, Playlist, RankedTrack, SearchOverview, Track, User } from '../../sdk/starry';
import { cities, provinces } from './region-table';
import { array, bool, compact, int, nonEmpty, num, object, str, unique } from './util';

/** The image CDN (`*.126.net`) scales and crops to `?param=WxH`. */
export function artwork(url: unknown): Artwork | undefined {
  const text = str(url);
  if (!text) return undefined;
  const https = text.startsWith('http://') ? `https://${text.slice('http://'.length)}` : text;
  const base = https.split('?')[0];
  return { url: https, sizedTemplate: `${base}?param={width}y{height}` };
}

/** An artist's or album's id; NetEase gives the ones it has no page for (cloud uploads, unmatched names) id 0, which becomes "" (no page). */
export const linkID = (id: string) => (id === '0' ? '' : id);

/** NetEase's `fee`: 0 free, 1 VIP, 4 bought album, 8 free at standard quality. */
export function fee(code: number | undefined): NonNullable<Track['fee']> {
  switch (code) {
    case 1:
      return 'vip';
    case 4:
      return 'purchase';
    case 8:
      return 'freeLowQuality';
    default:
      return 'free';
  }
}

/** `cd` is "1", "01" or "CD 2"; the digits are the disc. */
export function discNumber(text: string): number | undefined {
  const digits = text.replace(/\D/g, '');
  const number = digits ? parseInt(digits, 10) : 0;
  return number > 0 ? number : undefined;
}

function artistRefs(value: unknown): ArtistRef[] {
  return compact(
    array(value).map((a) => {
      const id = str(a?.id);
      return id === undefined ? undefined : { id: linkID(id), name: str(a?.name) ?? '' };
    }),
  );
}

export function track(json: any, privilege?: any): Track | undefined {
  const id = str(json?.id);
  const name = str(json?.name);
  if (id === undefined || name === undefined) return undefined;
  const albumJSON = object(json.al) ?? object(json.album);
  const cover = artwork(albumJSON?.picUrl);
  const albumID = albumJSON ? str(albumJSON.id) : undefined;
  const album: AlbumRef | undefined = albumID === undefined ? undefined : { id: linkID(albumID), name: str(albumJSON.name) ?? '', artwork: cover };
  // The tiers are the generic levels (playback.ts), so their ids.
  const tiers = ['lq'];
  if (json.m != null || json.mMusic != null) tiers.push('sq');
  if (json.h != null || json.hMusic != null) tiers.push('hq');
  if (json.sq != null) tiers.push('lossless');
  if (json.hr != null) tiers.push('hi-res');
  const alias = str(array(json.alia ?? json.alias)[0]) ?? str(array(json.tns)[0]);
  const popularity = num(json.pop);
  const trackNumber = int(json.no);
  const disc = str(json.cd);
  return {
    id,
    title: name,
    alias: alias ? alias : undefined,
    artists: artistRefs(json.ar ?? json.artists),
    album,
    duration: (num(json.dt) ?? num(json.duration) ?? 0) / 1000,
    artwork: cover,
    tiers,
    fee: fee(int(json.fee) ?? int(privilege?.fee)),
    hasVideo: (int(json.mv) ?? 0) > 0,
    popularity: popularity === undefined ? undefined : Math.min(Math.max(popularity / 100, 0), 1),
    discNumber: disc === undefined ? undefined : discNumber(disc),
    trackNumber: trackNumber !== undefined && trackNumber > 0 ? trackNumber : undefined,
  };
}

export function tracks(list: unknown, privileges?: unknown): Track[] {
  const byID = new Map<string, any>();
  for (const p of array(privileges)) {
    const id = str(p?.id);
    if (id !== undefined && !byID.has(id)) byID.set(id, p);
  }
  return compact(array(list).map((json) => track(json, byID.get(str(json?.id) ?? ''))));
}

export const trackWithPrivilege = (json: any) => track(json, json?.privilege);

export function playlist(json: any, currentUserID: string | undefined): Playlist | undefined {
  const id = str(json?.id);
  const name = str(json?.name);
  if (id === undefined || name === undefined) return undefined;
  const creator = object(json.creator);
  const ownerID = str(json.userId) ?? str(creator?.userId);
  return {
    id,
    name,
    artwork: artwork(str(json.coverImgUrl) ?? json.picUrl),
    creatorID: ownerID,
    creatorName: str(creator?.nickname),
    creatorAvatar: artwork(creator?.avatarUrl),
    createdAt: num(json.createTime),
    updatedAt: num(json.updateTime ?? json.trackUpdateTime),
    trackCount: int(json.trackCount) ?? 0,
    playCount: int(json.playCount) ?? 0,
    tags: compact(array(json.tags).map(str)),
    description: str(json.description) ?? str(json.copywriter),
    isOwned: currentUserID !== undefined && ownerID === currentUserID,
    // 10: private.
    isPrivate: json.privacy === undefined || json.privacy === null ? undefined : int(json.privacy) === 10,
  };
}

// Dynamic playlist details name the subscription count `bookedCount`;
// `subscribed` is null for anonymous sessions.
export function playlistCounters(playlistJSON: any, dynamic: any): { subscribed?: number; comments?: number; isSubscribed?: boolean } {
  return {
    subscribed: int(dynamic?.bookedCount) ?? int(playlistJSON?.subscribedCount),
    comments: int(dynamic?.commentCount) ?? int(playlistJSON?.commentCount),
    isSubscribed: bool(dynamic?.subscribed) ?? bool(playlistJSON?.subscribed),
  };
}

export function creativePlaylist(json: any): Playlist | undefined {
  const resource = array(json?.resources)[0];
  const id = str(resource?.resourceId) ?? str(json?.resourceId);
  const name = str(json?.uiElement?.mainTitle?.title) ?? str(resource?.uiElement?.mainTitle?.title);
  if (id === undefined || name === undefined) return undefined;
  const cover = str(json.uiElement?.image?.imageUrl) ?? str(array(json.uiElement?.images)[0]?.imageUrl);
  return {
    id,
    name,
    artwork: artwork(cover),
    trackCount: 0,
    playCount: int((object(resource?.resourceExtInfo) ?? object(resource?.resourceExt))?.playCount) ?? 0,
    tags: compact(array(json.uiElement?.labelTexts).map(str)),
    isOwned: false,
  };
}

export function album(json: any): Album | undefined {
  const id = str(json?.id);
  const name = str(json?.name);
  if (id === undefined || name === undefined) return undefined;
  let artists = artistRefs(json.artists);
  if (!artists.length && object(json.artist)) artists = artistRefs([json.artist]);
  return {
    id,
    name,
    artists,
    artwork: artwork(str(json.picUrl) ?? json.blurPicUrl),
    releaseDate: num(json.publishTime),
    trackCount: int(json.size) ?? 0,
    description: nonEmpty(json.description) ?? nonEmpty(json.briefDesc),
    alias: nonEmpty(compact(array(json.alias).map(str)).join(' / ')) ?? nonEmpty(json.transName),
    releaseType: nonEmpty(json.type),
    edition: nonEmpty(json.subType),
    company: nonEmpty(json.company),
  };
}

/** A user's id, unless missing or 0 (a deleted account). */
export function userID(user: any): string | undefined {
  const id = str(user?.userId);
  return id === undefined || id === '0' ? undefined : id;
}

export function comment(json: any): Comment | undefined {
  const id = str(json?.commentId);
  if (id === undefined) return undefined;
  const user = object(json.user);
  const reply = array(json.beReplied)[0];
  return {
    id,
    userID: userID(user),
    userName: str(user?.nickname) ?? '',
    avatar: artwork(user?.avatarUrl),
    content: str(json.content) ?? '',
    time: num(json.time) ?? 0,
    likedCount: int(json.likedCount) ?? 0,
    isLiked: bool(json.liked) ?? false,
    location: nonEmpty(json.ipLocation?.location),
    replyTo: reply
      ? { commentID: str(reply.beRepliedCommentId), userID: userID(reply.user), userName: str(reply.user?.nickname) ?? '', content: str(reply.content) ?? '该评论已删除' }
      : undefined,
    replyCount: int(json.showFloorComment?.replyCount) ?? 0,
  };
}

/** NetEase's grey stand-in for artists without a picture reads as no picture, so the app shows its own. */
export function artistImage(url: unknown): Artwork | undefined {
  const text = str(url);
  if (text === undefined || text.includes('/5639395138885805.')) return undefined;
  return artwork(text);
}

export function artist(json: any): Artist | undefined {
  const id = str(json?.id);
  const name = str(json?.name);
  if (id === undefined || name === undefined) return undefined;
  const names = compact([json.trans, ...array(json.transNames), ...array(json.alias)].map(nonEmpty)).filter((alias) => alias !== name);
  const aliases = unique(names);
  return {
    id,
    name,
    artwork: artistImage(str(json.avatar) ?? str(json.img1v1Url) ?? json.picUrl),
    albumCount: int(json.albumSize) ?? 0,
    songCount: int(json.musicSize) ?? 0,
    description: nonEmpty(json.briefDesc),
    alias: aliases.length ? aliases.join(' / ') : undefined,
    followerCount: int(json.fansCount),
  };
}

export function artistDetail(json: any, dynamic: any, introduction: any): ArtistDetail | undefined {
  const artistJSON = object(json?.artist) ?? object(json?.data?.artist);
  const mapped = artistJSON ? artist(artistJSON) : undefined;
  if (!mapped) return undefined;
  if (mapped.description === undefined) mapped.description = nonEmpty(introduction?.briefDesc);
  const sections = compact(
    array(introduction?.introduction).map((item) => {
      const title = nonEmpty(item?.ti);
      const text = nonEmpty(item?.txt);
      return title && text ? { title, text } : undefined;
    }),
  );
  return {
    artist: mapped,
    topTracks: tracks(json.hotSongs ?? json.data?.hotSongs, json.songPrivileges),
    photo: artistImage(artistJSON!.picUrl),
    videoCount: int(artistJSON!.mvSize),
    isFollowed: bool(dynamic?.followed) ?? bool(artistJSON!.followed),
    introduction: sections,
  };
}

export function searchArtist(resource: any): Artist | undefined {
  const mapped = resource?.baseInfo?.artistDTO ? artist(resource.baseInfo.artistDTO) : undefined;
  if (mapped && mapped.followerCount === undefined) mapped.followerCount = int(resource.extInfo?.fansSize);
  return mapped;
}

export function searchResource(resource: any, currentUserID: string | undefined): SearchOverview['topResult'] {
  const info = resource?.baseInfo;
  switch (str(resource?.resourceType) ?? str(resource?.type)) {
    case 'song': {
      const song = info?.simpleSongData ? trackWithPrivilege(info.simpleSongData) : undefined;
      return song && { song };
    }
    case 'artist': {
      const found = searchArtist(resource);
      return found && { artist: found };
    }
    case 'album': {
      const found = info?.albumData ? album(info.albumData) : undefined;
      return found && { album: found };
    }
    case 'playlist': {
      const found = info?.pubPlaylistData ? playlist(info.pubPlaylistData, currentUserID) : undefined;
      return found && { playlist: found };
    }
    default:
      return undefined;
  }
}

// Skip unsupported best-match kinds such as shop items and videos.
export function searchOverview(blocks: unknown, currentUserID: string | undefined): SearchOverview {
  const overview: SearchOverview = { songs: [], artists: [], albums: [], playlists: [] };
  for (const block of array(blocks)) {
    const resources = array(block?.resources);
    switch (str(block?.blockCode)) {
      case 'search_block_best_match':
        for (const resource of resources) {
          const top = searchResource(resource, currentUserID);
          if (top) {
            overview.topResult = top;
            break;
          }
        }
        break;
      case 'search_block_song':
        overview.songs = compact(resources.map((r) => (r?.baseInfo?.simpleSongData ? trackWithPrivilege(r.baseInfo.simpleSongData) : undefined)));
        break;
      case 'search_block_artist':
        overview.artists = compact(resources.map(searchArtist));
        break;
      case 'search_block_album':
        overview.albums = compact(resources.map((r) => (r?.baseInfo?.albumData ? album(r.baseInfo.albumData) : undefined)));
        break;
      case 'search_block_playlist':
        overview.playlists = compact(resources.map((r) => (r?.baseInfo?.pubPlaylistData ? playlist(r.baseInfo.pubPlaylistData, currentUserID) : undefined)));
        break;
    }
  }
  return overview;
}

/** Hot-search items (`searchWord`, `iconType`: 1 hot, 2 new, 4 surging, 5 rising). */
export function trends(items: unknown): { query: string; badge?: 'hot' | 'new' | 'surging' | 'rising' }[] {
  const seen = new Set<string>();
  const badges: Record<number, 'hot' | 'new' | 'surging' | 'rising'> = { 1: 'hot', 2: 'new', 4: 'surging', 5: 'rising' };
  return compact(
    array(items).map((item) => {
      const query = nonEmpty(item?.searchWord) ?? nonEmpty(item?.toUserWord);
      if (!query || seen.has(query)) return undefined;
      seen.add(query);
      const badge = badges[int(item.iconType) ?? 0];
      return badge ? { query, badge } : { query };
    }),
  );
}

const ABROAD = 1_000_000;
const MUNICIPALITIES = new Set([110000, 120000, 310000, 500000, 810000, 820000]);

export function regionName(province: number | undefined, city: number | undefined): string | undefined {
  const provinceName = province === undefined ? undefined : provinces[province];
  if (province === undefined || !provinceName) return undefined;
  if (MUNICIPALITIES.has(province)) return provinceName;
  const cityName = city === undefined ? undefined : cities[city];
  if (province === ABROAD) return cityName ?? provinceName;
  return compact([provinceName, cityName]).join(' ');
}

// Search `description` is the verified identity, not the user's signature.
export function userSummary(json: any, signedIn: boolean): User | undefined {
  const id = userID(json);
  if (!id) return undefined;
  return {
    id,
    nickname: str(json.nickname) ?? '',
    avatar: bool(json.defaultAvatar) === true ? undefined : artwork(json.avatarUrl),
    signature: nonEmpty(json.signature),
    isVIP: (int(json.vipType) ?? 0) > 0,
    identity: nonEmpty(json.description),
    followCount: int(json.follows),
    followerCount: int(json.followeds),
    eventCount: int(json.eventCount),
    createdPlaylistCount: int(json.playlistCount),
    isFollowed: signedIn ? (bool(json.followed) ?? false) : undefined,
    followsYou: signedIn && bool(json.mutual) === true,
  };
}

/** A birthday of 1900-01-01 (-2209017600000) means none was set. */
const NO_BIRTHDAY_BEFORE = -1_577_923_200_000;
/** NetEase levels run 0–10. */
const MAX_LEVEL = 10;

// NetEase date fields use UTC+8 without DST.
function beijingDate(ms: number): { year: number; month: number; day: number; time: number } {
  const date = new Date(ms + 8 * 3_600_000);
  return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate(), time: date.getTime() % 86_400_000 };
}

/** `95后`, `00后`: the half decade of the birth year. */
export function generation(birthday: number): string {
  const year = beijingDate(birthday).year % 100;
  return `${String(Math.floor(year / 5) * 5).padStart(2, '0')}后`;
}

/** The day each sign ends in month 1…12; after it the next sign starts. */
const SIGN_ENDS = [19, 18, 20, 19, 20, 21, 22, 22, 22, 23, 21, 21];
const SIGNS = ['摩羯座', '水瓶座', '双鱼座', '白羊座', '金牛座', '双子座', '巨蟹座', '狮子座', '处女座', '天秤座', '天蝎座', '射手座', '摩羯座'];

export function zodiac(birthday: number): string {
  const { month, day } = beijingDate(birthday);
  return SIGNS[day <= SIGN_ENDS[month - 1] ? month - 1 : month];
}

/** Account age: `村龄 12 年`, months in the first year, nothing in the first month. */
export function villageAge(created: number, now: number): string | undefined {
  const from = beijingDate(created);
  const to = beijingDate(now);
  let months = (to.year - from.year) * 12 + (to.month - from.month);
  if (to.day < from.day || (to.day === from.day && to.time < from.time)) months -= 1;
  if (months >= 12) return `村龄 ${Math.floor(months / 12)} 年`;
  return months > 0 ? `村龄 ${months} 个月` : undefined;
}

// Respect `privacyItemUnlimit` for profile details; `followed` requires a signed-in account.
// Default avatars are placeholders and should be treated as missing.
export function userProfile(json: any, isSelf: boolean, signedIn: boolean, relation?: any, now = Date.now()): User | undefined {
  const profile = object(json?.profile);
  const id = str(profile?.userId);
  if (!profile || id === undefined) return undefined;
  const shows = (item: string) => bool(profile.privacyItemUnlimit?.[item]) !== false;
  const birthday = num(profile.birthday);
  const created = num(json.createTime ?? profile.createTime);
  const gender = ({ 1: 'male', 2: 'female' } as const)[int(profile.gender) as 1 | 2];
  return {
    id,
    nickname: str(profile.nickname) ?? '',
    avatar: bool(profile.defaultAvatar) === true ? undefined : artwork(profile.avatarUrl),
    signature: nonEmpty(profile.signature),
    level: int(json.level),
    maxLevel: MAX_LEVEL,
    isVIP: (int(profile.vipType) ?? 0) > 0,
    identity: nonEmpty(profile.mainAuthType?.desc) ?? compact(array(profile.allAuthTypes).map((type) => nonEmpty(type?.desc)))[0],
    gender: shows('gender') ? gender : undefined,
    details: compact([
      ...(shows('age') && birthday !== undefined && birthday > NO_BIRTHDAY_BEFORE ? [generation(birthday), zodiac(birthday)] : []),
      shows('area') ? regionName(int(profile.province), int(profile.city)) : undefined,
      shows('villageAge') && created !== undefined ? villageAge(created, now) : undefined,
    ]),
    followCount: int(profile.follows),
    followerCount: int(profile.followeds),
    eventCount: int(profile.eventCount),
    listenedSongCount: int(json.listenSongs),
    createdPlaylistCount: int(profile.playlistCount),
    isFollowed: signedIn && !isSelf ? (bool(profile.followed) ?? false) : undefined,
    followsYou: signedIn && bool(profile.followMe) === true,
    isRankingPublic: isSelf || bool(json.peopleCanSeeMyPlayRecord) === true,
    areFollowsPublic: isSelf || bool(relation?.canSeeFansOrFollows) !== false,
  };
}

// Other users' listening rankings report playCount as zero.
export function rankedTracks(items: unknown): RankedTrack[] {
  return compact(
    array(items).map((item) => {
      const song = item?.song ? trackWithPrivilege(item.song) : undefined;
      if (!song) return undefined;
      const plays = int(item.playCount) ?? 0;
      return { track: song, score: Math.min(Math.max(int(item.score) ?? 0, 0), 100), playCount: plays > 0 ? plays : undefined };
    }),
  );
}
