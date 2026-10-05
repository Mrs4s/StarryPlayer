// The NetEase account: QR login (`type` 4), phone + SMS code, a pasted cookie; the token extended
// at launch (every 20 h); logout. The session lives in client.ts; the app keeps other accounts
// with `exportCredentials` (the account's cookies).

import type { Profile } from '../../sdk/starry';
import {
  ACCOUNT_COOKIE_NAMES,
  clearAccount,
  clearCache,
  currentSession,
  ensureAnonymousSession,
  isLoggedIn,
  loginRequired,
  parseCookieString,
  request,
  send,
  setCookies,
  updateSession,
  type NeteaseError,
} from './client';
import { Login } from './endpoints';
import { artwork } from './mapping';
import { setSignedInProfile, signedInProfile } from './state';
import { int, object, str } from './util';

/** MUSIC_U is extended at most every 20 h. */
const TOKEN_REFRESH_INTERVAL = 20 * 3600 * 1000;
let lastTokenRefresh: number | undefined;

const PROFILE_KEY = 'profile';

export function profileFrom(json: any): Profile | undefined {
  const account = object(json?.account);
  const profile = object(json?.profile);
  const userID = str(profile?.userId);
  if (account?.anonimous === true || !profile || userID === undefined) return undefined;
  return {
    userID,
    nickname: str(profile.nickname) ?? '网易云用户',
    avatar: artwork(profile.avatarUrl),
    isVIP: (int(account?.vipType) ?? int(profile.vipType) ?? 0) > 0,
  };
}

function signIn(profile: Profile | undefined): void {
  setSignedInProfile(profile);
  if (profile) starry.storage.set(PROFILE_KEY, profile);
  else starry.storage.remove(PROFILE_KEY);
}

export function current(): Profile | null {
  if (!isLoggedIn()) return null;
  return starry.storage.get<Profile>(PROFILE_KEY) ?? null;
}

export async function refresh(): Promise<Profile | null> {
  if (isLoggedIn()) {
    setSignedInProfile(signedInProfile() ?? current() ?? undefined);
    let json: any;
    try {
      json = await request(Login.account);
    } catch (error) {
      // 301: the session is gone; the cookies are kept.
      if ((error as { code?: string }).code !== 'loginRequired') throw error;
      signIn(undefined);
      throw starry.error('loginExpired', '网易云的登录已失效');
    }
    const profile = profileFrom(json);
    if (profile) {
      signIn(profile);
      await refreshTokenIfDue();
      return profile;
    }
    clearAccount();
    signIn(undefined);
    throw starry.error('loginExpired', '网易云的登录已失效');
  }
  signIn(undefined);
  await ensureAnonymousSession();
  return null;
}

async function refreshTokenIfDue(): Promise<void> {
  if (lastTokenRefresh !== undefined && Date.now() - lastTokenRefresh < TOKEN_REFRESH_INTERVAL) return;
  try {
    const json = await request(Login.refreshToken);
    if (int(json?.code) === 200) lastTokenRefresh = Date.now();
  } catch {
  }
}

async function completeLogin(): Promise<Profile> {
  updateSession((s) => {
    delete s.cookies.MUSIC_A;
  });
  clearCache();
  lastTokenRefresh = Date.now();
  const profile = await refresh();
  if (!profile) throw loginRequired();
  return profile;
}

/** `unikey`; the code holds `https://music.163.com/login?codekey=<unikey>`. */
export async function beginQRLogin(): Promise<{ key: string; url: string }> {
  const json = await request(Login.qrKey, { type: 4 });
  const key = str(json?.unikey);
  if (!key) throw starry.error('invalidResponse', '网易云没有给出二维码');
  return { key, url: `https://music.163.com/login?codekey=${key}` };
}

export async function pollQRLogin(session: { key: string }): Promise<'waiting' | 'scanned' | 'expired' | { status: 'confirmed'; profile: Profile }> {
  let response;
  try {
    response = await send(Login.qrCheck, { key: session.key, type: 4, secureCaptcha: '' });
  } catch (error) {
    if ((error as NeteaseError).neteaseCode === 8821) throw starry.error('captchaRequired', '需要完成安全验证，请在网易云音乐 App 中确认或改用其他方式登录');
    throw error;
  }
  switch (response.code) {
    case 800:
      return 'expired';
    case 801:
      return 'waiting';
    case 802:
      return 'scanned';
    case 803: {
      const cookie = str(response.json.cookie);
      const parsed = cookie ? parseCookieString(cookie) : undefined;
      if (!isLoggedIn() && parsed) setCookies(parsed);
      return { status: 'confirmed', profile: await completeLogin() };
    }
    default:
      throw starry.error('api', `网易云返回 ${response.code}${str(response.json.message) ? `：${str(response.json.message)}` : ''}`);
  }
}

export async function sendPhoneCode(phone: string, countryCode: string): Promise<void> {
  const json = await request(Login.sendCaptcha, { scene: 0, cellphone: phone, ctcode: countryCode || '86', secrete: 'music_middleuser_maclogin' });
  if (int(json?.code) !== 200) throw starry.error('api', `网易云返回 ${int(json?.code) ?? -1}${str(json?.message) ? `：${str(json?.message)}` : ''}`);
}

/** Phone + SMS code. 8821 Yidun captcha, 8830 two-factor, 8810 security notice, 501 wrong code, 509 too many tries. */
export async function loginWithPhoneCode(phone: string, countryCode: string, code: string): Promise<Profile> {
  const response = await send(Login.cellphone, { type: 1, phone, captcha: code, remember: true, https: true, countrycode: countryCode || '86' });
  if (response.code !== 200) {
    const message = str(response.json.message) ?? str(response.json.msg);
    throw starry.error('api', `网易云返回 ${response.code}${message ? `：${message}` : ''}`);
  }
  return completeLogin();
}

// MARK: Cookie

export async function loginWithCookie(text: string): Promise<Profile> {
  const parsed = parseCookieString(text);
  if (!parsed) throw starry.error('invalidCookie', 'Cookie 里需要有 MUSIC_U');
  clearAccount();
  setCookies(parsed);
  const profile = await refresh();
  if (!profile) throw loginRequired();
  return profile;
}

export async function logout(): Promise<void> {
  try {
    await request(Login.logout);
  } catch {
  }
  await signOutLocally();
}

/** Drops the account's cookies without `/api/logout`, which would end the session on the server too. */
export async function signOutLocally(): Promise<void> {
  clearAccount();
  lastTokenRefresh = undefined;
  signIn(undefined);
  try {
    await ensureAnonymousSession();
  } catch {
  }
}

/**
 * The account's cookies (MUSIC_U, __csrf, …). MUSIC_A, the device's anonymous token, stays with the
 * device; so do NMTID and the session's identity fields.
 */
export function exportCredentials(): Record<string, string> | null {
  if (!isLoggedIn()) return null;
  const cookies = currentSession().cookies;
  const out: Record<string, string> = {};
  for (const name of ACCOUNT_COOKIE_NAMES) if (name !== 'MUSIC_A' && cookies[name] !== undefined) out[name] = cookies[name];
  return out;
}

/** Signs a kept account in; when it does not come back (expired, no network) its cookies go again, so a later launch does not sign in with them unasked. */
export async function restoreCredentials(credentials: any): Promise<Profile> {
  const cookies: Record<string, string> = {};
  for (const [name, value] of Object.entries(object(credentials) ?? {})) if (typeof value === 'string' && name !== 'MUSIC_A') cookies[name] = value;
  if (!cookies.MUSIC_U) throw starry.error('invalidCredentials', '保存的登录信息里没有 MUSIC_U');
  clearAccount();
  setCookies(cookies);
  lastTokenRefresh = undefined;
  let profile: Profile | null;
  try {
    profile = await refresh();
  } catch (error) {
    await signOutLocally();
    throw error;
  }
  if (!profile) {
    await signOutLocally();
    throw loginRequired();
  }
  return profile;
}
