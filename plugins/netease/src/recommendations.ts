import type { RecommendationStyleCategory, Track } from '../../sdk/starry';
import { businessError, currentSession, loginRequired, request } from './client';
import { Discovery } from './endpoints';
import * as map from './mapping';
import { currentUserID, rememberAlgorithms } from './state';
import { compact, int, nonEmpty, str, unique, uniqueBy } from './util';

const STYLE_SONGS_TTL = 5000;

// Selected tags come with the style songs (`data.tags`); keep that list for the next call.
let pendingStyleSongs: { session: string; expires: number; tracks: Track[] } | undefined;
let styleGeneration = 0;
const styleSessionKey = () => `${currentUserID() ?? ''}|${currentSession().cookies.MUSIC_U ?? ''}`;

function invalidateStyleSongs(): number {
  pendingStyleSongs = undefined;
  return ++styleGeneration;
}

function requireUID(): string {
  const uid = currentUserID();
  if (uid === undefined) throw loginRequired();
  return uid;
}

function expect(json: any): void {
  const code = int(json?.code);
  if (code !== 200) throw businessError(code ?? -1, str(json?.message) ?? str(json?.msg));
}

function requiredArray(value: unknown, field: string): any[] {
  if (!Array.isArray(value)) throw starry.error('invalidResponse', `网易云的推荐响应缺少 ${field}`);
  return value;
}

/** YYYY-MM-DD, checked in UTC so the local time zone does not move the day. */
export function isRecommendationDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export async function dailyRecommendationDates(): Promise<string[]> {
  requireUID();
  const json = await request(Discovery.dailyHistoryDates);
  expect(json);
  return unique(requiredArray(json?.data?.dates, 'data.dates').filter(isRecommendationDate)).sort().reverse();
}

function recommendedTracks(items: any[]): Track[] {
  const songs = items.map((item) => item?.song ?? item);
  rememberAlgorithms(compact(songs.map((song): [string, string] | undefined => {
    const id = str(song?.id);
    const alg = nonEmpty(song?.alg);
    return id !== undefined && alg !== undefined ? [id, alg] : undefined;
  })));
  const tracks = uniqueBy(compact(songs.map(map.trackWithPrivilege)), (track) => track.id);
  if (songs.length && !tracks.length) throw starry.error('invalidResponse', '网易云的推荐响应没有可解析的歌曲');
  return tracks;
}

export async function dailyRecommendationHistory(date: string): Promise<Track[]> {
  requireUID();
  if (!isRecommendationDate(date)) throw starry.error('invalidResponse', '历史日推日期格式不正确');
  const json = await request(Discovery.dailyHistory, { date });
  expect(json);
  return recommendedTracks(requiredArray(json?.data?.songs ?? json?.data?.dailySongs, 'data.songs'));
}

export async function styleRecommendations(): Promise<Track[]> {
  requireUID();
  const pending = pendingStyleSongs;
  invalidateStyleSongs();
  if (pending && pending.session === styleSessionKey() && pending.expires > Date.now()) return pending.tracks;
  const json = await request(Discovery.styleDailySongs);
  expect(json);
  return styleTracks(json);
}

function styleTracks(json: any): Track[] {
  return recommendedTracks(requiredArray(json?.data?.dailySongs, 'data.dailySongs'));
}

/** Available tags: `data.categorys[].tagVOList`. */
async function styleCategories(): Promise<RecommendationStyleCategory[]> {
  const json = await request(Discovery.styleDailyConfig);
  expect(json);
  const categories = requiredArray(json?.data?.categorys, 'data.categorys');
  const mapped = uniqueBy(compact(categories.map((category): RecommendationStyleCategory | undefined => {
    const id = nonEmpty(category?.categoryId);
    const name = nonEmpty(category?.categoryName);
    if (!id || !name) return undefined;
    const tags = requiredArray(category.tagVOList, 'tagVOList');
    const styles = uniqueBy(compact(tags.map((tag) => {
      const id = nonEmpty(tag?.tagId);
      const name = nonEmpty(tag?.tagName);
      return id && name ? { id, name } : undefined;
    })), (style) => style.id);
    return { id, name, styles, selectedStyleIDs: [] };
  })), (category) => category.id);
  if (categories.length && !mapped.length) throw starry.error('invalidResponse', '网易云的推荐响应没有可解析的风格分类');
  return mapped;
}

export async function recommendationStyles(): Promise<RecommendationStyleCategory[]> {
  requireUID();
  const session = styleSessionKey();
  const generation = invalidateStyleSongs();
  const categories = await styleCategories();
  const json = await request(Discovery.styleDailySongs);
  expect(json);
  const tags = json?.data?.tags;
  const selectedCategory = str(tags?.categoryId);
  if (tags != null && selectedCategory === undefined) throw starry.error('invalidResponse', '网易云的推荐响应缺少 data.tags.categoryId');
  if (selectedCategory !== undefined) {
    const selected = new Set(compact(requiredArray(tags?.tagVOList, 'data.tags.tagVOList').map((tag) => str(tag?.tagId))));
    for (const category of categories) {
      category.selectedStyleIDs = category.id === selectedCategory
        ? category.styles.filter((style) => selected.has(style.id)).map((style) => style.id)
        : [];
    }
  }
  const tracks = styleTracks(json);
  if (generation === styleGeneration && session === styleSessionKey()) {
    pendingStyleSongs = { session, expires: Date.now() + STYLE_SONGS_TTL, tracks };
  }
  return categories;
}

export async function setRecommendationStyles(categoryID: string, styleIDs: string[]): Promise<void> {
  const uid = requireUID();
  const session = currentSession().cookies.MUSIC_U;
  const category = (await styleCategories()).find((category) => category.id === categoryID);
  // Restoring an account can replace its cookies before its profile arrives.
  if (currentUserID() !== uid || currentSession().cookies.MUSIC_U !== session) throw loginRequired();
  const ids = unique(styleIDs);
  if (!category || ids.some((id) => !category.styles.some((style) => style.id === id))) {
    throw starry.error('invalidResponse', '请选择当前分类中的推荐风格');
  }
  const numericID = (id: string): number => {
    const number = Number(id);
    if (!/^\d+$/.test(id) || !Number.isSafeInteger(number)) throw starry.error('invalidResponse', '推荐风格 ID 不正确');
    return number;
  };
  invalidateStyleSongs();
  try {
    const json = await request(Discovery.styleDailyTagSave, {
      tags: JSON.stringify({ tagIds: ids.map(numericID), categoryId: numericID(categoryID) }),
    });
    expect(json);
  } finally {
    // Reads started during the save may still carry the previous selection's songs.
    invalidateStyleSongs();
  }
}
