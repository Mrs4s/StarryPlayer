// Song search requires signed `musics.fcg` requests; unsigned calls return 2001.
// Other lyric calls use `musicu.fcg`; retain session uid/sid for one hour.

import { apiError, int, randomInt, sleep, str } from './util';
import { teaEncrypt } from './tea';

export const PROFILE = {
  ct: 6,
  /** Version 11.10.0 as `major·10000 + minor·100 + patch`. */
  cv: '111000',
  tmeAppID: 'qqmusic',
  host: 'u6.y.qq.com',
  userAgent: 'QQMusic/73282 CFNetwork/3860.100.1 Darwin/25.0.0',
  referer: 'http://y.qq.com',
};

export interface Request {
  module: string;
  method: string;
  param: Record<string, unknown>;
}

export const cgi = (module: string, method: string, param: Record<string, unknown> = {}): Request => ({ module, method, param });
const cgiName = (request: Request) => `${request.module}.${request.method}`;

const DEVICE_KEY = 'openUDID';
let openUDID: string | undefined;

/** A device identifier of 40 hexadecimal digits, generated once and persisted across launches. */
function guid(): string {
  if (!openUDID) {
    const stored = starry.storage.get<string>(DEVICE_KEY);
    if (typeof stored === 'string' && /^[0-9a-f]{40}$/.test(stored)) {
      openUDID = stored;
    } else {
      openUDID = '';
      for (let i = 0; i < 40; i++) openUDID += randomInt(16).toString(16);
      starry.storage.set(DEVICE_KEY, openUDID);
    }
  }
  return openUDID;
}

interface ServerSession {
  uid: string;
  sid: string;
}

let serverSession: { value: ServerSession; expires: number } | undefined;
let serverSessionTask: Promise<ServerSession | undefined> | undefined;

/** The session the comm carries, asked for once an hour; undefined while the server gives none. */
async function currentServerSession(): Promise<ServerSession | undefined> {
  if (serverSession && serverSession.expires > Date.now()) return serverSession.value;
  if (serverSessionTask) return serverSessionTask;
  serverSessionTask = (async () => {
    try {
      const request = cgi('music.getSession.session', 'GetSession', { uid: '', vkey: 0, caller: 0 });
      const json = await post({ comm: comm(undefined), req: request }, false, '');
      const info = data(json.req, cgiName(request)).session;
      const uid = str(info?.uid);
      const sid = str(info?.sid);
      if (uid === undefined || sid === undefined) return undefined;
      const value = { uid, sid };
      serverSession = { value, expires: Date.now() + 3600 * 1000 };
      return value;
    } catch {
      return undefined;
    } finally {
      serverSessionTask = undefined;
    }
  })();
  return serverSessionTask;
}

/** A CGI answer's `data`, or an error when its code is not 0. */
function data(answer: any, name: string): any {
  const code = int(answer?.code) ?? 0;
  if (code !== 0) throw apiError(code, name);
  return answer?.data ?? {};
}

export async function call(request: Request, options: { signed?: boolean } = {}): Promise<any> {
  const server = await currentServerSession();
  const json = await post({ comm: comm(server), req: request }, options.signed ?? false, server?.uid ?? '');
  const code = int(json.code) ?? 0;
  if (code !== 0) throw apiError(code, cgiName(request));
  if (!json.req) throw starry.error('invalidResponse', `${cgiName(request)} 没有返回`);
  return data(json.req, cgiName(request));
}

function comm(server: ServerSession | undefined): Record<string, string> {
  return {
    ct: String(PROFILE.ct),
    cv: PROFILE.cv,
    uid: server?.uid ?? '',
    sid: server?.sid ?? '',
    OpenUDID: guid(),
    gray: '1',
    patch: '1',
    nettype: '2',
    qq: '0',
    tmeAppID: PROFILE.tmeAppID,
    authst: '',
  };
}

const RETRIES = 2;

/** Network failures are tried again twice, after 0.3 and 0.6 s. */
async function post(body: Record<string, unknown>, signed: boolean, uid: string): Promise<any> {
  const text = JSON.stringify(body);
  const path = signed ? 'musics.fcg' : 'musicu.fcg';
  const headers: Record<string, string> = { 'Content-Type': 'application/json', Referer: PROFILE.referer, 'User-Agent': PROFILE.userAgent };
  if (signed) Object.assign(headers, sign(text, '', uid));
  let last: unknown;
  for (let attempt = 1; attempt <= RETRIES + 1; attempt++) {
    let response;
    try {
      response = await starry.http.post(`https://${PROFILE.host}/cgi-bin/${path}`, text, { headers, cookies: false, timeout: 10 });
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (code !== 'network' && code !== 'timeout') throw error;
      last = error;
      if (attempt <= RETRIES) await sleep(300 * attempt);
      continue;
    }
    if (response.status !== 200) throw starry.error('network', `QQ音乐返回 HTTP ${response.status}`);
    try {
      return JSON.parse(response.body);
    } catch {
      throw starry.error('invalidResponse', `响应解析失败：${String(response.body).slice(0, 120)}`);
    }
  }
  throw last;
}

const HMAC_KEY = '9FF169D646A3';

// Sign = base64(nonce12 + HMAC-SHA1(key, reverse(base64(body)))).
// Mask uses QQTEA with Sign's first and last eight characters as the key.
// Signed-out requests leave uin empty.
export function sign(body: string, uin: string, uid: string, now = Date.now()): { Sign: string; Mask: string } {
  const reversed = starry.encoding.base64.encode(body).split('').reverse().join('');
  const digest = starry.crypto.hmac('sha1', HMAC_KEY, reversed) as Uint8Array;
  const nonce = starry.crypto.randomBytes(12).map((byte) => 65 + (byte % 26));
  const signature = new Uint8Array(32);
  signature.set(nonce, 0);
  signature.set(digest, 12);
  const Sign = starry.encoding.base64.encode(signature);
  const header = `${PROFILE.ct}&${PROFILE.cv}&&${uin}&${Math.floor(now / 1000)}&${uid}&`;
  const signBytes = starry.encoding.utf8.encode(Sign);
  const key = new Uint8Array(16);
  key.set(signBytes.subarray(0, 8), 0);
  key.set(signBytes.subarray(signBytes.length - 8), 8);
  const Mask = starry.encoding.base64.encode(teaEncrypt(starry.encoding.utf8.encode(header), key));
  return { Sign, Mask };
}
