// `cache` is the in-memory TTL in seconds; null disables caching.

import { ep } from './client';

export const Song = {
  detail: ep('/api/v3/song/detail'),
  playerURL: ep('/api/song/enhance/player/url/v1', { cache: null }),
  downloadURL: ep('/api/song/enhance/download/url/v1', { cache: null }),
  privilege: ep('/api/song/enhance/privilege', { cache: 60 }),
  lyric: ep('/api/song/lyric/v1', { cache: 15 * 60 }),
  cloudLyric: ep('/api/cloud/lyric/get', { cache: null }),
  lyricFeedback: ep('/api/v1/feedback/lyric', { cache: null }),
  chorus: ep('/api/song/chorus', { cache: 600 }),
  like: ep('/api/song/like', { cache: null }),
  likeCount: ep('/api/song/red/count', { cache: null }),
  feature: ep('/api/song/feature/detail', { cache: 600 }),
  qualitySizes: ep('/api/song/music/detail/get', { cache: 600 }),
  singleBaseInfo: ep('/api/single/song/baseinfo', { cache: null }),
  copyrightRecommend: ep('/api/song/copyright/rcmd', { cache: null }),
  toast: ep('/api/song/toast', { cache: null }),
  privilegeMessage: ep('/api/privilege/song/message/get', { cache: null }),
  similar: ep('/api/v1/discovery/simiSong'),
  bpm: ep('/api/playermode/showmeta/get'),
};

export const FM = {
  personal: ep('/api/v1/radio/get', { cache: null }),
  skip: ep('/api/v1/radio/skip', { cache: null }),
  trash: ep('/api/radio/trash/add', { cache: null }),
  trashList: ep('/api/v3/radio/trash/get', { cache: null }),
  trashRemove: ep('/api/radio/trash/del/batch', { cache: null }),
  zone: ep('/api/tag/tab/fm/recommends', { cache: null }),
  scene: ep('/api/content/scene/fm/play/list', { cache: null }),
  heartbeat: ep('/api/playmode/intelligence/list', { cache: null }),
};

export const Blacklist = {
  dislikes: ep('/api/music/dislike/get', { cache: null }),
  dislikeChanges: ep('/api/music/dislike/change', { cache: null }),
  add: ep('/api/music-blacklist/add', { cache: null }),
  delete: ep('/api/music-blacklist/delete', { cache: null }),
};

export const PlayRecord = {
  ranking: ep('/api/v1/play/record', { cache: null }),
  rankingRemove: ep('/api/play/record/empty', { cache: null }),
  songs: ep('/api/play-record/song/list', { cache: null }),
  albums: ep('/api/play-record/album/list', { cache: null }),
  playlists: ep('/api/play-record/playlist/list', { cache: null }),
  voices: ep('/api/play-record/voice/list', { cache: null }),
  clear: ep('/api/play-record/clear', { cache: null }),
  batchDelete: ep('/api/play-record/batch/delete', { cache: null }),
  recentShelf: ep('/api/pc/recent/listen/list', { cache: null }),
};

export const Playlist = {
  /** Own / radar / liked lists (`n = trackCount || 500`, `s = 0`, `newStyle`). */
  detailV6: ep('/api/v6/playlist/detail', { cache: null }),
  /** Everyone else's lists (`nginxCache`, `n = 0`), followed by `detailDynamic`. */
  detailV4: ep('/api/playlist/v4/detail', { cache: 60, nginxCache: true }),
  detailDynamic: ep('/api/playlist/detail/dynamic', { cache: null }),
  subscribe: ep('/api/playlist/subscribe', { cache: null }),
  unsubscribe: ep('/api/playlist/unsubscribe', { cache: null }),
  subscribers: ep('/api/playlist/subscribers', { cache: null }),
  create: ep('/api/playlist/create', { cache: null }),
  uniqueCreate: ep('/api/unique/playlist/create', { cache: null }),
  delete: ep('/api/playlist/delete', { cache: null }),
  updateName: '/api/playlist/update/name',
  updateTags: '/api/playlist/tags/update',
  updateDescription: '/api/playlist/desc/update',
  updateCover: ep('/api/playlist/cover/update', { cache: null }),
  updatePrivacy: ep('/api/playlist/update/privacy', { cache: null }),
  updateOrder: ep('/api/playlist/order/update', { cache: null }),
  updatePlayCount: ep('/api/playlist/update/playcount', { cache: null }),
  manipulateTracks: ep('/api/v1/playlist/manipulate/tracks', { cache: null }),
  insertTrack: ep('/api/playlist/track/insert', { cache: null }),
  highQualityTags: ep('/api/playlist/highquality/tags'),
  highQualityList: ep('/api/playlist/highquality/list'),
  catalogue: ep('/api/playlist/catalogue'),
  categoryList: ep('/api/playlist/category/list'),
  listByIDs: ep('/api/playlist/list/get'),
  squareBlocks: ep('/api/playlist/square/block/page'),
  tags: ep('/api/playlist/tags'),
  userPlaylists: ep('/api/user/playlist', { cache: null }),
  userPlaylistsV2: ep('/api/user/playlist/v2', { cache: null }),
  userTopPlaylists: ep('/api/user/playlist/getTop', { cache: null }),
  similar: ep('/api/discovery/simiPlaylist'),
};

export const Album = {
  /** `nginxCache`; falls back to `detailV4` on any error. */
  detailV3: ep('/api/album/v3/detail', { cache: 300, nginxCache: true }),
  detailV4: ep('/api/album/v4/detail', { cache: 300 }),
  detailDynamic: ep('/api/album/detail/dynamic', { cache: null }),
  privilege: ep('/api/album/privilege', { cache: null }),
  subscribe: ep('/api/album/sub', { cache: null }),
  unsubscribe: ep('/api/album/unsub', { cache: null }),
  subscribed: ep('/api/album/sublist', { cache: null }),
  purchasedDigital: ep('/api/digitalAlbum/purchased', { cache: null }),
  newByArea: ep('/api/discovery/new/albums/area'),
};

export const Artist = {
  /** `nginxCache`, `top` = 50 hot songs. */
  detailV3: ep('/api/artist/v3/detail', { cache: 300, nginxCache: true }),
  detailDynamic: ep('/api/artist/detail/dynamic', { cache: null }),
  songs: ep('/api/v2/artist/songs', { cache: 300 }),
  introduction: ep('/api/artist/introduction', { cache: 600 }),
  subscribe: ep('/api/artist/sub', { cache: null }),
  unsubscribe: ep('/api/artist/unsub', { cache: null }),
  list: ep('/api/v1/artist/list'),
  similar: ep('/api/discovery/simiArtist'),
  videos: ep('/api/mlog/artist/video'),
  newWorks: ep('/api/sub/artist/new/works/song-mv/list/v2', { cache: null }),
  newWorksPlayAll: ep('/api/sub/artist/new/works/song/playall', { cache: null }),
  albums: (id: string) => ep(`/api/artist/albums/${id}`, { cache: 300 }),
};

export const Chart = {
  toplists: ep('/api/toplist/detail/v2', { cache: 600 }),
  detail: ep('/api/chart/detail'),
  songs: ep('/api/chart/song/detail'),
};

export const MV = {
  detail: ep('/api/mlog/detail/v1'),
  playURL: ep('/api/song/enhance/play/mv/url', { cache: null }),
  downloadURL: ep('/api/song/enhance/download/mv/url', { cache: null }),
  subscribe: ep('/api/mv/sub', { cache: null }),
  unsubscribe: ep('/api/mv/unsub', { cache: null }),
  subscribeVideo: ep('/api/cloudvideo/video/sub', { cache: null }),
  unsubscribeVideo: ep('/api/cloudvideo/video/unsub', { cache: null }),
};

export const Search = {
  songs: ep('/api/search/song/list/page', { cache: null }),
  complex: ep('/api/search/pc/complex/page/v3', { cache: null }),
  complexLegacy: ep('/api/search/pc/complex/page', { cache: null }),
  tabs: ep('/api/search/pc/result/tab'),
  playlists: ep('/api/v1/search/playlist/get', { cache: null }),
  artists: ep('/api/v1/search/artist/get', { cache: null }),
  albums: ep('/api/v1/search/album/get', { cache: null }),
  users: ep('/api/v1/search/user/get', { cache: null }),
  lyrics: ep('/api/search/resource/lyric', { cache: null }),
  voices: ep('/api/search/voice/get', { cache: null }),
  voicelists: ep('/api/search/voicelist/get', { cache: null }),
  mvs: ep('/api/search/mlog/get', { cache: null }),
  topics: ep('/api/v1/search/topic/get', { cache: null }),
  suggest: ep('/api/search/pc/suggest/keyword/get', { cache: 30 }),
  defaultKeyword: ep('/api/search/default/keyword/get', { cache: 60 }),
  hotCharts: ep('/api/search/pc/chart/list'),
  hotChartDetail: ep('/api/search/pc/chart/detail'),
  recommendKeywords: ep('/api/search/pc/rcmd/keyword/get', { cache: 60 }),
  hotRelatedSongs: ep('/api/hot/search/relate/song/get'),
  matchLocal: ep('/api/search/match/new', { cache: null }),
  /** Legacy typed search (`type` 1 / 10 / 100 / 1000 / 1002 / 1004 / 1006 / 1009); pages with `total`. */
  cloudSearch: ep('/api/cloudsearch/pc', { cache: null }),
};

export const Discovery = {
  /** Daily recommendations (abtest `PH-PC-Blacklist` t1): `data.dailySongs[]`. */
  dailySongs: ep('/api/v3/discovery/recommend/songs', { cache: null }),
  dailySongsV1: ep('/api/v1/discovery/recommend/songs', { cache: null }),
  dailyHistoryDates: ep('/api/discovery/recommend/songs/history/recent', { cache: null }),
  dailyHistory: ep('/api/discovery/recommend/songs/history/detail'),
  dailyDislike: ep('/api/v2/discovery/recommend/dislike', { cache: null }),
  styleDailySongs: ep('/api/homepage/category/daily/song/list', { cache: null }),
  styleDailyConfig: ep('/api/homepage/daily/song/config/get', { cache: null }),
  styleDailyTagSave: ep('/api/homepage/daily/song/tag/save', { cache: null }),
  tagSongs: ep('/api/homepage/rcmd/tag/songs', { cache: null }),
  moreQueueSongs: ep('/api/homepage/more/rcmd/song', { cache: null }),
  homeResources: ep('/api/pc/page/rcmd/resource/show', { cache: null }),
  homeBlockRefresh: ep('/api/pc/page/rcmd/block/resource/refresh', { cache: null }),
  homeBlocks: '/api/homepage/block/page',
  customizeBlocks: '/api/pc/customize/block/page',
  taste: '/api/personalized/taste',
  podcastBlock: '/api/podcast/common/single/block/get',
  voicelistRecommend: '/api/pc/voicelist/rcmd/list',
  featureCards: ep('/api/pc/daily/rcmd/block', { cache: null }),
  banners: ep('/api/v2/banner/get'),
  personalizedNewSongs: ep('/api/personalized/newsong'),
  newSongs: ep('/api/v2/discovery/new/songs'),
  playlistTagRecommend: ep('/api/personalized/playlist/tag/rcmd'),
  personalPlaylistRecommend: ep('/api/pc/personal/page/playlist/rcmd', { cache: null }),
  zoneTabs: ep('/api/secondary/tab/list'),
  likedSongTags: ep('/api/star/song/filter/tag/list', { cache: null }),
  dislike: ep('/api/personalized/dislike', { cache: null }),
  dislikeReasons: ep('/api/personalized/dislike/reason', { cache: null }),
  resourceDislikeReasons: ep('/api/common/resource/dislike/reason', { cache: null }),
  feedDislike: ep('/api/common/feed/resource/dislike', { cache: null }),
};

export const Login = {
  /** Sent with `type` 4. */
  qrKey: ep('/api/login/qrcode/unikey', { cache: null, requiresSession: false }),
  qrCheck: ep('/api/login/qrcode/client/login', { cache: null, requiresSession: false }),
  cellphone: ep('/api/w/login/cellphone', { cache: null, requiresSession: false }),
  email: ep('/api/w/login', { cache: null, requiresSession: false }),
  sendCaptcha: ep('/api/sms/captcha/sent', { cache: null, requiresSession: false }),
  verifyCaptcha: ep('/api/sms/captcha/verify', { cache: null, requiresSession: false }),
  cellphoneExists: ep('/api/cellphone/existence/check', { cache: null, requiresSession: false }),
  register: ep('/api/w/register/cellphone', { cache: null, requiresSession: false }),
  /** Every 20 h for logged-in users (1 h retry on failure). */
  refreshToken: ep('/api/login/token/refresh', { cache: null }),
  /** After a 301 while logged in: `data.action` 1 = still valid, 2 = kicked out. */
  checkToken: ep('/api/middle/account/token/refresh', { cache: null }),
  logout: ep('/api/logout', { cache: null, requiresSession: false }),
  quickLoginList: ep('/api/login/getquickloginlist', { cache: null }),
  switchUser: ep('/api/login/switchuser', { cache: null }),
  account: ep('/api/w/nuser/account/get', { cache: null }),
};

export const User = {
  detail: (uid: string) => ep(`/api/w/v1/user/detail/${uid}`, { cache: 60 }),
  bindings: (uid: string) => ep(`/api/w/v1/user/bindings/${uid}`, { cache: null }),
  vipInfo: ep('/api/music-vip-membership/client/vip/info', { cache: null }),
  personalPage: ep('/api/user/personal/page/info'),
  setting: ep('/api/user/setting', { cache: null }),
  settingUpdate: ep('/api/user/setting/update', { cache: null }),
  follow: (uid: string) => ep(`/api/user/follow/${uid}`, { cache: null }),
  unfollow: (uid: string) => ep(`/api/user/delfollow/${uid}`, { cache: null }),
  follows: (uid: string) => ep(`/api/user/getfollows/${uid}`, { cache: null }),
  followers: ep('/api/user/getfolloweds/', { cache: null }),
  followsMixed: ep('/api/user/follow/users/mixed/get/v2', { cache: null }),
  vipSign: ep('/api/vip-center-bff/task/sign', { cache: null }),
  pointSign: ep('/api/pointmall/user/sign', { cache: null }),
  devices: ep('/api/middle/user/device/list', { cache: null }),
  deviceName: ep('/api/deviceinfo/center/upload', { cache: null }),
  blacklistAdd: ep('/api/blacklist/add', { cache: null }),
  blacklistDelete: ep('/api/blacklist/delete', { cache: null }),
  blacklist: ep('/api/blacklist/get', { cache: null }),
  privateMessages: ep('/api/msg/private/users', { cache: null }),
  notices: ep('/api/msg/notices', { cache: null }),
  counters: ep('/api/pl/count', { cache: null }),
  eventFeed: ep('/api/event/pc/history/feed/get', { cache: null }),
  events: (uid: string) => ep(`/api/event/get/${uid}`, { cache: null }),
  share: ep('/api/share/friends/resource', { cache: null }),
};

export const App = {
  version: ep('/api/pc/version', { cache: null }),
  upgrade: ep('/api/mac/upgrade/get', { cache: null }),
  abtests: ep('/api/rtrs/abt/front/expinfo/list', { cache: null }),
  zone: ep('/api/zone/get'),
};

export const Comment = {
  list: (threadID: string) => ep(`/api/v1/resource/comments/${threadID}`, { cache: null }),
  hot: (threadID: string) => ep(`/api/v1/resource/hotcomments/${threadID}`, { cache: null }),
  /** Sorted comment thread, which also carries each comment's reply count. */
  sorted: ep('/api/v2/resource/comments', { cache: null }),
  floor: ep('/api/resource/comment/floor/get', { cache: null }),
  add: ep('/api/resource/comments/add', { cache: null }),
  reply: ep('/api/v1/resource/comments/reply', { cache: null }),
  delete: ep('/api/resource/comments/delete', { cache: null }),
  like: ep('/api/v1/comment/like', { cache: null }),
  unlike: ep('/api/v1/comment/unlike', { cache: null }),
  /** Like a resource by thread (programs, events, MVs). */
  likeResource: ep('/api/resource/like', { cache: null }),
  unlikeResource: ep('/api/resource/unlike', { cache: null }),
  info: ep('/api/resource/commentInfo/list', { cache: 60 }),
  songCarousel: ep('/api/comment/pc/song/mode/carousel', { cache: null }),
  initialCarousel: ep('/api/comment/pc/song/mode/initial/carousel', { cache: null }),
  user: (uid: string) => ep(`/api/v1/user/comments/${uid}`, { cache: null }),
  replyNotification: ep('/api/user/comments/reply', { cache: null }),
  report: ep('/api/report/reportcomment', { cache: null }),
};

export const Cloud = {
  list: ep('/api/v1/cloud/get', { cache: null }),
  delete: ep('/api/cloud/del', { cache: null }),
  transcodeStatus: ep('/api/v1/cloud/music/status', { cache: null }),
  publish: ep('/api/cloud/pub/v2', { cache: null }),
  download: ep('/api/cloud/dowonload', { cache: null }),
  localMatchBlacklist: ep('/api/music/file/config'),
  localMatchCheck: ep('/api/music/file/check', { cache: null }),
};

export const Podcast = {
  radio: ep('/api/djradio/v3/get', { cache: 60 }),
  programs: ep('/api/v6/dj/program/byradio', { cache: null }),
  programsPaged: ep('/api/v4/dj/program/byradio', { cache: null }),
  program: ep('/api/dj/program/detail', { cache: 60 }),
  programsBatch: ep('/api/dj/program/batch/detail', { cache: null }),
  programTracks: ep('/api/v1/dj/program/tracks', { cache: 300 }),
  programMusics: ep('/api/dj/program/song/musics', { cache: null }),
  programsAround: ep('/api/dj/around/program/v1', { cache: null }),
  searchPrograms: ep('/api/dj/radio/program/search', { cache: null }),
  playCheck: ep('/api/dj/play/url/check', { cache: null }),
  playRecord: ep('/api/dj/playrecord/upload', { cache: null }),
  resumeSetting: ep('/api/dj/user/setting/resumeplay/get', { cache: null }),
  resumeSettingUpdate: ep('/api/dj/user/setting/resumeplay/update', { cache: null }),
  subscribe: ep('/api/djradio/sub', { cache: null }),
  unsubscribe: ep('/api/djradio/unsub', { cache: null }),
  subscribed: ep('/api/djradio/get/subed', { cache: null }),
  created: ep('/api/djradio/get/byuser/v1', { cache: null }),
  categories: ep('/api/dj/radio/category/list'),
  categoryRadios: ep('/api/dj/radio/category/radio/list'),
  rankSquare: ep('/api/podcast/ranklist/square/ranklist/get/v2'),
  block: ep('/api/podcast/common/single/block/get'),
  recommendPrograms: ep('/api/program/recommend/v2', { cache: null }),
  myRecommend: ep('/api/djradio/my/radio/recommend', { cache: null }),
  likedPrograms: ep('/api/content/my/liked/voice', { cache: null }),
  likedProgramCount: ep('/api/content/my/liked/voice/count', { cache: null }),
  mySubscribed: ep('/api/social/my/subscribed/voicelist/v1', { cache: null }),
  myCreated: ep('/api/social/my/created/voicelist/v1', { cache: null }),
  bought: ep('/api/voicelist/bought/list', { cache: null }),
  recentBooks: ep('/api/voice/book/recent', { cache: null }),
  recommendVoices: ep('/api/pc/voicelist/rcmd/list'),
  homeBlocks: ep('/api/voice/homepage/block/page'),
  homeBlockContent: ep('/api/voice/homepage/block/content'),
  playPageRecommend: ep('/api/voice/play/page/rcmd'),
  toplist: (type: string) => ep(`/api/dj/toplist/${type}`),
};

export const Scrobble = {
  logUpload: 'https://music.163.com/api/clientlog/encrypt/upload?multiupload=true',
  logField: 'attach',
};
