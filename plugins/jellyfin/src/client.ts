// Jellyfin 12.x requires `Authorization: MediaBrowser …` for tokens.
// Retain server credentials so saved tracks remain playable after account switches.

import type { HttpResponse } from '../../sdk/starry';

/** A server signed in to: where it is and a token for it. */
export interface Server {
  serverId: string;
  serverName: string;
  address: string;
  userId: string;
  token: string;
}

export interface Session extends Server {
  userName: string;
  imageTag?: string;
}

const CLIENT = 'Starry Player';

export const loginRequired = () => starry.error('loginRequired', '请先登录 Jellyfin 服务器');
export const notFound = () => starry.error('notFound', '服务器上找不到它，可能已被移除');

const isNotFound = (error: unknown) => (error as { code?: string })?.code === 'notFound';

/** Made once per installation; every account shares it (a user signing in again on the same id revokes their old token). */
export function deviceId(): string {
  let id = starry.storage.get<string>('deviceId');
  if (!id) {
    id = starry.encoding.hex.encode(starry.crypto.randomBytes(16));
    starry.storage.set('deviceId', id);
  }
  return id;
}

/** `MediaBrowser Client="…", Device="…", DeviceId="…", Version="…"[, Token="…"]`; the server URL-decodes each value. */
export function authorization(token?: string): string {
  const fields: [string, string][] = [
    ['Client', CLIENT],
    ['Device', starry.app.deviceName || 'Mac'],
    ['DeviceId', deviceId()],
    ['Version', starry.app.version],
  ];
  if (token) fields.push(['Token', token]);
  return `MediaBrowser ${fields.map(([name, value]) => `${name}="${encodeURIComponent(value)}"`).join(', ')}`;
}

let current: Session | null | undefined;

export function session(): Session | null {
  if (current === undefined) current = sessionFrom(starry.storage.get('session'));
  return current;
}

export function requireSession(): Session {
  const signedIn = session();
  if (!signedIn) throw loginRequired();
  return signedIn;
}

/** Signs `next` in here (null: out), and remembers its server. */
export function setSession(next: Session | null): void {
  current = next;
  if (next) {
    starry.storage.set('session', next);
    remember(next);
  } else {
    starry.storage.remove('session');
  }
}

export function sessionFrom(value: any): Session | null {
  const text = (field: unknown) => (typeof field === 'string' && field ? field : undefined);
  const address = text(value?.address);
  const serverId = text(value?.serverId);
  const userId = text(value?.userId);
  const token = text(value?.token);
  if (!address || !serverId || !userId || !token) return null;
  return {
    serverId,
    serverName: text(value?.serverName) ?? address,
    address,
    userId,
    token,
    userName: text(value?.userName) ?? '',
    imageTag: text(value?.imageTag),
  };
}

export function knownServers(): Record<string, Server> {
  return starry.storage.get<Record<string, Server>>('servers') ?? {};
}

function remember(server: Server): void {
  const { serverId, serverName, address, userId, token } = server;
  starry.storage.set('servers', { ...knownServers(), [serverId]: { serverId, serverName, address, userId, token } });
}

/** After a real sign-out: the server's token is gone, so the server is forgotten unless another token stands for it. */
export function forget(server: Server): void {
  const servers = knownServers();
  if (servers[server.serverId]?.token !== server.token) return;
  delete servers[server.serverId];
  starry.storage.set('servers', servers);
}

/** Items found on a server other than the current one, by id: asked there first next time. */
const homes = new Map<string, string>();

/** Where to ask for `id`: the server it was found on, the current one, then the others. */
export function serversFor(id?: string): Server[] {
  const signedIn = session();
  const known = knownServers();
  const order: Server[] = [];
  const add = (server: Server | null | undefined) => {
    if (server && !order.some((other) => other.serverId === server.serverId)) order.push(server);
  };
  const home = id === undefined ? undefined : homes.get(id);
  if (home) add(home === signedIn?.serverId ? signedIn : known[home]);
  add(signedIn);
  for (const server of Object.values(known)) add(server);
  return order;
}

/** The server `id` lives on as far as known, without asking: for the lists under an item already opened. */
export function serverOf(id: string): Server {
  const server = serversFor(id)[0];
  if (!server) throw loginRequired();
  return server;
}

export function noteHome(id: string, server: Server): void {
  if (server.serverId === session()?.serverId) homes.delete(id);
  else homes.set(id, server.serverId);
}

// Forget expired credentials for other servers; only the current session's expiry
// should interrupt the listener.
export async function locate<T>(id: string, attempt: (server: Server) => Promise<T>): Promise<{ server: Server; value: T }> {
  const servers = serversFor(id);
  if (servers.length === 0) throw loginRequired();
  let failure: unknown;
  for (const server of servers) {
    try {
      const value = await attempt(server);
      noteHome(id, server);
      return { server, value };
    } catch (error) {
      const code = (error as { code?: string })?.code;
      if (code === 'loginExpired' && server.serverId !== session()?.serverId) {
        forget(server);
        continue;
      }
      if (!isNotFound(error) && failure === undefined) failure = error;
    }
  }
  throw failure ?? notFound();
}

export type Query = Record<string, string | number | boolean | undefined | null>;

export interface Call {
  method?: string;
  query?: Query;
  json?: unknown;
  /** Seconds; 15 when missing. */
  timeout?: number;
}

/** One request to `address`, signed with `token` when there is one. Statuses do not throw. */
export function send(address: string, path: string, token: string | undefined, call: Call = {}): Promise<HttpResponse<string>> {
  return starry.http.request<string>({
    url: address + path,
    method: call.method ?? (call.json === undefined ? 'GET' : 'POST'),
    query: call.query,
    json: call.json,
    timeout: call.timeout,
    headers: { Authorization: authorization(token), Accept: 'application/json' },
    cookies: false,
  });
}

export function answer<T>(response: HttpResponse<string>, path: string): T {
  const { status } = response;
  if (status === 401) throw starry.error('loginExpired', '登录已过期');
  if (status === 404) throw notFound();
  if (status === 403) throw starry.error('forbidden', '这个账号没有权限');
  if (status >= 400) throw starry.error('server', `服务器返回 ${status}（${path.split('?')[0]}）`);
  const body = response.body?.trim();
  if (!body) return undefined as T;
  try {
    return JSON.parse(body) as T;
  } catch {
    throw starry.error('invalidResponse', `服务器的响应不是 JSON（${path.split('?')[0]}）`);
  }
}

/** A call on `server` as its user. */
export async function api<T = any>(server: Server, path: string, call: Call = {}): Promise<T> {
  return answer<T>(await send(server.address, path, server.token, call), path);
}

/** A call on the current account's server. */
export function call<T = any>(path: string, options: Call = {}): Promise<T> {
  return api<T>(requireSession(), path, options);
}
