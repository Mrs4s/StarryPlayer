// Prefer reusable salted tokens; servers returning code 41 require hex-encoded passwords.
// There is no server session, so sign-out only forgets local credentials.

import { addressCandidates as candidates, compareVersions } from '../../common/server';
import type { Profile, ServerInfo } from '../../sdk/starry';
import { answer, codeOf, forget, keyFor, PROTOCOL, send, serverFrom, session, setSession, type Server } from './client';
import { clearAccountState } from './library';

/** What a server's web pages look like when pasted: Navidrome's `/app/#/…`, LMS's pages, Airsonic's `*.view`, the API's own `/rest`. */
const WEB_PATHS = [/\/rest(\/.*)?$/i, /\/app(\/.*)?$/i, /\/(releases|artists|tracks|tracklists|playqueue|settings|admin)(\/.*)?$/i, /\/[a-z]+\.view$/i, /\/index\.html$/i];

export const addressCandidates = (typed: string) => candidates(typed, WEB_PATHS);

const NAMES: Record<string, string> = {
  navidrome: 'Navidrome',
  gonic: 'gonic',
  lms: 'LMS',
  ampache: 'Ampache',
  'airsonic-advanced': 'Airsonic-Advanced',
  airsonic: 'Airsonic',
  'nextcloud music': 'Nextcloud Music',
  funkwhale: 'Funkwhale',
  supysonic: 'Supysonic',
  astiga: 'Astiga',
};

/** What the server is, as people know it (`Navidrome`); `Subsonic` for one that does not say. */
export const kindOf = (server: Pick<Server, 'type'>) => (server.type ? NAMES[server.type.toLowerCase()] ?? server.type : 'Subsonic');

/** `Navidrome · nas.local:4533`, for account lists: the protocol has no server names. */
export function serverName(server: Pick<Server, 'type' | 'address'>): string {
  return `${kindOf(server)} · ${server.address.replace(/^https?:\/\//i, '')}`;
}

/** The server `connect` reached, which the login that follows signs in to. */
type Pending = Omit<Server, 'user' | 'auth'>;

let pending: Pending | undefined;

/** The protocol version to send a server that speaks `version`: its own, at most this plugin's. */
export const negotiated = (version: unknown) => (typeof version === 'string' && /^\d+\.\d+/.test(version) && compareVersions(version, PROTOCOL) < 0 ? version : PROTOCOL);

/** The OpenSubsonic extensions, by name; none when the server has none or will not tell. */
async function extensionsOf(server: Pick<Server, 'address' | 'version'> & Partial<Server>): Promise<Record<string, number[]>> {
  try {
    const result = answer(await send(server, 'getOpenSubsonicExtensions', {}, { timeout: 8 }), 'getOpenSubsonicExtensions');
    const extensions: Record<string, number[]> = {};
    for (const extension of Array.isArray(result?.openSubsonicExtensions) ? result.openSubsonicExtensions : []) {
      if (typeof extension?.name === 'string') extensions[extension.name] = Array.isArray(extension.versions) ? extension.versions.filter((version: unknown) => typeof version === 'number') : [1];
    }
    return extensions;
  } catch {
    return {};
  }
}

/** A `subsonic-response` without credentials (an error that still says what the server is), or undefined when the address does not answer as one. */
async function probe(address: string): Promise<any> {
  const response = await send({ address, version: PROTOCOL }, 'ping', {}, { timeout: 8 });
  if (response.status >= 400) return undefined;
  try {
    const envelope = JSON.parse(response.body)?.['subsonic-response'];
    return envelope && typeof envelope.version === 'string' ? envelope : undefined;
  } catch {
    return undefined;
  }
}

export async function connect(typed: string): Promise<ServerInfo> {
  const addresses = addressCandidates(typed);
  if (addresses.length === 0) throw starry.error('connect', '请输入服务器地址');
  let unreachable: string | undefined;
  let refused: string | undefined;
  for (const address of addresses) {
    let envelope: any;
    try {
      envelope = await probe(address);
    } catch (error) {
      const code = codeOf(error);
      if (code === 'network' || code === 'timeout') unreachable ??= (error as Error).message;
      continue;
    }
    if (!envelope) {
      refused ??= `${address} 不是 Subsonic 服务器`;
      continue;
    }
    const version = negotiated(envelope.version);
    const type = typeof envelope.type === 'string' && envelope.type ? envelope.type : undefined;
    const serverVersion = typeof envelope.serverVersion === 'string' && envelope.serverVersion ? envelope.serverVersion : undefined;
    // Navidrome and LMS tell without credentials; gonic and Ampache only once signed in.
    const extensions = envelope.openSubsonic === true ? await extensionsOf({ address, version }) : {};
    pending = { key: keyFor(address), address, type, serverVersion, version, extensions };
    // The login window shows the address under the name: the kind of server is name enough.
    return { address, name: kindOf(pending), version: serverVersion ?? `API ${envelope.version}`, methods: ['password'] };
  }
  throw starry.error('connect', refused ?? `连不上 ${addresses[0]}${unreachable ? `：${unreachable}` : ''}`);
}

function requirePending(): Pending {
  if (!pending) throw starry.error('connect', '请先连接服务器');
  return pending;
}

/** Why the server said no (40), with what that kind of server wants instead. */
export function wrongPassword(type: string | undefined): string {
  const base = '用户名或密码不正确';
  switch (type?.toLowerCase()) {
    case 'lms':
      return `${base}。LMS 要用 API 密钥登录：在 LMS 网页的“设置 › Subsonic API”里生成密钥，把它填在密码框里`;
    case 'ampache':
      return `${base}。Ampache 要用单独设置的 Subsonic 密码，或者 API 密钥`;
    case 'nextcloud music':
      return `${base}。Nextcloud Music 要用在音乐应用设置里生成的密码`;
    case 'funkwhale':
      return `${base}。Funkwhale 要用在设置里单独设置的 Subsonic API 密码`;
    default:
      return base;
  }
}

export function signedInAs(account: Server): Profile {
  return { userID: `${account.key}:${account.user}`, nickname: account.user, detail: serverName(account) };
}

async function check(account: Server): Promise<{ code: number; message?: string; version?: string } | undefined> {
  const response = await send(account, 'ping', {}, { timeout: 15 });
  if (response.status >= 400) throw starry.error('server', `服务器返回 ${response.status}（ping）`);
  let envelope: any;
  try {
    envelope = JSON.parse(response.body)?.['subsonic-response'];
  } catch {
    throw starry.error('invalidResponse', '服务器的响应不是 JSON（ping）');
  }
  if (envelope?.status === 'ok') return undefined;
  return { code: Number(envelope?.error?.code), message: envelope?.error?.message, version: envelope?.version };
}

export async function loginWithPassword(username: string, password: string): Promise<Profile> {
  const server = requirePending();
  const user = username.trim();
  const salt = starry.encoding.hex.encode(starry.crypto.randomBytes(8));
  let account: Server = { ...server, user, auth: { token: starry.crypto.md5(password + salt, 'hex'), salt } };
  let refused = await check(account);
  // Too new a protocol for the server (30): what it speaks, then.
  if (refused?.code === 30 && refused.version && refused.version !== account.version) {
    account = { ...account, version: negotiated(refused.version) };
    refused = await check(account);
  }
  // No tokens here (41, or 42 from an OpenSubsonic server that dropped them): the password itself.
  if (refused?.code === 41 || refused?.code === 42) {
    account = { ...account, auth: { password } };
    refused = await check(account);
  }
  if (refused) {
    if (refused.code === 40) throw starry.error('loginFailed', wrongPassword(server.type));
    throw starry.error('loginFailed', refused.message ? `服务器：${refused.message}` : `服务器拒绝了登录（${refused.code}）`);
  }
  if (Object.keys(account.extensions).length === 0) account = { ...account, extensions: await extensionsOf(account) };
  clearAccountState();
  setSession(account);
  return signedInAs(account);
}

export function current(): Profile | null {
  const account = session();
  return account ? signedInAs(account) : null;
}

/** Checks the credentials, and reads the extensions again after the server was upgraded. */
export async function refresh(): Promise<Profile | null> {
  const account = session();
  if (!account) return null;
  const refused = await check(account);
  if (refused) {
    if ([40, 41, 42, 43, 44].includes(refused.code)) throw starry.error('loginExpired', '登录信息已失效，请重新登录');
    throw starry.error('server', refused.message ? `服务器：${refused.message}` : `服务器返回错误 ${refused.code}`);
  }
  const envelope = await probe(account.address).catch(() => undefined);
  const serverVersion = typeof envelope?.serverVersion === 'string' ? envelope.serverVersion : account.serverVersion;
  if (serverVersion === account.serverVersion) return signedInAs(account);
  const next: Server = { ...account, serverVersion, extensions: await extensionsOf(account) };
  if (session() !== account) return current();
  setSession(next);
  return signedInAs(next);
}

/** The server keeps no session: the credentials are forgotten here. */
export async function logout(): Promise<void> {
  const account = session();
  if (account) forget(account);
  signOutLocally();
}

export function signOutLocally(): void {
  setSession(null);
  clearAccountState();
}

export function exportCredentials(): Server | null {
  return session();
}

/**
 * Another kept account. A server out of reach does not stop the switch (the account shows as
 * kept, and its songs come once the server answers); only credentials the server refused do.
 */
export async function restoreCredentials(credentials: unknown): Promise<Profile> {
  const account = serverFrom(credentials);
  if (!account) throw starry.error('invalidCredentials', '保存的登录信息不完整，请重新登录');
  clearAccountState();
  setSession(account);
  try {
    return (await refresh()) ?? signedInAs(account);
  } catch (error) {
    if (codeOf(error) === 'loginExpired') throw error;
    return signedInAs(account);
  }
}
