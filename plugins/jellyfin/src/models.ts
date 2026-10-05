// BaseItemDto → the plugin API's models. Ids are the server's item
// ids as they come; times are ticks (10⁷ a second); pictures need no token, so their URLs are
// plain (and the same for every account on the server).

import { isLossless, tiersFor } from '../../common/library';
import { date, text } from '../../common/server';
import type { Album, AlbumRef, Artist, ArtistRef, Artwork, LibraryGenre, Playlist, Track } from '../../sdk/starry';
import type { Server } from './client';

type Item = any;

export const SONG_FIELDS = 'MediaStreams';

export function tiersOf(item: Item): string[] | undefined {
  const audio = Array.isArray(item?.MediaStreams) ? item.MediaStreams.find((stream: any) => stream?.Type === 'Audio') : undefined;
  return audio ? tiersFor(isLossless(audio.Codec), audio.SampleRate) : undefined;
}

export const seconds = (ticks: unknown) => (typeof ticks === 'number' && ticks > 0 ? ticks / 1e7 : 0);

/**
 * `/Items/{id}/Images/{type}`, at the size the host asks for. `fillWidth` / `fillHeight` keep the
 * picture's shape and never upscale past the original (12.x).
 */
export function image(server: Server, id: unknown, tag: unknown, type = 'Primary'): Artwork | undefined {
  if (typeof id !== 'string' || !id || typeof tag !== 'string' || !tag) return undefined;
  const base = `${server.address}/Items/${id}/Images/${type}`;
  const sized = (width: string, height: string) => `${base}?fillWidth=${width}&fillHeight=${height}&quality=90&tag=${tag}`;
  return { url: sized('300', '300'), sizedTemplate: sized('{width}', '{height}') };
}

export function wideImage(server: Server, id: unknown, tag: unknown, type = 'Backdrop'): Artwork | undefined {
  if (typeof id !== 'string' || !id || typeof tag !== 'string' || !tag) return undefined;
  const base = `${server.address}/Items/${id}/Images/${type}/0`;
  return { url: `${base}?maxWidth=1280&quality=90&tag=${tag}`, sizedTemplate: `${base}?maxWidth={width}&quality=90&tag=${tag}` };
}

function refs(list: unknown): ArtistRef[] {
  if (!Array.isArray(list)) return [];
  return list.filter((ref) => typeof ref?.Id === 'string' && text(ref?.Name)).map((ref) => ({ id: ref.Id, name: ref.Name.trim() }));
}

function songArtwork(server: Server, item: Item): Artwork | undefined {
  return image(server, item.AlbumId, item.AlbumPrimaryImageTag) ?? image(server, item.Id, item.ImageTags?.Primary);
}

export function track(server: Server, item: Item): Track {
  const artists = refs(item.ArtistItems);
  const albumArtwork = image(server, item.AlbumId, item.AlbumPrimaryImageTag);
  const album: AlbumRef | undefined = typeof item.AlbumId === 'string' && item.AlbumId
    ? { id: item.AlbumId, name: text(item.Album) ?? '', artwork: albumArtwork }
    : undefined;
  return {
    id: item.Id,
    title: text(item.Name) ?? '',
    artists: artists.length > 0 ? artists : refs(item.AlbumArtists),
    album,
    duration: seconds(item.RunTimeTicks),
    artwork: songArtwork(server, item),
    tiers: tiersOf(item),
    discNumber: typeof item.ParentIndexNumber === 'number' ? item.ParentIndexNumber : undefined,
    trackNumber: typeof item.IndexNumber === 'number' ? item.IndexNumber : undefined,
  };
}

export function album(server: Server, item: Item): Album {
  const artists = refs(item.AlbumArtists);
  const count = typeof item.ChildCount === 'number' ? item.ChildCount : typeof item.SongCount === 'number' ? item.SongCount : undefined;
  return {
    id: item.Id,
    name: text(item.Name) ?? '',
    artists: artists.length > 0 ? artists : refs(item.ArtistItems),
    artwork: image(server, item.Id, item.ImageTags?.Primary),
    releaseDate: date(item.PremiereDate, item.ProductionYear),
    trackCount: count,
    description: text(item.Overview),
    company: text(item.Studios?.[0]?.Name),
  };
}

export function artist(server: Server, item: Item): Artist {
  return {
    id: item.Id,
    name: text(item.Name) ?? '',
    artwork: image(server, item.Id, item.ImageTags?.Primary),
    albumCount: typeof item.AlbumCount === 'number' ? item.AlbumCount : undefined,
    songCount: typeof item.SongCount === 'number' ? item.SongCount : undefined,
    description: text(item.Overview),
  };
}

// Exclude metadata-only genres with no albums; Jellyfin may attach them to artists.
export function genre(server: Server, item: Item): LibraryGenre | undefined {
  const name = text(item?.Name);
  const albumCount = typeof item?.AlbumCount === 'number' ? item.AlbumCount : 0;
  if (!name || albumCount <= 0) return undefined;
  return { name, albumCount, artwork: image(server, item.Id, item.ImageTags?.Primary) };
}

/**
 * Who made a playlist is not told; `CanDelete` of the item alone says whether it is the user's
 * (others' public playlists show too; in lists the field is not to be trusted).
 */
export function playlist(server: Server, item: Item): Playlist {
  return {
    id: item.Id,
    name: text(item.Name) ?? '',
    artwork: image(server, item.Id, item.ImageTags?.Primary),
    trackCount: typeof item.ChildCount === 'number' ? item.ChildCount : undefined,
    description: text(item.Overview),
    createdAt: date(item.DateCreated),
    isOwned: item.CanDelete !== false,
  };
}

/** Music playlists: a playlist of videos is left out (old ones may not say). */
export const isMusicPlaylist = (item: Item) => item?.Type === 'Playlist' && item.MediaType !== 'Video';
