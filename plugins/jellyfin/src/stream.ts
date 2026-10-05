// Long transcodes use HLS to avoid waiting for a full download; HLS has no EQ or spectrum.

import { isLossless, qualityTiers as commonTiers } from '../../common/library';
import type { Container, PlayableAsset, QualityTier, Track } from '../../sdk/starry';
import { api, authorization, deviceId, locate, type Server } from './client';

/** A song comes in the tiers its file reaches (`models.tiersOf`); the server converts to AAC below `lossless`. */
export const qualityTiers: QualityTier[] = commonTiers('AAC');

const HLS_AFTER_SECONDS = 20 * 60;

/** The file the server keeps, from `MediaSources`. */
export interface Media {
  sourceId?: string;
  /** Lower case: `mp3`, `flac`, `m4a`, `ogg`, `asf`… */
  container: string;
  codec?: string;
  bitrate?: number;
  sampleRate?: number;
  bitDepth?: number;
  channels?: number;
  size?: number;
}

export function mediaOf(item: any): Media | undefined {
  const source = Array.isArray(item?.MediaSources) ? item.MediaSources[0] : undefined;
  if (!source) return undefined;
  const audio = (Array.isArray(source.MediaStreams) ? source.MediaStreams : []).find((stream: any) => stream?.Type === 'Audio') ?? {};
  const number = (value: unknown) => (typeof value === 'number' && value > 0 ? value : undefined);
  return {
    sourceId: typeof source.Id === 'string' ? source.Id : undefined,
    container: typeof source.Container === 'string' ? source.Container.toLowerCase() : '',
    codec: typeof audio.Codec === 'string' ? audio.Codec.toLowerCase() : undefined,
    bitrate: number(audio.BitRate) ?? number(source.Bitrate),
    sampleRate: number(audio.SampleRate),
    bitDepth: number(audio.BitDepth),
    channels: number(audio.Channels),
    size: number(source.Size),
  };
}

export function nativeFormat(media: Media, formats: readonly string[]): { ext: string; container: Container } | undefined {
  const containers = media.container.split(',');
  const has = (...names: string[]) => names.some((name) => containers.includes(name));
  const codec = media.codec ?? '';
  if (has('mp3') && (codec === 'mp3' || !codec)) return { ext: 'mp3', container: 'mp3' };
  if (has('flac') && (codec === 'flac' || !codec)) return { ext: 'flac', container: 'flac' };
  if (has('wav') && codec.startsWith('pcm')) return { ext: 'wav', container: 'wav' };
  if (has('aiff', 'aif') && codec.startsWith('pcm')) return { ext: 'aiff', container: 'wav' };
  if (has('m4a', 'mp4', 'm4b', 'mov')) {
    if (codec === 'aac') return { ext: 'm4a', container: 'aac' };
    if (codec === 'alac') return { ext: 'm4a', container: 'alac' };
    return undefined;
  }
  if (has('aac') && codec === 'aac') return { ext: 'aac', container: 'aac' };
  if (has('ogg', 'oga') && codec === 'vorbis' && formats.includes('ogg')) return { ext: 'ogg', container: 'ogg' };
  return undefined;
}

export interface Plan {
  tier: string;
  direct?: { ext: string; container: Container };
  transcode?: { codec: 'flac' | 'aac'; bitrate?: number; sampleRate?: number };
}

export function plan(media: Media, requested: string, formats: readonly string[]): Plan {
  const native = nativeFormat(media, formats);
  const kbps = (media.bitrate ?? 0) / 1000;
  const rate = media.sampleRate ?? 0;
  const family = rate > 0 && rate % 44100 === 0 ? 44100 : 48000;
  const direct = (tier: string): Plan | undefined => (native ? { tier, direct: native } : undefined);
  const flac = (tier: string, sampleRate?: number): Plan => ({ tier, transcode: { codec: 'flac', sampleRate } });
  const aac = (tier: string, bitrate: number): Plan => ({ tier, transcode: { codec: 'aac', bitrate: bitrate * 1000 } });
  const lossless = isLossless(media.codec);
  if (requested === '128') return (!lossless && kbps <= 170 ? direct('128') : undefined) ?? aac('128', 128);
  if (requested === '320' || !lossless) return (!lossless && kbps <= 330 ? direct('320') : undefined) ?? aac('320', 320);
  if (requested === 'lossless' || rate <= 48000) return (rate <= 48000 ? direct('lossless') : undefined) ?? flac('lossless', rate > 48000 ? family : undefined);
  return direct('hi-res') ?? flac('hi-res', rate > 192000 ? family * 4 : undefined);
}

/** A play session of its own for every transcode: the server reuses the output of one with the same device and session, whatever was asked. */
const playSession = () => starry.encoding.hex.encode(starry.crypto.randomBytes(16));

export function streamURL(server: Server, id: string, media: Media, plan: Plan, duration: number): Omit<PlayableAsset, 'headers'> {
  const base = `${server.address}/Audio/${encodeURIComponent(id)}`;
  const info = { bitrate: media.bitrate, sampleRate: media.sampleRate, bitDepth: media.bitDepth, channels: media.channels };
  if (plan.direct) {
    return { url: `${base}/stream.${plan.direct.ext}?static=true`, container: plan.direct.container, tier: plan.tier, info: { ...info, fileSize: media.size } };
  }
  const { codec, bitrate, sampleRate } = plan.transcode!;
  const query = new URLSearchParams();
  const add = (name: string, value: string | number | undefined) => value !== undefined && query.set(name, String(value));
  add('mediaSourceId', media.sourceId);
  add('deviceId', deviceId());
  add('playSessionId', playSession());
  const converted = {
    bitrate: codec === 'aac' ? bitrate : undefined,
    sampleRate: sampleRate ?? media.sampleRate,
    bitDepth: codec === 'flac' ? media.bitDepth : undefined,
  };
  if (duration > HLS_AFTER_SECONDS) {
    add('audioCodec', codec);
    add('segmentContainer', codec === 'flac' ? 'mp4' : 'ts');
    add('audioBitRate', bitrate);
    add('audioSampleRate', sampleRate);
    // Segments take the playlist's query: the token goes in it.
    add('ApiKey', server.token);
    return { url: `${base}/master.m3u8?${query}`, container: 'hls', tier: plan.tier, info: converted };
  }
  add('static', 'false');
  add('audioCodec', codec);
  add('audioBitRate', bitrate);
  add('audioSampleRate', sampleRate);
  return { url: `${base}/stream.${codec}?${query}`, container: codec, tier: plan.tier, info: converted, transcoded: true };
}

const gainValue = (gain: unknown) => (typeof gain === 'number' && Number.isFinite(gain) ? gain : undefined);

// Normalization gains target −18 LUFS. Before Jellyfin 12, fetch album gain from
// the album item; peaks are unavailable, so amplification is volume-limited.
export function gainOf(song: any, album?: any): PlayableAsset['gain'] {
  const trackGain = gainValue(song?.NormalizationGain);
  const albumGain = gainValue(song?.AlbumNormalizationGain) ?? gainValue(album?.NormalizationGain);
  return trackGain === undefined && albumGain === undefined ? undefined : { trackGain, albumGain };
}

// Fetch album gain via `/Items?Ids=…`; `/Items/{id}` omits it on older servers.
async function albumForGain(server: Server, song: any): Promise<any> {
  if (gainValue(song?.NormalizationGain) === undefined || gainValue(song?.AlbumNormalizationGain) !== undefined || typeof song?.AlbumId !== 'string') return undefined;
  try {
    const result = await api<{ Items?: any[] }>(server, '/Items', { query: { userId: server.userId, Ids: song.AlbumId, EnableImages: false, EnableUserData: false } });
    return result?.Items?.[0];
  } catch {
    return undefined;
  }
}

export async function resolve(track: Track, tier: QualityTier): Promise<PlayableAsset> {
  const { server, value: item } = await locate(track.id, (server) =>
    api(server, `/Items/${encodeURIComponent(track.id)}`, { query: { userId: server.userId, Fields: 'MediaSources' } }),
  );
  const media = mediaOf(item);
  if (!media) throw starry.error('notPlayable', '服务器上没有这首歌的文件');
  const duration = track.duration > 0 ? track.duration : (item?.RunTimeTicks ?? 0) / 1e7;
  const stream = streamURL(server, track.id, media, plan(media, tier.id, starry.app.formats), duration);
  return { ...stream, headers: { Authorization: authorization(server.token) }, expiresIn: 6 * 3600, gain: gainOf(item, await albumForGain(server, item)) };
}
