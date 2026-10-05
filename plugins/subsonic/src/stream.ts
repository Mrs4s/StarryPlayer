// Request `format=raw` to prevent Airsonic-Advanced silently converting FLAC to MP3.
// Without OpenSubsonic transcoding, request MP3 explicitly to avoid unsupported Ogg Opus.

import type { Container, PlayableAsset, QualityTier, Track } from '../../sdk/starry';
import { qualityTiers as commonTiers } from '../../common/library';
import { answer, call, CLIENT, locate, restURL, type Server } from './client';
import { formatOf, type Format } from './models';

/** A song comes in the tiers its file reaches (`models.tiersOf`); the server converts to MP3 below `lossless`. */
export const qualityTiers: QualityTier[] = commonTiers('MP3');

export function nativeContainer(format: Format, formats: readonly string[]): Container | undefined {
  switch (format.suffix) {
    case 'mp3': return 'mp3';
    case 'flac': return 'flac';
    case 'wav': return 'wav';
    case 'aif':
    case 'aiff': return 'wav';
    case 'm4a':
    case 'mp4':
    case 'm4b':
    case 'alac': return format.lossless ? 'alac' : 'aac';
    case 'aac': return 'aac';
    // Ogg Vorbis where this macOS plays it; Opus in Ogg (LMS says so in the type) it does not.
    case 'ogg':
    case 'oga': return formats.includes('ogg') && !format.contentType.includes('opus') ? 'ogg' : undefined;
    default: return undefined;
  }
}

/** What a stream counts as, asked for `requested`: lossless by its sample rate, lossy as the lossy tier asked for (`320` when a lossless one was). */
export function tierOf(requested: string, lossless: boolean, sampleRate?: number): string {
  if (lossless) return sampleRate !== undefined && sampleRate > 48000 ? 'hi-res' : 'lossless';
  return requested === '128' ? '128' : '320';
}

/** What `resolve` hands out without the server deciding: the file as it is, or an MP3 at a bit rate. */
export interface Plan {
  tier: string;
  direct?: Container;
  mp3?: number;
}

export function plan(format: Format, requested: string, formats: readonly string[]): Plan {
  const native = nativeContainer(format, formats);
  const kbps = format.kbps ?? 0;
  if (requested === '128') return !format.lossless && native && kbps <= 170 ? { tier: '128', direct: native } : { tier: '128', mp3: 128 };
  if (requested === '320' || !format.lossless) return !format.lossless && native && kbps <= 330 ? { tier: '320', direct: native } : { tier: '320', mp3: 320 };
  return native ? { tier: tierOf(requested, true, format.sampleRate), direct: native } : { tier: '320', mp3: 320 };
}

/** The MP3 bit rates LAME makes. */
const MP3_RATES = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

/**
 * The `maxBitRate` to ask for: gonic converts only when it is below the file's (else it sends the
 * file, which may be an Opus this Mac cannot play), so there it is the next rate down.
 */
export function maxBitRate(server: Pick<Server, 'type'>, wanted: number, kbps?: number): number {
  if (server.type?.toLowerCase() !== 'gonic' || kbps === undefined || kbps > wanted) return wanted;
  return [...MP3_RATES].reverse().find((rate) => rate < kbps) ?? MP3_RATES[0];
}

const fileInfo = (format: Format) => ({ bitrate: format.kbps ? format.kbps * 1000 : undefined, sampleRate: format.sampleRate, bitDepth: format.bitDepth, channels: format.channels, fileSize: format.size });

export function planned(server: Server, id: string, format: Format, plan: Plan): PlayableAsset {
  if (plan.direct) return { url: restURL(server, 'stream', { id, format: 'raw' }), container: plan.direct, tier: plan.tier, info: fileInfo(format) };
  const rate = maxBitRate(server, plan.mp3!, format.kbps);
  return { url: restURL(server, 'stream', { id, format: 'mp3', maxBitRate: rate }), container: 'mp3', tier: plan.tier, transcoded: true, info: { bitrate: rate * 1000, sampleRate: format.sampleRate, channels: format.channels } };
}

const http = (containers: string[], audioCodecs: string[]) => ({ containers, audioCodecs, protocols: ['http'], maxAudioChannels: 8 });
const lossyTarget = { container: 'mp3', audioCodec: 'mp3', protocol: 'http', maxAudioChannels: 2 };
const atMost48k = (name: string) => ({ type: 'AudioCodec', name, limitations: [{ name: 'audioSamplerate', comparison: 'LessThanEqual', values: ['48000'], required: true }] });

export function clientInfo(tier: string, formats: readonly string[]): Record<string, unknown> {
  const lossy = [http(['mp3'], ['mp3']), http(['mp4', 'm4a', 'aac'], ['aac'])];
  if (formats.includes('ogg')) lossy.push(http(['ogg', 'oga'], ['vorbis']));
  if (tier === '128' || tier === '320') {
    const kbps = tier === '128' ? 128 : 320;
    return {
      name: CLIENT,
      platform: 'macOS',
      maxAudioBitrate: (tier === '128' ? 170 : 330) * 1000,
      maxTranscodingAudioBitrate: kbps * 1000,
      directPlayProfiles: lossy,
      transcodingProfiles: [lossyTarget],
    };
  }
  return {
    name: CLIENT,
    platform: 'macOS',
    directPlayProfiles: [...lossy, http(['mp4', 'm4a'], ['alac']), http(['flac'], ['flac']), http(['wav', 'aiff', 'aif'], ['pcm'])],
    transcodingProfiles: [{ container: 'flac', audioCodec: 'flac', protocol: 'http', maxAudioChannels: 8 }, lossyTarget],
    codecProfiles: tier === 'lossless' ? [atMost48k('flac'), atMost48k('alac'), atMost48k('pcm')] : [],
  };
}

const CONTAINERS: Record<string, Container> = { mp3: 'mp3', flac: 'flac', aac: 'aac', mp4: 'aac', m4a: 'aac', ogg: 'ogg', wav: 'wav' };

/** The server's decision as an asset; undefined when it can do neither. */
export function decided(server: Server, id: string, format: Format, requested: string, decision: any, formats: readonly string[]): PlayableAsset | undefined {
  if (decision?.canDirectPlay === true) {
    const native = nativeContainer(format, formats);
    if (native) return { url: restURL(server, 'stream', { id, format: 'raw' }), container: native, tier: tierOf(requested, format.lossless, format.sampleRate), info: fileInfo(format) };
  }
  const stream = decision?.transcodeStream;
  if (decision?.canTranscode !== true || typeof decision?.transcodeParams !== 'string' || !stream) return undefined;
  const codec = String(stream.codec ?? stream.container ?? '').toLowerCase();
  const container = CONTAINERS[String(stream.container ?? '').toLowerCase()] ?? CONTAINERS[codec];
  if (!container) return undefined;
  const lossless = codec === 'flac' || codec === 'alac' || codec.startsWith('pcm');
  const kbps = typeof stream.audioBitrate === 'number' ? stream.audioBitrate / 1000 : undefined;
  const sampleRate = typeof stream.audioSamplerate === 'number' ? stream.audioSamplerate : format.sampleRate;
  return {
    url: restURL(server, 'getTranscodeStream', { mediaId: id, mediaType: 'song', transcodeParams: decision.transcodeParams }),
    container,
    tier: tierOf(requested, lossless, sampleRate),
    transcoded: true,
    info: { bitrate: kbps ? kbps * 1000 : undefined, sampleRate, bitDepth: typeof stream.audioBitdepth === 'number' ? stream.audioBitdepth : undefined, channels: typeof stream.audioChannels === 'number' ? stream.audioChannels : undefined },
  };
}

async function decide(server: Server, id: string, format: Format, tier: string, formats: readonly string[]): Promise<PlayableAsset | undefined> {
  const response = await starry.http.request<string>({
    url: `${restURL(server, 'getTranscodeDecision', { mediaId: id, mediaType: 'song' })}&f=json`,
    method: 'POST',
    json: clientInfo(tier, formats),
    cookies: false,
    responseType: 'text',
  });
  return decided(server, id, format, tier, answer(response, 'getTranscodeDecision')?.transcodeDecision, formats);
}

const finite = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) ? value : undefined);

// A zero peak means missing gain on gonic; LMS supplies no peaks.
export function gainOf(song: any): PlayableAsset['gain'] {
  const replayGain = song?.replayGain;
  if (!replayGain || typeof replayGain !== 'object') return undefined;
  const pair = (gain: unknown, peak: unknown) => {
    const value = finite(gain);
    const top = finite(peak);
    return value === undefined || (top !== undefined && top <= 0) ? {} : { gain: value, peak: top };
  };
  const track = pair(replayGain.trackGain, replayGain.trackPeak);
  const album = pair(replayGain.albumGain, replayGain.albumPeak);
  if (track.gain === undefined && album.gain === undefined) return undefined;
  return { trackGain: track.gain, trackPeak: track.peak, albumGain: album.gain, albumPeak: album.peak };
}

/**
 * Whether `url` sends an MP3. A server that is not OpenSubsonic may send the file itself when it has
 * no conversion set up for its format (Airsonic-Advanced has none for Opus), whatever was asked.
 */
async function sendsMP3(url: string): Promise<boolean> {
  const response = await starry.http.request({ url, headers: { Range: 'bytes=0-1' }, responseType: 'bytes', timeout: 20, cookies: false });
  return response.status < 400 && /mpeg|mp3/i.test(response.headers['content-type'] ?? '');
}

export async function resolve(track: Track, tier: QualityTier): Promise<PlayableAsset> {
  const { server, id } = locate(track.id);
  const song = (await call(server, 'getSong', { id }))?.song;
  if (!song) throw starry.error('notPlayable', '服务器上没有这首歌的文件');
  const format = formatOf(song);
  const formats = starry.app.formats;
  let asset: PlayableAsset | undefined;
  if (server.extensions.transcoding) asset = await decide(server, id, format, tier.id, formats).catch(() => undefined);
  if (!asset) {
    asset = planned(server, id, format, plan(format, tier.id, formats));
    if (asset.transcoded && Object.keys(server.extensions).length === 0 && !nativeContainer(format, formats) && !(await sendsMP3(asset.url).catch(() => true))) {
      throw starry.error('notPlayable', `服务器没有把这首歌转成 MP3（${format.suffix || '这种格式'} 本机放不了）：请在服务器的转码设置里加上 ${format.suffix || '它'}`);
    }
  }
  return { ...asset, expiresIn: 6 * 3600, gain: gainOf(song) };
}
