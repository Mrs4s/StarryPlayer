// Navidrome cue positions use UTF-8 bytes; gonic/LMS embed word times in text.
// Use `getLyricsBySongId` only: legacy artist/title lookup can return the wrong song on LMS.

import { inlineWords, lyricsOf, type TimedLine, type Word } from '../../common/lyrics';
import type { Lyrics } from '../../sdk/starry';
import { call, codeOf, list, locate } from './client';

/** Bytes `start` to `end` (both in) of `text` as UTF-8. */
function utf8Slice(text: string, start: number, end: number): string {
  const bytes = starry.encoding.utf8.encode(text);
  return starry.encoding.utf8.decode(bytes.slice(Math.max(0, start), Math.max(start, end + 1)));
}

/** A `cueLine`'s words: their text (`value`, else the bytes they cover), in seconds. */
function cueWords(cueLine: any, line: string, shift: (ms: number) => number): Word[] {
  const source = typeof cueLine?.value === 'string' ? cueLine.value : line;
  return list(cueLine?.cue)
    .filter((cue) => typeof cue?.start === 'number')
    .map((cue) => ({
      start: shift(cue.start),
      end: typeof cue.end === 'number' ? shift(cue.end) : undefined,
      text: typeof cue.value === 'string' ? cue.value : utf8Slice(source, Number(cue.byteStart) || 0, Number(cue.byteEnd) || 0),
    }));
}

// Positive lyric offsets move lyrics earlier.
export function linesOf(entry: any): { lines: TimedLine[]; translation: TimedLine[] } {
  const offset = typeof entry?.offset === 'number' ? entry.offset : 0;
  const shift = (ms: number) => Math.max(0, (ms - offset) / 1000);
  const firstCue = new Map<number, any>();
  for (const cueLine of list(entry?.cueLine)) {
    if (typeof cueLine?.index === 'number' && !firstCue.has(cueLine.index)) firstCue.set(cueLine.index, cueLine);
  }
  const lines: TimedLine[] = [];
  const translation: TimedLine[] = [];
  list(entry?.line).forEach((line, index) => {
    if (typeof line?.start !== 'number') return;
    const start = shift(line.start);
    const [first, ...rest] = String(line.value ?? '').split(/\r?\n/);
    const cues = firstCue.get(index);
    let main: TimedLine;
    if (cues && list(cues.cue).length > 0) {
      const words = cueWords(cues, first, shift);
      main = { start, text: words.map((word) => word.text).join(''), words };
    } else {
      const inline = inlineWords(first);
      main = inline ? { start, text: inline.text, words: inline.words.map((word) => ({ ...word, start: Math.max(0, word.start - offset / 1000), end: word.end === undefined ? undefined : Math.max(0, word.end - offset / 1000) })) } : { start, text: first };
    }
    const extra = rest.map((part) => inlineWords(part)?.text ?? part).filter((part) => part.trim());
    const previous = lines[lines.length - 1];
    if (previous && Math.abs(previous.start - start) < 0.001 && main.text.trim()) {
      translation.push({ start, text: main.text.trim() });
    } else {
      lines.push(main);
    }
    if (extra.length > 0) translation.push({ start, text: extra.join(' ') });
  });
  return { lines, translation };
}

export function lyricsFrom(entries: unknown, duration?: number): Lyrics | null {
  const all = list(entries);
  const main = all.find((entry) => (!entry?.kind || entry.kind === 'main') && entry?.synced === true);
  if (!main) return null;
  const { lines, translation } = linesOf(main);
  const extra = (kind: string) => {
    const entry = all.find((candidate) => candidate?.kind === kind && candidate?.synced === true);
    return entry ? linesOf(entry).lines : undefined;
  };
  return lyricsOf(lines, { translation: extra('translation') ?? translation, romanization: extra('pronunciation'), duration });
}

export async function fetch(song: { id: string; duration?: number }): Promise<Lyrics | null> {
  let found;
  try {
    found = locate(song.id);
  } catch (error) {
    if (codeOf(error) === 'notFound') return null;
    throw error;
  }
  const versions = found.server.extensions.songLyrics;
  if (!versions) return null;
  try {
    const result = await call(found.server, 'getLyricsBySongId', versions.includes(2) ? { id: found.id, enhanced: true } : { id: found.id });
    return lyricsFrom(result?.lyricsList?.structuredLyrics, song.duration);
  } catch (error) {
    if (codeOf(error) === 'notFound') return null;
    throw error;
  }
}

export async function search(): Promise<[]> {
  return [];
}
