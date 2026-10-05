// @ts-check
/// <reference path="../sdk/starry.d.ts" />

const API = 'https://lrclib.net/api';

/** Songs from the last searches, so `fetch` rarely needs another request. */
const found = new Map();

function headers() {
  return { 'User-Agent': `Starry Player ${starry.app.version} (LRCLIB plugin ${starry.plugin.version})` };
}

/** @param {string} text */
function splitArtists(text) {
  return String(text || '')
    .split(/\s*(?:,|&|、|\/|;| feat\. | ft\. )\s*/i)
    .filter(Boolean);
}

/** @type {import('../sdk/starry').Plugin} */
module.exports = {
  id: 'net.lrclib.lyrics',
  name: 'LRCLIB',
  version: '1.0.0',
  apiVersion: 1,
  description: '开放的逐行歌词库',
  homepage: 'https://lrclib.net',
  icon: 'text.quote',
  permissions: { hosts: ['lrclib.net'] },

  lyrics: {
    detail: 'LRC 逐行，社区维护',

    async search(keyword) {
      const response = await starry.http.get(`${API}/search`, { query: { q: keyword }, headers: headers(), responseType: 'json' });
      if (response.status !== 200) throw starry.error('network', `LRCLIB 返回 HTTP ${response.status}`);
      if (found.size > 500) found.clear();
      const songs = [];
      for (const item of response.body) {
        if (item.instrumental || !item.syncedLyrics) continue;
        found.set(String(item.id), item);
        songs.push({
          id: String(item.id),
          title: item.trackName,
          artists: splitArtists(item.artistName),
          album: item.albumName || undefined,
          duration: item.duration || undefined,
        });
      }
      return songs;
    },

    async fetch(song) {
      let item = found.get(song.id);
      if (!item) {
        const response = await starry.http.get(`${API}/get/${encodeURIComponent(song.id)}`, { headers: headers(), responseType: 'json' });
        if (response.status === 404) return null;
        if (response.status !== 200) throw starry.error('network', `LRCLIB 返回 HTTP ${response.status}`);
        item = response.body;
      }
      // Lyrics without timing cannot scroll; the host moves on to the next platform.
      return item.syncedLyrics ? { format: 'lrc', body: item.syncedLyrics } : null;
    },
  },
};
