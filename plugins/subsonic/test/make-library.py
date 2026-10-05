#!/usr/bin/env python3
"""The test library of the Subsonic plugin: make-library.py <dir> writes
<dir>/music with 16 songs of 60 s (one of 400 s) in five albums: MP3, AAC, ALAC, FLAC, 24/96 FLAC,
WAV, AIFF, Opus, Ogg Vorbis, WavPack, WMA; several artists (ID3v2.4 and Vorbis multi-values),
several genres, a compilation, an album without album artist, ReplayGain, an embedded cover;
lyrics as plain, enhanced and translated LRC beside the songs and in their tags, and a TXT.
Needs ffmpeg and mutagen (test-servers.sh makes a venv for it)."""
import os, subprocess, sys
from mutagen.id3 import ID3, TPE1, TPE2, TALB, TIT2, TRCK, TPOS, TDRC, TCON, TCMP, TXXX, USLT, APIC
from mutagen.flac import FLAC
from mutagen.mp4 import MP4, MP4FreeForm
from mutagen.oggopus import OggOpus
from mutagen.oggvorbis import OggVorbis
from mutagen.apev2 import APEv2
from mutagen.wave import WAVE
from mutagen.aiff import AIFF

root = os.path.abspath(sys.argv[1])
music = os.path.join(root, 'music')

def run(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args], check=True)

def cover(path, color):
    run('-f', 'lavfi', '-i', f'color=c={color}:s=600x600', '-frames:v', '1', path)

def tone(path, freq, seconds, rate, *codec):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    run('-f', 'lavfi', '-i', f'sine=frequency={freq}:sample_rate={rate}:duration={seconds}', '-ac', '2',
        '-map_metadata', '-1', *codec, path)

def vorbis_tags(f, t):
    for k, v in t.items():
        f[k] = v if isinstance(v, list) else [v]
    f.save()

def id3_tags(path, t, extra=()):
    container = WAVE(path) if path.endswith('.wav') else AIFF(path) if path.endswith('.aiff') else None
    if container is not None:
        container.add_tags()
    tags = container.tags if container is not None else ID3()
    tags.add(TIT2(encoding=3, text=t['title']))
    tags.add(TPE1(encoding=3, text=t['artist'] if isinstance(t['artist'], list) else [t['artist']]))
    if 'albumartist' in t: tags.add(TPE2(encoding=3, text=[t['albumartist']]))
    tags.add(TALB(encoding=3, text=[t['album']]))
    tags.add(TRCK(encoding=3, text=[str(t['track'])]))
    tags.add(TPOS(encoding=3, text=[str(t.get('disc', 1))]))
    tags.add(TDRC(encoding=3, text=[t['date']]))
    tags.add(TCON(encoding=3, text=t['genre'] if isinstance(t['genre'], list) else [t['genre']]))
    for frame in extra: tags.add(frame)
    if container is not None: container.save(v2_version=4)
    else: tags.save(path, v2_version=4)

def rg_vorbis(track, tpeak, album, apeak):
    return {'REPLAYGAIN_TRACK_GAIN': f'{track:.2f} dB', 'REPLAYGAIN_TRACK_PEAK': f'{tpeak:.6f}',
            'REPLAYGAIN_ALBUM_GAIN': f'{album:.2f} dB', 'REPLAYGAIN_ALBUM_PEAK': f'{apeak:.6f}'}

LRC_LINE = '[ar:测试歌手]\n[ti:MP3 歌曲]\n[offset:0]\n[00:01.00]第一行歌词\n[00:05.50]第二行歌词\n[00:10.00]第三行 third line\n'
LRC_WORD = '[00:01.00]<00:01.00>Word <00:01.50>by <00:02.00>word\n[00:04.00]<00:04.00>逐<00:04.40>字<00:04.80>歌<00:05.20>词\n'
LRC_TRANSLATED = ('[ti:晴天]\n[00:02.00]故事的小黄花\n[00:02.00]The little yellow flower of the story\n'
                  '[00:06.00]从出生那年就飘着\n[00:06.00]Has been floating since the year I was born\n')
LRC_EMBEDDED = '[00:01.00]嵌入的同步歌词\n[00:03.00]Embedded synced line\n'
TXT_EMBEDDED = '嵌入的纯文本歌词\n没有时间\n'

# Album A: one song per format.
A = os.path.join(music, '测试歌手', '格式测试专辑')
os.makedirs(A, exist_ok=True)
cover(os.path.join(A, 'cover.jpg'), '0x3366cc')
base = {'albumartist': '测试歌手', 'album': '格式测试专辑', 'date': '2024', 'genre': '华语流行'}

p = os.path.join(A, '01 MP3 歌曲.mp3'); tone(p, 330, 60, 44100, '-c:a', 'libmp3lame', '-b:a', '320k')
id3_tags(p, {**base, 'artist': '测试歌手', 'title': 'MP3 歌曲', 'track': 1},
         [TXXX(encoding=3, desc=k, text=[v]) for k, v in rg_vorbis(-6.5, 0.988, -7.0, 0.995).items()])
open(os.path.join(A, '01 MP3 歌曲.lrc'), 'w').write(LRC_LINE)

for name, freq, codec, track in [('02 AAC 歌曲.m4a', 350, ['-c:a', 'aac', '-b:a', '256k'], 2),
                                 ('03 ALAC 歌曲.m4a', 370, ['-c:a', 'alac'], 3)]:
    p = os.path.join(A, name); tone(p, freq, 60, 44100, *codec)
    m = MP4(p)
    m['\xa9nam'] = [name[3:-4]]; m['\xa9ART'] = ['测试歌手']; m['aART'] = ['测试歌手']; m['\xa9alb'] = ['格式测试专辑']
    m['trkn'] = [(track, 7)]; m['disk'] = [(1, 2)]; m['\xa9day'] = ['2024']; m['\xa9gen'] = ['华语流行']
    if track == 2:
        m['----:com.apple.iTunes:replaygain_track_gain'] = [MP4FreeForm(b'-5.20 dB')]
        m['----:com.apple.iTunes:replaygain_track_peak'] = [MP4FreeForm(b'0.950000')]
    m.save()

p = os.path.join(A, '04 FLAC 长歌.flac'); tone(p, 392, 400, 44100, '-c:a', 'flac')
vorbis_tags(FLAC(p), {**{k.upper(): v for k, v in base.items()}, 'ARTIST': '测试歌手', 'TITLE': 'FLAC 长歌', 'TRACKNUMBER': '4', 'DISCNUMBER': '1',
                      **rg_vorbis(-3.25, 0.891, -7.0, 0.995)})
open(os.path.join(A, '04 FLAC 长歌.lrc'), 'w').write(LRC_WORD)

p = os.path.join(A, '05 Hi-Res FLAC.flac'); tone(p, 415, 60, 96000, '-c:a', 'flac', '-sample_fmt', 's32')
vorbis_tags(FLAC(p), {**{k.upper(): v for k, v in base.items()}, 'ARTIST': '测试歌手', 'TITLE': 'Hi-Res FLAC', 'TRACKNUMBER': '5', 'DISCNUMBER': '1',
                      'LYRICS': LRC_TRANSLATED})

p = os.path.join(A, '06 WAV 歌曲.wav'); tone(p, 440, 60, 44100, '-c:a', 'pcm_s16le')
id3_tags(p, {**base, 'artist': '测试歌手', 'title': 'WAV 歌曲', 'track': 6})

p = os.path.join(A, '07 Opus 歌曲.opus'); tone(p, 466, 60, 48000, '-c:a', 'libopus', '-b:a', '160k')
vorbis_tags(OggOpus(p), {**{k.upper(): v for k, v in base.items()}, 'ARTIST': ['测试歌手', '合作歌手'], 'TITLE': 'Opus 歌曲',
                         'TRACKNUMBER': '1', 'DISCNUMBER': '2'})

# Album B: formats macOS cannot play, multi-valued genre.
B = os.path.join(music, 'Second Artist', 'Lossless Odds')
os.makedirs(B, exist_ok=True)
cover(os.path.join(B, 'folder.jpg'), '0xcc6633')
p = os.path.join(B, '01 WavPack Song.wv'); tone(p, 494, 60, 44100, '-c:a', 'wavpack')
ape = APEv2(); ape.update({'Title': 'WavPack Song', 'Artist': 'Second Artist', 'Album Artist': 'Second Artist', 'Album': 'Lossless Odds',
                           'Track': '1', 'Year': '2019', 'Genre': 'Rock'}); ape.save(p)
p = os.path.join(B, '02 AIFF Song.aiff'); tone(p, 523, 60, 44100, '-c:a', 'pcm_s16be')
id3_tags(p, {'artist': 'Second Artist', 'albumartist': 'Second Artist', 'album': 'Lossless Odds', 'title': 'AIFF Song', 'track': 2,
             'date': '2019', 'genre': 'Rock'})
open(os.path.join(B, '02 AIFF Song.txt'), 'w').write('Plain text lyric line one\nline two\n')
p = os.path.join(B, '03 WMA Song.wma'); tone(p, 554, 60, 44100, '-c:a', 'wmav2', '-b:a', '192k',
                                            '-metadata', 'title=WMA Song', '-metadata', 'artist=Second Artist',
                                            '-metadata', 'album_artist=Second Artist', '-metadata', 'album=Lossless Odds',
                                            '-metadata', 'track=3', '-metadata', 'date=2019', '-metadata', 'genre=Rock')
p = os.path.join(B, '04 Multi Genre.flac'); tone(p, 587, 60, 44100, '-c:a', 'flac')
vorbis_tags(FLAC(p), {'ARTIST': 'Second Artist', 'ALBUMARTIST': 'Second Artist', 'ALBUM': 'Lossless Odds', 'TITLE': 'Multi Genre',
                      'TRACKNUMBER': '4', 'DATE': '2019', 'GENRE': ['Rock', 'Alternative']})

# Album C: a compilation with multi-artist ID3v2.4 and embedded lyrics.
C = os.path.join(music, 'Various Artists', '华语金曲合辑')
p = os.path.join(C, '01 合唱.mp3'); tone(p, 622, 60, 44100, '-c:a', 'libmp3lame', '-b:a', '192k')
id3_tags(p, {'artist': ['歌手甲', '歌手乙'], 'albumartist': 'Various Artists', 'album': '华语金曲合辑', 'title': '合唱', 'track': 1,
             'date': '2010', 'genre': 'Jazz'}, [TCMP(encoding=3, text=['1']), USLT(encoding=3, lang='chi', desc='', text=TXT_EMBEDDED)])
p = os.path.join(C, '02 Vorbis 独唱.ogg'); tone(p, 659, 60, 44100, '-c:a', 'vorbis', '-strict', '-2')
vorbis_tags(OggVorbis(p), {'ARTIST': '歌手丙', 'ALBUMARTIST': 'Various Artists', 'ALBUM': '华语金曲合辑', 'TITLE': 'Vorbis 独唱',
                           'TRACKNUMBER': '2', 'DATE': '2010', 'GENRE': 'Jazz', 'COMPILATION': '1', 'LYRICS': LRC_WORD})

# Album D: embedded cover, translated sidecar LRC, synced lyrics in USLT.
D = os.path.join(music, '周杰伦', '叶惠美')
art = os.path.join(root, 'yhm.jpg'); cover(art, '0x228844')
for name, freq, title, track, extra in [('01 晴天.mp3', 698, '晴天', 1, []),
                                        ('02 以父之名.mp3', 740, '以父之名', 2, [USLT(encoding=3, lang='chi', desc='', text=LRC_EMBEDDED)])]:
    p = os.path.join(D, name); tone(p, freq, 60, 44100, '-c:a', 'libmp3lame', '-b:a', '256k')
    id3_tags(p, {'artist': '周杰伦', 'albumartist': '周杰伦', 'album': '叶惠美', 'title': title, 'track': track, 'date': '2003-07-31',
                 'genre': '华语流行'}, [APIC(encoding=3, mime='image/jpeg', type=3, desc='', data=open(art, 'rb').read()), *extra,
                                        *[TXXX(encoding=3, desc=k, text=[v]) for k, v in rg_vorbis(4.1, 0.5, 4.1, 0.5).items()]])
open(os.path.join(D, '01 晴天.lrc'), 'w').write(LRC_TRANSLATED.replace('[ti:晴天]\n', ''))

# Album E: no album artist tag.
E = os.path.join(music, 'Loose', 'Loose Tracks')
p = os.path.join(E, '01 Untagged Album Artist.mp3'); tone(p, 784, 60, 44100, '-c:a', 'libmp3lame', '-b:a', '128k')
id3_tags(p, {'artist': 'Solo Act', 'album': 'Loose Tracks', 'title': 'Untagged Album Artist', 'track': 1, 'date': '2021', 'genre': 'Pop'})
print('library:', music)
