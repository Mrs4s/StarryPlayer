// The library: every song by page, the library's albums, artists and genres, items by id (asked
// on the server they live on), albums, artists, playlists, search and Home's shelves.

import { remainingIDs } from '../../common/server';
import type { AlbumDetail, Album, Artist, ArtistDetail, HomeShelf, LibraryAlbumSort, LibraryGenre, Page, PlaylistDetail, SearchKind, SearchResult, Track } from '../../sdk/starry';
import { api, locate, loginRequired, noteHome, notFound, requireSession, serverOf, serversFor, session, type Query, type Server } from './client';
import * as model from './models';
import { playlistInfo } from './playlists';

type Items = { Items?: any[]; TotalRecordCount?: number };

const IDS_PER_REQUEST = 100;
const PLAYLIST_FIRST = 500;

/** `/Items` as `server`'s user: the whole library, small pictures only, no per-user data. */
export function items(server: Server, query: Query): Promise<Items> {
  return api<Items>(server, '/Items', {
    query: { userId: server.userId, Recursive: true, EnableImageTypes: 'Primary', ImageTypeLimit: 1, EnableUserData: false, ...query },
  });
}

export const songItems = (server: Server, query: Query) => items(server, { IncludeItemTypes: 'Audio', Fields: model.SONG_FIELDS, ...query });

const list = (result: Items | undefined) => (Array.isArray(result?.Items) ? result!.Items : []);
const songsOf = (server: Server, result: Items | undefined) => list(result).filter((item) => item?.Type === 'Audio').map((item) => model.track(server, item));

/** One item as `server`'s user, with every field. */
const item = (server: Server, id: string) => api(server, `/Items/${encodeURIComponent(id)}`, { query: { userId: server.userId } });

/** All media: by album artist, album and track, as a shelf of records would be. */
export async function allMedia(page: Page): Promise<{ songs: Track[]; total?: number; nextOffset: number }> {
  const server = requireSession();
  const result = await songItems(server, {
    SortBy: 'AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName',
    StartIndex: page.offset,
    Limit: page.limit,
  });
  return { songs: songsOf(server, result), total: result?.TotalRecordCount, nextOffset: page.offset + list(result).length };
}

const ALBUM_SORTS: Record<LibraryAlbumSort, Query> = {
  title: { SortBy: 'SortName' },
  artist: { SortBy: 'AlbumArtist,ProductionYear,SortName' },
  year: { SortBy: 'ProductionYear,PremiereDate,SortName', SortOrder: 'Descending,Descending,Ascending' },
  recentlyAdded: { SortBy: 'DateCreated,SortName', SortOrder: 'Descending,Ascending' },
};

/** Every album of the current server's music, or a genre's (`Genres` takes its name), by page. */
export async function libraryAlbums(sort: LibraryAlbumSort, genre: string | null, page: Page): Promise<{ albums: Album[]; total?: number }> {
  const server = requireSession();
  const result = await items(server, {
    IncludeItemTypes: 'MusicAlbum',
    Fields: 'ChildCount',
    ...(ALBUM_SORTS[sort] ?? ALBUM_SORTS.title),
    Genres: genre || undefined,
    StartIndex: page.offset,
    Limit: page.limit,
  });
  return { albums: list(result).map((album) => model.album(server, album)), total: result?.TotalRecordCount };
}

// Prefer `/Artists`: `/Items` also includes metadata-only artists without songs.
// Fall back if the deprecated endpoint disappears.
export async function libraryArtists(page: Page): Promise<{ artists: Artist[]; total?: number }> {
  const server = requireSession();
  const query: Query = { SortBy: 'SortName', Fields: 'ItemCounts', StartIndex: page.offset, Limit: page.limit };
  let result: Items;
  try {
    result = await api<Items>(server, '/Artists', {
      query: { userId: server.userId, EnableImageTypes: 'Primary', ImageTypeLimit: 1, EnableUserData: false, ...query },
    });
  } catch (error) {
    if ((error as { code?: string })?.code !== 'notFound') throw error;
    result = await items(server, { IncludeItemTypes: 'MusicArtist', ...query });
  }
  return { artists: list(result).map((artist) => model.artist(server, artist)), total: result?.TotalRecordCount };
}

export async function libraryGenres(): Promise<LibraryGenre[]> {
  const server = requireSession();
  const result = await items(server, { IncludeItemTypes: 'MusicGenre', Fields: 'ItemCounts', SortBy: 'SortName' });
  const genres = list(result).flatMap((item) => model.genre(server, item) ?? []);
  return genres.sort((a, b) => (b.albumCount ?? 0) - (a.albumCount ?? 0));
}

/**
 * Songs by id, in the order asked, those no server has left out. Each is asked where it was last
 * found (or on the current server), what is missing then on the other servers.
 */
export async function songs(ids: string[]): Promise<Track[]> {
  const wanted = [...new Set(ids.filter((id) => typeof id === 'string' && id))];
  const found = new Map<string, Track>();
  const asked = new Map<string, Set<string>>();
  let failure: unknown;
  const ask = async (server: Server, batch: string[]) => {
    const seen = asked.get(server.serverId) ?? new Set<string>();
    asked.set(server.serverId, seen);
    batch.forEach((id) => seen.add(id));
    const chunks: string[][] = [];
    for (let i = 0; i < batch.length; i += IDS_PER_REQUEST) chunks.push(batch.slice(i, i + IDS_PER_REQUEST));
    try {
      const results = await Promise.all(chunks.map((chunk) => songItems(server, { Ids: chunk.join(',') })));
      for (const result of results) {
        for (const song of songsOf(server, result)) {
          if (found.has(song.id)) continue;
          found.set(song.id, song);
          noteHome(song.id, server);
        }
      }
    } catch (error) {
      failure ??= error;
    }
  };
  const first = new Map<string, { server: Server; ids: string[] }>();
  for (const id of wanted) {
    const server = serversFor(id)[0];
    if (!server) throw loginRequired();
    const group = first.get(server.serverId) ?? { server, ids: [] };
    group.ids.push(id);
    first.set(server.serverId, group);
  }
  await Promise.all([...first.values()].map((group) => ask(group.server, group.ids)));
  for (const server of serversFor()) {
    const missing = wanted.filter((id) => !found.has(id) && !asked.get(server.serverId)?.has(id));
    if (missing.length > 0) await ask(server, missing);
  }
  if (found.size === 0 && failure !== undefined) throw failure;
  return ids.flatMap((id) => (found.has(id) ? [found.get(id)!] : []));
}

export async function album(id: string): Promise<AlbumDetail> {
  const { server, value } = await locate(id, (server) => item(server, id));
  const tracks = songsOf(server, await songItems(server, { ParentId: id, SortBy: 'ParentIndexNumber,IndexNumber,SortName' }));
  const album = model.album(server, value);
  if (album.artists?.length === 0) {
    const artists = tracks.flatMap((track) => track.artists ?? []);
    album.artists = artists.filter((artist, index) => artists.findIndex((other) => other.id === artist.id) === index).slice(0, 3);
  }
  return { album, tracks, isSubscribed: value?.UserData?.IsFavorite === true };
}

const ARTIST_ORDERS: Record<'hot' | 'time', Query> = {
  hot: { SortBy: 'PlayCount,SortName', SortOrder: 'Descending,Ascending' },
  time: { SortBy: 'ProductionYear,PremiereDate,Album,ParentIndexNumber,IndexNumber', SortOrder: 'Descending,Descending,Ascending,Ascending,Ascending' },
};

export async function artist(id: string): Promise<ArtistDetail> {
  const { server, value } = await locate(id, (server) => item(server, id));
  const top = await songItems(server, { ArtistIds: id, ...ARTIST_ORDERS.hot, Limit: 50 });
  return {
    artist: model.artist(server, value),
    topTracks: songsOf(server, top),
    photo: model.wideImage(server, value?.Id, value?.BackdropImageTags?.[0]),
    isFollowed: value?.UserData?.IsFavorite === true,
  };
}

/** `hot`: most played first (the server counts each account's plays); `time`: newest first. */
export async function artistSongs(id: string, order: 'hot' | 'time', page: Page): Promise<Track[]> {
  const server = serverOf(id);
  const result = await songItems(server, { ArtistIds: id, ...(ARTIST_ORDERS[order] ?? ARTIST_ORDERS.hot), StartIndex: page.offset, Limit: page.limit });
  return songsOf(server, result);
}

const ALBUM_ORDER: Query = { SortBy: 'ProductionYear,PremiereDate,SortName', SortOrder: 'Descending,Descending,Ascending', Fields: 'ChildCount' };

// Albums without album-artist tags require a fallback through the artist's songs.
export async function artistAlbums(id: string, page: Page): Promise<Album[]> {
  const server = serverOf(id);
  const byArtist = { ArtistIds: id, IncludeItemTypes: 'MusicAlbum' };
  const result = await items(server, { ...byArtist, ...ALBUM_ORDER, StartIndex: page.offset, Limit: page.limit });
  const albums = list(result).map((album) => model.album(server, album));
  const total = result?.TotalRecordCount ?? page.offset + albums.length;
  if (albums.length >= page.limit || page.offset + albums.length < total || page.offset > total) return albums;
  const tagged = new Set(page.offset === 0 ? albums.map((album) => album.id) : list(await items(server, byArtist)).map((album) => album?.Id));
  const songs = await items(server, { ArtistIds: id, IncludeItemTypes: 'Audio', EnableImages: false, Limit: 500 });
  const others = [...new Set(list(songs).map((song) => song?.AlbumId).filter((album): album is string => typeof album === 'string' && !tagged.has(album)))];
  if (others.length === 0) return albums;
  const extra = await items(server, { Ids: others.slice(0, IDS_PER_REQUEST).join(','), IncludeItemTypes: 'MusicAlbum', ...ALBUM_ORDER });
  return [...albums, ...list(extra).map((album) => model.album(server, album))];
}

/** The server's pick: by genres and tags, or ListenBrainz when the library turned it on. */
export async function similarArtists(id: string): Promise<Artist[]> {
  const server = serverOf(id);
  try {
    const result = await api<Items>(server, `/Artists/${encodeURIComponent(id)}/Similar`, { query: { userId: server.userId, Limit: 12 } });
    return list(result).map((artist) => model.artist(server, artist));
  } catch (error) {
    if ((error as { code?: string })?.code === 'notFound') return [];
    throw error;
  }
}

/** The first songs, and the ids of the rest from the playlist's entries (10.9+), which also say whether it is public. */
export async function playlist(id: string): Promise<PlaylistDetail> {
  const { server, value } = await locate(id, (server) => item(server, id));
  const [first, detail] = await Promise.all([
    api<Items>(server, `/Playlists/${encodeURIComponent(id)}/Items`, {
      query: { userId: server.userId, StartIndex: 0, Limit: PLAYLIST_FIRST, Fields: model.SONG_FIELDS, EnableImageTypes: 'Primary', ImageTypeLimit: 1, EnableUserData: false },
    }),
    playlistInfo(server, id).catch(() => undefined),
  ]);
  const tracks = songsOf(server, first);
  let pendingTrackIDs: string[] | undefined;
  if ((first?.TotalRecordCount ?? 0) > list(first).length) {
    if (Array.isArray(detail?.ItemIds)) {
      pendingTrackIDs = remainingIDs(detail!.ItemIds, list(first).map((entry) => entry.Id));
      pendingTrackIDs.forEach((song) => noteHome(song, server));
    } else {
      for (let start = list(first).length; start < (first?.TotalRecordCount ?? 0); start += PLAYLIST_FIRST) {
        const next = await api<Items>(server, `/Playlists/${encodeURIComponent(id)}/Items`, {
          query: { userId: server.userId, StartIndex: start, Limit: PLAYLIST_FIRST, Fields: model.SONG_FIELDS, EnableImageTypes: 'Primary', ImageTypeLimit: 1, EnableUserData: false },
        });
        if (list(next).length === 0) break;
        tracks.push(...songsOf(server, next));
      }
    }
  }
  const shown = { ...model.playlist(server, value), isPrivate: typeof detail?.OpenAccess === 'boolean' ? !detail.OpenAccess : undefined };
  return { playlist: shown, tracks, pendingTrackIDs, isSubscribed: value?.UserData?.IsFavorite === true };
}

const SEARCH_TYPES: Record<string, string> = { song: 'Audio', album: 'MusicAlbum', artist: 'MusicArtist', playlist: 'Playlist' };

/** The server matches names only: a song is not found by its artist's or album's. */
export async function search(query: string, kind: SearchKind, page: Page): Promise<SearchResult> {
  const type = SEARCH_TYPES[kind];
  if (!type) return {};
  const server = requireSession();
  const result = await items(server, {
    searchTerm: query.trim(),
    IncludeItemTypes: type,
    Fields: kind === 'song' ? model.SONG_FIELDS : 'ChildCount',
    StartIndex: page.offset,
    Limit: page.limit,
  });
  const found = list(result);
  const total = result?.TotalRecordCount;
  const paging = { total, hasMore: total === undefined ? found.length >= page.limit : page.offset + found.length < total };
  switch (kind) {
    case 'song': return { songs: songsOf(server, result), ...paging };
    case 'album': return { albums: found.map((album) => model.album(server, album)), ...paging };
    case 'artist': return { artists: found.map((artist) => model.artist(server, artist)), ...paging };
    default: return { playlists: found.filter(model.isMusicPlaylist).map((playlist) => model.playlist(server, playlist)), ...paging };
  }
}

export async function searchSuggestions(prefix: string): Promise<string[]> {
  const server = session();
  if (!server || !prefix.trim()) return [];
  const result = await api<{ SearchHints?: any[] }>(server, '/Search/Hints', {
    query: { userId: server.userId, searchTerm: prefix.trim(), Limit: 10, IncludeItemTypes: 'Audio,MusicAlbum,MusicArtist,Playlist' },
  });
  const names = (result?.SearchHints ?? []).map((hint) => (typeof hint?.Name === 'string' ? hint.Name.trim() : '')).filter(Boolean);
  return [...new Set(names)];
}

export async function homeShelves(): Promise<HomeShelf[]> {
  const server = session();
  if (!server) return [];
  const songs = (query: Query) => songItems(server, query).then((result) => songsOf(server, result));
  const albums = (query: Query) => items(server, { IncludeItemTypes: 'MusicAlbum', Fields: 'ChildCount', ...query }).then((result) => list(result).map((album) => model.album(server, album)));
  const artists = (query: Query) => items(server, { IncludeItemTypes: 'MusicArtist', ...query }).then((result) => list(result).map((artist) => model.artist(server, artist)));
  const shelves: Promise<HomeShelf>[] = [
    songs({ SortBy: 'Random', Limit: 30 }).then((songs) => ({ id: 'mix', title: '随便听听', songs })),
    albums({ SortBy: 'DateCreated,SortName', SortOrder: 'Descending,Ascending', Limit: 18 }).then((albums) => ({ id: 'latest', title: '最近添加', albums })),
    songs({ SortBy: 'PlayCount,DatePlayed', SortOrder: 'Descending,Descending', Filters: 'IsPlayed', Limit: 18 }).then((songs) => ({ id: 'frequent', title: '最常播放', songs })),
    items(server, { IncludeItemTypes: 'Playlist', SortBy: 'SortName', Fields: 'ChildCount' }).then((result) => ({
      id: 'playlists',
      title: '我的歌单',
      playlists: list(result).filter(model.isMusicPlaylist).map((playlist) => model.playlist(server, playlist)),
    })),
    albums({ Filters: 'IsFavorite', SortBy: 'SortName', Limit: 30 }).then((albums) => ({ id: 'favoriteAlbums', title: '收藏的专辑', albums })),
    artists({ Filters: 'IsFavorite', SortBy: 'SortName', Limit: 30 }).then((artists) => ({ id: 'favoriteArtists', title: '收藏的歌手', artists })),
    artists({ SortBy: 'Random', Limit: 18 }).then((artists) => ({ id: 'artists', title: '随机歌手', artists })),
  ];
  const settled = await Promise.allSettled(shelves);
  const fulfilled = settled.flatMap((result) => (result.status === 'fulfilled' ? [result.value] : []));
  if (fulfilled.length === 0) throw (settled.find((result) => result.status === 'rejected') as PromiseRejectedResult | undefined)?.reason ?? notFound();
  return fulfilled;
}
