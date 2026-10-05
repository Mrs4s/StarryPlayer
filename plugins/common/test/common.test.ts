// The shared parts under Node, run by each server plugin's `npm test` (plugins/jellyfin,
// plugins/subsonic).

import './starry-mock';
import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import { countsAsPlay, nextRadioSongs, qualityTiers, stopRadio, tiersFor, trashRadioSong, isLossless } from '../library';
import { inlineWords, lrcTime, lyricsOf, toTTML } from '../lyrics';
import { addressCandidates, compareVersions, date, isAtLeast, mapLimited, mergeOrder, remainingIDs } from '../server';

beforeEach(() => {
  stopRadio();
  starry.storage.clear();
});

test('a typed address becomes the places to try, a web page cut back to the server', () => {
  assert.deepEqual(addressCandidates(' 192.168.1.10:4533/ '), ['http://192.168.1.10:4533', 'https://192.168.1.10:4533']);
  assert.deepEqual(addressCandidates('nas.local'), ['http://nas.local', 'https://nas.local']);
  assert.deepEqual(addressCandidates('music.example.com'), ['https://music.example.com', 'http://music.example.com']);
  assert.deepEqual(addressCandidates('music.example.com:443'), ['https://music.example.com:443', 'http://music.example.com:443']);
  assert.deepEqual(addressCandidates('HTTPS://Example.com/music/app/#/album/x/show', [/\/app(\/.*)?$/i]), ['https://Example.com/music']);
  assert.deepEqual(addressCandidates('   '), []);
});

test('versions compare by their numbers, whatever is around them', () => {
  assert.ok(compareVersions('1.16.1', '1.15.0') > 0);
  assert.equal(compareVersions('1.15', '1.15.0'), 0);
  assert.ok(compareVersions('v3.81.0', '3.79') > 0);
  assert.ok(compareVersions('0.64.2 (10114574)', '0.61.0') > 0);
  assert.ok(isAtLeast('12.1.0', [10, 9]) && isAtLeast('10.9.0', [10, 9]) && !isAtLeast('10.8.13', [10, 9]));
  assert.ok(isAtLeast(undefined, [10, 9]));
});

test('dates with any number of decimals, or the year alone', () => {
  assert.equal(date('2026-10-04T01:03:03.633063419Z'), Date.UTC(2026, 9, 4, 1, 3, 3));
  assert.equal(date('2024-05-01T00:00:00.0000000Z'), Date.UTC(2024, 4, 1));
  assert.equal(date(undefined, 2003), Date.UTC(2003, 0, 1));
  assert.equal(date('nonsense'), undefined);
});

test('a playlist’s remaining ids, and a new order merged with what it has now', () => {
  assert.deepEqual(remainingIDs(['a', 'b', 'a', 'c', 'd'], ['a', 'b', 'a']), ['c', 'd']);
  assert.deepEqual(remainingIDs(['a', 'b', 'c'], ['a', 'c']), []);
  assert.deepEqual(remainingIDs(['a', 'b'], []), ['a', 'b']);
  assert.deepEqual(mergeOrder(['c', 'a', 'b'], ['a', 'b', 'c']), ['c', 'a', 'b']);
  assert.deepEqual(mergeOrder(['b', 'a', 'a'], ['a', 'b', 'a']), ['b', 'a', 'a']);
  assert.deepEqual(mergeOrder(['b', 'gone', 'a'], ['a', 'b', 'new']), ['b', 'a', 'new']);
  assert.deepEqual(mergeOrder([], ['a']), ['a']);
});

test('mapping a few at a time keeps the order', async () => {
  let running = 0;
  let most = 0;
  const out = await mapLimited([5, 1, 4, 2, 3], 2, async (value) => {
    running++;
    most = Math.max(most, running);
    await new Promise((resolve) => setTimeout(resolve, value));
    running--;
    return value * 10;
  });
  assert.deepEqual(out, [50, 10, 40, 20, 30]);
  assert.equal(most, 2);
});

test('tiers: lossy files up to 极高, lossless up to 无损, above 48 kHz Hi-Res', () => {
  assert.deepEqual(tiersFor(false, 96000), ['128', '320']);
  assert.deepEqual(tiersFor(true), ['128', '320', 'lossless']);
  assert.deepEqual(tiersFor(true, 96000), ['128', '320', 'lossless', 'hi-res']);
  assert.deepEqual(qualityTiers('MP3').map((tier) => [tier.id, tier.level]), [['128', 'lq'], ['320', 'hq'], ['lossless', 'lossless'], ['hi-res', 'hi-res']]);
  assert.match(qualityTiers('MP3')[0].detail!, /^MP3 128/);
  assert.ok(isLossless('flac') && isLossless('pcm_s16le') && isLossless('wv') && !isLossless('mp3') && !isLossless('opus'));
});

test('a play counts at half the song or four minutes', () => {
  const report = (playedSeconds: number, duration: number) => ({ trackID: 't', playedSeconds, duration, startedAt: 0, endedAt: 0 });
  assert.ok(countsAsPlay(report(100, 200)));
  assert.ok(!countsAsPlay(report(99, 200)));
  assert.ok(countsAsPlay(report(240, 3600)));
  assert.ok(!countsAsPlay(report(200, 3600)));
});

test('the radio hands out new songs from mixes of the last one, never a trashed one, and starts over', async () => {
  const song = (id: string) => ({ id, title: id, duration: 60 });
  const seeds: string[] = [];
  const source = {
    account: 'me',
    seed: async () => 's0',
    mix: async (seed: string) => {
      seeds.push(seed);
      return ['s0', 's1', 's2', 's3', 's4', 's5', 's6'].map(song);
    },
    random: async () => ['s0', 's1'].map(song),
  };
  trashRadioSong('me', 's2');
  const first = await nextRadioSongs(source, true);
  assert.deepEqual(first.map((track) => track.id), ['s0', 's1', 's3', 's4', 's5']);
  // Only s6 is new; the library has all been handed out, so it starts over from a seed.
  const second = await nextRadioSongs(source, false);
  assert.deepEqual(second.map((track) => track.id), ['s6', 's0', 's1', 's3', 's4']);
  assert.deepEqual(seeds, ['s0', 's5', 's0']);
  await nextRadioSongs(source, false);
  assert.equal(seeds[3], 's4');
});

test('lines with words become TTML, a break between lines shown, the last line ending with the song', () => {
  const body = toTTML([
    { start: 1, text: 'Word by word', words: [{ start: 1, end: 1.5, text: 'Word ' }, { start: 1.5, end: 2, text: 'by ' }, { start: 2, end: 40, text: 'word' }] },
    { start: 40, text: '<逐字> & 歌词', words: [{ start: 40, end: 41, text: '<逐字> ' }, { start: 41, end: 42, text: '& ' }, { start: 42, text: '歌词' }] },
    { start: 50, text: '没有字的行' },
  ], 60);
  assert.equal(
    body,
    '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
      + '<p begin="1.000s" end="7.000s"><span begin="1.000s" end="1.500s">Word</span> <span begin="1.500s" end="2.000s">by</span> <span begin="2.000s" end="7.000s">word</span></p>'
      + '<p begin="40.000s" end="47.000s"><span begin="40.000s" end="41.000s">&lt;逐字&gt;</span> <span begin="41.000s" end="42.000s">&amp;</span> <span begin="42.000s" end="47.000s">歌词</span></p>'
      + '<p begin="50.000s" end="60.000s">没有字的行</p>'
      + '</div></body></tt>',
  );
  assert.equal(lrcTime(3725.456), '[62:05.46]');
});

test('lyrics: words make TTML, lines LRC, translations and romanizations LRC of their own, nothing none', () => {
  assert.deepEqual(lyricsOf([{ start: 5.5, text: '第二行' }, { start: 1, text: '第一行' }], { translation: [{ start: 1, text: 'Line one' }, { start: 5.5, text: '' }] }), {
    format: 'lrc',
    body: '[00:01.00]第一行\n[00:05.50]第二行',
    translation: '[00:01.00]Line one',
  });
  const worded = lyricsOf([{ start: 1, text: 'a b', words: [{ start: 1, text: 'a ' }, { start: 2, text: 'b' }] }], { romanization: [{ start: 1, text: 'ei bi' }] });
  assert.equal(worded?.format, 'ttml');
  assert.equal(worded?.romanization, '[00:01.00]ei bi');
  assert.equal(lyricsOf([{ start: 1, text: '  ' }]), null);
  assert.equal(lyricsOf([]), null);
});

test('enhanced LRC times written into a line become its words', () => {
  assert.deepEqual(inlineWords('<00:01.00>Word <00:01.50>by <00:02.00>word'), {
    text: 'Word by word',
    words: [{ start: 1, text: 'Word ' }, { start: 1.5, text: 'by ' }, { start: 2, text: 'word' }],
  });
  assert.deepEqual(inlineWords('<01:04.00>逐<01:04.40>字<01:05.20>'), {
    text: '逐字',
    words: [{ start: 64, text: '逐' }, { start: 64.4, text: '字', end: 65.2 }],
  });
  assert.equal(inlineWords('no times here'), undefined);
});
