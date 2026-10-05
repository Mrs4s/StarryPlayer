// Reading QQ Music's JSON: ids, counts and codes come as numbers or as numeric strings, so every
// read is loose.

export function int(value: unknown): number | undefined {
  if (typeof value === 'number') return Number.isFinite(value) ? Math.trunc(value) : undefined;
  if (typeof value === 'string' && /^\s*[-+]?\d+\s*$/.test(value)) return parseInt(value, 10);
  if (typeof value === 'boolean') return value ? 1 : 0;
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

/** A string that is there and not empty. */
export function text(value: unknown): string | undefined {
  const string = str(value);
  return string ? string : undefined;
}

export function array(value: unknown): any[] {
  return Array.isArray(value) ? value : [];
}

export function compact<T>(values: (T | null | undefined)[]): T[] {
  return values.filter((value): value is T => value !== null && value !== undefined);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** A version 4 UUID, upper case (as `UUID().uuidString`). */
export function uuid(): string {
  const bytes = starry.crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const h = starry.encoding.hex.encode(bytes).toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function randomInt(below: number): number {
  const bytes = starry.crypto.randomBytes(4);
  return (((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0) % below;
}

export function apiError(code: number, name?: string): Error & { code: string; qqCode: number } {
  const error = starry.error('api', `接口返回 ${code}${name ? `（${name}）` : ''}`) as Error & { code: string; qqCode: number };
  error.qqCode = code;
  return error;
}
