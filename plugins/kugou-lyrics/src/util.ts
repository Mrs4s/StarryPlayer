// Reading Kugou's JSON: ids and numbers come as numbers or as strings, so every read is loose.

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

const ENTITIES: Record<string, string> = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&#039;': "'", '&nbsp;': ' ' };

export function clean(name: string): string {
  return name
    .replace(/<\/?em>/g, '')
    .replace(/&(amp|lt|gt|quot|apos|#039|nbsp);/g, (entity) => ENTITIES[entity])
    .trim();
}
