// Word timing is emitted as TTML; line timing as LRC.
// The host aligns separate translation and romanization bodies within ±0.5 s.

import type { Lyrics } from '../sdk/starry';

/** A timed piece of a line: its text with the spaces after it; `end` when the server says. */
export interface Word {
  start: number;
  end?: number;
  text: string;
}

/** A line, in seconds. Words, when there are any, make up its text. */
export interface TimedLine {
  start: number;
  text: string;
  words?: Word[];
}

/** The longest a line's last word is held: it would last until the next line, which may come after a long break. */
export const LAST_WORD_SECONDS = 5;

export function lrcTime(time: number): string {
  const hundredths = Math.max(0, Math.round(time * 100));
  const minutes = Math.floor(hundredths / 6000);
  const rest = hundredths % 6000;
  return `[${String(minutes).padStart(2, '0')}:${String(Math.floor(rest / 100)).padStart(2, '0')}.${String(rest % 100).padStart(2, '0')}]`;
}

export const escapeXML = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const clock = (time: number) => `${time.toFixed(3)}s`;

function spans(words: Word[], lineEnd: number): { xml: string; end?: number } {
  let out = '';
  let last: number | undefined;
  words.forEach((word, index) => {
    const next = words[index + 1];
    const text = word.text.trimEnd();
    if (!text.trim()) {
      out += escapeXML(word.text);
      return;
    }
    let end = word.end ?? next?.start ?? word.start + LAST_WORD_SECONDS;
    if (!next) end = Math.min(end, lineEnd, word.start + LAST_WORD_SECONDS);
    end = Math.max(end, word.start);
    last = Math.max(last ?? end, end);
    out += `<span begin="${clock(word.start)}" end="${clock(end)}">${escapeXML(text)}</span>${escapeXML(word.text.slice(text.length))}`;
  });
  return { xml: out, end: last };
}

/**
 * Lines as TTML: a line ends where the next starts, or with its last word (so a break between
 * lines shows as one); the last line ends with the song. Empty lines only time the one before.
 */
export function toTTML(lines: TimedLine[], duration?: number): string {
  const body = lines.flatMap((line, index) => {
    if (!line.text.trim()) return [];
    const following = lines[index + 1]?.start;
    const songEnd = duration && duration > line.start ? duration : undefined;
    const limit = following ?? songEnd ?? Number.POSITIVE_INFINITY;
    const words = spans(line.words ?? [], limit);
    const end = words.end ?? (Number.isFinite(limit) ? limit : line.start + LAST_WORD_SECONDS);
    return [`<p begin="${clock(line.start)}" end="${clock(Math.max(end, line.start))}">${words.end === undefined ? escapeXML(line.text.trim()) : words.xml}</p>`];
  });
  return `<tt xmlns="http://www.w3.org/ns/ttml"><body><div>${body.join('')}</div></body></tt>`;
}

export function toLRC(lines: TimedLine[]): string {
  return lines.map((line) => `${lrcTime(line.start)}${line.text.trim()}`).join('\n');
}

export function lyricsOf(lines: TimedLine[], extras: { translation?: TimedLine[]; romanization?: TimedLine[]; duration?: number } = {}): Lyrics | null {
  const sorted = [...lines].sort((a, b) => a.start - b.start);
  if (!sorted.some((line) => line.text.trim())) return null;
  const secondary = (extra: TimedLine[] | undefined) => {
    const kept = (extra ?? []).filter((line) => line.text.trim());
    return kept.length > 0 ? toLRC([...kept].sort((a, b) => a.start - b.start)) : undefined;
  };
  const worded = sorted.some((line) => (line.words ?? []).some((word) => word.text.trim()));
  const lyrics: Lyrics = worded ? { format: 'ttml', body: toTTML(sorted, extras.duration) } : { format: 'lrc', body: toLRC(sorted) };
  const translation = secondary(extras.translation);
  const romanization = secondary(extras.romanization);
  if (translation) lyrics.translation = translation;
  if (romanization) lyrics.romanization = romanization;
  return lyrics;
}

const INLINE_TIME = /<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>/g;

export function inlineWords(text: string): { text: string; words: Word[] } | undefined {
  const marks = [...text.matchAll(INLINE_TIME)];
  if (marks.length === 0) return undefined;
  const words: Word[] = [];
  const lead = text.slice(0, marks[0].index);
  marks.forEach((mark, index) => {
    const from = mark.index! + mark[0].length;
    const to = marks[index + 1]?.index ?? text.length;
    const start = Number(mark[1]) * 60 + Number(mark[2].replace(':', '.'));
    const piece = (index === 0 ? lead : '') + text.slice(from, to);
    if (!piece && index === marks.length - 1 && words.length > 0) {
      words[words.length - 1].end = start;
      return;
    }
    if (piece) words.push({ start, text: piece });
  });
  return { text: words.map((word) => word.text).join(''), words };
}
