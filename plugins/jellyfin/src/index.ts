import type { Plugin } from '../../sdk/starry';
import * as account from './account';
import * as catalog from './catalog';
import * as library from './library';
import * as lyrics from './lyrics';
import * as playlists from './playlists';
import { qualityTiers, resolve } from './stream';

const plugin: Plugin = {
  id: 'moe.mrs4s.jellyfin',
  name: 'Jellyfin',
  version: '1.1.0',
  apiVersion: 1,
  author: 'mrs4s',
  description: '连接自己的 Jellyfin 服务器：曲库、歌单、收藏、歌词和播放次数',
  homepage: 'https://jellyfin.org',
  icon: 'server.rack',
  // The server is wherever the listener keeps it.
  permissions: { hosts: ['*'] },

  source: {
    qualityTiers,
    searchKinds: ['song', 'artist', 'album', 'playlist'],
    artistSongOrders: ['hot', 'time'],
    // A playlist the server shows is the account's already.
    collectableKinds: ['album', 'artist'],
    // Description and cover need an administrator; public is for every user of the server.
    playlistOptions: { privacy: true, privateByDefault: true },

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
    methods: ['password', 'code'],
    server: { placeholder: 'http://192.168.1.10:8096' },
    passwordOptional: true,
    codeLogin: { title: '快速连接', hint: '在已登录的 Jellyfin 客户端里打开“快速连接”，输入这个验证码' },
    multipleAccounts: true,
    connect: account.connect,
    current: account.current,
    refresh: account.refresh,
    loginWithPassword: account.loginWithPassword,
    beginCodeLogin: account.beginCodeLogin,
    pollCodeLogin: account.pollCodeLogin,
    logout: account.logout,
    signOutLocally: async () => account.signOutLocally(),
    exportCredentials: async () => account.exportCredentials(),
    restoreCredentials: account.restoreCredentials,
  },

  lyrics: {
    detail: '服务器上的 LRC 歌词，增强 LRC 为逐字',
    search: lyrics.search,
    fetch: lyrics.fetch,
  },
};

export default plugin;
