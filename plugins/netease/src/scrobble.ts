// Upload encrypted playback logs over plain HTTPS, not eapi. The user-info blob
// identifies the account; `_pld.time` determines whether a play counts.

import type { PlaybackReport } from '../../sdk/starry';
import { businessError, connection, currentSession, cookieHeader, SUCCESS_CODES } from './client';
import { EventLogFile, type LogEvent } from './eventlog';
import { Scrobble } from './endpoints';
import { playbackFacts } from './playback';
import { APP_VERSION, BUILD_VERSION, CHANNEL, USER_AGENT } from './profile';
import { algorithm } from './state';
import { concat, int, orderedJSON, str, uuid } from './util';

export interface PlayEvent {
  songID: string;
  /** Milliseconds since 1970. */
  startedAt: number;
  endedAt: number;
  /** `time` / `realtime`: seconds actually heard. */
  playedSeconds: number;
  /** `resource_time`: the song's length in seconds. */
  durationSeconds: number;
  end: 'playend' | 'ui' | 'exception' | 'interrupt';
  source: string;
  sourceID: string;
  sourceType: string;
  /** kbps, and the matching `bitrate_level` name (standard … jymaster). */
  bitrate: number;
  bitrateLevel: string;
  fee: number;
  rightSource: number;
  /** `file`: 4 online, 3 cloud drive, 1 local. */
  file: 4 | 3 | 1;
  mode: 'order' | 'circulation' | 'single' | 'random' | 'ai';
  isHeartMode: boolean;
  /** `vipType`: -1 none, 220 music package, 100 vinyl VIP, 300 vinyl VIP Plus. */
  vipType: '-1' | '220' | '100' | '300';
  /** Recommendation token, when the song came from one. */
  alg?: string;
  /** A podcast programme logs as `dj` instead of `song`. */
  isPodcast: boolean;
}

export function playEvent(fields: Partial<PlayEvent> & Pick<PlayEvent, 'songID' | 'startedAt' | 'endedAt' | 'playedSeconds' | 'durationSeconds'>): PlayEvent {
  return {
    end: 'playend',
    source: 'list',
    sourceID: '',
    sourceType: 'list',
    bitrate: 320,
    bitrateLevel: 'exhigh',
    fee: 0,
    rightSource: 0,
    file: 4,
    mode: 'order',
    isHeartMode: false,
    vipType: '-1',
    isPodcast: false,
    ...fields,
  };
}

function common(event: PlayEvent): [string, unknown][] {
  const fields: [string, unknown][] = [
    ['mode', event.mode],
    ['download', event.file === 1 ? 1 : 0],
  ];
  if (event.alg) fields.push(['alg', event.alg]);
  fields.push(['status', 'front'], ['id', event.songID]);
  return fields;
}

function tail(event: PlayEvent): [string, unknown][] {
  return [
    ['vipType', event.vipType],
    ['fee', event.fee],
    ['file', event.file],
    ['rightSource', event.rightSource],
    ['sourceId', event.sourceID],
    ['sourcetype', event.sourceType],
    ['channel', CHANNEL],
    ['curStartChannel', ''],
  ];
}

export function startEvent(event: PlayEvent): LogEvent {
  const fields: [string, unknown][] = [
    ...common(event),
    ['bitrate', event.bitrate],
    ['type', event.isPodcast ? 'dj' : 'song'],
    ['is_listentogether', 0],
    ['source', event.source],
    ['is_heart', event.isHeartMode ? 1 : 0],
    ['resource_ratio', ''],
    ['resource_time', event.durationSeconds],
    ['musiceffect_id', ''],
    ['app_mode', 2],
    ['bitrate_level', event.bitrateLevel],
    ...tail(event),
  ];
  return { action: '_plv', time: event.startedAt, data: orderedJSON(fields) };
}

export function endEvent(event: PlayEvent): LogEvent {
  const fields: [string, unknown][] = [
    ...common(event),
    ['time', event.playedSeconds],
    ['type', event.isPodcast ? 'dj' : 'song'],
    ['is_listentogether', 0],
    ['source', event.source],
    ['is_heart', event.isHeartMode ? 1 : 0],
    ['realtime', event.playedSeconds],
    ['resource_ratio', ''],
    ['resource_time', event.durationSeconds],
    ['musiceffect_id', ''],
    ['app_mode', 1],
    ['lyriceffect', '-1'],
    ['displayMode', ''],
    ['bitrate', event.bitrate],
    ['bitrate_level', event.bitrateLevel],
    ...tail(event),
    ['end', event.end],
  ];
  return { action: '_pld', time: event.endedAt, data: orderedJSON(fields) };
}

/** Log event sequence. It restarts per launch, which is fine because every upload carries a fresh random file UUID. */
let logSequence = 1;

function takeLogSequence(count: number): number {
  const first = logSequence;
  logSequence = (logSequence + count) >>> 0;
  return first;
}

export function logUserToken(): string {
  const cookies = currentSession().cookies;
  const fields: [string, unknown][] = [];
  if (cookies.MUSIC_U) fields.push(['MUSIC_U', cookies.MUSIC_U]);
  if (cookies.MUSIC_A) fields.push(['MUSIC_A', cookies.MUSIC_A]);
  fields.push(['appver', APP_VERSION], ['buildver', BUILD_VERSION]);
  return orderedJSON(fields);
}

export async function reportPlay(event: PlayEvent): Promise<any> {
  return uploadEventLogs([startEvent(event), endEvent(event)]);
}

export async function uploadEventLogs(events: LogEvent[]): Promise<any> {
  if (!events.length) throw starry.error('invalidResponse', '没有要上传的日志');
  const file = new EventLogFile(logUserToken(), takeLogSequence(events.length));
  for (const event of events) {
    if (!file.append(event)) throw starry.error('invalidResponse', '日志事件太大，放不进一块');
  }
  return uploadLogFiles([[EventLogFile.fileName(), file.encoded()]]);
}

export async function uploadLogFiles(files: [string, Uint8Array][]): Promise<any> {
  const boundary = `0xKhTmLbOuNdArY-${uuid()}`;
  const text = starry.encoding.utf8.encode;
  const parts: Uint8Array[] = [];
  for (const [name, data] of files) {
    parts.push(
      text(`--${boundary}\r\n`),
      text(`Content-Disposition: form-data; name="${Scrobble.logField}"; filename="${name}"\r\n`),
      text('Content-Type: application/octet-stream\r\n\r\n'),
      data,
      text('\r\n'),
    );
  }
  parts.push(text(`--${boundary}--\r\n`));
  const { headers, proxy } = connection();
  const answer = await starry.http.request({
    url: Scrobble.logUpload,
    method: 'POST',
    headers: {
      'Content-Type': `multipart/form-data; charset=utf-8; boundary=${boundary}`,
      'User-Agent': USER_AGENT,
      Cookie: cookieHeader(),
      ...headers,
    },
    body: concat(parts),
    timeout: 8,
    cookies: false,
    proxy,
  });
  let json: any;
  try {
    json = JSON.parse(answer.body);
  } catch {
    throw starry.error('invalidResponse', `听歌上报：HTTP ${answer.status}：${String(answer.body).slice(0, 120)}`);
  }
  const code = int(json?.code) ?? answer.status;
  if (!SUCCESS_CODES.has(code)) throw businessError(code, str(json?.message));
  return json;
}

export function logSource(context: PlaybackReport['context']): { source: string; id: string; type: string } {
  if (!context) return { source: 'list', id: '', type: 'list' };
  const id = context.id ?? '';
  switch (context.type) {
    case 'playlist':
    case 'queue':
    case 'history':
      return { source: 'list', id, type: 'list' };
    case 'liked':
      return { source: 'likeMusic', id, type: 'list' };
    case 'album':
      return { source: 'album', id, type: 'album' };
    case 'artist':
      return { source: 'artist', id, type: 'artist' };
    case 'user':
      return { source: 'user', id, type: 'user' };
    case 'radio':
      return { source: 'userfm', id: '', type: 'fmTrack' };
    case 'search':
      return { source: 'search', id, type: 'track' };
    case 'dailyRecommendation':
      return { source: 'dailySongRecommend', id, type: 'dailyRecommend' };
    case 'allMedia':
      return { source: 'cloud', id, type: 'cloudTrack' };
    case 'local':
      return { source: 'local', id, type: 'localTrack' };
    default:
      return { source: 'list', id, type: 'list' };
  }
}

/**
 * Uploads the `_plv` / `_pld` pair. The player only tells of a play once it is over, so
 * both events go into one file with the real start and end times.
 */
export async function reportPlayback(report: PlaybackReport): Promise<void> {
  const played = Math.round(report.playedSeconds);
  if (played <= 0) return;
  const origin = logSource(report.context);
  const facts = playbackFacts(report.trackID);
  const event = playEvent({
    songID: report.trackID,
    startedAt: report.startedAt,
    endedAt: report.endedAt,
    playedSeconds: played,
    durationSeconds: Math.round(report.duration),
    end: report.duration > 0 && report.playedSeconds >= report.duration - 1 ? 'playend' : 'ui',
    source: origin.source,
    sourceID: origin.id,
    sourceType: origin.type,
    bitrate: facts && facts.bitrate > 0 ? facts.bitrate : 320,
    bitrateLevel: facts?.level || 'exhigh',
    fee: facts?.fee ?? 0,
    rightSource: facts?.rightSource ?? 0,
    alg: algorithm(report.trackID),
  });
  try {
    await reportPlay(event);
  } catch (error) {
    console.info(`听歌上报失败：${(error as Error).message}`);
  }
}
