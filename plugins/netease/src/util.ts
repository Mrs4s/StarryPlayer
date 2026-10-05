// Reading NetEase's JSON loosely: ids and counts come as
// numbers or numeric strings, `null` reads as missing, and a boolean may be 0 / 1.

export function int(value: unknown): number | undefined {
  if (typeof value === 'number') return Number.isFinite(value) ? Math.trunc(value) : undefined;
  if (typeof value === 'string' && /^\s*[-+]?\d+\s*$/.test(value)) return parseInt(value, 10);
  return undefined;
}

export function num(value: unknown): number | undefined {
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value);
  return undefined;
}

export function str(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return undefined;
}

export function bool(value: unknown): boolean | undefined {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  return undefined;
}

export function nonEmpty(value: unknown): string | undefined {
  const string = str(value)?.trim();
  return string ? string : undefined;
}

export function array(value: unknown): any[] {
  return Array.isArray(value) ? value : [];
}

/** An object, or undefined (null and arrays are not). */
export function object(value: unknown): any {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : undefined;
}

export function compact<T>(values: (T | null | undefined)[]): T[] {
  return values.filter((value): value is T => value !== null && value !== undefined);
}

export function unique<T>(values: T[]): T[] {
  return [...new Set(values)];
}

/** Items whose key was not seen before. */
export function uniqueBy<T>(values: T[], key: (value: T) => string): T[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    const k = key(value);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function hex(bytes: Uint8Array): string {
  let out = '';
  for (const byte of bytes) out += byte.toString(16).padStart(2, '0');
  return out;
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function randomInt(below: number): number {
  const bytes = starry.crypto.randomBytes(4);
  return (((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0) % below;
}

export function randomHex(length: number, upperCase = false): string {
  const digits = upperCase ? '0123456789ABCDEF' : '0123456789abcdef';
  let out = '';
  for (let i = 0; i < length; i++) out += digits[randomInt(16)];
  return out;
}

/** A version 4 UUID, upper case (as `UUID().uuidString`). */
export function uuid(): string {
  const bytes = starry.crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const h = hex(bytes).toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export const percentEncode = (string: string) => encodeURIComponent(string);

export function formEncode(pairs: [string, string][]): string {
  const encode = (s: string) =>
    encodeURIComponent(s)
      .replace(/[!'()~]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
      .replace(/%20/g, '+');
  return pairs.map(([name, value]) => `${encode(name)}=${encode(value)}`).join('&');
}

export function sortedJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(sortedJSON).join(',')}]`;
  if (value && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${sortedJSON(object[key])}`)
      .join(',')}}`;
  }
  if (typeof value === 'number') return numberText(value);
  return JSON.stringify(value) ?? 'null';
}

export function orderedJSON(fields: [string, unknown][]): string {
  return `{${fields.map(([key, value]) => `${JSON.stringify(key)}:${sortedJSON(value)}`).join(',')}}`;
}

/** Whole numbers as integers (no exponent below 1e15), others as JavaScript writes them. */
export function numberText(value: number): string {
  return Number.isInteger(value) && Math.abs(value) < 1e15 ? value.toFixed(0) : String(value);
}

export function clientTime(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}
