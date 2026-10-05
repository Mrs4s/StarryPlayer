import type { Plugin } from '../../sdk/starry';
import * as account from './account';
import * as catalog from './catalog';
import * as library from './library';
import * as lyrics from './lyrics';
import * as playlists from './playlists';
import { qualityTiers, resolve } from './stream';

const plugin: Plugin = {
  id: 'moe.mrs4s.subsonic',
  name: 'Subsonic',
  version: '1.0.0',
  apiVersion: 1,
  author: 'mrs4s',
  description: '连接自建的 Subsonic / OpenSubsonic 服务器（Navidrome、gonic、LMS、Airsonic-Advanced、Ampache 等）：曲库、歌单、收藏、歌词和播放次数',
  homepage: 'https://opensubsonic.netlify.app',
  icon: 'music.note.house',
  // The server is wherever the listener keeps it.
  permissions: { hosts: ['*'] },

  source: {
    qualityTiers,
    // `search3` finds songs, albums and artists; playlists it does not search.
    searchKinds: ['song', 'artist', 'album'],
    artistSongOrders: ['hot', 'time'],
    // Stars: albums and artists take them, playlists do not.
    collectableKinds: ['album', 'artist'],
    playlistOptions: { description: true, privacy: true, privateByDefault: true },

    resolve,

    search: catalog.search,
    searchSuggestions: catalog.searchSuggestions,

    songs: catalog.songs,
    album: catalog.album,
    artist: catalog.artist,
    artistSongs: catalog.artistSongs,
    artistAlbums: catalog.artistAlbums,
    similarArtists: catalog.similarArtists,
    playlist: catalog.playlist,

    homeShelves: catalog.homeShelves,
    allMedia: catalog.allMedia,

    albumSorts: ['title', 'artist', 'year', 'recentlyAdded'],
    libraryAlbums: catalog.libraryAlbums,
    libraryArtists: catalog.libraryArtists,
    libraryGenres: catalog.libraryGenres,

    userPlaylists: library.userPlaylists,
    likedTrackIDs: library.likedTrackIDs,
    setLiked: library.setLiked,
    setCollected: library.setCollected,
    createPlaylist: playlists.createPlaylist,
    editPlaylist: playlists.editPlaylist,
    deletePlaylist: playlists.deletePlaylist,
    addToPlaylist: playlists.addToPlaylist,
    removeFromPlaylist: playlists.removeFromPlaylist,
    reorderPlaylist: playlists.reorderPlaylist,
    personalFM: library.personalFM,
    trashFM: library.trashFM,
    reportPlayback: library.reportPlayback,
  },

  account: {
    methods: ['password'],
    server: { placeholder: 'http://192.168.1.10:4533' },
    multipleAccounts: true,
    connect: account.connect,
    current: account.current,
    refresh: account.refresh,
    loginWithPassword: account.loginWithPassword,
    logout: account.logout,
    signOutLocally: async () => account.signOutLocally(),
    exportCredentials: async () => account.exportCredentials(),
    restoreCredentials: account.restoreCredentials,
  },

  lyrics: {
    detail: '服务器上的歌词（LRC，增强 LRC 为逐字）',
    search: lyrics.search,
    fetch: lyrics.fetch,
  },
};

export default plugin;
