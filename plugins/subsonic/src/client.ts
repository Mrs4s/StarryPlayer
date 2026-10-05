// Subsonic can return API errors with HTTP 200.
// Namespace IDs by server and retain credentials so saved tracks survive account switches.

import type { HttpResponse } from '../../sdk/starry';

/** A server signed in to, as one of its users (also the account signed in, and what `exportCredentials` hands out). */
export interface Server {
  /** The plugin's name for the server, the prefix of its ids. */
  key: string;
  address: string;
  /** What the server calls itself: navidrome, gonic, lms, ampache, Airsonic-Advanced…; none for Subsonic and Airsonic. */
  type?: string;
  serverVersion?: string;
  /** The protocol version sent as `v`: the server's own, at most 1.16.1 (Airsonic-Advanced refuses higher). */
  version: string;
  extensions: Record<string, number[]>;
  user: string;
  /**
   * One token for good (`t` = md5(password + salt) with a salt kept, so cover addresses stay the
   * same), or the password itself for a server that cannot check tokens (`p=enc:`).
   */
  auth: { token: string; salt: string } | { password: string };
}

export const CLIENT = 'Starry Player';
export const PROTOCOL = '1.16.1';

export const loginRequired = () => starry.error('loginRequired', '请先登录 Subsonic 服务器');
export const notFound = () => starry.error('notFound', '服务器上找不到它，可能已被移除');

export const codeOf = (error: unknown) => (error as { code?: string })?.code;

export function failure(code: unknown, message: unknown, method: string): Error {
  const text = typeof message === 'string' && message.trim() ? message.trim() : undefined;
  switch (Number(code)) {
    case 40:
    case 41:
    case 42:
    case 43:
    case 44:
      return starry.error('loginExpired', '登录信息已失效，请重新登录');
    case 50:
      return starry.error('forbidden', '这个账号没有权限');
    case 70:
      return notFound();
    default:
      return starry.error('server', text ? `服务器：${text}` : `服务器返回错误 ${code}（${method}）`);
  }
}

let current: Server | null | undefined;

export function session(): Server | null {
  if (current === undefined) current = serverFrom(starry.storage.get('session'));
  return current;
}

export function requireSession(): Server {
  const signedIn = session();
  if (!signedIn) throw loginRequired();
  return signedIn;
}

/** Signs `next` in here (null: out), and remembers its server. */
export function setSession(next: Server | null): void {
  current = next;
  if (next) {
    starry.storage.set('session', next);
    remember(next);
  } else {
    starry.storage.remove('session');
  }
}

/** A kept or handed-back server, when it has what a request needs. */
export function serverFrom(value: any): Server | null {
  const text = (field: unknown) => (typeof field === 'string' && field ? field : undefined);
  const key = text(value?.key);
  const address = text(value?.address);
  const user = text(value?.user);
  const auth = value?.auth;
  const token = text(auth?.token);
  const salt = text(auth?.salt);
  const password = typeof auth?.password === 'string' ? auth.password : undefined;
  if (!key || !address || !user || (!(token && salt) && password === undefined)) return null;
  const extensions: Record<string, number[]> = {};
  for (const [name, versions] of Object.entries(value?.extensions ?? {})) {
    if (Array.isArray(versions)) extensions[name] = versions.filter((version) => typeof version === 'number');
  }
  return {
    key,
    address,
    type: text(value?.type),
    serverVersion: text(value?.serverVersion),
    version: text(value?.version) ?? PROTOCOL,
    extensions,
    user,
    auth: token && salt ? { token, salt } : { password: password! },
  };
}

export function knownServers(): Record<string, Server> {
  return starry.storage.get<Record<string, Server>>('servers') ?? {};
}

function remember(server: Server): void {
  starry.storage.set('servers', { ...knownServers(), [server.key]: server });
}

/** After a real sign-out: the server is forgotten, unless another account's credentials stand for it now. */
export function forget(server: Server): void {
  const servers = knownServers();
  const kept = servers[server.key];
  if (!kept || kept.user !== server.user) return;
  delete servers[server.key];
  starry.storage.set('servers', servers);
}

/** The key of the server at `address` this computer knows, or a new one. */
export function keyFor(address: string): string {
  const known = Object.values(knownServers()).find((server) => server.address === address);
  if (known) return known.key;
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return [...starry.crypto.randomBytes(6)].map((byte) => alphabet[byte % alphabet.length]).join('');
}

/** The plugin's id of a server's item; empty when the server gave none (Airsonic's song artists). */
export function ref(server: Server, id: unknown): string {
  if (typeof id === 'number' && Number.isFinite(id)) return `${server.key}/${id}`;
  return typeof id === 'string' && id ? `${server.key}/${id}` : '';
}

/** The server an id of the plugin's is on, and the server's own id. */
export function locate(id: string): { server: Server; id: string } {
  const slash = id.indexOf('/');
  if (slash <= 0 || slash === id.length - 1) throw notFound();
  const key = id.slice(0, slash);
  const signedIn = session();
  const server = signedIn?.key === key ? signedIn : knownServers()[key];
  if (!server) throw signedIn ? starry.error('notFound', '这首歌所在的服务器已不在账号里') : loginRequired();
  return { server, id: id.slice(slash + 1) };
}

/** The server's own id of one of the plugin's ids on `server`, or undefined when it is from elsewhere. */
export function rawOn(server: Server, id: string): string | undefined {
  return id.startsWith(`${server.key}/`) ? id.slice(server.key.length + 1) : undefined;
}

export type Params = Record<string, string | number | boolean | undefined | null | (string | number)[]>;

export function credentials(server: Pick<Server, 'user' | 'auth'>): [string, string][] {
  if ('token' in server.auth) return [['u', server.user], ['t', server.auth.token], ['s', server.auth.salt]];
  return [['u', server.user], ['p', `enc:${starry.encoding.hex.encode(server.auth.password)}`]];
}

/**
 * `v`, `c`, the credentials (when signed in), `f=json` (for calls), then `params` (a list repeats
 * the name), percent-encoded (a space as `%20`, which every server reads, not `+`).
 */
export function query(server: Pick<Server, 'version'> & Partial<Pick<Server, 'user' | 'auth'>>, params: Params = {}, json = true): string {
  const pairs: [string, string][] = [['v', server.version], ['c', CLIENT]];
  if (server.user && server.auth) pairs.push(...credentials(server as Server));
  if (json) pairs.push(['f', 'json']);
  for (const [name, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    for (const item of Array.isArray(value) ? value : [value]) pairs.push([name, String(item)]);
  }
  return pairs.map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`).join('&');
}

export function restURL(server: Server, method: string, params: Params = {}): string {
  return `${server.address}/rest/${method}?${query(server, params, false)}`;
}

export function answer<T = any>(response: HttpResponse<string>, method: string): T {
  const { status } = response;
  if (status === 404 || status === 405 || status === 501) throw starry.error('notSupported', `服务器不支持 ${method}`);
  if (status === 401) throw starry.error('loginExpired', '登录信息已失效，请重新登录');
  if (status === 403) throw starry.error('forbidden', '这个账号没有权限');
  if (status >= 400) throw starry.error('server', `服务器返回 ${status}（${method}）`);
  let body: any;
  try {
    body = JSON.parse(response.body);
  } catch {
    throw starry.error('invalidResponse', `服务器的响应不是 JSON（${method}）`);
  }
  const envelope = body?.['subsonic-response'];
  if (!envelope || typeof envelope !== 'object') throw starry.error('invalidResponse', `这不是 Subsonic 服务器的响应（${method}）`);
  if (envelope.status !== 'ok') throw failure(envelope.error?.code, envelope.error?.message, method);
  return envelope as T;
}

export interface CallOptions {
  /** A form POST, for long lists, where the server takes them (`formPost`); a GET elsewhere. */
  post?: boolean;
  /** Seconds; 15 when missing. */
  timeout?: number;
}

/** One request to `server`. Statuses do not throw. */
export function send(server: Pick<Server, 'address' | 'version'> & Partial<Server>, method: string, params: Params = {}, options: CallOptions = {}): Promise<HttpResponse<string>> {
  const url = `${server.address}/rest/${method}`;
  const all = query(server, params);
  if (options.post && server.extensions?.formPost) {
    return starry.http.request<string>({ url, method: 'POST', body: all, headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: options.timeout, cookies: false, responseType: 'text' });
  }
  return starry.http.request<string>({ url: `${url}?${all}`, timeout: options.timeout, cookies: false, responseType: 'text' });
}

/** A call on `server` as its user. */
export async function call<T = any>(server: Server, method: string, params: Params = {}, options: CallOptions = {}): Promise<T> {
  return answer<T>(await send(server, method, params, options), method);
}

export const list = (value: unknown): any[] => (Array.isArray(value) ? value : []);
