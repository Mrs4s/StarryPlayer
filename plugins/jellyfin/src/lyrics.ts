// Jellyfin lyric times use ticks; enhanced-LRC cues become TTML word timing.
// Only look up this server's own songs.

import { lyricsOf, type TimedLine, type Word } from '../../common/lyrics';
import type { Lyrics } from '../../sdk/starry';
import { api, locate } from './client';

interface Cue {
  Position?: number;
  EndPosition?: number;
  Start?: number;
  End?: number;
}

interface Line {
  Text?: string;
  Start?: number;
  Cues?: Cue[];
}

const seconds = (ticks: number) => ticks / 1e7;

function wordsOf(line: Line): Word[] {
  const text = line.Text ?? '';
  const cues = (line.Cues ?? []).filter((cue) => typeof cue.Start === 'number').sort((a, b) => (a.Position ?? 0) - (b.Position ?? 0));
  return cues.map((cue, index) => {
    const next = cues[index + 1];
    const from = index === 0 ? 0 : Math.max(0, cue.Position ?? 0);
    return {
      start: seconds(cue.Start!),
      end: typeof cue.End === 'number' ? seconds(cue.End) : undefined,
      text: text.slice(from, Math.min(text.length, next?.Position ?? text.length)),
    };
  });
}

export function toLyrics(dto: any, duration?: number): Lyrics | null {
  const lines: Line[] = Array.isArray(dto?.Lyrics) ? dto.Lyrics : [];
  const timed: TimedLine[] = lines
    .filter((line) => typeof line?.Start === 'number')
    .map((line) => ({ start: seconds(line.Start!), text: line.Text ?? '', words: wordsOf(line) }));
  return lyricsOf(timed, { duration });
}

const isNotFound = (error: unknown) => (error as { code?: string })?.code === 'notFound';

export async function fetch(song: { id: string; duration?: number }): Promise<Lyrics | null> {
  let found;
  try {
    found = await locate(song.id, (server) => api(server, `/Items/${encodeURIComponent(song.id)}`, { query: { userId: server.userId } }));
  } catch (error) {
    if (isNotFound(error)) return null;
    throw error;
  }
  if (found.value?.HasLyrics === false) return null;
  try {
    return toLyrics(await api(found.server, `/Audio/${encodeURIComponent(song.id)}/Lyrics`), song.duration);
  } catch (error) {
    if (isNotFound(error)) return null;
    throw error;
  }
}

export async function search(): Promise<[]> {
  return [];
}
