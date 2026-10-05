// @ts-check
/// <reference path="../sdk/starry.d.ts" />

const API = 'https://api.audius.co/v1';
const APP = 'starry-player';
const TIER = 'hq';

/**
 * @param {string} path
 * @param {Record<string, string | number | undefined>} [query]
 */
async function api(path, query = {}) {
  const response = await starry.http.get(`${API}${path}`, { query: { ...query, app_name: APP }, responseType: 'json' });
  if (response.status === 404) throw starry.error('notFound', '没有找到，可能已被删除');
  if (response.status !== 200) throw starry.error('network', `Audius 返回 HTTP ${response.status}`);
  return response.body.data;
}

function artwork(sizes) {
  const url = sizes && (sizes['1000x1000'] || sizes['480x480'] || sizes['150x150']);
  if (!url) return undefined;
  const template = /\/\d+x\d+\.jpg$/.test(url) ? url.replace(/\/\d+x\d+\.jpg$/, '/{width}x{height}.jpg') : undefined;
  return { url, sizedTemplate: template, sizeSteps: template ? [150, 480, 1000] : undefined };
}

/** Tracks whose artist left or that are gated cannot be streamed; lists leave them out. */
function playable(items) {
  return items.filter((item) => item.is_streamable !== false && !item.is_stream_gated);
}

/** @returns {import('../sdk/starry').Track} */
function track(item) {
  return {
    id: item.id,
    title: item.title,
    artists: item.user ? [{ id: item.user.id, name: item.user.name }] : [],
    duration: item.duration,
    artwork: artwork(item.artwork),
    tiers: [TIER],
  };
}

/** @returns {import('../sdk/starry').Artist} */
function artist(user) {
  return {
    id: user.id,
    name: user.name,
    artwork: artwork(user.profile_picture),
    songCount: user.track_count,
    albumCount: user.album_count,
    followerCount: user.follower_count,
    description: user.bio || undefined,
  };
}

/** @returns {import('../sdk/starry').Playlist} */
function playlist(item) {
  return {
    id: item.id,
    name: item.playlist_name,
    artwork: artwork(item.artwork),
    creatorID: item.user && item.user.id,
    creatorName: item.user && item.user.name,
    creatorAvatar: item.user && artwork(item.user.profile_picture),
    createdAt: item.created_at,
    updatedAt: item.updated_at,
    trackCount: item.track_count,
    playCount: item.total_play_count,
    description: item.description || undefined,
  };
}

/** @returns {import('../sdk/starry').Album} */
function album(item) {
  return {
    id: item.id,
    name: item.playlist_name,
    artists: item.user ? [{ id: item.user.id, name: item.user.name }] : [],
    artwork: artwork(item.artwork),
    releaseDate: item.release_date || item.created_at,
    trackCount: item.track_count,
    description: item.description || undefined,
  };
}

/** @type {import('../sdk/starry').Plugin} */
module.exports = {
  id: 'co.audius.source',
  name: 'Audius',
  version: '1.0.0',
  apiVersion: 1,
  description: '独立音乐人自己发布的音乐',
  homepage: 'https://audius.co',
  icon: 'waveform',
  permissions: { hosts: ['api.audius.co'] },

  source: {
    qualityTiers: [{ id: TIER, name: '320K', detail: '320 kbps · MP3', level: 'hq' }],
    searchKinds: ['song', 'artist', 'playlist'],
    artistSongOrders: ['hot', 'time'],

    async search(query, kind, page) {
      const paging = { query, limit: page.limit, offset: page.offset };
      switch (kind) {
        case 'song': {
          const items = await api('/tracks/search', paging);
          return { songs: playable(items).map(track), hasMore: items.length >= page.limit };
        }
        case 'artist': {
          const items = await api('/users/search', paging);
          return { artists: items.map(artist), hasMore: items.length >= page.limit };
        }
        case 'playlist': {
          const items = await api('/playlists/search', paging);
          return { playlists: items.filter((item) => !item.is_album).map(playlist), hasMore: items.length >= page.limit };
        }
        default:
          return {};
      }
    },

    async resolve(song) {
      // The stream address is signed and short-lived, so it is asked for just before playing.
      const url = await api(`/tracks/${encodeURIComponent(song.id)}/stream`, { no_redirect: 'true' });
      return { url, container: 'mp3', tier: TIER, expiresIn: 600, info: { bitrate: 320000 } };
    },

    async songs(ids) {
      if (ids.length === 0) return [];
      const query = ids.map((id) => `id=${encodeURIComponent(id)}`).join('&');
      const response = await starry.http.get(`${API}/tracks?${query}&app_name=${APP}`, { responseType: 'json' });
      if (response.status !== 200) throw starry.error('network', `Audius 返回 HTTP ${response.status}`);
      return response.body.data.map(track);
    },

    async artist(id) {
      const [user, top] = await Promise.all([api(`/users/${encodeURIComponent(id)}`), api(`/users/${encodeURIComponent(id)}/tracks`, { sort: 'plays', limit: 50 })]);
      const cover = user.cover_photo && (user.cover_photo['2000x'] || user.cover_photo['640x']);
      return { artist: artist(user), topTracks: playable(top).map(track), photo: cover || undefined };
    },

    async artistSongs(id, order, page) {
      const items = await api(`/users/${encodeURIComponent(id)}/tracks`, { sort: order === 'time' ? 'date' : 'plays', limit: page.limit, offset: page.offset });
      return playable(items).map(track);
    },

    async artistAlbums(id, page) {
      const items = await api(`/users/${encodeURIComponent(id)}/albums`, { limit: page.limit, offset: page.offset });
      return items.map(album);
    },

    async album(id) {
      const [items, tracks] = await Promise.all([api(`/playlists/${encodeURIComponent(id)}`), api(`/playlists/${encodeURIComponent(id)}/tracks`)]);
      return { album: album(items[0]), tracks: playable(tracks).map(track) };
    },

    async playlist(id) {
      const [items, tracks] = await Promise.all([api(`/playlists/${encodeURIComponent(id)}`), api(`/playlists/${encodeURIComponent(id)}/tracks`)]);
      return { playlist: playlist(items[0]), tracks: playable(tracks).map(track) };
    },

    async recommendedPlaylists() {
      const items = await api('/playlists/trending', { limit: 12 });
      return items.map(playlist);
    },

    async newSongs() {
      const items = await api('/tracks/trending', { limit: 20 });
      return playable(items).map(track);
    },
  },
};
