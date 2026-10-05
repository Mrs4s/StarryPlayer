// Playback: NetEase's quality levels as the source's tiers, and the player URL
// (`/api/song/enhance/player/url/v1`, one id at a time).

import type { PlayableAsset, QualityLevel, QualityTier, Track } from '../../sdk/starry';
import { request } from './client';
import { Song } from './endpoints';
import { fee as feeOf } from './mapping';
import { USER_AGENT } from './profile';
import { array, bool, int, num, str } from './util';

export const qualityTiers: QualityTier[] = [
  { id: 'lq', name: '标准', detail: '128 kbps · MP3', level: 'lq' },
  { id: 'sq', name: '较高', detail: '192 kbps · MP3', level: 'sq' },
  { id: 'hq', name: '极高', detail: '320 kbps · MP3', level: 'hq' },
  { id: 'lossless', name: '无损', detail: 'FLAC · CD 品质', level: 'lossless' },
  { id: 'hi-res', name: 'Hi-Res', detail: 'FLAC · 24 bit 高解析度', level: 'hi-res' },
];

export const LEVELS: Record<QualityLevel, string> = { lq: 'standard', sq: 'higher', hq: 'exhigh', lossless: 'lossless', 'hi-res': 'hires' };

export function tierForLevel(level: string): string {
  switch (level) {
    case 'standard':
      return 'lq';
    case 'higher':
      return 'sq';
    case 'exhigh':
      return 'hq';
    case 'lossless':
      return 'lossless';
    case 'hires':
    case 'dolby':
    case 'jyeffect':
    case 'jymaster':
    case 'sky':
    case 'vivid':
      return 'hi-res';
    default:
      return 'hq';
  }
}

export const TRIAL_MODE = { default: -1, dailyRecommend: 35, fm: 36, radarPlaylist: 37, likePlaylist: 43 } as const;

/** Direct links carry no explicit lifetime (`expi` is usually 1200 s); 20 minutes at most. */
const ASSET_LIFETIME = 20 * 60;

const CONTAINERS = new Set(['mp3', 'aac', 'flac', 'alac', 'wav', 'ogg', 'ape', 'mp4', 'hls']);

export interface PlaybackFacts {
  /** kbps. */
  bitrate: number;
  level: string;
  fee: number;
  rightSource: number;
}

/** Bounded: a long queue (or personal FM, three songs every few minutes) cannot grow it without limit. */
const facts = new Map<string, PlaybackFacts>();

export const playbackFacts = (id: string) => facts.get(id);

export async function resolve(track: Track, tier: QualityTier): Promise<PlayableAsset> {
  const body = { ids: JSON.stringify([track.id]), level: LEVELS[tier.level] ?? 'exhigh', immerseType: 'c51', encodeType: 'mp3', trialMode: TRIAL_MODE.default };
  const json = await request(Song.playerURL, body);
  const item = array(json?.data)[0];
  if (!item) throw starry.error('sourceUnreachable', '网易云没有返回播放地址');
  // A result is playable only with code 200 and a url.
  const url = str(item.url);
  if ((int(item.code) ?? 200) !== 200 || !url) {
    const fee = int(item.fee) !== undefined ? feeOf(int(item.fee)) : (track.fee ?? 'free');
    if (fee === 'vip' || fee === 'purchase' || track.fee === 'vip' || track.fee === 'purchase') throw starry.error('vipRequired');
    throw starry.error('unavailableInRegion');
  }
  const type = (str(item.type) ?? 'mp3').toLowerCase();
  if (facts.size > 500) facts.clear();
  facts.set(track.id, {
    // `br` is bits per second; the log reports kbps.
    bitrate: Math.trunc((int(item.br) ?? 0) / 1000),
    level: str(item.level) ?? '',
    fee: int(item.fee) ?? 0,
    rightSource: int(item.rightSource) ?? 0,
  });
  const trialPrivilege = item.freeTrialPrivilege;
  const consumableTrial = bool(trialPrivilege?.resConsumable) === true && bool(trialPrivilege?.userConsumable) === true;
  const positive = (value: unknown) => {
    const n = int(value);
    return n !== undefined && n > 0 ? n : undefined;
  };
  return {
    url,
    headers: { 'User-Agent': USER_AGENT },
    container: (CONTAINERS.has(type) ? type : 'mp3') as PlayableAsset['container'],
    tier: tierForLevel(str(item.level) ?? ''),
    expiresIn: Math.min(num(item.expi) ?? ASSET_LIFETIME, ASSET_LIFETIME),
    trial: item.freeTrialInfo != null ? true : consumableTrial,
    supportsOverlap: true,
    info: { bitrate: positive(item.br), sampleRate: positive(item.sr), fileSize: positive(item.size) },
  };
}
