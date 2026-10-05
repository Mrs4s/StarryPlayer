// The plugin under Node (`npm test`): its pure parts, and the flows against servers faked in
// ../../common/test/starry-mock.ts. Answers are shaped as Navidrome 0.64, gonic 0.22, LMS 3.81
// and Airsonic-Advanced 11 gave them.

import { sent, servers, type Sent } from '../../common/test/starry-mock';
import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import * as account from '../src/account';
import * as catalog from '../src/catalog';
import { locate, ref, restURL, session, setSession, type Server } from '../src/client';
import * as library from '../src/library';
import { linesOf, lyricsFrom } from '../src/lyrics';
import * as model from '../src/models';
import * as playlists from '../src/playlists';
import { clientInfo, decided, gainOf, maxBitRate, nativeContainer, plan, resolve } from '../src/stream';

const FORMATS = ['mp3', 'aac', 'alac', 'flac', 'wav', 'aiff', 'mp4', 'ogg'];

beforeEach(() => {
  servers.clear();
  sent.length = 0;
  account.signOutLocally();
  starry.storage.clear();
});

type Handler = (params: URLSearchParams, request: Sent) => unknown;

/** A server answering `/rest/<method>` (with or without `.view`) from `routes`: an object is wrapped as `subsonic-response`, `{ error: [code, message] }` as a failure. */
function fake(origin: string, routes: Record<string, Handler>, envelope: Record<string, unknown> = { version: '1.16.1', type: 'navidrome', serverVersion: '0.64.2', openSubsonic: true }): void {
  servers.set(origin, (request) => {
    const method = request.url.pathname.replace(/^.*\/rest\//, '').replace(/\.view$/, '');
    const params = request.form ?? request.url.searchParams;
    const handler = routes[method];
    if (!handler) return { body: { 'subsonic-response': { status: 'failed', ...envelope, error: { code: 0, message: `no ${method}` } } } };
    const result = handler(params, request) as any;
    if (result && typeof result === 'object' && 'status' in result && 'raw' in result) return result.raw;
    if (result && typeof result === 'object' && Array.isArray(result.error)) {
      return { body: { 'subsonic-response': { status: 'failed', ...envelope, error: { code: result.error[0], message: result.error[1] } } } };
    }
    return { body: { 'subsonic-response': { status: 'ok', ...envelope, ...(result ?? {}) } } };
  });
}

const signedIn = (address: string, extra: Partial<Server> = {}): Server => ({
  key: 'k1', address, type: 'navidrome', serverVersion: '0.64.2', version: '1.16.1', extensions: {}, user: 'family', auth: { token: 'tok', salt: 'salt' }, ...extra,
});

const child = (id: string, extra: Record<string, unknown> = {}) => ({
  id, title: `歌 ${id}`, album: '格式测试专辑', albumId: 'al1', artist: '测试歌手', artistId: 'ar1', duration: 60, suffix: 'mp3', contentType: 'audio/mpeg', bitRate: 320, coverArt: `mf-${id}`, track: 1, discNumber: 1, ...extra,
});

const methods = () => sent.map((request) => request.url.pathname.replace(/^.*\/rest\//, ''));

test('a typed address becomes the places to try, a web page or /rest cut back to the server', () => {
  assert.deepEqual(account.addressCandidates('nas.local:4533/app/#/album/x/show'), ['http://nas.local:4533', 'https://nas.local:4533']);
  assert.deepEqual(account.addressCandidates('https://music.example.com/navidrome/rest/ping.view?u=a'), ['https://music.example.com/navidrome']);
  assert.deepEqual(account.addressCandidates('http://192.168.1.2:5082/releases'), ['http://192.168.1.2:5082']);
  assert.deepEqual(account.addressCandidates('http://nas:4040/index.view'), ['http://nas:4040']);
  assert.deepEqual(account.addressCandidates('https://cloud.example.com/apps/music/subsonic'), ['https://cloud.example.com/apps/music/subsonic']);
});

test('the protocol version sent: the server’s own, at most 1.16.1', () => {
  assert.equal(account.negotiated('1.15.0'), '1.15.0');
  assert.equal(account.negotiated('1.16.1'), '1.16.1');
  assert.equal(account.negotiated('1.17.0'), '1.16.1');
  assert.equal(account.negotiated(undefined), '1.16.1');
});

test('connect reads what the server is from a ping without credentials, and its extensions when it tells', async () => {
  fake('http://nas.local:4533', {
    ping: () => ({ error: [10, "missing parameter: 'u'"] }),
    getOpenSubsonicExtensions: () => ({ openSubsonicExtensions: [{ name: 'songLyrics', versions: [1, 2] }, { name: 'transcoding', versions: [1] }] }),
  });
  const info = await account.connect('nas.local:4533');
  assert.deepEqual(info, { address: 'http://nas.local:4533', name: 'Navidrome', version: '0.64.2', methods: ['password'] });
  const ping = sent[0].url;
  assert.equal(ping.searchParams.get('v'), '1.16.1');
  assert.equal(ping.searchParams.get('c'), 'Starry Player');
  assert.equal(ping.searchParams.get('u'), null);

  // Not a Subsonic server; out of reach.
  servers.set('https://web.example.com', () => ({ body: '<html></html>' }));
  await assert.rejects(account.connect('web.example.com'), /不是 Subsonic 服务器/);
  await assert.rejects(account.connect('https://gone.example.com'), /连不上/);
});

test('a token is tried first and kept; the password is never stored then', async () => {
  let asked: URLSearchParams | undefined;
  fake('http://nas.local:4533', {
    ping: (params) => {
      if (!params.get('u')) return { error: [10, 'missing'] };
      asked = params;
      const expected = starry.crypto.md5(`pw${params.get('s')}`, 'hex');
      return params.get('t') === expected ? {} : { error: [40, 'Wrong username or password'] };
    },
    getOpenSubsonicExtensions: () => ({ openSubsonicExtensions: [] }),
  });
  await account.connect('http://nas.local:4533');
  const profile = await account.loginWithPassword(' family ', 'pw');
  assert.match(profile.userID, /^[a-z0-9]{6}:family$/);
  assert.equal(profile.detail, 'Navidrome · nas.local:4533');
  assert.ok(asked!.get('t') && asked!.get('s') && !asked!.get('p'));
  const kept = session()!;
  assert.deepEqual(kept.auth, { token: asked!.get('t'), salt: asked!.get('s') });
  assert.ok(!JSON.stringify(starry.storage.get('servers')).includes('"pw"'));
  assert.equal(restURL(kept, 'getCoverArt', { id: 'x' }), restURL(session()!, 'getCoverArt', { id: 'x' }));
});

test('41 (no tokens here) falls back to the password, hex-encoded; 30 to the server’s protocol version', async () => {
  fake('http://nas:4040', {
    ping: (params) => {
      if (!params.get('u')) return { error: [10, 'Required parameter is missing.'] };
      if (params.get('v') !== '1.15.0') return { error: [30, 'Incompatible Airsonic REST protocol version. Server must upgrade.'] };
      if (params.get('t')) return { error: [41, 'Wrong username or password, but try authenticating via non-hashed password.'] };
      return params.get('p') === `enc:${Buffer.from('密码').toString('hex')}` ? {} : { error: [40, 'Wrong username or password.'] };
    },
  }, { version: '1.15.0', type: 'Airsonic-Advanced' });
  const info = await account.connect('http://nas:4040');
  assert.equal(info.name, 'Airsonic-Advanced');
  assert.equal(info.version, 'API 1.15.0');
  await account.loginWithPassword('family', '密码');
  assert.deepEqual(session()!.auth, { password: '密码' });
  assert.equal(session()!.version, '1.15.0');
  assert.deepEqual(session()!.extensions, {});
});

test('a wrong password on LMS says to use an API key; gonic’s extensions are read once signed in', async () => {
  fake('http://lms:5082', { ping: (params) => (params.get('u') ? { error: [40, 'Wrong username or password.'] } : { error: [10, "Required parameter 'apiKey' is missing."] }) }, { version: '1.16.1', type: 'lms', serverVersion: 'v3.81.0', openSubsonic: true });
  await account.connect('http://lms:5082');
  await assert.rejects(account.loginWithPassword('admin', 'password'), /LMS 要用 API 密钥登录：在 LMS 网页的“设置 › Subsonic API”里生成密钥/);

  fake('http://gonic:4747', {
    ping: (params) => (params.get('u') ? {} : { error: [10, 'please provide a "u" parameter'] }),
    getOpenSubsonicExtensions: (params) => (params.get('u') ? { openSubsonicExtensions: [{ name: 'songLyrics', versions: [1] }] } : { error: [10, 'please provide a "u" parameter'] }),
  }, { version: '1.15.0', type: 'gonic', serverVersion: '0.22.0', openSubsonic: true });
  await account.connect('http://gonic:4747');
  await account.loginWithPassword('admin', 'admin');
  assert.deepEqual(session()!.extensions, { songLyrics: [1] });
  assert.equal(session()!.version, '1.15.0');
});

test('restoring keeps an account whose server is out of reach, not one whose credentials are refused', async () => {
  const away = signedIn('http://away.local:4533');
  assert.ok(await account.restoreCredentials(away));
  assert.equal(session()?.address, 'http://away.local:4533');
  fake('http://nas.local:4533', { ping: () => ({ error: [40, 'Wrong username or password'] }) });
  await assert.rejects(account.restoreCredentials(signedIn('http://nas.local:4533')), { code: 'loginExpired' });
  await assert.rejects(account.restoreCredentials({ key: 'x' }), { code: 'invalidCredentials' });
});

test('ids carry their server; a song of another kept server is asked there', async () => {
  const a = signedIn('http://a.local:4533', { key: 'aaaaaa' });
  const b = signedIn('http://b.local:4747', { key: 'bbbbbb', type: 'gonic' });
  setSession(b);
  setSession(a);
  assert.equal(ref(a, 'tr-1'), 'aaaaaa/tr-1');
  assert.equal(ref(a, 0), 'aaaaaa/0');
  assert.equal(ref(a, ''), '');
  assert.equal(locate('bbbbbb/tr-1').server.address, 'http://b.local:4747');
  assert.throws(() => locate('cccccc/tr-1'), { code: 'notFound' });
  fake('http://b.local:4747', { getSong: (params) => ({ song: child(params.get('id')!) }) });
  const found = await catalog.songs(['bbbbbb/tr-1', 'cccccc/x']);
  assert.deepEqual(found.map((track) => track.id), ['bbbbbb/tr-1']);
});

test('songs from what the servers send: artists, covers with a size, tiers from the format', () => {
  const server = signedIn('http://nas:4533');
  const navidrome = model.track(server, child('s1', {
    suffix: 'flac', contentType: 'audio/flac', bitRate: 842, samplingRate: 96000, bitDepth: 24,
    artists: [{ id: 'ar1', name: '测试歌手' }, { id: 'ar9', name: '合作歌手' }], displayArtist: '测试歌手 • 合作歌手',
  }));
  assert.deepEqual(navidrome.artists, [{ id: 'k1/ar1', name: '测试歌手' }, { id: 'k1/ar9', name: '合作歌手' }]);
  assert.deepEqual(navidrome.tiers, ['128', '320', 'lossless', 'hi-res']);
  const artwork = navidrome.artwork as { url: string; sizedTemplate: string };
  assert.match(artwork.sizedTemplate, /^http:\/\/nas:4533\/rest\/getCoverArt\?v=1\.16\.1&c=Starry%20Player&u=family&t=tok&s=salt&id=mf-s1&size=\{width\}$/);
  // Airsonic: no artist ids on songs (not linked), no sample rate (lossless reaches `lossless`).
  const airsonic = model.track(server, { id: '19', title: 'WavPack Song', artist: '测试歌手;合作歌手', suffix: 'wv', contentType: 'application/octet-stream', bitRate: 324, duration: 60, albumId: '3', album: 'Lossless Odds' });
  assert.deepEqual(airsonic.artists, [{ id: '', name: '测试歌手;合作歌手' }]);
  assert.deepEqual(airsonic.tiers, ['128', '320', 'lossless']);
  // m4a: ALAC by LMS's type or the bit rate, else AAC.
  assert.ok(model.formatOf({ suffix: 'm4a', contentType: 'audio/mp4; codecs="alac"', bitRate: 300 }).lossless);
  assert.ok(model.formatOf({ suffix: 'm4a', contentType: 'audio/mp4', bitRate: 1411 }).lossless);
  assert.ok(!model.formatOf({ suffix: 'm4a', contentType: 'audio/mp4', bitRate: 256 }).lossless);
});

test('albums, artists and playlists; others’ public playlists are not the account’s', () => {
  const server = signedIn('http://nas:4533');
  const album = model.album(server, { id: 'al1', name: '叶惠美', artist: '周杰伦', artistId: 'ar1', songCount: 2, year: 2003, releaseDate: { year: 2003, month: 7, day: 31 }, coverArt: 'al-1', recordLabels: [{ name: '杰威尔' }], isCompilation: false, releaseTypes: ['ep'] });
  assert.equal(album.releaseDate, Date.UTC(2003, 6, 31));
  assert.equal(album.company, '杰威尔');
  assert.equal(album.releaseType, 'EP');
  assert.equal(model.album(server, { id: 'al2', name: '合辑', isCompilation: true }).releaseType, '合辑');
  const mine = model.playlist(server, { id: 'p1', name: '我的', owner: 'family', songCount: 2, readonly: false });
  assert.equal(mine.isOwned, true);
  // Navidrome leaves `public` out when it is false.
  assert.equal(mine.isPrivate, true);
  const theirs = model.playlist(server, { id: 'p2', name: '公开的', owner: 'admin', public: true, readonly: true });
  assert.deepEqual([theirs.isOwned, theirs.isPrivate], [false, false]);
});

const format = (extra: Record<string, unknown>) => model.formatOf({ suffix: 'flac', contentType: 'audio/flac', bitRate: 900, samplingRate: 44100, ...extra });

test('which files play as they are: Opus does not, Ogg Vorbis where this macOS does', () => {
  assert.equal(nativeContainer(format({ suffix: 'opus', contentType: 'audio/ogg' }), FORMATS), undefined);
  assert.equal(nativeContainer(format({ suffix: 'ogg', contentType: 'audio/ogg; codecs="opus"' }), FORMATS), undefined);
  assert.equal(nativeContainer(format({ suffix: 'ogg', contentType: 'audio/ogg' }), FORMATS), 'ogg');
  assert.equal(nativeContainer(format({ suffix: 'ogg', contentType: 'audio/ogg' }), ['mp3']), undefined);
  assert.equal(nativeContainer(format({ suffix: 'aiff' }), FORMATS), 'wav');
  assert.equal(nativeContainer(format({ suffix: 'wv' }), FORMATS), undefined);
});

test('without the server deciding: the file when it fits the tier and plays here, else MP3, never above the file', () => {
  const mp3 = format({ suffix: 'mp3', contentType: 'audio/mpeg', bitRate: 320 });
  assert.deepEqual(plan(mp3, '128', FORMATS), { tier: '128', mp3: 128 });
  assert.deepEqual(plan(mp3, '320', FORMATS), { tier: '320', direct: 'mp3' });
  assert.deepEqual(plan(mp3, 'lossless', FORMATS), { tier: '320', direct: 'mp3' });
  assert.deepEqual(plan(format({}), 'lossless', FORMATS), { tier: 'lossless', direct: 'flac' });
  assert.deepEqual(plan(format({ samplingRate: 96000 }), 'lossless', FORMATS), { tier: 'hi-res', direct: 'flac' });
  assert.deepEqual(plan(format({ suffix: 'wv' }), 'lossless', FORMATS), { tier: '320', mp3: 320 });
  assert.deepEqual(plan(format({ suffix: 'opus', contentType: 'audio/ogg', bitRate: 96 }), '320', FORMATS), { tier: '320', mp3: 320 });
  // gonic converts only below the file's bit rate.
  assert.equal(maxBitRate({ type: 'gonic' }, 320, 96), 80);
  assert.equal(maxBitRate({ type: 'gonic' }, 128, 900), 128);
  assert.equal(maxBitRate({ type: 'navidrome' }, 320, 96), 320);
});

test('what this Mac plays, as getTranscodeDecision takes it', () => {
  const lossy = clientInfo('128', FORMATS) as any;
  assert.equal(lossy.maxAudioBitrate, 170000);
  assert.equal(lossy.maxTranscodingAudioBitrate, 128000);
  assert.deepEqual(lossy.transcodingProfiles.map((profile: any) => profile.container), ['mp3']);
  assert.ok(!lossy.directPlayProfiles.some((profile: any) => profile.audioCodecs.includes('flac')));
  const lossless = clientInfo('lossless', FORMATS) as any;
  assert.deepEqual(lossless.transcodingProfiles.map((profile: any) => profile.container), ['flac', 'mp3']);
  assert.deepEqual(lossless.codecProfiles.map((profile: any) => [profile.name, profile.limitations[0].values[0]]), [['flac', '48000'], ['alac', '48000'], ['pcm', '48000']]);
  assert.deepEqual((clientInfo('hi-res', FORMATS) as any).codecProfiles, []);
  assert.ok(!(clientInfo('320', ['mp3']) as any).directPlayProfiles.some((profile: any) => profile.audioCodecs.includes('vorbis')));
});

test('the server’s decision: the file itself, or its stream with the parameters it gave', () => {
  const server = signedIn('http://nas:4533');
  const hires = format({ samplingRate: 96000, bitDepth: 24 });
  const direct = decided(server, 's1', hires, 'hi-res', { canDirectPlay: true }, FORMATS)!;
  assert.match(direct.url, /\/rest\/stream\?.*&id=s1&format=raw$/);
  assert.deepEqual([direct.container, direct.tier, direct.transcoded], ['flac', 'hi-res', undefined]);
  const down = decided(server, 's1', hires, 'lossless', { canDirectPlay: false, canTranscode: true, transcodeParams: 'jwt', transcodeStream: { protocol: 'http', container: 'flac', codec: 'flac', audioChannels: 2, audioSamplerate: 48000, audioBitdepth: 24 } }, FORMATS)!;
  assert.match(down.url, /\/rest\/getTranscodeStream\?.*&mediaId=s1&mediaType=song&transcodeParams=jwt$/);
  assert.deepEqual([down.container, down.tier, down.transcoded, down.info?.sampleRate], ['flac', 'lossless', true, 48000]);
  const opus = decided(server, 's2', format({ suffix: 'opus', contentType: 'audio/ogg', bitRate: 162 }), '320', { canTranscode: true, transcodeParams: 'x', transcodeStream: { container: 'mp3', codec: 'mp3', audioBitrate: 162000 } }, FORMATS)!;
  assert.deepEqual([opus.container, opus.tier], ['mp3', '320']);
  assert.equal(decided(server, 's3', hires, 'lossless', { canDirectPlay: false, canTranscode: false, errorReason: 'x' }, FORMATS), undefined);
});

test('ReplayGain: a pair with a peak of 0 is none, peaks may be missing', () => {
  assert.deepEqual(gainOf({ replayGain: { trackGain: -6.5, albumGain: -7, trackPeak: 0.988, albumPeak: 0.995 } }), { trackGain: -6.5, trackPeak: 0.988, albumGain: -7, albumPeak: 0.995 });
  assert.deepEqual(gainOf({ replayGain: { trackGain: -5.2, trackPeak: 0.95, albumGain: 0, albumPeak: 0 } }), { trackGain: -5.2, trackPeak: 0.95, albumGain: undefined, albumPeak: undefined });
  assert.deepEqual(gainOf({ replayGain: { albumGain: 4.1, trackGain: 4.1 } }), { trackGain: 4.1, trackPeak: undefined, albumGain: 4.1, albumPeak: undefined });
  assert.equal(gainOf({ replayGain: {} }), undefined);
  assert.equal(gainOf({}), undefined);
});

test('resolve asks the server to decide where it can, posting what this Mac plays', async () => {
  const server = signedIn('http://nas:4533', { extensions: { transcoding: [1] } });
  setSession(server);
  let body: any;
  fake('http://nas:4533', {
    getSong: () => ({ song: child('s1', { suffix: 'wv', contentType: 'audio/x-wavpack', bitRate: 900, samplingRate: 44100, replayGain: { trackGain: -3 } }) }),
    getTranscodeDecision: (_params, request) => {
      body = request.json;
      return { transcodeDecision: { canDirectPlay: false, canTranscode: true, transcodeParams: 'p', transcodeStream: { container: 'flac', codec: 'flac', audioSamplerate: 44100 } } };
    },
  });
  const asset = await resolve({ id: 'k1/s1', title: 'x', duration: 60 }, { id: 'lossless', name: '无损', level: 'lossless' });
  assert.equal(sent[1].method, 'POST');
  assert.equal(body.transcodingProfiles[0].container, 'flac');
  assert.deepEqual([asset.container, asset.tier, asset.transcoded, asset.gain?.trackGain, asset.expiresIn], ['flac', 'lossless', true, -3, 21600]);
});

test('a server that sends the file instead of an MP3 (Airsonic’s Opus) is told, not played', async () => {
  const server = signedIn('http://nas:4040', { type: 'Airsonic-Advanced', version: '1.15.0' });
  setSession(server);
  servers.set('http://nas:4040', (request) => {
    if (request.url.pathname === '/rest/getSong') return { body: { 'subsonic-response': { status: 'ok', version: '1.15.0', song: child('18', { suffix: 'opus', contentType: 'audio/ogg', bitRate: 162 }) } } };
    return { status: 206, body: 'Og' };
  });
  await assert.rejects(resolve({ id: 'k1/18', title: 'x', duration: 60 }, { id: '320', name: '极高', level: 'hq' }), (error: any) => error.code === 'notPlayable' && /加上 opus/.test(error.message));
});

test('所有媒体 pages through an empty search; a server that wants it quoted gets that', async () => {
  setSession(signedIn('http://nas:4533'));
  const all = Array.from({ length: 5 }, (_, index) => child(`s${index}`));
  fake('http://nas:4533', {
    search3: (params) => {
      const offset = Number(params.get('songOffset'));
      const count = Number(params.get('songCount'));
      return params.get('query') === '""' ? { searchResult3: { song: all.slice(offset, offset + count) } } : { searchResult3: {} };
    },
  });
  const first = await catalog.allMedia({ offset: 0, limit: 2 });
  assert.deepEqual([first.songs.map((track) => track.id), first.hasMore, first.nextOffset], [['k1/s0', 'k1/s1'], true, 2]);
  assert.equal(sent.at(-1)!.url.searchParams.get('artistCount'), '0');
});

test('资料库: albums in the order picked (sorted here where the server will not), artists by page, genres with albums', async () => {
  setSession(signedIn('http://nas:4040', { type: 'Airsonic-Advanced' }));
  const albums = [{ id: 'a1', name: '旧', year: 2003, coverArt: 'c1' }, { id: 'a2', name: '新', year: 2024 }, { id: 'a3', name: '中', year: 2010 }];
  fake('http://nas:4040', {
    getAlbumList2: (params) => {
      if (params.get('type') === 'byYear') return { albumList2: { album: albums } };
      if (params.get('type') === 'byGenre') return { albumList2: { album: params.get('genre') === 'Rock' ? [albums[0]] : [] } };
      const offset = Number(params.get('offset') ?? 0);
      return { albumList2: { album: albums.slice(offset, offset + Number(params.get('size'))) } };
    },
    getArtists: () => ({ artists: { index: [{ name: 'S', artist: [{ id: 'r1', name: 'Second Artist', albumCount: 1 }] }, { name: 'Z', artist: [{ id: 'r2', name: '周杰伦', albumCount: 2, coverArt: 'ar-2' }] }] } }),
    getGenres: () => ({ genres: { genre: [{ value: 'Pop', songCount: 1, albumCount: 1 }, { value: 'Rock', songCount: 4, albumCount: 3 }, { value: 'mandopop', songCount: 0, albumCount: 0 }] } }),
  });
  const byYear = await catalog.libraryAlbums('year', null, { offset: 0, limit: 2 });
  assert.deepEqual([byYear.albums.map((album) => album.name), byYear.hasMore], [['新', '中'], true]);
  const next = await catalog.libraryAlbums('year', null, { offset: 2, limit: 2 });
  assert.deepEqual([next.albums.map((album) => album.name), next.hasMore], [['旧'], false]);
  assert.equal(sent.at(-1)!.url.searchParams.get('type'), 'alphabeticalByName');
  const artists = await catalog.libraryArtists({ offset: 1, limit: 10 });
  assert.deepEqual([artists.artists.map((artist) => artist.name), artists.total], [['周杰伦'], 2]);
  const genres = await catalog.libraryGenres();
  assert.deepEqual(genres.map((genre) => [genre.name, genre.albumCount, Boolean(genre.artwork)]), [['Rock', 3, true], ['Pop', 1, false]]);
});

test('an artist’s songs: its albums’ (only its own on others’ albums) and those found by its name; most played first', async () => {
  setSession(signedIn('http://nas:5082', { type: 'lms', extensions: { topSongsByArtistId: [1] } }));
  fake('http://nas:5082', {
    getArtist: () => ({ artist: { id: 'ar4', name: '歌手甲', album: [{ id: 'own', name: '个人专辑', artistId: 'ar4', year: 2020 }, { id: 'va', name: '华语金曲合辑', artistId: 'ar3', year: 2010 }] } }),
    getArtistInfo2: () => ({ artistInfo2: { biography: 'Born in 1979. <a href="https://last.fm">Read more on Last.fm</a>', similarArtist: [{ id: 'ar5', name: '歌手乙' }, { name: '没有 id 的' }] } }),
    getAlbum: (params) => ({
      album: params.get('id') === 'own'
        ? { id: 'own', song: [child('o1', { artists: [{ id: 'ar4', name: '歌手甲' }], playCount: 1, year: 2020 }), child('o2', { artists: [{ id: 'ar6', name: '嘉宾' }], playCount: 9, year: 2020 })] }
        : { id: 'va', song: [child('v1', { artists: [{ id: 'ar4', name: '歌手甲' }], playCount: 5, year: 2010 }), child('v2', { artists: [{ id: 'ar7', name: '歌手丙' }], playCount: 7, year: 2010 })] },
    }),
    search3: () => ({ searchResult3: { song: [child('f1', { artists: [{ id: 'ar4', name: '歌手甲' }, { id: 'ar5', name: '歌手乙' }], playCount: 3, year: 2015 }), child('f2', { artist: '歌手甲啊', artistId: 'other' })] } }),
    getTopSongs: (params) => ({ topSongs: params.get('id') === 'ar4' ? {} : { song: [child('x')] } }),
  });
  const hot = await catalog.artistSongs('k1/ar4', 'hot', { offset: 0, limit: 10 });
  assert.deepEqual(hot.map((track) => track.id), ['k1/o2', 'k1/v1', 'k1/f1', 'k1/o1']);
  const newest = await catalog.artistSongs('k1/ar4', 'time', { offset: 0, limit: 10 });
  assert.deepEqual(newest.map((track) => track.id), ['k1/o1', 'k1/o2', 'k1/f1', 'k1/v1']);
  const detail = await catalog.artist('k1/ar4');
  assert.equal(detail.artist.description, 'Born in 1979.');
  // No top songs from the server: the most played.
  assert.deepEqual(detail.topTracks?.map((track) => track.id), hot.map((track) => track.id));
  assert.deepEqual((await catalog.similarArtists('k1/ar4')).map((artist) => artist.name), ['歌手乙']);
  assert.deepEqual((await catalog.artistAlbums('k1/ar4', { offset: 0, limit: 10 })).map((album) => album.name), ['个人专辑', '华语金曲合辑']);
  const asked = methods().filter((method) => method === 'getArtist').length;
  servers.set('http://nas:5082', ((route) => (request: Sent) => (request.url.pathname.endsWith('/star') ? { body: { 'subsonic-response': { status: 'ok', version: '1.16.1' } } } : route(request)))(servers.get('http://nas:5082')!));
  await library.setCollected('artist', 'k1/ar4', true);
  await catalog.artist('k1/ar4');
  assert.equal(methods().filter((method) => method === 'getArtist').length, asked + 1);
});

test('search asks for one kind at a time; Home leaves a failing shelf out', async () => {
  setSession(signedIn('http://nas:4533'));
  fake('http://nas:4533', {
    search3: (params) => ({ searchResult3: Number(params.get('albumCount')) > 0 ? { album: [{ id: 'al', name: '专辑' }] } : {} }),
    getRandomSongs: () => ({ randomSongs: { song: [child('r')] } }),
    getAlbumList2: (params) => (params.get('type') === 'recent' ? { error: [0, 'boom'] } : { albumList2: { album: [{ id: 'a', name: params.get('type') }] } }),
    getPlaylists: () => ({ playlists: { playlist: [{ id: 'p', name: '歌单', owner: 'family' }] } }),
    getStarred2: () => ({ starred2: { album: [{ id: 's', name: '收藏' }], artist: [] } }),
  });
  const albums = await catalog.search('专', 'album', { offset: 30, limit: 30 });
  const asked = sent.at(-1)!.url.searchParams;
  assert.deepEqual([asked.get('albumCount'), asked.get('albumOffset'), asked.get('songCount'), asked.get('artistCount')], ['30', '30', '0', '0']);
  assert.deepEqual(albums.albums?.map((album) => album.name), ['专辑']);
  assert.deepEqual(await catalog.search('x', 'playlist', { offset: 0, limit: 10 }), {});
  const shelves = await catalog.homeShelves();
  assert.deepEqual(shelves.map((shelf) => shelf.title), ['随便听听', '最近添加', '最常播放', '我的歌单', '收藏的专辑', '收藏的歌手']);
});

test('liked songs newest star first; stars on albums and artists; a play counted at its end, one song a call', async () => {
  setSession(signedIn('http://nas:4533'));
  fake('http://nas:4533', {
    getStarred2: () => ({ starred2: { song: [child('old', { starred: '2026-10-01T00:00:00.000Z' }), child('new', { starred: '2026-10-04T01:03:04.752279713Z' })] } }),
    star: () => ({}),
    unstar: () => ({}),
    scrobble: () => ({}),
  });
  assert.deepEqual(await library.likedTrackIDs(), ['k1/new', 'k1/old']);
  await library.setCollected('album', 'k1/al1', true);
  assert.equal(sent.at(-1)!.url.searchParams.get('albumId'), 'al1');
  await library.setLiked('k1/s1', false);
  assert.deepEqual([methods().at(-1), sent.at(-1)!.url.searchParams.get('id')], ['unstar', 's1']);
  await assert.rejects(library.setCollected('playlist', 'k1/p', true), { code: 'notSupported' });
  const report = { trackID: 'k1/s1', playedSeconds: 30, duration: 200, startedAt: 1_759_000_000_000, endedAt: 1_759_000_030_000 };
  await library.reportPlayback(report);
  assert.notEqual(methods().at(-1), 'scrobble');
  await library.reportPlayback({ ...report, playedSeconds: 120 });
  const scrobble = sent.at(-1)!.url.searchParams;
  assert.deepEqual([methods().at(-1), scrobble.get('id'), scrobble.get('submission'), scrobble.get('time')], ['scrobble', 's1', 'true', '1759000000000']);
});

test('私人 FM mixes by sound where the server can, else its similar songs', async () => {
  setSession(signedIn('http://nas:5082', { type: 'lms', extensions: { sonicSimilarity: [1] } }));
  fake('http://nas:5082', {
    getStarred2: () => ({ starred2: { song: [child('seed')] } }),
    getSonicSimilarTracks: () => ({ sonicMatch: ['m1', 'm2', 'm3', 'm4', 'm5', 'm6'].map((id) => ({ entry: child(id), similarity: 0.9 })) }),
    getRandomSongs: () => ({ randomSongs: { song: [] } }),
  });
  const first = await library.personalFM('default', true);
  assert.deepEqual(first.map((track) => track.id), ['k1/m1', 'k1/m2', 'k1/m3', 'k1/m4', 'k1/m5']);
  assert.ok(methods().includes('getSonicSimilarTracks'));
});

test('editing a playlist: create (finding it where the server does not hand it back), add skipping songs in it, remove, reorder, empty', async () => {
  let entries = ['a', 'b'];
  let info: Record<string, unknown> = { name: '歌单', comment: '简介', public: true };
  const overwrites: string[][] = [];
  setSession(signedIn('http://nas:4040', { type: 'Airsonic-Advanced', version: '1.15.0' }));
  fake('http://nas:4040', {
    createPlaylist: (params) => {
      if (params.get('playlistId')) {
        // Navidrome takes no songs as no change.
        if (params.getAll('songId').length > 0) entries = params.getAll('songId');
        overwrites.push(params.getAll('songId'));
        return {};
      }
      return {};
    },
    getPlaylists: () => ({ playlists: { playlist: [{ id: '3', name: '新歌单', owner: 'family', created: '2026-10-04T01:00:00Z' }, { id: '1', name: '新歌单', owner: 'family', created: '2026-10-01T01:00:00Z' }] } }),
    getPlaylist: () => ({ playlist: { id: 'p', ...info, entry: entries.map((id) => child(id)) } }),
    updatePlaylist: (params) => {
      entries = [...entries.filter((_, index) => !params.getAll('songIndexToRemove').map(Number).includes(index)), ...params.getAll('songIdToAdd')];
      if (params.get('comment')) info = { ...info, comment: params.get('comment') };
      return {};
    },
  });
  const made = await playlists.createPlaylist({ name: '新歌单', description: '说明', isPrivate: false });
  assert.deepEqual([made.id, made.isOwned, made.isPrivate, made.description], ['k1/3', true, false, '说明']);
  assert.equal(await playlists.addToPlaylist('k1/p', ['k1/b', 'k1/c', 'other/d', 'k1/c']), 1);
  assert.deepEqual(entries, ['a', 'b', 'c']);
  await playlists.reorderPlaylist('k1/p', ['k1/c', 'k1/a', 'k1/b']);
  assert.deepEqual(entries, ['c', 'a', 'b']);
  await playlists.removeFromPlaylist('k1/p', ['k1/a']);
  assert.deepEqual(entries, ['c', 'b']);
  await playlists.removeFromPlaylist('k1/p', ['k1/c', 'k1/b']);
  assert.deepEqual(entries, []);
  assert.deepEqual(overwrites.at(-1), []);
});

test('a server that keeps its own order is said to', async () => {
  setSession(signedIn('http://nas:4040', { type: 'Airsonic-Advanced' }));
  fake('http://nas:4040', {
    getPlaylist: () => ({ playlist: { id: 'p', name: 'x', entry: [child('b'), child('a')] } }),
    createPlaylist: () => ({}),
  });
  await assert.rejects(playlists.reorderPlaylist('k1/p', ['k1/a', 'k1/b']), /没有按这个顺序保存/);
});

test('lyrics: Navidrome’s word cues by UTF-8 byte, an offset, kinds of their own', () => {
  const navidrome = lyricsFrom([
    {
      lang: 'xxx', kind: 'main', synced: true, offset: 500,
      line: [{ start: 1500, value: '逐字 歌词' }, { start: 4500, value: 'Word by' }],
      cueLine: [
        { index: 0, start: 1500, end: 4500, value: '逐字 歌词', cue: [{ start: 1500, end: 2000, byteStart: 0, byteEnd: 6 }, { start: 2000, end: 4500, byteStart: 7, byteEnd: 12 }] },
        { index: 0, start: 1500, value: '和声', agentId: 'bg', cue: [{ start: 1500, byteStart: 0, byteEnd: 5 }] },
        { index: 1, start: 4500, value: 'Word by', cue: [{ start: 4500, end: 5000, value: 'Word ', byteStart: 0, byteEnd: 4 }, { start: 5000, end: 5500, value: 'by', byteStart: 5, byteEnd: 6 }] },
      ],
    },
    { kind: 'translation', lang: 'eng', synced: true, line: [{ start: 1500, value: 'word by word lyrics' }] },
    { kind: 'pronunciation', synced: true, line: [{ start: 1500, value: 'zhu zi ge ci' }] },
  ], 60);
  assert.equal(navidrome?.format, 'ttml');
  assert.match(navidrome!.body, /^<tt .*<p begin="1\.000s" end="4\.000s"><span begin="1\.000s" end="1\.500s">逐字<\/span> <span begin="1\.500s" end="4\.000s">歌词<\/span><\/p><p begin="4\.000s" end="5\.000s"><span begin="4\.000s" end="4\.500s">Word<\/span> <span begin="4\.500s" end="5\.000s">by<\/span><\/p>/);
  assert.equal(navidrome?.translation, '[00:01.50]word by word lyrics');
  assert.equal(navidrome?.romanization, '[00:01.50]zhu zi ge ci');
});

test('lyrics: gonic’s and LMS’s words in the line, translations at the same time or after a line break, untimed none', () => {
  const gonic = lyricsFrom([{ lang: 'xxx', synced: true, line: [{ start: 1000, value: '<00:01.00>Word <00:01.50>by <00:02.00>word' }, { start: 4000, value: '<00:04.00>逐<00:04.40>字' }] }]);
  assert.equal(gonic?.format, 'ttml');
  assert.match(gonic!.body, /<span begin="1\.500s" end="2\.000s">by<\/span>/);
  const twoLines = linesOf({ synced: true, line: [{ start: 2000, value: '故事的小黄花' }, { start: 2000, value: 'The little yellow flower' }, { start: 6000, value: '从出生那年就飘着' }] });
  assert.deepEqual(twoLines.lines.map((line) => line.text), ['故事的小黄花', '从出生那年就飘着']);
  assert.deepEqual(twoLines.translation, [{ start: 2, text: 'The little yellow flower' }]);
  const lms = lyricsFrom([{ synced: true, line: [{ start: 2000, value: '故事的小黄花\nThe little yellow flower' }, { start: 6000, value: '从出生那年就飘着\nHas been floating' }] }]);
  assert.deepEqual(lms, { format: 'lrc', body: '[00:02.00]故事的小黄花\n[00:06.00]从出生那年就飘着', translation: '[00:02.00]The little yellow flower\n[00:06.00]Has been floating' });
  assert.equal(lyricsFrom([{ synced: false, line: [{ value: '纯文本' }] }]), null);
  assert.equal(lyricsFrom(null), null);
});
