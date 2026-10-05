// Signing in: the server first (`connect`), then a user name and
// password (which may be empty) or Quick Connect, a code entered in a client already signed in. One
// account is one user on one server; several servers are several accounts (`detail` names the
// server). Restoring an account never signs in again: that would revoke the token kept for it.

import * as common from '../../common/server';
import type { Profile, ServerInfo } from '../../sdk/starry';
import { answer, api, forget, send, session, sessionFrom, setSession, type Session } from './client';
import { clearAccountState } from './library';

/** The oldest server with the lyrics and favourites APIs this plugin uses. */
const MINIMUM_VERSION = [10, 9];

/** The server `connect` reached, which the login calls that follow sign in to. */
interface Pending {
  address: string;
  serverId: string;
  serverName: string;
}

let pending: Pending | undefined;

/** Where to look for the server the user typed; a web client page pasted (`…/web/#/home.html`) is cut back to the server. */
export const addressCandidates = (typed: string) => common.addressCandidates(typed, [/\/web(\/.*)?$/i]);

/** `12.1.0` is at least `minimum`. */
export const isAtLeast = (version: unknown, minimum = MINIMUM_VERSION) => common.isAtLeast(version, minimum);

/** Why `/System/Info/Public` does not make a server this plugin can use; undefined when it does. */
export function refusal(info: any, address: string): string | undefined {
  if (!info || typeof info.Id !== 'string' || !info.Id) return `${address} 不是 Jellyfin 服务器`;
  if (typeof info.ProductName === 'string' && /emby/i.test(info.ProductName)) return '这是 Emby 服务器，目前只支持 Jellyfin';
  if (!isAtLeast(info.Version)) return `服务器版本 ${info.Version} 太旧，需要 Jellyfin 10.9 或更新的版本`;
  if (info.StartupWizardCompleted === false) return '服务器还没有完成初始设置，请先在网页上完成';
  return undefined;
}

export async function connect(typed: string): Promise<ServerInfo> {
  const candidates = addressCandidates(typed);
  if (candidates.length === 0) throw starry.error('connect', '请输入服务器地址');
  let unreachable: string | undefined;
  let refused: string | undefined;
  for (const address of candidates) {
    let info: any;
    try {
      info = answer(await send(address, '/System/Info/Public', undefined, { timeout: 8 }), '/System/Info/Public');
    } catch (error) {
      const code = (error as { code?: string })?.code;
      if (code === 'network' || code === 'timeout') unreachable ??= (error as Error).message;
      else refused ??= `${address} 不是 Jellyfin 服务器`;
      continue;
    }
    const reason = refusal(info, address);
    if (reason) {
      refused ??= reason;
      continue;
    }
    const quickConnect = await send(address, '/QuickConnect/Enabled', undefined, { timeout: 8 })
      .then((response) => response.status === 200 && response.body.trim() === 'true')
      .catch(() => false);
    pending = { address, serverId: info.Id, serverName: typeof info.ServerName === 'string' && info.ServerName ? info.ServerName : address };
    return { address, name: pending.serverName, version: info.Version, methods: quickConnect ? ['password', 'code'] : ['password'] };
  }
  throw starry.error('connect', refused ?? `连不上 ${candidates[0]}${unreachable ? `：${unreachable}` : ''}`);
}

function requirePending(): Pending {
  if (!pending) throw starry.error('connect', '请先连接服务器');
  return pending;
}

/** The account as the app shows it; the server's web pages become the links' templates. */
export function signedInAs(account: Session): Profile {
  const page = `${account.address}/web/#/details?id={id}&serverId=${account.serverId}`;
  starry.setWebPages({ song: page, album: page, artist: page, playlist: page });
  return {
    userID: `${account.serverId}:${account.userId}`,
    nickname: account.userName || '未命名用户',
    avatar: account.imageTag
      ? `${account.address}/Users/${account.userId}/Images/Primary?fillWidth=200&fillHeight=200&quality=90&tag=${account.imageTag}`
      : undefined,
    detail: account.serverName,
  };
}

function signIn(result: any, server: Pending): Profile {
  const token = result?.AccessToken;
  const user = result?.User;
  if (typeof token !== 'string' || !token || typeof user?.Id !== 'string') throw starry.error('invalidResponse', '服务器没有返回登录信息');
  clearAccountState();
  const account: Session = {
    serverId: server.serverId,
    serverName: server.serverName,
    address: server.address,
    userId: user.Id,
    token,
    userName: typeof user.Name === 'string' ? user.Name : '',
    imageTag: typeof user.PrimaryImageTag === 'string' ? user.PrimaryImageTag : undefined,
  };
  setSession(account);
  return signedInAs(account);
}

export async function loginWithPassword(username: string, password: string): Promise<Profile> {
  const server = requirePending();
  const path = '/Users/AuthenticateByName';
  const response = await send(server.address, path, undefined, { json: { Username: username.trim(), Pw: password } });
  if (response.status === 401) throw starry.error('loginFailed', '用户名或密码不正确');
  return signIn(answer(response, path), server);
}

export async function beginCodeLogin(): Promise<{ key: string; code: string }> {
  const server = requirePending();
  const path = '/QuickConnect/Initiate';
  const response = await send(server.address, path, undefined, { method: 'POST' });
  if (response.status === 401 || response.status === 403) throw starry.error('quickConnect', '这台服务器没有开启快速连接');
  const result = answer<any>(response, path);
  if (typeof result?.Secret !== 'string' || result.Code === undefined) throw starry.error('invalidResponse', '服务器没有返回快速连接的验证码');
  return { key: result.Secret, code: String(result.Code) };
}

export async function pollCodeLogin({ key }: { key: string }): Promise<'waiting' | 'expired' | { status: 'confirmed'; profile: Profile }> {
  const server = requirePending();
  const response = await send(server.address, '/QuickConnect/Connect', undefined, { query: { secret: key } });
  // Gone after 10 minutes.
  if (response.status === 404) return 'expired';
  if (!answer<any>(response, '/QuickConnect/Connect')?.Authenticated) return 'waiting';
  const path = '/Users/AuthenticateWithQuickConnect';
  const result = answer(await send(server.address, path, undefined, { json: { Secret: key } }), path);
  return { status: 'confirmed', profile: signIn(result, server) };
}

export function current(): Profile | null {
  const account = session();
  return account ? signedInAs(account) : null;
}

/** Checks the token (`/Users/Me`) and picks up a new name, picture or server name. */
export async function refresh(): Promise<Profile | null> {
  const account = session();
  if (!account) return null;
  const [me, info] = await Promise.all([
    api(account, '/Users/Me'),
    api(account, '/System/Info/Public').catch(() => undefined),
  ]);
  const next: Session = {
    ...account,
    userName: typeof me?.Name === 'string' ? me.Name : account.userName,
    imageTag: typeof me?.PrimaryImageTag === 'string' ? me.PrimaryImageTag : undefined,
    serverName: typeof info?.ServerName === 'string' && info.ServerName ? info.ServerName : account.serverName,
  };
  if (session()?.token !== account.token) return current();
  setSession(next);
  return signedInAs(next);
}

/** Ends the session on the server too; its token is forgotten. */
export async function logout(): Promise<void> {
  const account = session();
  if (account) {
    await api(account, '/Sessions/Logout', { method: 'POST' }).catch(() => undefined);
    forget(account);
  }
  signOutLocally();
}

export function signOutLocally(): void {
  setSession(null);
  clearAccountState();
  starry.setWebPages(null);
}

export function exportCredentials(): Session | null {
  return session();
}

/**
 * Another kept account. A server out of reach does not stop the switch (the account shows as
 * kept, and its songs come once the server answers); only a token the server refused does.
 */
export async function restoreCredentials(credentials: unknown): Promise<Profile> {
  const account = sessionFrom(credentials);
  if (!account) throw starry.error('invalidCredentials', '保存的登录信息不完整，请重新登录');
  clearAccountState();
  setSession(account);
  try {
    return (await refresh()) ?? signedInAs(account);
  } catch (error) {
    if ((error as { code?: string })?.code === 'loginExpired') throw error;
    return signedInAs(account);
  }
}
