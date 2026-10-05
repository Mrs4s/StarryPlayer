import type { Plugin } from '../../sdk/starry';
import * as account from './account';
import * as catalog from './catalog';
import * as library from './library';
import * as lyrics from './lyrics';
import * as playlists from './playlists';
import { qualityTiers, resolve } from './playback';
import { reportPlayback } from './scrobble';
import * as users from './users';

const plugin: Plugin = {
  id: 'moe.mrs4s.netease',
  name: '网易云音乐',
  version: '1.0.0',
  apiVersion: 1,
  author: 'mrs4s',
  description: '网易云音乐的歌曲、歌单、账号、评论、用户主页和歌词',
  icon: 'cloud',
  idNamespace: 'netease',
  // interface(3).music.163.com, music.163.com (play reports); ac.dun.163yun.com for the Yidun token.
  permissions: { hosts: ['*.163.com', 'ac.dun.163yun.com'] },

  settings: [
    {
      id: 'connection',
      title: '连接',
      settings: [
        {
          key: 'realIP',
          title: '海外模式',
          detail: '在中国大陆以外使用时保持开启，避免歌曲因地区限制无法播放',
          keywords: 'real ip 地区 海外 版权 网络',
          type: 'toggle',
          default: true,
        },
        {
          key: 'proxy',
          title: '代理',
          detail: '连接网易云音乐时使用，http:// 或 socks5:// 地址，留空则直接连接',
          keywords: 'proxy socks http 翻墙 网络',
          advanced: true,
          type: 'text',
          placeholder: '未设置',
        },
      ],
    },
  ],

  source: {
    qualityTiers,
    webPages: {
      song: 'https://music.163.com/#/song?id={id}',
      playlist: 'https://music.163.com/#/playlist?id={id}',
      album: 'https://music.163.com/#/album?id={id}',
      artist: 'https://music.163.com/#/artist?id={id}',
      user: 'https://music.163.com/#/user/home?id={id}',
    },
    searchKinds: ['song', 'artist', 'album', 'playlist', 'user'],
    artistSongOrders: ['hot', 'time'],
    collectableKinds: ['playlist', 'album', 'artist'],
    // A public playlist cannot be made private again.
    playlistOptions: { description: true, privacy: true, publicIsFinal: true, nameLimit: 40 },
    commentSorts: ['recommended', 'hot', 'latest'],
    canLikeComments: true,

    resolve,

    search: catalog.search,
    searchOverview: catalog.searchOverview,
    searchSuggestions: catalog.searchSuggestions,
    trendingSearches: catalog.trendingSearches,
    searchHints: catalog.searchHints,

    songs: catalog.songs,
    album: catalog.album,
    artist: catalog.artist,
    artistSongs: catalog.artistSongs,
    artistAlbums: catalog.artistAlbums,
    similarArtists: catalog.similarArtists,
    playlist: catalog.playlist,

    recommendedPlaylists: catalog.recommendedPlaylists,
    newSongs: catalog.newSongs,
    newAlbums: catalog.newAlbums,
    topArtists: catalog.topArtists,

    comments: catalog.comments,
    commentThread: catalog.commentThread,
    replies: catalog.replies,
    setCommentLiked: catalog.setCommentLiked,

    user: users.user,
    playlistsOfUser: users.playlistsOfUser,
    listeningRanking: users.listeningRanking,
    follows: users.follows,
    followers: users.followers,
    setUserFollowed: users.setUserFollowed,

    userPlaylists: library.userPlaylists,
    likedPlaylistID: library.likedPlaylistID,
    likedTrackIDs: library.likedTrackIDs,
    setLiked: library.setLiked,
    setCollected: library.setCollected,
    createPlaylist: playlists.createPlaylist,
    editPlaylist: playlists.editPlaylist,
    deletePlaylist: playlists.deletePlaylist,
    addToPlaylist: playlists.addToPlaylist,
    removeFromPlaylist: playlists.removeFromPlaylist,
    reorderPlaylist: playlists.reorderPlaylist,
    dailyRecommendations: library.dailyRecommendations,
    dailyPlaylists: library.dailyPlaylists,
    personalFM: library.personalFM,
    skipFM: library.skipFM,
    trashFM: library.trashFM,
    allMedia: library.allMedia,
    reportPlayback,
  },

  account: {
    methods: ['qrCode', 'phoneCode', 'cookie'],
    cookieHint: '粘贴包含 MUSIC_U 的 Cookie 字符串',
    multipleAccounts: true,
    current: account.current,
    refresh: account.refresh,
    beginQRLogin: account.beginQRLogin,
    pollQRLogin: account.pollQRLogin,
    sendPhoneCode: account.sendPhoneCode,
    loginWithPhoneCode: account.loginWithPhoneCode,
    loginWithCookie: account.loginWithCookie,
    logout: account.logout,
    signOutLocally: account.signOutLocally,
    exportCredentials: async () => account.exportCredentials(),
    restoreCredentials: account.restoreCredentials,
  },

  lyrics: {
    detail: 'YRC 逐字 / LRC，含翻译与音译',
    ttmlFolder: 'ncm-lyrics',
    search: lyrics.search,
    fetch: lyrics.fetch,
  },
};

export default plugin;
