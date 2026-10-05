import { anonymousUsername, cacheKey, eapiDecryptResponse, eapiParams } from './crypto';
import { API_DOMAIN, baseCookies, eapiPayload, stringify, USER_AGENT } from './profile';
import { formEncode, int, orderedJSON, percentEncode, randomInt, sleep, sortedJSON, str, uuid } from './util';

export interface Endpoint {
  path: string;
  host?: string;
  /** Fetch a Yidun token; sent as the `checkToken` param and `X-antiCheatToken`. */
  checkToken: boolean;
  /** Seconds an answer is kept in memory; null: never. */
  cache: number | null;
  /** Whether an anonymous session must exist before the call. */
  requiresSession: boolean;
  /** eapi `e_r`: the server AES-encrypts the answer. */
  encryptResponse: boolean;
  /** `nginxCache` factories (playlist v4, album v3, artist v3 detail): `e_r = false` plus a `cache_key` param also appended to the URL. */
  nginxCache: boolean;
}

export function ep(path: string, options: Partial<Omit<Endpoint, 'path'>> = {}): Endpoint {
  return {
    path,
    host: options.host,
    checkToken: options.checkToken ?? false,
    cache: options.cache === undefined ? 120 : options.cache,
    requiresSession: options.requiresSession ?? true,
    encryptResponse: options.encryptResponse ?? true,
    nginxCache: options.nginxCache ?? false,
  };
}

const encryptsResponse = (endpoint: Endpoint) => endpoint.encryptResponse && !endpoint.nginxCache;

const REGISTER_ANONYMOUS = '/api/register/anonimous';
const BATCH = ep('/api/batch', { cache: null });

export type NeteaseError = Error & { code: string; neteaseCode?: number };

export const SUCCESS_CODES = new Set([200, 201, 302, 400, 502, 800, 801, 802, 803]);

export function businessError(code: number, message?: string): NeteaseError {
  const error = starry.error('api', `网易云返回 ${code}${message ? `：${message}` : ''}`) as NeteaseError;
  error.neteaseCode = code;
  return error;
}

export const loginRequired = () => starry.error('loginRequired', '需要登录');

const invalidResponse = (message: string) => starry.error('invalidResponse', `网易云的响应解析失败：${message}`);

const isTransportError = (error: unknown) => ['network', 'timeout'].includes((error as { code?: string })?.code ?? '');

/** Cookie / device identity for the account; other stored fields are dropped when read. */
export interface Session {
  cookies: Record<string, string>;
  nmtid?: string;
  deviceUUID: string;
  /** The `deviceId` value: `deviceUUID|<random UUID>`, kept percent-encoded (`%7C`). */
  deviceID: string;
}

export const ACCOUNT_COOKIE_NAMES = ['MUSIC_U', '__csrf', 'MUSIC_A', 'MUSIC_SNS', '__remember_me', 'MUSIC_R_T', 'MUSIC_A_T', 'MUSIC_R_U'];
/** Cookies the request profile owns; stored copies (from a pasted browser cookie, say) never win. */
const PROFILE_COOKIE_NAMES = new Set(['os', 'deviceId', 'osver', 'appver', 'clientSign', 'channel', 'mode']);

const SESSION_KEY = 'session';
let session: Session | undefined;

const makeDeviceID = (deviceUUID: string) => `${deviceUUID.toUpperCase()}%7C${uuid()}`;

export function sessionFrom(stored: any): Session {
  const text = (value: unknown) => (typeof value === 'string' && value ? value : undefined);
  const cookies: Record<string, string> = {};
  for (const [name, value] of Object.entries(stored?.cookies ?? {})) if (typeof value === 'string') cookies[name] = value;
  const deviceUUID = text(stored?.deviceUUID) ?? uuid();
  return {
    cookies,
    nmtid: text(stored?.nmtid),
    deviceUUID,
    deviceID: text(stored?.deviceID) ?? makeDeviceID(deviceUUID),
  };
}

export function currentSession(): Session {
  if (!session) {
    session = sessionFrom(starry.storage.get(SESSION_KEY));
    // Kept right away so an identity made up here stays the same.
    starry.storage.set(SESSION_KEY, session);
  }
  return session;
}

export function updateSession(transform: (session: Session) => void): void {
  const current = currentSession();
  transform(current);
  starry.storage.set(SESSION_KEY, current);
}

export const isLoggedIn = () => !!currentSession().cookies.MUSIC_U;
export const hasAnySession = () => isLoggedIn() || !!currentSession().cookies.MUSIC_A;

export function setCookies(cookies: Record<string, string>): void {
  updateSession((s) => Object.assign(s.cookies, cookies));
}

/** Drops the account's cookies; the device identity stays, so the anonymous session can be made again. */
export function clearAccount(): void {
  updateSession((s) => {
    for (const name of ACCOUNT_COOKIE_NAMES) delete s.cookies[name];
  });
  cache.clear();
}

export function clearCache(): void {
  cache.clear();
}

/** A pasted cookie string, which must hold `MUSIC_U`. */
export function parseCookieString(text: string): Record<string, string> | undefined {
  const cookies: Record<string, string> = {};
  for (const pair of text.split(';')) {
    const equals = pair.indexOf('=');
    if (equals < 0) continue;
    const name = pair.slice(0, equals).trim();
    const value = pair.slice(equals + 1).trim();
    if (name) cookies[name] = value;
  }
  return cookies.MUSIC_U ? cookies : undefined;
}

const REAL_IP_PREFIXES = ['116.25', '121.8', '120.36', '39.144', '117.136', '223.104', '171.8', '182.140'];
const TIMEOUT = 8;
const RETRIES = 3;
let realIP: string | undefined;

function currentRealIP(): string | undefined {
  if (starry.settings.realIP !== true) {
    realIP = undefined;
  } else if (!realIP) {
    realIP = `${REAL_IP_PREFIXES[randomInt(REAL_IP_PREFIXES.length)]}.${randomInt(256)}.${1 + randomInt(254)}`;
  }
  return realIP;
}

/** The proxy setting: `http://host:port` or `socks5://host:port`; anything else connects directly. */
function currentProxy(): string | undefined {
  const text = typeof starry.settings.proxy === 'string' ? starry.settings.proxy.trim() : '';
  return /^(https?|socks5):\/\/(\[[0-9a-f:.]+\]|[^\s/:@]+):\d+\/?$/i.test(text) ? text : undefined;
}

export function connection(realIP = true): { headers: Record<string, string>; proxy?: string } {
  const ip = realIP ? currentRealIP() : undefined;
  return { headers: ip ? { 'X-Real-IP': ip, 'X-Forwarded-For': ip } : {}, proxy: currentProxy() };
}

// Send cookie values raw, not percent-encoded; omit `MUSIC_A` when `MUSIC_U` exists.
export function profileCookies(): [string, string][] {
  const s = currentSession();
  const stored: Record<string, string> = {};
  for (const [name, value] of Object.entries(s.cookies)) if (!PROFILE_COOKIE_NAMES.has(name)) stored[name] = value;
  if (!stored.NMTID && s.nmtid) stored.NMTID = s.nmtid;
  if (stored.MUSIC_U) delete stored.MUSIC_A;
  const pairs = [...baseCookies(s), ...Object.keys(stored).sort().map((name): [string, string] => [name, stored[name]])];
  return pairs.filter(([, value]) => value && !value.includes(';') && !value.includes('\n'));
}

export const cookieHeader = () => profileCookies().map(([name, value]) => `${name}=${value}`).join('; ');

export interface Response {
  json: any;
  code: number;
  status: number;
  /** What `Set-Cookie` set (cookies it removed are not here). */
  cookies: Record<string, string>;
}

const cache = new Map<string, { expires: number; response: Response }>();

export async function request(endpoint: Endpoint, body: Record<string, unknown> = {}): Promise<any> {
  return (await send(endpoint, body)).json;
}

export async function send(endpoint: Endpoint, body: Record<string, unknown> = {}, realIP = true): Promise<Response> {
  if (endpoint.requiresSession && !hasAnySession()) {
    // Registration is rate-limited per IP and most catalogue calls work without MUSIC_A, so a
    // failed one is tried again later rather than failing this call.
    try {
      await ensureAnonymousSession();
    } catch (error) {
      console.debug(`匿名登录推迟：${(error as Error).message}`);
    }
  }
  const key = endpoint.cache !== null ? `${endpoint.path} ${sortedJSON(body)}` : undefined;
  const hit = key ? cache.get(key) : undefined;
  if (hit && hit.expires > Date.now()) return hit.response;

  const token = endpoint.checkToken ? await fetchCheckToken().catch(() => undefined) : undefined;
  const options = build(endpoint, body, token, realIP);
  let last: unknown;
  for (let attempt = 1; attempt <= RETRIES; attempt++) {
    let answer;
    try {
      answer = await starry.http.request<Uint8Array>(options);
    } catch (error) {
      if (!isTransportError(error)) throw error;
      last = error;
      if (attempt < RETRIES) await sleep(200 * attempt);
      continue;
    }
    const response = decode(answer.body, answer.status, answer.cookies, endpoint);
    if (key && endpoint.cache !== null) {
      // Lookups only skip expired answers, so expired entries are pruned here.
      const now = Date.now();
      for (const [k, entry] of cache) if (entry.expires <= now) cache.delete(k);
      cache.set(key, { expires: now + endpoint.cache * 1000, response });
    }
    return response;
  }
  throw last;
}

export async function batch(calls: [string, Record<string, unknown>][], cacheSeconds: number | null = null): Promise<Record<string, any>> {
  const body: Record<string, unknown> = {};
  for (const [path, params] of calls) {
    body[path] = orderedJSON(Object.keys(params).sort().map((name): [string, unknown] => [name, stringify(params[name])]));
  }
  const json = await request({ ...BATCH, cache: cacheSeconds }, body);
  const answers: Record<string, any> = {};
  for (const [path] of calls) if (json[path] !== undefined && json[path] !== null) answers[path] = json[path];
  return answers;
}

function build(endpoint: Endpoint, body: Record<string, unknown>, token: string | undefined, realIP: boolean) {
  const params = Object.keys(body)
    .sort()
    .map((name): [string, string] => [name, stringify(body[name])]);
  const extraHeader: [string, string][] = [];
  if (token) {
    params.push(['checkToken', token]);
    extraHeader.push(['X-antiCheatToken', token]);
  }
  let query = '';
  if (endpoint.nginxCache) {
    const source = [...params, ['e_r', 'false'] as [string, string]]
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([name, value]) => `${percentEncode(name)}=${percentEncode(value)}`)
      .join('&');
    const key = cacheKey(source);
    params.push(['cache_key', key]);
    query = `?cache_key=${percentEncode(key)}`;
  }
  const json = eapiPayload(params, encryptsResponse(endpoint), currentSession(), extraHeader);
  const { headers: connectionHeaders, proxy } = connection(realIP);
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': USER_AGENT,
    Cookie: cookieHeader(),
  };
  if (token) headers['X-antiCheatToken'] = token;
  Object.assign(headers, connectionHeaders);
  return {
    url: `${endpoint.host ?? API_DOMAIN}/eapi/${endpoint.path.slice('/api/'.length)}${query}`,
    method: 'POST',
    headers,
    body: formEncode([['params', eapiParams(endpoint.path, json)]]),
    timeout: TIMEOUT,
    responseType: 'bytes' as const,
    cookies: false,
    proxy,
  };
}

function decode(data: Uint8Array, status: number, setCookies: Record<string, string>, endpoint: Endpoint): Response {
  const payload = encryptsResponse(endpoint) ? eapiDecryptResponse(data) : data;
  let json: any;
  const text = starry.encoding.utf8.decode(payload);
  try {
    json = JSON.parse(text);
  } catch {
    throw invalidResponse(`HTTP ${status}：${text.slice(0, 120)}`);
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) throw invalidResponse('不是一个对象');
  const code = int(json.code) ?? status;

  // A cookie the answer removes (expired, emptied) comes as "".
  const set: Record<string, string> = {};
  const removed: string[] = [];
  for (const [name, value] of Object.entries(setCookies ?? {})) {
    if (!name) continue;
    if (value) set[name] = value;
    else removed.push(name);
  }
  if (Object.keys(set).length || removed.length) {
    updateSession((s) => {
      for (const name of removed) delete s.cookies[name];
      for (const [name, value] of Object.entries(set)) if (!PROFILE_COOKIE_NAMES.has(name)) s.cookies[name] = value;
      if (set.NMTID) s.nmtid = set.NMTID;
    });
  }

  if (!SUCCESS_CODES.has(code)) {
    if (code === 301) throw loginRequired();
    throw businessError(code, str(json.msg) ?? str(json.message));
  }
  return { json, code, status, cookies: set };
}

let bootstrap: Promise<void> | undefined;
let lastBootstrapFailure = 0;
const BOOTSTRAP_RETRY_INTERVAL = 60_000;

export async function ensureAnonymousSession(): Promise<void> {
  if (hasAnySession()) return;
  if (lastBootstrapFailure && Date.now() - lastBootstrapFailure < BOOTSTRAP_RETRY_INTERVAL) {
    throw starry.error('network', '匿名登录太频繁，稍后再试');
  }
  if (!bootstrap) {
    bootstrap = registerAnonymous().then(
      () => {
        lastBootstrapFailure = 0;
        bootstrap = undefined;
      },
      (error) => {
        lastBootstrapFailure = Date.now();
        bootstrap = undefined;
        throw error;
      },
    );
  }
  return bootstrap;
}

// Anonymous registration may reject the overseas header with code 400; retry without it.
async function registerAnonymous(): Promise<void> {
  const failures: string[] = [];
  const attempts = connection().headers['X-Real-IP'] ? [true, false] : [true];
  for (const realIP of attempts) {
    const endpoint = ep(REGISTER_ANONYMOUS, { cache: null, requiresSession: false });
    try {
      const response = await send(endpoint, { username: anonymousUsername(currentSession().deviceID) }, realIP);
      const token = str(response.json.token) || response.cookies.MUSIC_A || currentSession().cookies.MUSIC_A;
      if (response.code === 200 && token) {
        updateSession((session) => {
          session.cookies.MUSIC_A = token;
        });
        return;
      }
      failures.push(`${realIP ? '' : '不带伪造 IP '}code ${response.code}, cookies ${Object.keys(response.cookies).sort().join(',')}`);
    } catch (error) {
      failures.push(`${realIP ? '' : '不带伪造 IP：'}${(error as Error).message}`);
    }
  }
  throw invalidResponse(`匿名登录失败（${failures.join('；')}）`);
}

async function fetchCheckToken(): Promise<string | undefined> {
  const answer = await starry.http.request({ url: 'https://ac.dun.163yun.com/v3/b?pn=YD00000558929251', timeout: TIMEOUT, proxy: connection().proxy });
  const text = String(answer.body);
  const open = text.indexOf('[');
  const close = text.lastIndexOf(']');
  if (open < 0 || close < open) return undefined;
  try {
    const array = JSON.parse(text.slice(open, close + 1));
    return Array.isArray(array) && array[0] === 200 && typeof array[2] === 'string' && array[2] ? array[2] : undefined;
  } catch {
    return undefined;
  }
}
