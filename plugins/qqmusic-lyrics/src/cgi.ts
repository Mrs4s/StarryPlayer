import { cgi } from './client';
import { randomInt, uuid } from './util';

export const songSearch = (query: string, page: number, perPage: number) =>
  cgi('music.search.SearchCgiService', 'DoSearchForQQMusicDesktop', {
    searchid: uuid() + String(randomInt(100_000)),
    search_type: 0,
    query,
    page_num: page,
    num_per_page: perPage,
    nqc_flag: 0,
    remoteplace: 'txt.mac.search',
    grp: 1,
  });

export const lyric = (songMID: string, songID = 0, title = '', duration = 0) =>
  cgi('music.musichallSong.PlayLyricInfo', 'GetPlayLyricInfo', {
    songMID,
    songID,
    songName: starry.encoding.base64.encode(title),
    singerName: '',
    albumName: '',
    interval: duration,
    crypt: 1,
    ct: 19,
    cv: 2111,
    type: 0,
    qrc: 1,
    qrc_t: 0,
    lrc_t: 0,
    trans: 1,
    trans_t: 0,
    roma: 1,
    roma_t: 0,
  });
