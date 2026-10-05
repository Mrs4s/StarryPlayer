// Subsonic's Child / AlbumID3 / ArtistID3 / Playlist → the plugin API's models. OpenSubsonic fields are used when they are there (`artists`, `samplingRate`,
// `releaseDate`…), the classic ones otherwise. Covers need the account's credentials, which stay
// the same, so a cover's address does too (the app caches pictures by address). Every song seen is
// kept for `songs(ids)`, as the protocol cannot fetch many by id.

import { isLossless, tiersFor } from '../../common/library';
import { date, positive, text } from '../../common/server';
import type { Album, ArtistRef, Artist, Artwork, LibraryGenre, Playlist, Track } from '../../sdk/starry';
import { ref, restURL, type Server } from './client';

type Item = any;

/** `getCoverArt` of the item's `coverArt` (not its id: gonic and LMS refuse those), at the size the app asks for. */
export function cover(server: Server, coverArt: unknown): Artwork | undefined {
  const id = typeof coverArt === 'number' ? String(coverArt) : text(coverArt);
  if (!id) return undefined;
  const base = restURL(server, 'getCoverArt', { id });
  return { url: `${base}&size=300`, sizedTemplate: `${base}&size={width}` };
}

/** An address the server gave (an artist's picture from Last.fm, Navidrome's own); none for an empty one. */
const plainImage = (value: unknown): Artwork | undefined => {
  const url = text(value);
  return url && /^https?:\/\//i.test(url) ? url : undefined;
};

export interface Format {
  /** Lower case: `mp3`, `flac`, `m4a`, `opus`, `wv`… */
  suffix: string;
  contentType: string;
  lossless: boolean;
  kbps?: number;
  sampleRate?: number;
  bitDepth?: number;
  channels?: number;
  size?: number;
}

export function formatOf(song: Item): Format {
  const suffix = (text(song?.suffix) ?? '').toLowerCase();
  const contentType = (text(song?.contentType) ?? '').toLowerCase();
  const kbps = positive(song?.bitRate);
  // m4a holds AAC or ALAC; only LMS says which, otherwise the bit rate does.
  const mp4 = ['m4a', 'mp4', 'm4b', 'alac'].includes(suffix);
  const lossless = mp4 ? contentType.includes('alac') || suffix === 'alac' || (kbps ?? 0) > 400 : isLossless(suffix) || /flac|wav|aiff|wavpack|x-ape|dsf/.test(contentType);
  return { suffix, contentType, lossless, kbps, sampleRate: positive(song?.samplingRate), bitDepth: positive(song?.bitDepth), channels: positive(song?.channelCount), size: positive(song?.size) };
}

/** The tiers (stream.ts) the file reaches; without a sample rate (gonic, Airsonic), a lossless file reaches `lossless`. */
export function tiersOf(song: Item): string[] {
  const format = formatOf(song);
  return tiersFor(format.lossless, format.sampleRate);
}

/** OpenSubsonic `artists` / `albumArtists`, else the classic `artistId` and `artist` (no id on Airsonic's songs: not linked). */
function artistsOf(server: Server, list: unknown, id: unknown, name: unknown): ArtistRef[] {
  if (Array.isArray(list)) {
    const refs = list.filter((artist) => text(artist?.name)).map((artist) => ({ id: ref(server, artist.id), name: artist.name.trim() }));
    if (refs.length > 0) return refs;
  }
  const single = text(name);
  return single ? [{ id: ref(server, id), name: single }] : [];
}

/** OpenSubsonic `ItemDate` (`{year, month, day}`) as milliseconds. */
function itemDate(value: Item): number | undefined {
  const year = positive(value?.year);
  if (!year) return undefined;
  return Date.UTC(year, Math.max((positive(value.month) ?? 1) - 1, 0), positive(value.day) ?? 1);
}

const RELEASE_TYPES: Record<string, string> = { ep: 'EP', single: '单曲', compilation: '合辑', live: '现场', soundtrack: '原声', remix: '混音', demo: 'Demo' };

export function track(server: Server, song: Item): Track {
  const albumID = ref(server, song.albumId);
  const artwork = cover(server, song.coverArt);
  const kept: Track = {
    id: ref(server, song.id),
    title: text(song.title) ?? text(song.path)?.split('/').pop() ?? '',
    artists: artistsOf(server, song.artists, song.artistId, song.displayArtist ?? song.artist),
    album: albumID ? { id: albumID, name: text(song.album) ?? '', artwork } : undefined,
    duration: positive(song.duration) ?? 0,
    artwork,
    tiers: tiersOf(song),
    discNumber: positive(song.discNumber),
    trackNumber: positive(song.track),
  };
  keep(kept, song);
  return kept;
}

export function album(server: Server, item: Item): Album {
  const types = Array.isArray(item.releaseTypes) ? item.releaseTypes.map((type: unknown) => (typeof type === 'string' ? type.toLowerCase() : '')) : [];
  const releaseType = item.isCompilation === true ? '合辑' : types.map((type: string) => RELEASE_TYPES[type]).find(Boolean);
  return {
    id: ref(server, item.id),
    name: text(item.name) ?? text(item.title) ?? '',
    artists: artistsOf(server, item.artists, item.artistId, item.displayArtist ?? item.artist),
    artwork: cover(server, item.coverArt),
    releaseDate: itemDate(item.releaseDate) ?? itemDate(item.originalReleaseDate) ?? date(undefined, item.year),
    trackCount: positive(item.songCount),
    releaseType,
    edition: text(item.version),
    company: text(item.recordLabels?.[0]?.name),
  };
}

export function artist(server: Server, item: Item): Artist {
  return {
    id: ref(server, item.id),
    name: text(item.name) ?? '',
    artwork: cover(server, item.coverArt) ?? plainImage(item.artistImageUrl),
    albumCount: positive(item.albumCount),
  };
}

/**
 * Its owner is told (`owner`); others' public playlists show too, `readonly` where the server says
 * so (Navidrome, LMS), and may not be changed.
 */
export function playlist(server: Server, item: Item): Playlist {
  const owner = text(item.owner);
  return {
    id: ref(server, item.id),
    name: text(item.name) ?? '',
    artwork: cover(server, item.coverArt),
    creatorName: owner,
    trackCount: typeof item.songCount === 'number' ? item.songCount : undefined,
    description: text(item.comment),
    createdAt: date(item.created),
    updatedAt: date(item.changed),
    isOwned: item.readonly !== true && (!owner || owner.toLowerCase() === server.user.toLowerCase()),
    // Navidrome leaves `public` out when it is false.
    isPrivate: item.public !== true,
  };
}

export function genre(item: Item): LibraryGenre | undefined {
  const name = text(item?.value) ?? text(item?.name);
  const albumCount = typeof item?.albumCount === 'number' ? item.albumCount : 0;
  return name && albumCount > 0 ? { name, albumCount } : undefined;
}

/** A song as it came, with what the server said beyond the model (play count, year, its album's artist). */
export interface Seen {
  track: Track;
  playCount: number;
  year: number;
}

const KEPT = 20000;
const seen = new Map<string, Seen>();

function keep(track: Track, song: Item): void {
  seen.delete(track.id);
  seen.set(track.id, { track, playCount: positive(song.playCount) ?? 0, year: positive(song.year) ?? 0 });
  if (seen.size > KEPT) {
    let drop = KEPT / 10;
    for (const id of seen.keys()) {
      if (drop-- <= 0) break;
      seen.delete(id);
    }
  }
}

export const known = (id: string) => seen.get(id);
