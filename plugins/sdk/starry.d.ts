// Types for Starry Player plugins, API version 1.
// Plain JS: add `// @ts-check` and `/// <reference path=".../starry.d.ts" />`, and type the
// export with `/** @type {import('.../starry').Plugin} */`. TypeScript: import the types and
// bundle to one CommonJS file (`esbuild --bundle --format=cjs`).

/** A URL, or one the host can ask for at other sizes. */
export type Artwork = string | {
  url: string;
  /** The URL with `{width}` and `{height}` where the pixel size goes. */
  sizedTemplate?: string;
  /** The only sizes the host makes, smallest first. */
  sizeSteps?: number[];
};

/** Milliseconds since 1970, or an ISO 8601 date. */
export type DateValue = number | string;

export interface ArtistRef { id: string; name: string }
export interface AlbumRef { id: string; name: string; artwork?: Artwork }

export interface Track {
  /** Must be enough to find the song again: the queue, likes and lyric pins keep it. */
  id: string;
  title: string;
  alias?: string;
  artists?: ArtistRef[];
  album?: AlbumRef;
  /** Seconds. */
  duration: number;
  artwork?: Artwork;
  /** Ids of the `qualityTiers` the song comes in. */
  tiers?: string[];
  fee?: 'free' | 'vip' | 'purchase' | 'freeLowQuality';
  /** 0…1. */
  popularity?: number;
  discNumber?: number;
  trackNumber?: number;
  /** Has a music video on the platform. */
  hasVideo?: boolean;
  /**
   * The song's entries in the AMLL TTML database, when the source knows them (an id from another
   * platform, a tag on the file): asked, in order, before any other id. Kept with the song.
   */
  ttml?: TTMLKey[];
}

/** A folder of the AMLL TTML database (`'am-lyrics'`, `'ncm-lyrics'`, …) and the song's id in it. */
export interface TTMLKey { folder: string; id: string }

export interface Artist {
  id: string;
  name: string;
  artwork?: Artwork;
  albumCount?: number;
  songCount?: number;
  description?: string;
  alias?: string;
  followerCount?: number;
}

export interface Album {
  id: string;
  name: string;
  artists?: ArtistRef[];
  artwork?: Artwork;
  releaseDate?: DateValue;
  trackCount?: number;
  description?: string;
  alias?: string;
  /** Album, EP/Single, compilation… */
  releaseType?: string;
  /** Studio version, live version… */
  edition?: string;
  company?: string;
}

export interface Playlist {
  id: string;
  name: string;
  artwork?: Artwork;
  creatorID?: string;
  creatorName?: string;
  creatorAvatar?: Artwork;
  createdAt?: DateValue;
  updatedAt?: DateValue;
  trackCount?: number;
  playCount?: number;
  tags?: string[];
  description?: string;
  /** The signed-in account made it (its own lists in `userPlaylists`), so it may edit it. */
  isOwned?: boolean;
  /** Only its owner sees it (a private playlist); left out when the platform does not say. */
  isPrivate?: boolean;
}

/** Creating / editing a playlist: the name, and what else `playlistOptions` says the platform keeps. */
export interface PlaylistDraft {
  name: string;
  description?: string;
  isPrivate?: boolean;
}

export interface Page { offset: number; limit: number }

export type QualityLevel = 'lq' | 'sq' | 'hq' | 'lossless' | 'hi-res';

export interface QualityTier {
  id: string;
  /** As the platform names it (`标准`, `极高`, `无损`…). */
  name: string;
  /** `320 kbps · MP3`. */
  detail?: string;
  /** What it counts as on the app's scale (the global quality preference maps to tiers by it). */
  level: QualityLevel;
  /** A spatial mix the system renders (Dolby Atmos): no equalizer, spectrum or sing-along mode on it. */
  spatial?: boolean;
  /** Tag in lists (`无损`, `Hi-Res`, `杜比`). */
  badge?: string;
}

/** `user` needs `user` (listeners' pages to open). */
export type SearchKind = 'song' | 'album' | 'artist' | 'playlist' | 'user';

export interface SearchResult {
  songs?: Track[];
  albums?: Album[];
  artists?: Artist[];
  playlists?: Playlist[];
  users?: User[];
  hasMore?: boolean;
  /** Where the next page starts, when it is not `offset + items returned`. */
  nextOffset?: number;
  total?: number;
}

/** The combined search results: the likeliest thing meant and a few of each kind. Without a top result the host guesses one from exact names. */
export interface SearchOverview {
  topResult?: { song: Track } | { artist: Artist } | { album: Album } | { playlist: Playlist };
  songs?: Track[];
  artists?: Artist[];
  albums?: Album[];
  playlists?: Playlist[];
}

/** A listener's profile page. Built from what the platform shows; leave out what it does not. */
export interface User {
  id: string;
  nickname: string;
  avatar?: Artwork;
  /** The self-description they wrote. */
  signature?: string;
  /** The platform's account level. */
  level?: number;
  /** The highest level the platform has; the page then shows how far along `level` is. */
  maxLevel?: number;
  isVIP?: boolean;
  /** What the platform vouches them for (`音乐人`, `歌单达人`…). */
  identity?: string;
  gender?: 'male' | 'female';
  /**
   * Short facts shown in a row under the name, each worded as the platform words it, only what the
   * user shows: `['95后', '天秤座', '重庆', '村龄 11 年']`.
   */
  details?: string[];
  followCount?: number;
  followerCount?: number;
  /** Posts. */
  eventCount?: number;
  /** Songs listened to in all. */
  listenedSongCount?: number;
  createdPlaylistCount?: number;
  /** Whether the signed-in account follows them; leave out when no one is signed in. */
  isFollowed?: boolean;
  followsYou?: boolean;
  /** Whether the signed-in account may see their listening ranking; true when missing. */
  isRankingPublic?: boolean;
  /** Whether who they follow and who follows them can be seen; true when missing. */
  areFollowsPublic?: boolean;
}

/** The playlists a user made (their liked list first) and the ones they collected. */
export interface UserPlaylists { created?: Playlist[]; subscribed?: Playlist[] }

/** One page of users; `nextOffset` where the next starts (none: this was the last). */
export interface UserPage { users: User[]; total?: number; nextOffset?: number }

/** A song in a listening ranking: `score` 0…100 (the first song's plays are 100), `playCount` when the platform tells. */
export interface RankedTrack { track: Track; score: number; playCount?: number }

export type Container = 'mp3' | 'aac' | 'flac' | 'alac' | 'wav' | 'ogg' | 'ape' | 'mp4' | 'hls';

export interface PlayableAsset {
  /** http(s); the player downloads it, with `headers`. */
  url: string;
  headers?: Record<string, string>;
  /** Guessed from the URL's extension when missing. */
  container?: Container;
  /** The tier this stream is; the one asked for when missing. */
  tier?: string;
  /** Seconds the URL stays valid; 1200 when missing. */
  expiresIn?: number;
  /** A short excerpt rather than the song. */
  trial?: boolean;
  info?: { bitrate?: number; sampleRate?: number; bitDepth?: number; channels?: number; fileSize?: number };
  /** Whether crossfades may overlap this stream with the next. */
  supportsOverlap?: boolean;
  /**
   * The server makes the file while it sends it (a transcode): no length, no byte ranges. The
   * player then downloads all of it and plays it once it is in (seeks work then).
   */
  transcoded?: boolean;
  /**
   * The file comes scrambled: what `source.decryptor` needs to unscramble it (a key, say). The
   * player then downloads it itself and hands every chunk to the decryptor.
   */
  decrypt?: unknown;
  // ReplayGain 2.0 gains target −18 LUFS; peaks use 1 for full scale.
  gain?: { trackGain?: number; trackPeak?: number; albumGain?: number; albumPeak?: number };
}

export type HomeShelf = { id?: string; title: string } & (
  | { songs: Track[] }
  | { albums: Album[] }
  | { artists: Artist[] }
  | { playlists: Playlist[] }
);

/** The library's album orders: by name; by album artist, then year; newest first; last added first. */
export type LibraryAlbumSort = 'title' | 'artist' | 'year' | 'recentlyAdded';

/** A genre of the library's genre list: its name opens its albums (`libraryAlbums`). */
export interface LibraryGenre { name: string; albumCount?: number; artwork?: Artwork }

export interface AlbumDetail { album: Album; tracks?: Track[]; subscribedCount?: number; commentCount?: number; isSubscribed?: boolean }
export interface ArtistDetail { artist: Artist; topTracks?: Track[]; photo?: Artwork; videoCount?: number; isFollowed?: boolean; introduction?: { title: string; text: string }[] }
export interface PlaylistDetail { playlist: Playlist; tracks?: Track[]; pendingTrackIDs?: string[]; subscribedCount?: number; commentCount?: number; isSubscribed?: boolean }

export interface CommentTarget { kind: 'song' | 'album' | 'playlist'; id: string }

export interface Comment {
  id: string;
  userID?: string;
  userName: string;
  avatar?: Artwork;
  content: string;
  time: DateValue;
  likedCount?: number;
  isLiked?: boolean;
  /** Where it was posted from. */
  location?: string;
  /** The comment this one answers. */
  replyTo?: { commentID?: string; userID?: string; userName: string; content: string };
  /** Replies under it (`replies`). */
  replyCount?: number;
}

/** Hot comments come on the first page only. */
export interface CommentPage { hot?: Comment[]; latest?: Comment[]; total?: number; hasMore?: boolean }
/** `next`: the cursor of the next page, or null after the last. */
export interface CommentSlice { comments: Comment[]; total?: number; next?: string | null }

export type CommentSort = 'recommended' | 'hot' | 'latest';

/** A play that ended; times in milliseconds since 1970. */
export interface PlaybackReport {
  trackID: string;
  /** Where it was played from: the playlist's or album's id… */
  context?: { type: 'playlist' | 'album' | 'artist' | 'radio' | 'search' | 'dailyRecommendation' | 'liked' | 'local' | 'allMedia' | 'queue' | 'history' | 'user'; id?: string; name?: string };
  playedSeconds: number;
  duration: number;
  startedAt: number;
  endedAt: number;
}

export interface Source {
  qualityTiers?: QualityTier[];
  /** URL templates with `{id}`, for the copy link and open in browser actions. */
  webPages?: { song?: string; album?: string; artist?: string; playlist?: string; user?: string };
  /** The kinds `search` answers, `'song'` first. */
  searchKinds?: SearchKind[];
  artistSongOrders?: ('hot' | 'time')[];

  /** Required. A fresh address for `track` at `tier`, or at a lower tier when it is not there. */
  resolve(track: Track, tier: QualityTier): Promise<PlayableAsset> | PlayableAsset;
  // Runs synchronously in an isolated plugin copy without network, storage or timers.
  // Modify `bytes` in place; `offset` is the byte position in the file.
  decryptor?(params: any): (bytes: Uint8Array, offset: number) => void;

  search?(query: string, kind: SearchKind, page: Page): Promise<SearchResult>;
  /** The combined search results in one call; without it the host asks `search` for each kind. */
  searchOverview?(query: string): Promise<SearchOverview>;
  searchSuggestions?(prefix: string): Promise<string[]>;
  trendingSearches?(): Promise<(string | { query: string; badge?: 'hot' | 'new' | 'surging' | 'rising' })[]>;
  searchHints?(): Promise<(string | { display: string; query: string })[]>;

  songs?(ids: string[]): Promise<Track[]>;
  album?(id: string): Promise<AlbumDetail>;
  artist?(id: string): Promise<ArtistDetail>;
  artistSongs?(id: string, order: 'hot' | 'time', page: Page): Promise<Track[]>;
  artistAlbums?(id: string, page: Page): Promise<Album[]>;
  similarArtists?(id: string): Promise<Artist[]>;
  playlist?(id: string): Promise<PlaylistDetail>;

  /**
   * Home's shelves in the platform's own words (a server's recently added, most played…), shown
   * after the shelves above: each one kind of item; empty ones are left out.
   */
  homeShelves?(): Promise<HomeShelf[]>;
  recommendedPlaylists?(): Promise<Playlist[]>;
  newSongs?(): Promise<Track[]>;
  newAlbums?(page: Page): Promise<Album[]>;
  topArtists?(page: Page): Promise<Artist[]>;

  // Listeners' profile pages; `user` makes the others count.
  user?(id: string): Promise<User>;
  playlistsOfUser?(id: string): Promise<UserPlaylists>;
  /** The listening ranking, most played first; throw `starry.error('rankingHidden')` when the user keeps it to themself. */
  listeningRanking?(id: string, period: 'week' | 'allTime'): Promise<RankedTrack[]>;
  /** Follows / followers, newest first; throw `starry.error('followsHidden')` when the user keeps them to themself. */
  follows?(id: string, page: Page): Promise<UserPage>;
  followers?(id: string, page: Page): Promise<UserPage>;
  setUserFollowed?(id: string, followed: boolean): Promise<void>;

  // The signed-in account's (`account`).
  /** Own playlists (`isOwned`) and collected ones; the liked list first when there is one. */
  userPlaylists?(): Promise<Playlist[]>;
  /** The playlist that holds the liked songs, when the platform keeps them as one. */
  likedPlaylistID?(): Promise<string | null>;
  /** Newest first. */
  likedTrackIDs?(): Promise<string[]>;
  setLiked?(trackID: string, liked: boolean): Promise<void>;
  /** The kinds `setCollected` takes (collecting / following). */
  collectableKinds?: ('playlist' | 'album' | 'artist')[];
  setCollected?(kind: 'playlist' | 'album' | 'artist', id: string, collected: boolean): Promise<void>;
  // The account's own playlists; declare the ones the platform has.
  /**
   * What a playlist keeps besides its name; whether a new one starts private, whether a public one
   * stays public (the platform cannot make it private again), and the longest name it takes.
   */
  playlistOptions?: { description?: boolean; privacy?: boolean; privateByDefault?: boolean; publicIsFinal?: boolean; nameLimit?: number };
  /** Create a playlist: the new playlist, empty. */
  createPlaylist?(draft: PlaylistDraft): Promise<Playlist>;
  /** Edit a playlist: only what changed is given. */
  editPlaylist?(id: string, changes: Partial<PlaylistDraft>): Promise<void>;
  deletePlaylist?(id: string): Promise<void>;
  /** Add to a playlist: songs already in it are skipped; resolve with how many were added. */
  addToPlaylist?(id: string, trackIDs: string[]): Promise<number>;
  /** Every entry of these songs leaves the playlist. */
  removeFromPlaylist?(id: string, trackIDs: string[]): Promise<void>;
  /**
   * The whole playlist in its new order (`playlist` and its `pendingTrackIDs`, rearranged). Songs
   * added elsewhere since then are not in it: keep them, after the others.
   */
  reorderPlaylist?(id: string, trackIDs: string[]): Promise<void>;
  /** Daily recommendations. */
  dailyRecommendations?(): Promise<Track[]>;
  dailyPlaylists?(): Promise<Playlist[]>;
  /** Personal radio: a few songs a call. */
  personalFM?(mode: 'default' | 'familiar' | 'explore' | 'scene' | 'puzzle', firstFetch: boolean): Promise<Track[]>;
  skipFM?(trackID: string, playedSeconds: number): Promise<void>;
  /** Dislike: the song leaves the radio. */
  trashFM?(trackID: string, playedSeconds: number): Promise<void>;
  // Set `nextOffset` when filtering entries and provide totals when available.
  // Without paging metadata, a full page triggers another request.
  allMedia?(page: Page): Promise<Track[] | { songs: Track[]; total?: number; hasMore?: boolean; nextOffset?: number }>;

  // The library: the whole library as grids (albums, artists, genres), for a library the listener
  // owns (a server of their own) rather than a catalogue. Each one exported is a page of the sidebar.
  /** The orders `libraryAlbums` takes, the default first; without it, by name only. */
  albumSorts?: LibraryAlbumSort[];
  // Return albums in `sort` order. Without totals, a full page triggers another request.
  libraryAlbums?(sort: LibraryAlbumSort, genre: string | null, page: Page): Promise<Album[] | { albums: Album[]; total?: number; hasMore?: boolean }>;
  /** Library artists: the library's artists by name, a page at a time; `songCount` shows on each. */
  libraryArtists?(page: Page): Promise<Artist[] | { artists: Artist[]; total?: number; hasMore?: boolean }>;
  /** Library genres (with `libraryAlbums`): the genres the library's albums carry, all at once. */
  libraryGenres?(): Promise<LibraryGenre[]>;
  reportPlayback?(report: PlaybackReport): Promise<void>;

  // Comments.
  /** The orders `commentThread` reads in, the default first. */
  commentSorts?: CommentSort[];
  canLikeComments?: boolean;
  comments?(target: CommentTarget, page: Page): Promise<CommentPage>;
  /** One page of the thread from `cursor` (null for the first). */
  commentThread?(target: CommentTarget, sort: CommentSort, cursor: string | null, limit: number): Promise<CommentSlice>;
  replies?(commentID: string, target: CommentTarget, cursor: string | null, limit: number): Promise<CommentSlice>;
  setCommentLiked?(commentID: string, target: CommentTarget, liked: boolean): Promise<void>;
}

export interface Profile {
  userID: string;
  nickname: string;
  avatar?: Artwork;
  isVIP?: boolean;
  /** Under the name in account lists: the server the account is on, when accounts can be on several. */
  detail?: string;
}

/** What `connect` reached. */
export interface ServerInfo {
  /** The address as it is used from now on (scheme added, trailing slash dropped). */
  address: string;
  name?: string;
  version?: string;
  /** The ways this server takes, when fewer than `methods` (a server with Quick Connect turned off). */
  methods?: Account['methods'];
}

/**
 * Signing in. The plugin keeps the session itself (in `starry.storage`); every call that
 * signs in answers with the profile, `refresh` with the profile or null.
 */
export interface Account {
  /** `code`: a code shown here that the user enters on a device already signed in (Jellyfin's Quick Connect). */
  methods: ('qrCode' | 'code' | 'cookie' | 'password' | 'phoneCode')[];
  /**
   * A self-hosted server: the login window first asks for its address and hands it to `connect`;
   * the ways show once it is reached, and the login calls sign in there.
   */
  server?: { placeholder?: string };
  /** `loginWithPassword` takes an empty password (a server's users without one). */
  passwordOptional?: boolean;
  /** With `code`: its name in the switch and what to do with the code. */
  codeLogin?: { title: string; hint?: string };
  /** Several QR codes, each scanned with another app. */
  qrKinds?: { id: string; title: string; appName?: string }[];
  /** Under the cookie field: what to paste. */
  cookieHint?: string;
  /** The app may keep several accounts and switch (needs export / restore / signOutLocally). */
  multipleAccounts?: boolean;

  /** The account kept, without the network (shown while `refresh` runs). */
  current?(): Profile | null | Promise<Profile | null>;
  /** Required. Checks the session; throw `starry.error('loginExpired')` when it is gone. */
  refresh(): Promise<Profile | null>;
  /** With `server`: checks the address (the user typed it) and keeps the server for the login calls that follow. */
  connect?(address: string): Promise<ServerInfo>;
  /** `image` is the code as drawn (bytes or base64), `url` its content. */
  beginQRLogin?(kind?: string): Promise<{ key: string; url?: string; image?: Uint8Array | string; kind?: string }>;
  /** May take up to 100 s (a long poll). */
  pollQRLogin?(session: { key: string; kind?: string }): Promise<'waiting' | 'scanned' | 'expired' | { status: 'confirmed'; profile: Profile }>;
  /** `code`: the code to show (polled every second with `pollCodeLogin`). */
  beginCodeLogin?(): Promise<{ key: string; code: string }>;
  pollCodeLogin?(session: { key: string }): Promise<'waiting' | 'expired' | { status: 'confirmed'; profile: Profile }>;
  loginWithCookie?(text: string): Promise<Profile>;
  loginWithPassword?(username: string, password: string): Promise<Profile>;
  sendPhoneCode?(phone: string, countryCode: string): Promise<void>;
  loginWithPhoneCode?(phone: string, countryCode: string, code: string): Promise<Profile>;
  /** Required. Ends the session, on the platform too. */
  logout(): Promise<void>;
  /** Forgets the session here only, so `restoreCredentials` can bring it back. */
  signOutLocally?(): Promise<void>;
  exportCredentials?(): Promise<unknown>;
  restoreCredentials?(credentials: any): Promise<Profile>;
}

/** `mid`: a second id of the song, when the platform has two; the AMLL TTML database is asked with it before `id`. */
export interface LyricsSong { id: string; mid?: string; title: string; artists: string[]; album?: string; duration?: number }

export type LyricsFormat = 'ttml' | 'yrc' | 'qrc' | 'krc' | 'lrc';

export interface Lyrics {
  format: LyricsFormat;
  /** Plain text: QRC / KRC already decrypted. */
  body: string;
  translation?: string;
  romanization?: string;
}

export interface LyricsProvider {
  /** Under the name in the lyric source order setting. */
  detail?: string;
  /**
   * The AMLL TTML database folder the platform's song ids are keys in (`'ncm-lyrics'`, `'qq-lyrics'`):
   * the songs this provider matches, and the tracks of its own platform, are asked there.
   */
  ttmlFolder?: string;
  /** Songs for words typed or made from a track; the host picks the one that matches. */
  search(keyword: string): Promise<LyricsSong[]>;
  /** One song's lyrics, or null when it has none. Own tracks of a source plugin come by id. */
  fetch(song: { id: string; mid?: string; title?: string; duration?: number }): Promise<Lyrics | null>;
}

export type Setting = {
  key: string;
  title: string;
  detail?: string;
  /** More words settings search finds it by. */
  keywords?: string;
  /** Listed only with advanced settings on. */
  advanced?: boolean;
} & (
  | { type: 'toggle'; default?: boolean }
  | { type: 'text'; default?: string; placeholder?: string; secure?: boolean }
  | { type: 'choice'; default?: string; choices: { value: string; title: string }[] }
);

export interface SettingsSection { id: string; title?: string; footer?: string; advanced?: boolean; settings: Setting[] }

export interface Plugin {
  /** Reverse-DNS, lower case; never change it once published. */
  id: string;
  name: string;
  version: string;
  apiVersion: 1;
  author?: string;
  description?: string;
  homepage?: string;
  /** SF Symbol for the settings rail. */
  icon?: string;
  // Identifies a known platform whose saved songs, accounts and lyric matches this plugin owns.
  idNamespace?: 'netease' | 'qqmusic' | 'kugou';
  permissions: {
    /** `example.com`, `*.example.com` (the domain and its subdomains), or `*`. */
    hosts: string[];
  };
  source?: Source;
  /** With `source` only. */
  account?: Account;
  lyrics?: LyricsProvider;
  settings?: SettingsSection[];
  /** After `starry.settings` changed in the settings. */
  onSettingsChanged?(values: Readonly<Record<string, string | boolean>>): void | Promise<void>;
}

export type Bytes = Uint8Array;
export type Data = string | Uint8Array | ArrayBuffer | ArrayBufferView;
export type OutputEncoding = 'hex' | 'base64' | 'utf8';

export interface HttpRequest {
  url: string;
  method?: string;
  headers?: Record<string, string | number | undefined>;
  /** Appended to the URL's query. */
  query?: Record<string, string | number | boolean | undefined | null>;
  body?: string | Data;
  /** Sent as JSON, with its Content-Type. */
  json?: unknown;
  /** Sent as a form, with its Content-Type. */
  form?: Record<string, string> | URLSearchParams | string;
  /** Seconds; 15 when missing. */
  timeout?: number;
  redirect?: 'follow' | 'manual';
  responseType?: 'text' | 'json' | 'bytes';
  /** `http://host:port` or `socks5://host:port`. */
  proxy?: string;
  /** false: send only the `Cookie` header given, and keep nothing the response sets. */
  cookies?: boolean;
}

export interface HttpResponse<Body = any> {
  status: number;
  /** Lower-case names. */
  headers: Record<string, string>;
  /** What `Set-Cookie` set, by name; a cookie it removed (expired) is "". */
  cookies: Record<string, string>;
  /** After redirects. */
  url: string;
  body: Body;
}

export interface CipherOptions {
  mode?: 'ecb' | 'cbc' | 'gcm';
  key: Data;
  /** Zeros when missing (CBC); the nonce for GCM. */
  iv?: Data;
  /** GCM only. */
  aad?: Data;
  /** Strings are UTF-8: decode base64 or hex first. GCM output and input end with the 16-byte tag. */
  data: Data;
  /** PKCS#7; true when missing. */
  padding?: boolean;
  out?: OutputEncoding;
}

type Digest = {
  (data: Data): Bytes;
  (data: Data, out: OutputEncoding): string;
};

export interface Starry {
  readonly apiVersion: 1;
  readonly plugin: { readonly id: string; readonly name: string; readonly version: string };
  readonly app: {
    readonly version: string;
    readonly platform: 'macOS';
    /** `26.0.1`. */
    readonly osVersion: string;
    readonly arch: 'arm64' | 'x86_64';
    /** `Mac16,1`. */
    readonly model: string;
    /** The computer's name. */
    readonly deviceName: string;
    /** What this macOS plays: mp3, aac, alac, flac, wav, aiff, mp4, and `ogg` / `eac3` where it can. */
    readonly formats: readonly string[];
  };
  /** The current values of `settings`, defaults filled in. */
  readonly settings: Readonly<Record<string, string | boolean>>;
  /** `throw starry.error('vipRequired')`: vipRequired, loginExpired, unavailableInRegion, trialOnly, sourceUnreachable, notSupported, network, timeout, rateLimited, rankingHidden, followsHidden, or your own. */
  error(code: string, message?: string): Error & { code: string };
  http: {
    /** Only `permissions.hosts`, redirects included. Statuses never throw; network failures do. */
    request<Body = any>(options: HttpRequest | string): Promise<HttpResponse<Body>>;
    get<Body = any>(url: string, options?: Omit<HttpRequest, 'url' | 'method'>): Promise<HttpResponse<Body>>;
    /** A plain object goes as JSON, URLSearchParams as a form. */
    post<Body = any>(url: string, body?: unknown, options?: Omit<HttpRequest, 'url' | 'method' | 'body' | 'json' | 'form'>): Promise<HttpResponse<Body>>;
  };
  crypto: {
    md5: Digest;
    sha1: Digest;
    sha256: Digest;
    sha384: Digest;
    sha512: Digest;
    hmac(algorithm: 'md5' | 'sha1' | 'sha256' | 'sha384' | 'sha512', key: Data, data: Data, out?: OutputEncoding): any;
    aes: { encrypt(options: CipherOptions): any; decrypt(options: CipherOptions): any };
    des: { encrypt(options: CipherOptions): any; decrypt(options: CipherOptions): any };
    /** 16- or 24-byte keys. */
    tripleDES: { encrypt(options: CipherOptions): any; decrypt(options: CipherOptions): any };
    rsa: {
      /** `none` pads the data with leading zeros to the key size (raw RSA). */
      encrypt(options: { publicKey: string; data: Data; padding?: 'pkcs1' | 'oaep' | 'none'; out?: OutputEncoding }): any;
    };
    randomBytes(count: number): Bytes;
  };
  encoding: {
    utf8: { encode(text: string): Bytes; decode(data: Data): string };
    hex: { encode(data: Data): string; decode(text: string): Bytes };
    /** `decode` also takes the URL-safe alphabet and missing padding. */
    base64: { encode(data: Data): string; decode(text: string): Bytes };
  };
  zlib: {
    /** zlib, gzip or raw deflate, told apart by the header. */
    inflate(data: Data, out?: OutputEncoding): any;
    deflate(data: Data, options?: { format?: 'zlib' | 'gzip' | 'raw'; out?: OutputEncoding }): any;
  };
  // Overrides `source.webPages`; null restores defaults. Not persisted: set again
  // when restoring the session in `account.current`.
  setWebPages(pages: Source['webPages'] | null): void;
  /** Kept per plugin across launches. Values must be JSON. */
  storage: {
    get<T = unknown>(key: string): T | undefined;
    set(key: string, value: unknown): void;
    remove(key: string): void;
    keys(): string[];
    clear(): void;
  };
}

export interface FetchInit {
  method?: string;
  headers?: Record<string, string> | Headers;
  body?: string | Data | URLSearchParams;
  redirect?: 'follow' | 'manual';
}

declare global {
  const starry: Starry;
  /** CommonJS: `module.exports = { … }` (or `export default` bundled to CommonJS). */
  const module: { exports: Plugin | { default: Plugin } | Record<string, unknown> };
  const exports: Record<string, unknown>;

  const console: {
    log(...values: unknown[]): void;
    info(...values: unknown[]): void;
    debug(...values: unknown[]): void;
    warn(...values: unknown[]): void;
    error(...values: unknown[]): void;
  };

  function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
  function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
  function clearTimeout(id?: number): void;
  function clearInterval(id?: number): void;
  function queueMicrotask(callback: () => void): void;
  function atob(data: string): string;
  function btoa(data: string): string;

  class TextEncoder {
    readonly encoding: 'utf-8';
    encode(input?: string): Uint8Array;
  }

  /** utf-8, utf-16le / be, latin1, gbk / gb2312 / gb18030, big5, shift_jis, euc-jp, euc-kr. */
  class TextDecoder {
    constructor(label?: string, options?: { fatal?: boolean; ignoreBOM?: boolean });
    readonly encoding: string;
    decode(input?: Data): string;
  }

  class URLSearchParams implements Iterable<[string, string]> {
    constructor(init?: string | Record<string, string> | Iterable<[string, string]> | URLSearchParams);
    readonly size: number;
    append(name: string, value: string): void;
    delete(name: string): void;
    get(name: string): string | null;
    getAll(name: string): string[];
    has(name: string): boolean;
    set(name: string, value: string): void;
    sort(): void;
    forEach(callback: (value: string, key: string, parent: URLSearchParams) => void, thisArg?: unknown): void;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    entries(): IterableIterator<[string, string]>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
    toString(): string;
  }

  class URL {
    constructor(url: string, base?: string);
    protocol: string;
    username: string;
    password: string;
    hostname: string;
    port: string;
    pathname: string;
    search: string;
    hash: string;
    readonly searchParams: URLSearchParams;
    readonly host: string;
    readonly origin: string;
    readonly href: string;
    toString(): string;
    toJSON(): string;
  }

  class Headers implements Iterable<[string, string]> {
    constructor(init?: Record<string, string> | Iterable<[string, string]> | Headers);
    get(name: string): string | null;
    has(name: string): boolean;
    set(name: string, value: string): void;
    append(name: string, value: string): void;
    delete(name: string): void;
    forEach(callback: (value: string, key: string, parent: Headers) => void, thisArg?: unknown): void;
    entries(): IterableIterator<[string, string]>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
  }

  interface Response {
    readonly status: number;
    readonly ok: boolean;
    readonly url: string;
    readonly headers: Headers;
    arrayBuffer(): Promise<ArrayBuffer>;
    bytes(): Promise<Uint8Array>;
    text(): Promise<string>;
    json(): Promise<any>;
  }

  /** A subset over `starry.http`, under the same host rules. */
  function fetch(input: string | URL, init?: FetchInit): Promise<Response>;
}
