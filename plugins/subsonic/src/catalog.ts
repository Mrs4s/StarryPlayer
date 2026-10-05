// The library: every song by page, the library's albums, artists and
// genres, items by id (on the server their id names), albums, artists, playlists, search and
// Home's shelves. The protocol has no "songs of an artist": they are gathered from the artist's
// albums, and found by name for an artist only on others' songs.

import { mapLimited, text } from '../../common/server';
import type { Album, AlbumDetail, Artist, ArtistDetail, Artwork, HomeShelf, LibraryAlbumSort, LibraryGenre, Page, PlaylistDetail, SearchKind, SearchResult, Track } from '../../sdk/starry';
import { call, codeOf, list, locate, loginRequired, notFound, requireSession, session, type Server } from './client';
import * as model from './models';

/** The most `search3` and `getAlbumList2` hand out at once. */
const PAGE_MAX = 500;
const KEEP_MS = 5 * 60 * 1000;

const songsOf = (server: Server, songs: unknown) => list(songs).map((song) => model.track(server, song));
const albumsOf = (server: Server, albums: unknown) => list(albums).map((album) => model.album(server, album));
const artistsOf = (server: Server, artists: unknown) => list(artists).map((artist) => model.artist(server, artist));

/** Kept for a while, by key; a failure is not kept. */
const kept = new Map<string, { at: number; value: Promise<any> }>();
function remembered<T>(key: string, make: () => Promise<T>): Promise<T> {
  const entry = kept.get(key);
  if (entry && Date.now() - entry.at < KEEP_MS) return entry.value;
  const value = make();
  kept.set(key, { at: Date.now(), value });
  value.catch(() => kept.delete(key));
  return value;
}

export function clearCatalog(): void {
  kept.clear();
}

/** An artist starred or not since: its page asks the server again. */
export function forgetArtist(server: Server, raw: string): void {
  kept.delete(`artist:${server.key}/${raw}`);
}

/** All media: `search3` with an empty query lists the whole library (in the server's order), a page at a time. */
export async function allMedia(page: Page): Promise<{ songs: Track[]; hasMore: boolean; nextOffset: number }> {
  const server = requireSession();
  const limit = Math.min(page.limit, PAGE_MAX);
  const ask = (query: string) => call(server, 'search3', { query, songCount: limit, songOffset: page.offset, artistCount: 0, albumCount: 0 });
  let songs = list((await ask(''))?.searchResult3?.song);
  // A server that wants the empty query quoted.
  if (songs.length === 0 && page.offset === 0) songs = list((await ask('""').catch(() => undefined))?.searchResult3?.song);
  return { songs: songsOf(server, songs), hasMore: songs.length >= limit, nextOffset: page.offset + songs.length };
}

/**
 * Servers that will not list albums by year newest first: Airsonic-Advanced answers nothing,
 * Ampache sorts by name whatever the years. There the whole list is fetched and sorted here.
 */
const yearsSortedHere = new Set<string>();

const ALBUM_LISTS: Record<LibraryAlbumSort, Record<string, string | number>> = {
  title: { type: 'alphabeticalByName' },
  artist: { type: 'alphabeticalByArtist' },
  year: { type: 'byYear', fromYear: 9999, toYear: 0 },
  recentlyAdded: { type: 'newest' },
};

/** Every album, by name, a page of 500 at a time (at most 20 000), kept a while. */
const everyAlbum = (server: Server) =>
  remembered(`albums:${server.key}`, async () => {
    const all: any[] = [];
    for (let offset = 0; offset < 20000; offset += PAGE_MAX) {
      const page = list((await call(server, 'getAlbumList2', { type: 'alphabeticalByName', size: PAGE_MAX, offset }))?.albumList2?.album);
      all.push(...page);
      if (page.length < PAGE_MAX) break;
    }
    return all;
  });

const yearOf = (album: any) => (typeof album?.year === 'number' ? album.year : 0);
const newestFirst = (albums: any[]) => albums.every((album, index) => index === 0 || yearOf(albums[index - 1]) >= yearOf(album));

export async function libraryAlbums(sort: LibraryAlbumSort, genre: string | null, page: Page): Promise<{ albums: Album[]; hasMore: boolean }> {
  const server = requireSession();
  const size = Math.min(page.limit, PAGE_MAX);
  const byYear = sort === 'year' && !genre;
  if (!byYear || !yearsSortedHere.has(server.key)) {
    const albums = list((await call(server, 'getAlbumList2', { ...(genre ? { type: 'byGenre', genre } : ALBUM_LISTS[sort] ?? ALBUM_LISTS.title), size, offset: page.offset }))?.albumList2?.album);
    if (!byYear || page.offset > 0 || (albums.length > 0 && newestFirst(albums))) return { albums: albumsOf(server, albums), hasMore: albums.length >= size };
    yearsSortedHere.add(server.key);
  }
  const sorted = [...(await everyAlbum(server))].sort((a, b) => yearOf(b) - yearOf(a));
  const slice = sorted.slice(page.offset, page.offset + size);
  return { albums: albumsOf(server, slice), hasMore: page.offset + slice.length < sorted.length };
}

/** The server's artist index (`getArtists`), all of it, kept a while. */
const artistIndex = (server: Server) =>
  remembered(`artists:${server.key}`, async () => list((await call(server, 'getArtists'))?.artists?.index).flatMap((index) => list(index?.artist)));

/** The artists by the server's index (its own order), a page at a time. */
export async function libraryArtists(page: Page): Promise<{ artists: Artist[]; total: number }> {
  const server = requireSession();
  const all = await artistIndex(server);
  return { artists: artistsOf(server, all.slice(page.offset, page.offset + page.limit)), total: all.length };
}

export async function libraryGenres(): Promise<LibraryGenre[]> {
  const server = requireSession();
  const items = list((await call(server, 'getGenres'))?.genres?.genre);
  const songCounts = server.type?.toLowerCase() === 'ampache';
  const genres = songCounts
    ? items.filter((item) => text(item?.value) && Number(item?.songCount) > 0).sort((a, b) => Number(b.songCount) - Number(a.songCount)).map((item): LibraryGenre => ({ name: text(item.value)! }))
    : items.flatMap((item) => model.genre(item) ?? []).sort((a, b) => (b.albumCount ?? 0) - (a.albumCount ?? 0));
  await mapLimited(genres.slice(0, 48), 6, async (genre) => {
    const first = list((await call(server, 'getAlbumList2', { type: 'byGenre', genre: genre.name, size: 1 }).catch(() => undefined))?.albumList2?.album)[0];
    if (first) genre.artwork = model.cover(server, first.coverArt);
  });
  return genres;
}

/**
 * Songs by id, in the order asked, those no server has left out: those seen lately as they were,
 * the rest one by one (`getSong`; there is no call for many).
 */
export async function songs(ids: string[]): Promise<Track[]> {
  const found = new Map<string, Track>();
  const missing = [...new Set(ids.filter((id) => typeof id === 'string' && id))].filter((id) => {
    const seen = model.known(id);
    if (seen) found.set(id, seen.track);
    return !seen;
  });
  let failure: unknown;
  await mapLimited(missing, 8, async (id) => {
    try {
      const { server, id: raw } = locate(id);
      const song = (await call(server, 'getSong', { id: raw }))?.song;
      if (song) found.set(id, model.track(server, song));
    } catch (error) {
      if (codeOf(error) !== 'notFound') failure ??= error;
    }
  });
  if (found.size === 0 && failure !== undefined) throw failure;
  return ids.flatMap((id) => (found.has(id) ? [found.get(id)!] : []));
}

export async function album(id: string): Promise<AlbumDetail> {
  const { server, id: raw } = locate(id);
  const item = (await call(server, 'getAlbum', { id: raw }))?.album;
  if (!item) throw notFound();
  const tracks = songsOf(server, item.song);
  const shown = model.album(server, item);
  if (shown.artists?.length === 0) {
    const artists = tracks.flatMap((track) => track.artists ?? []);
    shown.artists = artists.filter((artist, index) => artists.findIndex((other) => other.name === artist.name) === index).slice(0, 3);
  }
  return { album: shown, tracks, isSubscribed: Boolean(item.starred) };
}

const artistItem = (server: Server, raw: string) =>
  remembered(`artist:${server.key}/${raw}`, async () => {
    const item = (await call(server, 'getArtist', { id: raw }))?.artist;
    if (!item) throw notFound();
    return item;
  });

/** `getArtistInfo2`: biography, pictures, similar artists; nothing when the server has none. */
const artistInfo = (server: Server, raw: string) =>
  remembered(`info:${server.key}/${raw}`, async () => (await call(server, 'getArtistInfo2', { id: raw, count: 12 }).catch(() => undefined))?.artistInfo2 ?? {});

/**
 * A picture `getArtistInfo2` gives: elsewhere (Last.fm, Navidrome's own) as it is; the server's
 * own cover (gonic's, with the credentials of that request in it) as this plugin's address of it.
 */
function infoImage(server: Server, value: unknown): Artwork | undefined {
  const url = text(value);
  if (!url || !/^https?:\/\//i.test(url)) return undefined;
  if (url.startsWith(`${server.address}/rest/getCoverArt`)) {
    const id = /[?&]id=([^&]+)/.exec(url)?.[1];
    return id ? model.cover(server, decodeURIComponent(id.replace(/\+/g, ' '))) : undefined;
  }
  return url;
}

export const plainBiography = (html: unknown) => text(typeof html === 'string' ? html.replace(/<a [^>]*>.*?<\/a>\.?/gi, '').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'") : undefined);

// Include search results: artists appearing only on others' songs have no albums on Navidrome.
function artistSongList(server: Server, raw: string): Promise<model.Seen[]> {
  return remembered(`songs:${server.key}/${raw}`, async () => {
    const item = await artistItem(server, raw);
    const albums = list(item.album).slice(0, 100);
    const own = (album: any) => album?.artistId === raw || list(album?.artists).some((artist) => artist?.id === raw);
    const names = (song: any) => list(song?.artists).some((artist) => artist?.id === raw) || song?.artistId === raw;
    const byAlbum = await mapLimited(albums, 6, async (album) => {
      const songs = list((await call(server, 'getAlbum', { id: album.id }).catch(() => undefined))?.album?.song);
      return own(album) ? songs : songs.filter(names);
    });
    const name = text(item.name);
    const found = name ? list((await call(server, 'search3', { query: name, songCount: 200, artistCount: 0, albumCount: 0 }).catch(() => undefined))?.searchResult3?.song).filter(names) : [];
    const result: model.Seen[] = [];
    const taken = new Set<string>();
    for (const song of [...byAlbum.flat(), ...found]) {
      const track = model.track(server, song);
      if (taken.has(track.id)) continue;
      taken.add(track.id);
      result.push(model.known(track.id) ?? { track, playCount: 0, year: 0 });
    }
    return result;
  });
}

function ordered(songs: model.Seen[], order: 'hot' | 'time'): Track[] {
  const indexed = songs.map((seen, index) => ({ seen, index }));
  if (order === 'hot') indexed.sort((a, b) => b.seen.playCount - a.seen.playCount || a.index - b.index);
  else indexed.sort((a, b) => b.seen.year - a.seen.year || a.index - b.index);
  return indexed.map(({ seen }) => seen.track);
}

/** The server's top songs (by id where it can, else by name: Last.fm's, or its own), else the artist's most played. */
async function topSongs(server: Server, raw: string, name: string | undefined): Promise<Track[]> {
  const byID = Boolean(server.extensions.topSongsByArtistId);
  if (byID || name) {
    const result = await call(server, 'getTopSongs', byID ? { id: raw, count: 50 } : { artist: name, count: 50 }).catch(() => undefined);
    const top = songsOf(server, result?.topSongs?.song);
    if (top.length > 0) return top;
  }
  return ordered(await artistSongList(server, raw), 'hot').slice(0, 50);
}

export async function artist(id: string): Promise<ArtistDetail> {
  const { server, id: raw } = locate(id);
  const [item, info] = await Promise.all([artistItem(server, raw), artistInfo(server, raw)]);
  const shown = model.artist(server, item);
  shown.artwork ??= infoImage(server, info?.largeImageUrl ?? info?.mediumImageUrl);
  shown.description = plainBiography(info?.biography);
  return { artist: shown, topTracks: await topSongs(server, raw, text(item.name)), isFollowed: Boolean(item.starred) };
}

export async function artistSongs(id: string, order: 'hot' | 'time', page: Page): Promise<Track[]> {
  const { server, id: raw } = locate(id);
  return ordered(await artistSongList(server, raw), order).slice(page.offset, page.offset + page.limit);
}

export async function artistAlbums(id: string, page: Page): Promise<Album[]> {
  const { server, id: raw } = locate(id);
  const albums = albumsOf(server, (await artistItem(server, raw)).album);
  albums.sort((a, b) => (Number(b.releaseDate) || 0) - (Number(a.releaseDate) || 0));
  return albums.slice(page.offset, page.offset + page.limit);
}

/** The server's similar artists (Last.fm's, or its own), those it has. */
export async function similarArtists(id: string): Promise<Artist[]> {
  const { server, id: raw } = locate(id);
  return artistsOf(server, (await artistInfo(server, raw))?.similarArtist).filter((artist) => artist.id);
}

export async function playlist(id: string): Promise<PlaylistDetail> {
  const { server, id: raw } = locate(id);
  const item = (await call(server, 'getPlaylist', { id: raw }))?.playlist;
  if (!item) throw notFound();
  return { playlist: model.playlist(server, item), tracks: songsOf(server, item.entry) };
}

const SEARCH: Partial<Record<SearchKind, [string, string]>> = { song: ['songCount', 'songOffset'], album: ['albumCount', 'albumOffset'], artist: ['artistCount', 'artistOffset'] };

/** One kind at a time (the others asked for none). Navidrome and Airsonic match songs by artist and album too, gonic and LMS by their names. */
export async function search(query: string, kind: SearchKind, page: Page): Promise<SearchResult> {
  const fields = SEARCH[kind];
  if (!fields || !query.trim()) return {};
  const server = requireSession();
  const limit = Math.min(page.limit, PAGE_MAX);
  const result = (await call(server, 'search3', { query: query.trim(), songCount: 0, albumCount: 0, artistCount: 0, [fields[0]]: limit, [fields[1]]: page.offset }))?.searchResult3 ?? {};
  switch (kind) {
    case 'song': return { songs: songsOf(server, result.song), hasMore: list(result.song).length >= limit };
    case 'album': return { albums: albumsOf(server, result.album), hasMore: list(result.album).length >= limit };
    default: return { artists: artistsOf(server, result.artist), hasMore: list(result.artist).length >= limit };
  }
}

export async function searchSuggestions(prefix: string): Promise<string[]> {
  const server = session();
  if (!server || !prefix.trim()) return [];
  const result = (await call(server, 'search3', { query: prefix.trim(), artistCount: 3, albumCount: 3, songCount: 6 }))?.searchResult3 ?? {};
  const names = [...list(result.artist), ...list(result.album), ...list(result.song)].map((item) => text(item?.name) ?? text(item?.title) ?? '').filter(Boolean);
  return [...new Set(names)].slice(0, 10);
}

export async function homeShelves(): Promise<HomeShelf[]> {
  const server = session();
  if (!server) return [];
  const albums = (type: string) => call(server, 'getAlbumList2', { type, size: 18 }).then((result) => albumsOf(server, result?.albumList2?.album));
  const starred = call(server, 'getStarred2').then((result) => result?.starred2 ?? {});
  const shelves: Promise<HomeShelf>[] = [
    call(server, 'getRandomSongs', { size: 30 }).then((result) => ({ id: 'mix', title: '随便听听', songs: songsOf(server, result?.randomSongs?.song) })),
    albums('newest').then((albums) => ({ id: 'latest', title: '最近添加', albums })),
    albums('recent').then((albums) => ({ id: 'recent', title: '最近播放', albums })),
    albums('frequent').then((albums) => ({ id: 'frequent', title: '最常播放', albums })),
    call(server, 'getPlaylists').then((result) => ({ id: 'playlists', title: '我的歌单', playlists: list(result?.playlists?.playlist).map((item) => model.playlist(server, item)) })),
    starred.then((found) => ({ id: 'favoriteAlbums', title: '收藏的专辑', albums: albumsOf(server, found.album) })),
    starred.then((found) => ({ id: 'favoriteArtists', title: '收藏的歌手', artists: artistsOf(server, found.artist) })),
  ];
  const settled = await Promise.allSettled(shelves);
  const fulfilled = settled.flatMap((result) => (result.status === 'fulfilled' ? [result.value] : []));
  if (fulfilled.length === 0) throw (settled.find((result) => result.status === 'rejected') as PromiseRejectedResult | undefined)?.reason ?? loginRequired();
  return fulfilled;
}
