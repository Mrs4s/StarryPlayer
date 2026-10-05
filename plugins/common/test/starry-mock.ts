// A `starry` for running a plugin's modules under Node (`npm test`): the same host API as
// prelude.js, on node:crypto, with servers faked by origin (`servers`) instead of the network, and
// the requests they got kept in `sent`. Shared by the server plugins' tests (Jellyfin, Subsonic).

import { createHash, createHmac, randomBytes } from 'node:crypto';

const toBytes = (data: unknown): Uint8Array => {
  if (typeof data === 'string') return new TextEncoder().encode(data);
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  throw new TypeError('data must be a string or a Uint8Array');
};

const output = (bytes: Uint8Array, encoding?: string): any => {
  switch (encoding) {
    case undefined:
    case 'bytes':
      return new Uint8Array(bytes);
    case 'hex':
      return Buffer.from(bytes).toString('hex');
    case 'base64':
      return Buffer.from(bytes).toString('base64');
    case 'utf8':
      return new TextDecoder().decode(bytes);
    default:
      throw new TypeError(`unknown output encoding: ${encoding}`);
  }
};

export interface Sent {
  url: URL;
  method: string;
  headers: Record<string, string>;
  json?: any;
  form?: URLSearchParams;
}

/** A fake server: an answer for each request it takes (undefined: 404). */
export type Route = (request: Sent) => { status?: number; body?: unknown } | undefined;

export const servers = new Map<string, Route>();
export const sent: Sent[] = [];
export const pages: { current: Record<string, string> | null } = { current: null };

const storage = new Map<string, string>();

async function request(options: any) {
  const url = new URL(options.url);
  for (const [name, value] of Object.entries(options.query ?? {})) {
    if (value !== undefined && value !== null) url.searchParams.append(name, String(value));
  }
  const formBody = options.form ?? (String(options.headers?.['Content-Type'] ?? '').startsWith('application/x-www-form-urlencoded') ? options.body : undefined);
  const form = formBody === undefined ? undefined : new URLSearchParams(formBody);
  const request: Sent = { url, method: String(options.method ?? 'GET').toUpperCase(), headers: options.headers ?? {}, json: options.json, form };
  sent.push(request);
  const route = servers.get(url.origin);
  if (!route) throw Object.assign(new Error(`could not connect to ${url.host}`), { code: 'network' });
  const answer = route(request) ?? { status: 404 };
  const body = answer.body === undefined ? '' : typeof answer.body === 'string' ? answer.body : JSON.stringify(answer.body);
  return { status: answer.status ?? 200, headers: {}, cookies: {}, url: url.href, body };
}

(globalThis as any).starry = {
  apiVersion: 1,
  plugin: { id: 'test.plugin', name: 'Test', version: 'test' },
  app: { version: '1.2.3', platform: 'macOS', osVersion: '26.0.1', arch: 'arm64', model: 'Mac16,1', deviceName: '测试的 Mac', formats: ['mp3', 'aac', 'alac', 'flac', 'wav', 'aiff', 'mp4', 'ogg', 'eac3'] },
  settings: {},
  error(code: string, message?: string) {
    const error = new Error(message ?? code) as Error & { code: string };
    error.code = code;
    return error;
  },
  http: { request },
  crypto: {
    ...Object.fromEntries(['md5', 'sha1', 'sha256', 'sha384', 'sha512'].map((name) => [name, (data: unknown, out?: string) => output(createHash(name).update(toBytes(data)).digest(), out)])),
    hmac: (algorithm: string, key: unknown, data: unknown, out?: string) => output(createHmac(algorithm, toBytes(key)).update(toBytes(data)).digest(), out),
    randomBytes: (count: number) => new Uint8Array(randomBytes(count)),
  },
  encoding: {
    utf8: { encode: (text: string) => new TextEncoder().encode(text), decode: (data: unknown) => new TextDecoder().decode(toBytes(data)) },
    hex: {
      encode: (data: unknown) => Buffer.from(toBytes(data)).toString('hex'),
      decode: (text: string) => new Uint8Array(Buffer.from(text, 'hex')),
    },
    base64: {
      encode: (data: unknown) => Buffer.from(toBytes(data)).toString('base64'),
      decode: (text: string) => new Uint8Array(Buffer.from(text.replace(/-/g, '+').replace(/_/g, '/'), 'base64')),
    },
  },
  setWebPages(next: Record<string, string> | null) {
    pages.current = next;
  },
  storage: {
    get: (key: string) => (storage.has(key) ? JSON.parse(storage.get(key)!) : undefined),
    set: (key: string, value: unknown) => (value === undefined ? storage.delete(key) : storage.set(key, JSON.stringify(value))),
    remove: (key: string) => storage.delete(key),
    keys: () => [...storage.keys()].sort(),
    clear: () => storage.clear(),
  },
};
