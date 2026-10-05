// Request identity and eapi envelope. Every API call is an eapi POST to
// `https://interface.music.163.com/eapi/...` with `e_r = true`.

import { md5Hex } from './crypto';
import { numberText, orderedJSON, sortedJSON } from './util';

export const APP_VERSION = '3.1.12';
export const BUILD_VERSION = '3443';
export const BUNDLE_IDENTIFIER = 'com.netease.163music';
export const CHANNEL = 'netease';
export const API_DOMAIN = 'https://interface.music.163.com';
/** The `clientSign` cookie and header value (a fixed string). */
export const CLIENT_SIGN = '00:1C:42:A4:31:D9@@@VC5VVZ9X9AWM7ESBET88@@@@@@34cfda17-a6d7-446e-8b22-34bf2880e9448fe09668892848e1c627587e78022715';
export const USER_AGENT = `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 NeteaseMusicDesktop/${APP_VERSION}.${BUILD_VERSION}`;

/** The running macOS as `major.minor.patch`. */
export function systemVersion(): string {
  const parts = starry.app.osVersion.split('.');
  while (parts.length < 3) parts.push('0');
  return parts.slice(0, 3).join('.');
}

/** The Mac's model identifier (`hw.model`), sent as the `mode` cookie. */
export const deviceModel = () => starry.app.model;

export interface Device {
  deviceUUID: string;
  /** `deviceUUID|<random UUID>`, kept percent-encoded (`%7C`). */
  deviceID: string;
}

/** The device id added to every eapi payload: `md5(deviceUUID + bundle id)`. */
export const hashedDeviceID = (device: Device) => md5Hex(device.deviceUUID + BUNDLE_IDENTIFIER);

export function baseCookies(device: Device): [string, string][] {
  return [
    ['os', 'osx'],
    ['deviceId', device.deviceID],
    ['osver', systemVersion()],
    ['appver', APP_VERSION],
    ['clientSign', CLIENT_SIGN],
    ['channel', CHANNEL],
    ['mode', deviceModel()],
  ];
}

export function eapiHeader(device: Device, extra: [string, string][] = []): string {
  return orderedJSON([
    ['clientSign', CLIENT_SIGN],
    ['os', 'osx'],
    ['appver', APP_VERSION],
    ['deviceId', device.deviceID],
    ['requestId', 0],
    ['osver', systemVersion()],
    ...extra,
  ]);
}

// Keep payload field order: params, `e_r`, `header`, then `os`, `verifyId`, `deviceId`.
export function eapiPayload(params: [string, string][], encryptResponse: boolean, device: Device, extraHeader: [string, string][] = []): string {
  const fields: [string, unknown][] = [...params];
  if (encryptResponse) fields.push(['e_r', true]);
  fields.push(['header', eapiHeader(device, extraHeader)]);
  fields.push(['os', 'OSX']);
  fields.push(['verifyId', 1]);
  fields.push(['deviceId', hashedDeviceID(device)]);
  return orderedJSON(fields);
}

export function stringify(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return numberText(value);
  if (Array.isArray(value)) return `[${value.map(stringify).join(',')}]`;
  if (value && typeof value === 'object') return sortedJSON(value);
  return String(value);
}
