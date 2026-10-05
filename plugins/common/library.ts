// What a library of the listener's own offers on top of its songs, whatever the server: the
// quality tiers a song's file reaches, when a play counts, and an endless radio made from mixes
// of the library (personal FM).

import type { PlaybackReport, QualityTier, Track } from '../sdk/starry';

export const isLossless = (codec: unknown) => typeof codec === 'string' && /^(flac|alac|pcm|wav|aiff?|wavpack|wv|ape|tta|dsd|dsf|dff|mlp|truehd|wmalossless)/i.test(codec);

export function qualityTiers(lossy: string): QualityTier[] {
  return [
    { id: '128', name: '省流', detail: `${lossy} 128 kbps`, level: 'lq' },
    { id: '320', name: '极高', detail: `${lossy} 320 kbps，或有损的原文件`, level: 'hq' },
    { id: 'lossless', name: '无损', detail: 'FLAC 最高 48 kHz，或无损的原文件', level: 'lossless' },
    { id: 'hi-res', name: 'Hi-Res', detail: '原采样率的无损原文件', level: 'hi-res' },
  ];
}

export function tiersFor(lossless: boolean, sampleRate?: number): string[] {
  if (!lossless) return ['128', '320'];
  return typeof sampleRate === 'number' && sampleRate > 48000 ? ['128', '320', 'lossless', 'hi-res'] : ['128', '320', 'lossless'];
}

export const countsAsPlay = (report: PlaybackReport) => report.playedSeconds >= Math.min(report.duration * 0.5, 240);

export interface RadioSource {
  account: string;
  seed(): Promise<string | undefined>;
  mix(seed: string): Promise<Track[]>;
  random(): Promise<Track[]>;
}

const BATCH = 5;
const TRASH_KEPT = 500;

interface Radio {
  account: string;
  queue: Track[];
  /** Handed out since the radio started, so the mixes bring new ones. */
  given: Set<string>;
  seed?: string;
}

let radio: Radio | undefined;

const trashedBy = (account: string) => new Set((starry.storage.get<Record<string, string[]>>('fmTrash') ?? {})[account] ?? []);

export async function nextRadioSongs(source: RadioSource, firstFetch: boolean): Promise<Track[]> {
  if (firstFetch || radio?.account !== source.account) radio = { account: source.account, queue: [], given: new Set() };
  const current = radio;
  const skip = trashedBy(source.account);
  const isNew = (track: Track) => !current.given.has(track.id) && !skip.has(track.id) && !current.queue.some((queued) => queued.id === track.id);
  for (let round = 0; current.queue.length < BATCH && round < 3; round++) {
    const seed = current.seed ?? (await source.seed());
    if (!seed) break;
    let fresh = (await source.mix(seed).catch(() => [])).filter(isNew);
    if (fresh.length === 0) {
      fresh = (await source.random()).filter(isNew);
      if (fresh.length === 0) current.given.clear();
    }
    current.queue.push(...fresh);
    current.seed = undefined;
  }
  const batch = current.queue.splice(0, BATCH);
  for (const track of batch) current.given.add(track.id);
  if (batch.length > 0) current.seed = batch[batch.length - 1].id;
  return batch;
}

/** Dislike: never on this account's radio again. */
export function trashRadioSong(account: string, trackID: string): void {
  const all = starry.storage.get<Record<string, string[]>>('fmTrash') ?? {};
  const kept = (all[account] ?? []).filter((id) => id !== trackID);
  all[account] = [...kept, trackID].slice(-TRASH_KEPT);
  starry.storage.set('fmTrash', all);
  if (radio) radio.queue = radio.queue.filter((track) => track.id !== trackID);
}

export function stopRadio(): void {
  radio = undefined;
}
