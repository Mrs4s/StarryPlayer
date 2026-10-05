// The account's own: playlists, favourites (liking and collecting are both stars, which the
// server times), personal FM from similar songs, and plays counted on the server.

import { countsAsPlay, nextRadioSongs, stopRadio, trashRadioSong } from '../../common/library';
import { date } from '../../common/server';
import type { Playlist, PlaybackReport, Track } from '../../sdk/starry';
import { clearCatalog, forgetArtist } from './catalog';
import { call, list, locate, requireSession, type Server } from './client';
import * as model from './models';

const accountKey = (server: Server) => `${server.key}:${server.user}`;

export function clearAccountState(): void {
  stopRadio();
  clearCatalog();
}

export async function userPlaylists(): Promise<Playlist[]> {
  const server = requireSession();
  return list((await call(server, 'getPlaylists'))?.playlists?.playlist).map((item) => model.playlist(server, item));
}

/** The starred songs, newest star first (every server says when). */
export async function likedTrackIDs(): Promise<string[]> {
  const server = requireSession();
  const songs = list((await call(server, 'getStarred2'))?.starred2?.song);
  return songs
    .map((song, index) => ({ id: model.track(server, song).id, at: date(song?.starred) ?? 0, index }))
    .sort((a, b) => b.at - a.at || a.index - b.index)
    .map((song) => song.id);
}

export async function setLiked(trackID: string, liked: boolean): Promise<void> {
  const { server, id } = locate(trackID);
  await call(server, liked ? 'star' : 'unstar', { id });
}

/** Albums and artists take stars too; playlists do not. */
export async function setCollected(kind: 'playlist' | 'album' | 'artist', id: string, collected: boolean): Promise<void> {
  if (kind === 'playlist') throw starry.error('notSupported', 'Subsonic 服务器不能收藏歌单');
  const { server, id: raw } = locate(id);
  await call(server, collected ? 'star' : 'unstar', kind === 'album' ? { albumId: raw } : { artistId: raw });
  if (kind === 'artist') forgetArtist(server, raw);
}

const MIX_SIZE = 30;

async function randomSeed(server: Server): Promise<string | undefined> {
  const starred = list((await call(server, 'getStarred2').catch(() => undefined))?.starred2?.song);
  const pick = starred[Math.floor(Math.random() * starred.length)] ?? list((await call(server, 'getRandomSongs', { size: 1 }))?.randomSongs?.song)[0];
  return pick ? model.track(server, pick).id : undefined;
}

/** Songs like the seed: by sound where the server can tell (`sonicSimilarity`), else the server's similar songs (Last.fm's, or its own). */
async function mix(server: Server, seed: string): Promise<Track[]> {
  const { id } = locate(seed);
  if (server.extensions.sonicSimilarity) {
    const matches = list((await call(server, 'getSonicSimilarTracks', { id, count: MIX_SIZE }).catch(() => undefined))?.sonicMatch);
    if (matches.length > 0) return matches.flatMap((match) => (match?.entry ? [model.track(server, match.entry)] : []));
  }
  return list((await call(server, 'getSimilarSongs', { id, count: MIX_SIZE }))?.similarSongs?.song).map((song) => model.track(server, song));
}

/** Endless radio from the library, starting from a starred song; songs at random when the server finds none alike. */
export async function personalFM(_mode: string, firstFetch: boolean): Promise<Track[]> {
  const server = requireSession();
  return nextRadioSongs({
    account: accountKey(server),
    seed: () => randomSeed(server),
    mix: (seed) => mix(server, seed),
    random: async () => list((await call(server, 'getRandomSongs', { size: MIX_SIZE }))?.randomSongs?.song).map((song) => model.track(server, song)),
  }, firstFetch);
}

/** Dislike: never on this account's radio again. */
export async function trashFM(trackID: string): Promise<void> {
  trashRadioSong(accountKey(requireSession()), trackID);
}

// Submit one finished song per scrobble call: LMS ignores extra songs.
// Do not send now-playing reports, which gonic also counts as plays.
export async function reportPlayback(report: PlaybackReport): Promise<void> {
  if (!countsAsPlay(report)) return;
  const { server, id } = locate(report.trackID);
  await call(server, 'scrobble', { id, submission: true, time: Math.round(report.startedAt) });
}
