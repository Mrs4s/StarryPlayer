// What a plugin for a server of the listener's own needs whatever the server speaks: where to look
// for the address typed, versions compared, dates read, and lists of songs kept in order.

export function addressCandidates(typed: string, webPaths: RegExp[] = []): string[] {
  let address = typed.trim().replace(/[?#].*$/, '');
  for (const path of webPaths) address = address.replace(path, '');
  address = address.replace(/\/+$/, '');
  if (!address) return [];
  const scheme = /^(https?):\/\//i.exec(address);
  if (scheme) return [scheme[1].toLowerCase() + address.slice(scheme[1].length)];
  const host = address.split('/')[0];
  const local = /^(localhost|\d{1,3}(\.\d{1,3}){3}|\[[0-9a-f:]+\])(:\d+)?$/i.test(host) || /\.local(:\d+)?$/i.test(host) || /:(?!443$)\d+$/.test(host);
  return local ? [`http://${address}`, `https://${address}`] : [`https://${address}`, `http://${address}`];
}

/** `a` against `b` by their dotted numbers (`1.16.1`, `v3.81.0`, `0.64.2 (10114574)`): negative, zero or positive. */
export function compareVersions(a: string, b: string): number {
  const parts = (version: string) => (version.match(/\d+(\.\d+)*/)?.[0] ?? '').split('.').map((part) => parseInt(part, 10) || 0);
  const x = parts(a);
  const y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
  }
  return 0;
}

/** `12.1.0` is at least `minimum` (`[10, 9]`); a version that is not a string passes. */
export function isAtLeast(version: unknown, minimum: number[]): boolean {
  if (typeof version !== 'string') return true;
  return compareVersions(version, minimum.join('.')) >= 0;
}

export const text = (value: unknown) => (typeof value === 'string' && value.trim() ? value.trim() : undefined);

/** A positive number, or undefined. */
export const positive = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined);

/**
 * An ISO 8601 date (any number of decimals, which not every parser takes) as milliseconds; the
 * year alone when that is all there is.
 */
export function date(value: unknown, year?: unknown): number | undefined {
  const match = typeof value === 'string' ? /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2}))?/.exec(value) : null;
  if (match) {
    const [y, mo, d, h, mi, s] = match.slice(1).map((part) => Number(part ?? 0));
    if (y > 1) return Date.UTC(y, mo - 1, d, h, mi, s);
  }
  return typeof year === 'number' && year > 1 ? Date.UTC(year, 0, 1) : undefined;
}

export function remainingIDs(all: string[], first: string[]): string[] {
  let next = 0;
  for (const id of first) {
    const index = all.indexOf(id, next);
    if (index >= 0) next = index + 1;
  }
  return all.slice(next);
}

export function mergeOrder(order: string[], now: string[]): string[] {
  const left = new Map<string, number>();
  for (const song of now) left.set(song, (left.get(song) ?? 0) + 1);
  const merged: string[] = [];
  const take = (song: string) => {
    const count = left.get(song) ?? 0;
    if (count === 0) return;
    left.set(song, count - 1);
    merged.push(song);
  };
  order.forEach(take);
  now.forEach(take);
  return merged;
}

export async function mapLimited<T, R>(items: T[], limit: number, transform: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await transform(items[index], index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}
