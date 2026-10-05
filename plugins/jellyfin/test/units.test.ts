// The plugin under Node (`npm test`): its pure parts, and the flows against servers faked in
// starry-mock.ts. Item shapes and lyric answers follow those of a Jellyfin 12.1 server.

import { pages, sent, servers, type Route, type Sent } from '../../common/test/starry-mock';
import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import * as account from '../src/account';
import * as catalog from '../src/catalog';
import { authorization, session, setSession, type Session } from '../src/client';
import * as library from '../src/library';
import { toLyrics } from '../src/lyrics';
import * as model from '../src/models';
import * as playlists from '../src/playlists';
import { mediaOf, nativeFormat, plan, resolve, streamURL, type Media } from '../src/stream';

const FORMATS = ['mp3', 'aac', 'alac', 'flac', 'wav', 'aiff', 'mp4'];

beforeEach(() => {
  servers.clear();
  sent.length = 0;
  account.signOutLocally();
  starry.storage.clear();
});

/** A server answering `routes` by path (`GET /Items/x`); `/System/Info/Public` and Quick Connect's switch are filled in. */
function fake(origin: string, routes: Record<string, (request: Sent) => { status?: number; body?: unknown } | undefined>, info: Record<string, unknown> = {}): void {
  const route: Route = (request) => {
    const key = `${request.method} ${request.url.pathname}`;
    if (routes[key]) return routes[key](request);
    if (key === 'GET /System/Info/Public') return { body: { ServerName: '家里的 NAS', Version: '12.1.0', Id: 'srv-a', ProductName: 'Jellyfin Server', StartupWizardCompleted: true, ...info } };
    if (key === 'GET /QuickConnect/Enabled') return { body: true };
    return undefined;
  };
  servers.set(origin, route);
}

const accountOn = (address: string, serverId: string, token = `token-${serverId}`): Session => ({
  serverId, serverName: `服务器 ${serverId}`, address, userId: `user-${serverId}`, token, userName: '我',
});

const audio = (id: string, extra: Record<string, unknown> = {}) => ({
  Id: id, Name: `歌 ${id}`, Type: 'Audio', RunTimeTicks: 600000000, Container: 'flac',
  ArtistItems: [{ Name: '测试歌手', Id: 'artist-1' }], Album: '格式测试专辑', AlbumId: 'album-1', AlbumPrimaryImageTag: 'tag-1', ...extra,
});

test('the authorization header carries the device, percent-encoded, and the token', () => {
  const header = authorization('abc');
  assert.match(header, /^MediaBrowser Client="Starry%20Player", Device="%E6%B5%8B%E8%AF%95%E7%9A%84%20Mac", DeviceId="[0-9a-f]{32}", Version="1.2.3", Token="abc"$/);
  assert.equal(authorization().match(/DeviceId="(\w+)"/)![1], header.match(/DeviceId="(\w+)"/)![1]);
  assert.ok(!authorization().includes('Token'));
});

test('a typed address becomes the places to try', () => {
  assert.deepEqual(account.addressCandidates(' 192.168.1.10:8096/ '), ['http://192.168.1.10:8096', 'https://192.168.1.10:8096']);
  assert.deepEqual(account.addressCandidates('nas.local'), ['http://nas.local', 'https://nas.local']);
  assert.deepEqual(account.addressCandidates('music.example.com'), ['https://music.example.com', 'http://music.example.com']);
  assert.deepEqual(account.addressCandidates('music.example.com:443'), ['https://music.example.com:443', 'http://music.example.com:443']);
  assert.deepEqual(account.addressCandidates('HTTPS://Example.com/jellyfin/web/#/home.html'), ['https://Example.com/jellyfin']);
  assert.deepEqual(account.addressCandidates('http://demo.jellyfin.org/stable/web/index.html?x=1'), ['http://demo.jellyfin.org/stable']);
  assert.deepEqual(account.addressCandidates('   '), []);
});

test('servers that are too old, Emby or not set up are refused', () => {
  assert.ok(account.isAtLeast('12.1.0') && account.isAtLeast('10.9.0') && account.isAtLeast('10.10.7'));
  assert.ok(!account.isAtLeast('10.8.13') && !account.isAtLeast('4.9.0'));
  assert.equal(account.refusal({ Id: 'x', Version: '12.1.0', ProductName: 'Jellyfin Server' }, 'a'), undefined);
  assert.match(account.refusal({ Id: 'x', Version: '10.8.13' }, 'a')!, /10\.8\.13 太旧/);
  assert.match(account.refusal({ Id: 'x', Version: '4.9.1', ProductName: 'Emby Server' }, 'a')!, /Emby/);
  assert.match(account.refusal({ Id: 'x', Version: '12.1.0', StartupWizardCompleted: false }, 'a')!, /初始设置/);
  assert.match(account.refusal({ status: 404 }, 'http://a')!, /不是 Jellyfin/);
});

test('connect tries https, then http, and offers 快速连接 when the server has it on', async () => {
  fake('http://music.example.com', {});
  const info = await account.connect('music.example.com/');
  assert.deepEqual(info, { address: 'http://music.example.com', name: '家里的 NAS', version: '12.1.0', methods: ['password', 'code'] });
  assert.deepEqual(sent.map((request) => request.url.origin + request.url.pathname), [
    'https://music.example.com/System/Info/Public',
    'http://music.example.com/System/Info/Public',
    'http://music.example.com/QuickConnect/Enabled',
  ]);
  fake('http://old.local', { 'GET /QuickConnect/Enabled': () => ({ body: false }) }, { Version: '10.11.11' });
  assert.deepEqual((await account.connect('old.local')).methods, ['password']);
  await assert.rejects(account.connect('gone.local:8096'), /连不上 http:\/\/gone\.local:8096/);
  fake('http://nginx.local', { 'GET /System/Info/Public': () => ({ status: 404, body: '<html>' }) });
  await assert.rejects(account.connect('nginx.local'), /不是 Jellyfin 服务器/);
});

const LOGIN = {
  'POST /Users/AuthenticateByName': (request: Sent) =>
    request.json.Username === 'family' && request.json.Pw === ''
      ? { body: { AccessToken: 'tok-family', ServerId: 'srv-a', User: { Id: 'u-family', Name: 'family', PrimaryImageTag: 'face' } } }
      : { status: 401 },
};

test('a password, empty or not, signs in; the profile names the server and the pages follow it', async () => {
  fake('http://nas.local:8096', LOGIN);
  await account.connect('nas.local:8096');
  await assert.rejects(account.loginWithPassword('family', 'wrong'), { code: 'loginFailed', message: '用户名或密码不正确' });
  const profile = await account.loginWithPassword(' family ', '');
  assert.deepEqual(profile, {
    userID: 'srv-a:u-family',
    nickname: 'family',
    avatar: 'http://nas.local:8096/Users/u-family/Images/Primary?fillWidth=200&fillHeight=200&quality=90&tag=face',
    detail: '家里的 NAS',
  });
  assert.equal(pages.current?.song, 'http://nas.local:8096/web/#/details?id={id}&serverId=srv-a');
  const login = sent.find((request) => request.url.pathname === '/Users/AuthenticateByName')!;
  assert.ok(!login.headers.Authorization.includes('Token'));
  assert.equal(session()?.token, 'tok-family');
  assert.deepEqual(Object.keys(starry.storage.get<object>('servers')!), ['srv-a']);
  // Out here only: the server stays known (its songs in the queue still play); a real sign-out forgets it.
  account.signOutLocally();
  assert.equal(pages.current, null);
  assert.deepEqual(Object.keys(starry.storage.get<object>('servers')!), ['srv-a']);
});

test('快速连接 shows a code, waits for it to be approved, then signs in; an old code expires', async () => {
  let approved = false;
  fake('http://nas.local:8096', {
    'POST /QuickConnect/Initiate': () => ({ body: { Secret: 'secret-1', Code: '123456', Authenticated: false } }),
    'GET /QuickConnect/Connect': (request) => (request.url.searchParams.get('secret') === 'secret-1' ? { body: { Authenticated: approved } } : { status: 404 }),
    'POST /Users/AuthenticateWithQuickConnect': (request) =>
      request.json.Secret === 'secret-1' ? { body: { AccessToken: 'tok-qc', User: { Id: 'u-admin', Name: 'admin' } } } : { status: 400 },
  });
  await account.connect('http://nas.local:8096');
  const code = await account.beginCodeLogin();
  assert.deepEqual(code, { key: 'secret-1', code: '123456' });
  assert.equal(await account.pollCodeLogin(code), 'waiting');
  approved = true;
  const confirmed = await account.pollCodeLogin(code);
  assert.ok(typeof confirmed === 'object' && confirmed.profile.userID === 'srv-a:u-admin');
  assert.equal(await account.pollCodeLogin({ key: 'old' }), 'expired');
});

test('restoring an account keeps it when its server is out of reach, not when the token is refused', async () => {
  const kept = accountOn('http://away.local:8096', 'srv-away');
  const profile = await account.restoreCredentials(kept);
  assert.equal(profile.userID, 'srv-away:user-srv-away');
  assert.equal(session()?.serverId, 'srv-away');
  fake('http://away.local:8096', { 'GET /Users/Me': () => ({ status: 401 }) });
  await assert.rejects(account.restoreCredentials(kept), { code: 'loginExpired' });
  await assert.rejects(account.restoreCredentials({ address: 'http://x' }), { code: 'invalidCredentials' });
});

test('refresh picks up a new name and the server’s new name', async () => {
  fake('http://nas.local:8096', { 'GET /Users/Me': () => ({ body: { Id: 'user-srv-a', Name: '新名字' } }) }, { ServerName: '客厅' });
  setSession(accountOn('http://nas.local:8096', 'srv-a'));
  const profile = await account.refresh();
  assert.equal(profile?.nickname, '新名字');
  assert.equal(profile?.detail, '客厅');
  assert.equal(starry.storage.get<Session>('session')?.serverName, '客厅');
});

test('songs, albums and playlists from BaseItemDto', () => {
  const server = accountOn('http://nas.local:8096', 'srv-a');
  const song = model.track(server, audio('s1', { Container: 'mp3', MediaStreams: [{ Type: 'Audio', Codec: 'mp3', SampleRate: 44100 }], IndexNumber: 3, ParentIndexNumber: 2, ArtistItems: [], AlbumArtists: [{ Name: 'Band', Id: 'b' }] }));
  assert.deepEqual(song, {
    id: 's1',
    title: '歌 s1',
    artists: [{ id: 'b', name: 'Band' }],
    album: {
      id: 'album-1',
      name: '格式测试专辑',
      artwork: {
        url: 'http://nas.local:8096/Items/album-1/Images/Primary?fillWidth=300&fillHeight=300&quality=90&tag=tag-1',
        sizedTemplate: 'http://nas.local:8096/Items/album-1/Images/Primary?fillWidth={width}&fillHeight={height}&quality=90&tag=tag-1',
      },
    },
    duration: 60,
    artwork: song.album!.artwork,
    tiers: ['128', '320'],
    discNumber: 2,
    trackNumber: 3,
  });
  const own = model.track(server, audio('s2', { AlbumPrimaryImageTag: undefined, ImageTags: { Primary: 'own' } }));
  assert.match((own.artwork as { url: string }).url, /Items\/s2\/Images\/Primary.*tag=own/);
  assert.equal(own.tiers, undefined);
  const stream = (Codec: string, SampleRate: number) => ({ MediaStreams: [{ Type: 'Lyric' }, { Type: 'Audio', Codec, SampleRate }] });
  assert.deepEqual(model.tiersOf(stream('flac', 44100)), ['128', '320', 'lossless']);
  assert.deepEqual(model.tiersOf(stream('alac', 96000)), ['128', '320', 'lossless', 'hi-res']);
  assert.deepEqual(model.tiersOf(stream('pcm_s24le', 48000)), ['128', '320', 'lossless']);
  assert.deepEqual(model.tiersOf(stream('opus', 48000)), ['128', '320']);
  const album = model.album(server, { Id: 'al', Name: '专辑', AlbumArtists: [{ Name: 'A', Id: 'a' }], PremiereDate: '2024-03-05T00:00:00.0000000Z', ChildCount: 7, ImageTags: {} });
  assert.equal(album.releaseDate, Date.UTC(2024, 2, 5));
  assert.equal(album.trackCount, 7);
  assert.equal(album.artwork, undefined);
  assert.equal(model.album(server, { Id: 'x', Name: 'x', ProductionYear: 1999 }).releaseDate, Date.UTC(1999, 0, 1));
  assert.equal(model.playlist(server, { Id: 'p', Name: '歌单', ChildCount: 3, MediaType: 'Audio' }).isOwned, true);
  assert.ok(model.isMusicPlaylist({ Type: 'Playlist', MediaType: 'Audio' }) && !model.isMusicPlaylist({ Type: 'Playlist', MediaType: 'Video' }));
});

const media = (container: string, codec: string, extra: Partial<Media> = {}): Media => ({ container, codec, sourceId: 'm', ...extra });

test('the file itself when it fits the tier and plays here, else a conversion, never above the file', () => {
  const mp3 = media('mp3', 'mp3', { bitrate: 320322 });
  assert.deepEqual(plan(mp3, '128', FORMATS), { tier: '128', transcode: { codec: 'aac', bitrate: 128000 } });
  assert.deepEqual(plan(mp3, '320', FORMATS), { tier: '320', direct: { ext: 'mp3', container: 'mp3' } });
  assert.deepEqual(plan(mp3, 'lossless', FORMATS), { tier: '320', direct: { ext: 'mp3', container: 'mp3' } });
  assert.deepEqual(plan(mp3, 'hi-res', FORMATS), { tier: '320', direct: { ext: 'mp3', container: 'mp3' } });
  assert.deepEqual(plan(media('mp3', 'mp3', { bitrate: 96000 }), '128', FORMATS).direct, { ext: 'mp3', container: 'mp3' });

  const cd = media('flac', 'flac', { sampleRate: 44100, bitDepth: 16 });
  assert.deepEqual(plan(cd, '320', FORMATS), { tier: '320', transcode: { codec: 'aac', bitrate: 320000 } });
  assert.deepEqual(plan(cd, 'lossless', FORMATS), { tier: 'lossless', direct: { ext: 'flac', container: 'flac' } });
  assert.deepEqual(plan(cd, 'hi-res', FORMATS), { tier: 'lossless', direct: { ext: 'flac', container: 'flac' } });

  const hiRes = media('flac', 'flac', { sampleRate: 96000, bitDepth: 24 });
  assert.deepEqual(plan(hiRes, 'lossless', FORMATS), { tier: 'lossless', transcode: { codec: 'flac', sampleRate: 48000 } });
  assert.deepEqual(plan(media('flac', 'flac', { sampleRate: 88200 }), 'lossless', FORMATS).transcode, { codec: 'flac', sampleRate: 44100 });
  assert.deepEqual(plan(hiRes, 'hi-res', FORMATS), { tier: 'hi-res', direct: { ext: 'flac', container: 'flac' } });

  const wavpack = media('wv', 'wavpack', { sampleRate: 44100 });
  assert.deepEqual(plan(wavpack, 'lossless', FORMATS), { tier: 'lossless', transcode: { codec: 'flac', sampleRate: undefined } });
  assert.deepEqual(plan(wavpack, 'hi-res', FORMATS), { tier: 'lossless', transcode: { codec: 'flac', sampleRate: undefined } });
  const dsd = media('dsf', 'dsd_lsbf_planar', { sampleRate: 2822400 });
  assert.deepEqual(plan(dsd, 'hi-res', FORMATS), { tier: 'hi-res', transcode: { codec: 'flac', sampleRate: 176400 } });
  assert.deepEqual(plan(dsd, 'lossless', FORMATS).transcode, { codec: 'flac', sampleRate: 44100 });
  // Opus does not play here: AAC, at most `320`.
  const opus = media('ogg', 'opus', { bitrate: 160000 });
  assert.deepEqual(plan(opus, '320', FORMATS).transcode, { codec: 'aac', bitrate: 320000 });
  assert.deepEqual(plan(opus, 'hi-res', FORMATS), { tier: '320', transcode: { codec: 'aac', bitrate: 320000 } });
});

test('which files play as they are', () => {
  assert.deepEqual(nativeFormat(media('m4a', 'alac'), FORMATS), { ext: 'm4a', container: 'alac' });
  assert.deepEqual(nativeFormat(media('m4a', 'aac'), FORMATS), { ext: 'm4a', container: 'aac' });
  assert.deepEqual(nativeFormat(media('mov,mp4,m4a,3gp,3g2,mj2', 'aac'), FORMATS), { ext: 'm4a', container: 'aac' });
  assert.deepEqual(nativeFormat(media('aiff', 'pcm_s16be'), FORMATS), { ext: 'aiff', container: 'wav' });
  assert.deepEqual(nativeFormat(media('wav', 'pcm_s16le'), FORMATS), { ext: 'wav', container: 'wav' });
  assert.equal(nativeFormat(media('ogg', 'vorbis'), FORMATS), undefined);
  assert.deepEqual(nativeFormat(media('ogg', 'vorbis'), [...FORMATS, 'ogg']), { ext: 'ogg', container: 'ogg' });
  for (const [container, codec] of [['asf', 'wmav2'], ['wv', 'wavpack'], ['ogg', 'opus'], ['ape', 'ape'], ['m4a', 'mp3']]) {
    assert.equal(nativeFormat(media(container, codec), FORMATS), undefined, `${container}/${codec}`);
  }
  assert.deepEqual(mediaOf({ MediaSources: [{ Id: 'm1', Container: 'FLAC', Bitrate: 900000, Size: 10, MediaStreams: [{ Type: 'Lyric' }, { Type: 'Audio', Codec: 'flac', SampleRate: 96000, BitDepth: 24, Channels: 2 }] }] }), {
    sourceId: 'm1', container: 'flac', codec: 'flac', bitrate: 900000, sampleRate: 96000, bitDepth: 24, channels: 2, size: 10,
  });
  assert.equal(mediaOf({ MediaSources: [] }), undefined);
});

test('stream addresses: the file with ranges, a transcode with a play session of its own, HLS for a long one', () => {
  const server = accountOn('http://nas.local:8096', 'srv-a', 'tok');
  const hiRes = media('flac', 'flac', { sampleRate: 96000, bitDepth: 24, size: 1234 });
  const direct = streamURL(server, 'id1', hiRes, { tier: 'hi-res', direct: { ext: 'flac', container: 'flac' } }, 60);
  assert.equal(direct.url, 'http://nas.local:8096/Audio/id1/stream.flac?static=true');
  assert.equal(direct.info?.fileSize, 1234);
  assert.equal(direct.transcoded, undefined);

  const converted = streamURL(server, 'id1', hiRes, { tier: 'lossless', transcode: { codec: 'flac', sampleRate: 48000 } }, 60);
  const url = new URL(converted.url);
  assert.equal(url.pathname, '/Audio/id1/stream.flac');
  assert.equal(url.searchParams.get('static'), 'false');
  assert.equal(url.searchParams.get('audioCodec'), 'flac');
  assert.equal(url.searchParams.get('audioSampleRate'), '48000');
  assert.equal(url.searchParams.get('mediaSourceId'), 'm');
  assert.equal(url.searchParams.has('ApiKey'), false);
  assert.ok(converted.transcoded && converted.container === 'flac' && converted.tier === 'lossless');
  assert.equal(converted.info?.sampleRate, 48000);
  // Another request is another session: the server would otherwise hand back the last output.
  const again = new URL(streamURL(server, 'id1', hiRes, { tier: 'lossless', transcode: { codec: 'flac', sampleRate: 48000 } }, 60).url);
  assert.notEqual(again.searchParams.get('playSessionId'), url.searchParams.get('playSessionId'));

  const aac = new URL(streamURL(server, 'id1', hiRes, { tier: '128', transcode: { codec: 'aac', bitrate: 128000 } }, 60).url);
  assert.equal(aac.pathname, '/Audio/id1/stream.aac');
  assert.equal(aac.searchParams.get('audioBitRate'), '128000');

  const long = streamURL(server, 'id1', hiRes, { tier: 'lossless', transcode: { codec: 'flac', sampleRate: 48000 } }, 3600);
  const hls = new URL(long.url);
  assert.equal(hls.pathname, '/Audio/id1/master.m3u8');
  assert.equal(long.container, 'hls');
  assert.equal(long.transcoded, undefined);
  assert.equal(hls.searchParams.get('segmentContainer'), 'mp4');
  assert.equal(hls.searchParams.get('ApiKey'), 'tok');
});

test('resolve asks the server the song was found on, with the token in the header', async () => {
  const a = accountOn('http://a.local:8096', 'srv-a');
  const b = accountOn('http://b.local:8096', 'srv-b');
  fake('http://a.local:8096', {});
  fake('http://b.local:8096', {
    'GET /Items/only-b': () => ({ body: { Id: 'only-b', RunTimeTicks: 600000000, MediaSources: [{ Id: 'only-b', Container: 'mp3', MediaStreams: [{ Type: 'Audio', Codec: 'mp3', BitRate: 320000 }] }] } }),
  });
  setSession(b);
  setSession(a);
  const tier = { id: '320', name: '极高', level: 'hq' as const };
  const asset = await resolve({ id: 'only-b', title: 'x', duration: 60 }, tier);
  assert.equal(asset.url, 'http://b.local:8096/Audio/only-b/stream.mp3?static=true');
  assert.match(asset.headers!.Authorization, /Token="token-srv-b"/);
  sent.length = 0;
  await resolve({ id: 'only-b', title: 'x', duration: 60 }, tier);
  assert.deepEqual(sent.map((request) => request.url.host), ['b.local:8096']);
});

test('a stream carries the gains the server measured for the song and its album', async () => {
  const song: Record<string, unknown> = {
    Id: 's', AlbumId: 'al', RunTimeTicks: 600000000, NormalizationGain: -7.4, AlbumNormalizationGain: -6.9,
    MediaSources: [{ Id: 's', Container: 'flac', MediaStreams: [{ Type: 'Audio', Codec: 'flac', SampleRate: 44100 }] }],
  };
  let albumGain: number | undefined = -6.5;
  fake('http://a.local:8096', {
    'GET /Items/s': () => ({ body: song }),
    'GET /Items': (request) => ({ body: { Items: request.url.searchParams.get('Ids') === 'al' ? [{ Id: 'al', Type: 'MusicAlbum', NormalizationGain: albumGain }] : [] } }),
    'GET /Items/al': () => ({ body: { Id: 'al', Type: 'MusicAlbum' } }),
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const tier = { id: 'lossless', name: '无损', level: 'lossless' as const };
  const track = { id: 's', title: 'x', duration: 60 };
  assert.deepEqual((await resolve(track, tier)).gain, { trackGain: -7.4, albumGain: -6.9 });
  assert.equal(sent.length, 1);
  delete song.AlbumNormalizationGain;
  assert.deepEqual((await resolve(track, tier)).gain, { trackGain: -7.4, albumGain: -6.5 });
  albumGain = undefined;
  assert.deepEqual((await resolve(track, tier)).gain, { trackGain: -7.4, albumGain: undefined });
  // Not measured: no gain, and the album is not asked.
  delete song.NormalizationGain;
  sent.length = 0;
  assert.equal((await resolve(track, tier)).gain, undefined);
  assert.deepEqual(sent.map((request) => request.url.pathname), ['/Items/s']);
});

test('songs by id come in the order asked, from whichever server has them', async () => {
  const a = accountOn('http://a.local:8096', 'srv-a');
  const b = accountOn('http://b.local:8096', 'srv-b');
  const answer = (have: string[]) => (request: Sent) => {
    const ids = request.url.searchParams.get('Ids')!.split(',');
    return { body: { Items: ids.filter((id) => have.includes(id)).reverse().map((id) => audio(id)), TotalRecordCount: 0 } };
  };
  fake('http://a.local:8096', { 'GET /Items': answer(['a1', 'a2']) });
  fake('http://b.local:8096', { 'GET /Items': answer(['b1']) });
  setSession(b);
  setSession(a);
  const songs = await catalog.songs(['b1', 'a2', 'gone', 'a1']);
  assert.deepEqual(songs.map((song) => song.id), ['b1', 'a2', 'a1']);
  // Each from its own server.
  assert.match((songs[0].artwork as { url: string }).url, /^http:\/\/b\.local/);
  // B was asked only for what A did not have.
  assert.deepEqual(sent.filter((request) => request.url.host === 'b.local:8096').map((request) => request.url.searchParams.get('Ids')), ['b1,gone']);
});

test('a server whose token stopped working is forgotten, not the account signed in', async () => {
  const a = accountOn('http://a.local:8096', 'srv-a');
  const b = accountOn('http://b.local:8096', 'srv-b');
  fake('http://a.local:8096', {});
  fake('http://b.local:8096', { 'GET /Items/x1': () => ({ status: 401 }) });
  setSession(b);
  setSession(a);
  await assert.rejects(catalog.album('x1'), { code: 'notFound' });
  assert.deepEqual(Object.keys(starry.storage.get<object>('servers')!), ['srv-a']);
  assert.equal(session()?.serverId, 'srv-a');
});

test('a big playlist comes with its first songs and the ids of the rest', async () => {
  const ids = Array.from({ length: 600 }, (_, i) => `p${i}`);
  fake('http://a.local:8096', {
    'GET /Items/pl': () => ({ body: { Id: 'pl', Name: '大歌单', Type: 'Playlist', ChildCount: 600, UserData: { IsFavorite: false } } }),
    'GET /Playlists/pl/Items': (request) => {
      const start = Number(request.url.searchParams.get('StartIndex'));
      const limit = Number(request.url.searchParams.get('Limit'));
      return { body: { Items: ids.slice(start, start + limit).map((id) => audio(id)), TotalRecordCount: 600 } };
    },
    'GET /Playlists/pl': () => ({ body: { ItemIds: ids } }),
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const detail = await catalog.playlist('pl');
  assert.equal(detail.tracks!.length, 500);
  assert.deepEqual(detail.pendingTrackIDs, ids.slice(500));
  assert.equal(detail.playlist.name, '大歌单');
});

test('a playlist is the user’s when its item says it may be deleted; detail says whether it is public', async () => {
  fake('http://a.local:8096', {
    'GET /Items': () => ({ body: { Items: [{ Id: 'mine', Name: '我的', Type: 'Playlist', MediaType: 'Audio', ChildCount: 2, CanDelete: true }, { Id: 'theirs', Name: '别人的公开歌单', Type: 'Playlist', MediaType: 'Audio', CanDelete: true }] } }),
    'GET /Items/mine': () => ({ body: { Id: 'mine', Name: '我的', Type: 'Playlist', CanDelete: true } }),
    'GET /Items/theirs': () => ({ body: { Id: 'theirs', Name: '别人的公开歌单', Type: 'Playlist', CanDelete: false } }),
    'GET /Playlists/theirs/Items': () => ({ body: { Items: [], TotalRecordCount: 0 } }),
    'GET /Playlists/theirs': () => ({ body: { OpenAccess: true, ItemIds: [] } }),
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const lists = await library.userPlaylists();
  assert.deepEqual(lists.map((list) => [list.id, list.isOwned]), [['mine', true], ['theirs', false]]);
  const detail = await catalog.playlist('theirs');
  assert.equal(detail.playlist.isOwned, false);
  assert.equal(detail.playlist.isPrivate, false);
});

test('editing a playlist: create, add skipping songs in it, remove every entry, reorder, rename, delete', async () => {
  let entries = ['a', 'b'];
  let created: any;
  const deleted: string[] = [];
  fake('http://a.local:8096', {
    'POST /Playlists': (request) => { created = request.json; return { body: { Id: 'new' } }; },
    'GET /Items/pl': () => ({ body: { Id: 'pl', Name: '歌单', Type: 'Playlist', CanDelete: true } }),
    'GET /Playlists/pl': () => ({ body: { OpenAccess: false, ItemIds: entries } }),
    'POST /Playlists/pl/Items': (request) => {
      // Ids the server does not have are dropped without a word.
      entries = [...entries, ...request.url.searchParams.get('ids')!.split(',').filter((id) => id !== 'elsewhere')];
      return { status: 204 };
    },
    'POST /Playlists/pl': (request) => {
      if (request.json.Ids) entries = request.json.Ids;
      return { status: 204 };
    },
    'DELETE /Items/pl': () => { deleted.push('pl'); return { status: 204 }; },
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));

  const made = await playlists.createPlaylist({ name: '新歌单', isPrivate: false });
  assert.deepEqual(created, { Name: '新歌单', UserId: 'user-srv-a', MediaType: 'Audio', IsPublic: true, Ids: [] });
  assert.deepEqual([made.id, made.name, made.trackCount, made.isOwned, made.isPrivate], ['new', '新歌单', 0, true, false]);

  assert.equal(await playlists.addToPlaylist('pl', ['b', 'c', 'c', 'elsewhere']), 1);
  assert.deepEqual(entries, ['a', 'b', 'c']);
  const posts = sent.filter((request) => request.method === 'POST' && request.url.pathname === '/Playlists/pl/Items');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url.searchParams.get('ids'), 'c,elsewhere');
  assert.equal(await playlists.addToPlaylist('pl', ['a']), 0);

  entries = ['a', 'b', 'a', 'c'];
  await playlists.removeFromPlaylist('pl', ['a']);
  assert.deepEqual(entries, ['b', 'c']);

  entries = ['b', 'c', 'd'];
  await playlists.reorderPlaylist('pl', ['c', 'b']);
  assert.deepEqual(entries, ['c', 'b', 'd']);

  sent.length = 0;
  await playlists.editPlaylist('pl', { name: '改名', isPrivate: true });
  assert.deepEqual(sent.find((request) => request.method === 'POST')!.json, { Name: '改名', IsPublic: false });
  await playlists.deletePlaylist('pl');
  assert.deepEqual(deleted, ['pl']);
});

test('an artist’s albums include those whose tags name no album artist, once', async () => {
  const tagged = ['t1', 't2'];
  fake('http://a.local:8096', {
    'GET /Items': (request) => {
      const query = request.url.searchParams;
      if (query.get('IncludeItemTypes') === 'Audio') return { body: { Items: [audio('x1', { AlbumId: 't1' }), audio('x2', { AlbumId: 'loose' }), audio('x3', { AlbumId: 'loose' })] } };
      if (query.get('Ids')) return { body: { Items: query.get('Ids')!.split(',').map((id) => ({ Id: id, Name: id, Type: 'MusicAlbum' })) } };
      const start = Number(query.get('StartIndex') ?? 0);
      const limit = Number(query.get('Limit') ?? 100);
      return { body: { Items: tagged.slice(start, start + limit).map((id) => ({ Id: id, Name: id, Type: 'MusicAlbum' })), TotalRecordCount: tagged.length } };
    },
    'GET /Items/loose': () => ({ body: { Id: 'loose', Name: '没写专辑歌手', Type: 'MusicAlbum', AlbumArtists: [] } }),
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const ids = async (offset: number, limit: number) => (await catalog.artistAlbums('artist-x', { offset, limit })).map((album) => album.id);
  assert.deepEqual(await ids(0, 20), ['t1', 't2', 'loose']);
  assert.deepEqual(await ids(20, 20), []);
  assert.deepEqual(await ids(3, 20), []);
  assert.deepEqual(await ids(0, 2), ['t1', 't2']);
  assert.deepEqual(await ids(2, 2), ['loose']);
  assert.deepEqual(await ids(4, 2), []);
  const detail = await catalog.album('loose');
  assert.deepEqual(detail.album.artists, [{ id: 'artist-1', name: '测试歌手' }]);
});

test('Home: the server’s shelves, one failing left out; none signed out', async () => {
  assert.deepEqual(await catalog.homeShelves(), []);
  fake('http://a.local:8096', {
    'GET /Items': (request) => {
      const type = request.url.searchParams.get('IncludeItemTypes');
      if (type === 'MusicArtist') return { status: 500 };
      if (type === 'Audio') return { body: { Items: [audio('h1')] } };
      if (type === 'MusicAlbum') return { body: { Items: [{ Id: 'al', Name: '专辑', Type: 'MusicAlbum' }] } };
      return { body: { Items: [{ Id: 'pl', Name: '歌单', Type: 'Playlist', MediaType: 'Audio' }, { Id: 'v', Name: '视频', Type: 'Playlist', MediaType: 'Video' }] } };
    },
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const shelves = await catalog.homeShelves();
  assert.deepEqual(shelves.map((shelf) => shelf.id), ['mix', 'latest', 'frequent', 'playlists', 'favoriteAlbums']);
  assert.deepEqual(shelves.map((shelf) => shelf.title), ['随便听听', '最近添加', '最常播放', '我的歌单', '收藏的专辑']);
  assert.deepEqual((shelves[3] as { playlists: { id: string }[] }).playlists.map((playlist) => playlist.id), ['pl']);
  servers.clear();
  await assert.rejects(catalog.homeShelves(), { code: 'network' });
});

test('资料库: albums in the order picked or of a genre, artists with songs, genres on albums', async () => {
  let artistsGone = false;
  fake('http://a.local:8096', {
    'GET /Items': (request) => {
      const query = request.url.searchParams;
      switch (query.get('IncludeItemTypes')) {
        case 'MusicAlbum':
          return { body: { Items: [{ Id: 'al', Name: '叶惠美', Type: 'MusicAlbum', ChildCount: 2, ProductionYear: 2003, AlbumArtists: [{ Id: 'jay', Name: '周杰伦' }] }], TotalRecordCount: 9 } };
        case 'MusicArtist':
          return { body: { Items: [{ Id: 'jay', Name: '周杰伦', SongCount: 4 }], TotalRecordCount: 14 } };
        case 'MusicGenre':
          assert.equal(query.get('Fields'), 'ItemCounts');
          return {
            body: {
              Items: [
                { Id: 'g1', Name: 'Jazz', AlbumCount: 1, ImageTags: { Primary: 'c1' } },
                { Id: 'g2', Name: 'mandopop', AlbumCount: 0, SongCount: 0 },
                { Id: 'g3', Name: '华语流行', AlbumCount: 2, ImageTags: {} },
              ],
            },
          };
      }
      return undefined;
    },
    'GET /Artists': (request) => {
      if (artistsGone) return { status: 404 };
      assert.equal(request.url.searchParams.get('Fields'), 'ItemCounts');
      return { body: { Items: [{ Id: 'jay', Name: '周杰伦', AlbumCount: 2, SongCount: 4, ImageTags: { Primary: 'p' } }], TotalRecordCount: 10 } };
    },
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));

  const albums = await catalog.libraryAlbums('year', null, { offset: 60, limit: 60 });
  assert.deepEqual(albums.albums.map((album) => [album.id, album.trackCount, album.artists]), [['al', 2, [{ id: 'jay', name: '周杰伦' }]]]);
  assert.equal(albums.total, 9);
  let query = sent.at(-1)!.url.searchParams;
  assert.equal(query.get('SortBy'), 'ProductionYear,PremiereDate,SortName');
  assert.equal(query.get('SortOrder'), 'Descending,Descending,Ascending');
  assert.equal(query.get('StartIndex'), '60');
  assert.equal(query.has('Genres'), false);
  await catalog.libraryAlbums('artist', '华语流行;R&B', { offset: 0, limit: 60 });
  query = sent.at(-1)!.url.searchParams;
  assert.equal(query.get('Genres'), '华语流行;R&B');
  assert.equal(query.get('SortBy'), 'AlbumArtist,ProductionYear,SortName');
  assert.equal(query.has('SortOrder'), false);

  const artists = await catalog.libraryArtists({ offset: 0, limit: 80 });
  assert.equal(sent.at(-1)!.url.pathname, '/Artists');
  assert.deepEqual(artists.artists.map((artist) => [artist.name, artist.songCount, artist.albumCount]), [['周杰伦', 4, 2]]);
  assert.equal(artists.total, 10);
  // A server without /Artists: its artist items.
  artistsGone = true;
  assert.equal((await catalog.libraryArtists({ offset: 0, limit: 80 })).total, 14);

  const genres = await catalog.libraryGenres();
  assert.deepEqual(genres.map((genre) => [genre.name, genre.albumCount]), [['华语流行', 2], ['Jazz', 1]]);
  assert.match((genres[1].artwork as { url: string }).url, /\/Items\/g1\/Images\/Primary\?.*tag=c1/);
  assert.equal(genres[0].artwork, undefined);

  account.signOutLocally();
  await assert.rejects(catalog.libraryAlbums('title', null, { offset: 0, limit: 60 }), { code: 'loginRequired' });
});

test('search pages by the server’s count', async () => {
  fake('http://a.local:8096', {
    'GET /Items': (request) => {
      assert.equal(request.url.searchParams.get('searchTerm'), '歌');
      assert.equal(request.url.searchParams.get('IncludeItemTypes'), 'Audio');
      return { body: { Items: [audio('r1'), audio('r2')], TotalRecordCount: 5 } };
    },
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  const page = await catalog.search(' 歌 ', 'song', { offset: 0, limit: 2 });
  assert.deepEqual(page.songs?.map((song) => song.id), ['r1', 'r2']);
  assert.equal(page.total, 5);
  assert.equal(page.hasMore, true);
  assert.equal((await catalog.search('歌', 'song', { offset: 3, limit: 2 })).hasMore, false);
});

test('liked songs: liked here first, newest first, the rest as the server lists them', () => {
  const { ids, times } = library.orderLikes(['x', 'y', 'z', 'w'], { z: 5, y: 9, gone: 20 });
  assert.deepEqual(ids, ['y', 'z', 'x', 'w']);
  assert.deepEqual(times, { y: 9, z: 5 });
});

test('私人 FM hands out new songs from mixes, never a trashed one', async () => {
  const library_ = Array.from({ length: 12 }, (_, i) => `f${i}`);
  fake('http://a.local:8096', {
    'GET /Items': (request) => ({ body: { Items: library_.slice(0, Number(request.url.searchParams.get('Limit'))).map((id) => audio(id)) } }),
    'GET /Items/f0/InstantMix': () => ({ body: { Items: library_.slice(0, 8).map((id) => audio(id)) } }),
  });
  setSession(accountOn('http://a.local:8096', 'srv-a'));
  await library.trashFM('f2');
  const first = await library.personalFM('default', true);
  assert.deepEqual(first.map((track) => track.id), ['f0', 'f1', 'f3', 'f4', 'f5']);
  const second = await library.personalFM('default', false);
  assert.ok(second.length > 0 && second.every((track) => !first.some((given) => given.id === track.id) && track.id !== 'f2'));
});

test('lyrics: enhanced LRC becomes word-timed TTML, plain LRC stays LRC, untimed text is none', () => {
  const enhanced = {
    Metadata: {},
    Lyrics: [
      { Text: 'Word by word', Start: 10000000, Cues: [{ Position: 0, EndPosition: 5, Start: 10000000, End: 15000000 }, { Position: 5, EndPosition: 8, Start: 15000000, End: 20000000 }, { Position: 8, EndPosition: 12, Start: 20000000, End: 400000000 }] },
      { Text: '<逐字> & 歌词', Start: 400000000, Cues: [{ Position: 0, EndPosition: 5, Start: 400000000, End: 410000000 }, { Position: 5, EndPosition: 7, Start: 410000000, End: 420000000 }, { Position: 7, EndPosition: 9, Start: 420000000 }] },
    ],
  };
  const ttml = toLyrics(enhanced, 60);
  assert.equal(ttml?.format, 'ttml');
  assert.equal(
    ttml?.body,
    '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
      + '<p begin="1.000s" end="7.000s"><span begin="1.000s" end="1.500s">Word</span> <span begin="1.500s" end="2.000s">by</span> <span begin="2.000s" end="7.000s">word</span></p>'
      + '<p begin="40.000s" end="47.000s"><span begin="40.000s" end="41.000s">&lt;逐字&gt;</span> <span begin="41.000s" end="42.000s">&amp;</span> <span begin="42.000s" end="47.000s">歌词</span></p>'
      + '</div></body></tt>',
  );
  const plain = toLyrics({ Lyrics: [{ Text: '第一行歌词', Start: 10000000, Cues: [] }, { Text: '', Start: 30000000, Cues: [] }, { Text: '第三行 third line', Start: 755000000, Cues: [] }] });
  assert.deepEqual(plain, { format: 'lrc', body: '[00:01.00]第一行歌词\n[00:03.00]\n[01:15.50]第三行 third line' });
  assert.equal(toLyrics({ Lyrics: [{ Text: 'Plain text lyric line one' }, { Text: 'line two' }] }), null);
  assert.equal(toLyrics({ Lyrics: [] }), null);
});
