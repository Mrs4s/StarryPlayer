#!/usr/bin/env python3
"""Builds a tag test corpus: raw audio from ffmpeg, tags written by hand so every byte is known.

    make-corpus.py <dir> [seconds]

`seconds` (default 8) is each file's length; the tests' fixtures are made with 1.
"""
import base64, os, struct, subprocess, sys

OUT = sys.argv[1]
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 8
os.makedirs(OUT, exist_ok=True)

def ff(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)

def sine(freq, secs=None, rate=44100):
    secs = SECONDS if secs is None else secs
    return ["-f", "lavfi", "-i", f"sine=frequency={freq}:sample_rate={rate}:duration={secs}", "-ac", "2"]

# Cover images
cover = os.path.join(OUT, "_cover.jpg")
ff("-f", "lavfi", "-i", "color=c=0x3366cc:s=500x500", "-frames:v", "1", cover)
COVER = open(cover, "rb").read()
png = os.path.join(OUT, "_cover.png")
ff("-f", "lavfi", "-i", "color=c=0xcc3366:s=300x300", "-frames:v", "1", png)

LRC = "[00:01.00]第一行歌词\n[00:03.50]第二行 second line\n[00:06.00]第三行"
PLAIN = "纯文本歌词第一行\n第二行"

# ---------- ID3v2 ----------
def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])

def enc_text(s, enc):
    if enc == 0: return s.encode("latin-1")
    if enc == 1: return b"\xff\xfe" + s.encode("utf-16-le")
    if enc == 3: return s.encode("utf-8")
    if enc == "gbk": return s.encode("gbk")
    raise ValueError(enc)

def term(enc):
    return b"\x00\x00" if enc == 1 else b"\x00"

def frame(fid, body, v):
    size = syncsafe(len(body)) if v == 4 else struct.pack(">I", len(body))
    return fid.encode() + size + b"\x00\x00" + body

def text_frame(fid, values, enc, v):
    e = 0 if enc == "gbk" else enc
    if isinstance(values, str): values = [values]
    sep = term(enc)
    body = bytes([e]) + sep.join(enc_text(x, enc) for x in values)
    return frame(fid, body, v)

def txxx(desc, value, enc, v):
    e = 0 if enc == "gbk" else enc
    return frame("TXXX", bytes([e]) + enc_text(desc, enc) + term(enc) + enc_text(value, enc), v)

def uslt(text, enc, v, lang=b"chi"):
    e = 0 if enc == "gbk" else enc
    return frame("USLT", bytes([e]) + lang + enc_text("", enc) + term(enc) + enc_text(text, enc), v)

def sylt(lines, enc, v):
    # timestamp format 2 = ms, content type 1 = lyrics
    e = 0 if enc == "gbk" else enc
    body = bytes([e]) + b"chi" + bytes([2, 1]) + enc_text("", enc) + term(enc)
    for ms, t in lines:
        body += enc_text(t, enc) + term(enc) + struct.pack(">I", ms)
    return frame("SYLT", body, v)

def apic(data, mime="image/jpeg", v=3):
    return frame("APIC", b"\x00" + mime.encode() + b"\x00" + b"\x03" + b"\x00" + data, v)

def id3(frames, v):
    body = b"".join(frames)
    pad = b"\x00" * 256
    return b"ID3" + bytes([v, 0, 0]) + syncsafe(len(body) + len(pad)) + body + pad

def id3v1(title, artist, album, year="2024", enc="gbk", track=3, genre=13):
    def f(s, n): b = s.encode(enc)[:n]; return b + b"\x00" * (n - len(b))
    return b"TAG" + f(title, 30) + f(artist, 30) + f(album, 30) + year.encode()[:4] + f("", 28) + b"\x00" + bytes([track, genre])

def raw_mp3(name, freq):
    p = os.path.join(OUT, name + ".raw.mp3")
    ff(*sine(freq), "-c:a", "libmp3lame", "-b:a", "192k", "-write_xing", "1", "-id3v2_version", "0", "-write_id3v1", "0", p)
    data = open(p, "rb").read(); os.remove(p); return data

def write(name, data):
    open(os.path.join(OUT, name), "wb").write(data)

# 1. ID3v2.4 UTF-8, multi-value TPE1 (null separated), full set of frames
v = 4; e = 3
write("01 v24 utf8.mp3", id3([
    text_frame("TIT2", "测试标题 v2.4", e, v),
    text_frame("TPE1", ["歌手甲", "Singer B"], e, v),
    text_frame("TPE2", "专辑歌手", e, v),
    text_frame("TALB", "测试专辑", e, v),
    text_frame("TRCK", "3/12", e, v),
    text_frame("TPOS", "1/2", e, v),
    text_frame("TDRC", "2021-05-20", e, v),
    text_frame("TCON", "Pop", e, v),
    text_frame("TCMP", "1", e, v),
    text_frame("TSOP", "geshou jia", e, v),
    text_frame("TCOM", "作曲者", e, v),
    txxx("REPLAYGAIN_TRACK_GAIN", "-7.50 dB", e, v),
    txxx("MusicBrainz Album Id", "0f3f2f6e-1111-2222-3333-444455556666", e, v),
    txxx("ARTISTS", "歌手甲", e, v),
    uslt(LRC, e, v),
    sylt([(1000, "同步第一行"), (3500, "同步第二行")], e, v),
    apic(COVER, v=v),
], v) + raw_mp3("a", 330))

# 2. ID3v2.3 UTF-16 with BOM, artists joined by "/"
v = 3; e = 1
write("02 v23 utf16.mp3", id3([
    text_frame("TIT2", "测试标题 v2.3", e, v),
    text_frame("TPE1", "歌手甲/歌手乙", e, v),
    text_frame("TALB", "测试专辑", e, v),
    text_frame("TRCK", "4", e, v),
    text_frame("TYER", "2021", e, v),
    text_frame("TCON", "(13)", e, v),
    uslt(PLAIN, e, v),
    apic(COVER, v=v),
], v) + raw_mp3("b", 350))

# 3. ID3v2.3 with GBK bytes declared as ISO-8859-1 (common in old Chinese rips)
v = 3; e = "gbk"
write("03 v23 gbk.mp3", id3([
    text_frame("TIT2", "国标编码标题", e, v),
    text_frame("TPE1", "周杰伦", e, v),
    text_frame("TALB", "叶惠美", e, v),
    text_frame("TRCK", "5", e, v),
], v) + raw_mp3("c", 370))

# 4. Only ID3v1, GBK
write("04 v1 gbk.mp3", raw_mp3("d", 392) + id3v1("只有一版标签", "陈奕迅", "十年"))

# 5. No tags at all; file name carries the info
write("05 林俊杰 - 江南.mp3", raw_mp3("e", 415))

# ---------- FLAC (rewrite metadata blocks) ----------
def flac_blocks(data):
    assert data[:4] == b"fLaC"
    pos = 4; blocks = []
    while True:
        hdr = data[pos]; last = hdr & 0x80; typ = hdr & 0x7F
        ln = int.from_bytes(data[pos + 1:pos + 4], "big")
        blocks.append((typ, data[pos + 4:pos + 4 + ln])); pos += 4 + ln
        if last: break
    return blocks, data[pos:]

def vorbis_comment(fields, vendor="starry test"):
    v = vendor.encode()
    out = struct.pack("<I", len(v)) + v + struct.pack("<I", len(fields))
    for k, val in fields:
        s = f"{k}={val}".encode("utf-8")
        out += struct.pack("<I", len(s)) + s
    return out

def picture_block(data, mime="image/jpeg", w=500, h=500, ptype=3):
    m = mime.encode()
    return struct.pack(">I", ptype) + struct.pack(">I", len(m)) + m + struct.pack(">I", 0) + struct.pack(">IIII", w, h, 24, 0) + struct.pack(">I", len(data)) + data

def build_flac(src, fields, pictures=(), prefix=b""):
    blocks, audio = flac_blocks(open(src, "rb").read())
    keep = [(t, b) for t, b in blocks if t not in (1, 4, 6)]  # drop padding, comments, pictures
    keep.insert(1, (4, vorbis_comment(fields)))
    for p in pictures: keep.append((6, p))
    keep.append((1, b"\x00" * 512))
    out = b"fLaC"
    for i, (t, b) in enumerate(keep):
        out += bytes([(0x80 if i == len(keep) - 1 else 0) | t]) + len(b).to_bytes(3, "big") + b
    return prefix + out + audio

tmp = os.path.join(OUT, "_raw.flac")
ff(*sine(440, rate=96000), "-c:a", "flac", "-sample_fmt", "s32", tmp)
write("06 flac multi.flac", build_flac(tmp, [
    ("TITLE", "FLAC 多值"), ("ARTIST", "歌手甲"), ("ARTIST", "Singer B"), ("ALBUMARTIST", "Various Artists"),
    ("ALBUM", "合辑测试"), ("TRACKNUMBER", "7"), ("TRACKTOTAL", "15"), ("DISCNUMBER", "2"), ("DISCTOTAL", "2"),
    ("DATE", "2019"), ("GENRE", "Rock"), ("GENRE", "Live"), ("COMPILATION", "1"), ("LYRICS", LRC),
    ("UNSYNCEDLYRICS", PLAIN), ("REPLAYGAIN_TRACK_GAIN", "-6.20 dB"), ("REPLAYGAIN_ALBUM_GAIN", "-7.00 dB"),
    ("MUSICBRAINZ_TRACKID", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), ("ARTISTSORT", "geshou"),
], [picture_block(COVER)]))
os.remove(tmp)

tmp = os.path.join(OUT, "_raw2.flac")
ff(*sine(466), "-c:a", "flac", tmp)
write("07 flac id3 prefix.flac", build_flac(tmp, [("TITLE", "FLAC 带 ID3 头"), ("ARTIST", "某歌手")],
    prefix=id3([text_frame("TIT2", "ID3 里的标题", 1, 3)], 3)))
os.remove(tmp)

# ---------- MP4 ----------
ff(*sine(494), "-i", cover, "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-b:a", "256k", "-c:v", "copy", "-disposition:v", "attached_pic",
   "-metadata", "title=AAC 标题", "-metadata", "artist=歌手甲 & 歌手乙", "-metadata", "album_artist=歌手甲", "-metadata", "album=M4A 专辑",
   "-metadata", "track=2/9", "-metadata", "disc=1/1", "-metadata", "date=2020", "-metadata", "genre=Jazz",
   "-metadata", "compilation=1", "-metadata", "lyrics=" + LRC, "-metadata", "sort_artist=gsj",
   os.path.join(OUT, "08 aac.m4a"))
ff(*sine(523, rate=96000), "-c:a", "alac", "-sample_fmt", "s32p",
   "-metadata", "title=ALAC 24-96", "-metadata", "artist=无损歌手", "-metadata", "album=ALAC 专辑", "-metadata", "track=1",
   os.path.join(OUT, "09 alac 24-96.m4a"))

# ---------- Ogg family ----------
mbp = base64.b64encode(picture_block(COVER)).decode()
ff(*sine(554), "-c:a", "vorbis", "-strict", "-2", "-q:a", "5",
   "-metadata", "title=Vorbis 标题", "-metadata", "artist=歌手甲", "-metadata", "album=Ogg 专辑",
   "-metadata", "tracknumber=1", "-metadata", "lyrics=" + LRC, "-metadata", "METADATA_BLOCK_PICTURE=" + mbp,
   os.path.join(OUT, "10 vorbis.ogg"))
ff(*sine(587, rate=48000), "-c:a", "libopus", "-b:a", "128k",
   "-metadata", "title=Opus 标题", "-metadata", "artist=歌手甲;歌手乙", "-metadata", "album=Opus 专辑", "-metadata", "tracknumber=2",
   os.path.join(OUT, "11 opus.opus"))

# ---------- Others ----------
ff(*sine(622), "-c:a", "wavpack", "-metadata", "title=WavPack 标题", "-metadata", "artist=歌手甲", "-metadata", "album=WV 专辑",
   "-metadata", "track=1", os.path.join(OUT, "12 wavpack.wv"))
ff(*sine(659), "-c:a", "pcm_s24le", "-metadata", "title=WAV 标题", "-metadata", "artist=歌手甲", "-metadata", "album=WAV 专辑",
   os.path.join(OUT, "13 wav info.wav"))
ff(*sine(698), "-i", cover, "-map", "0:a", "-map", "1:v", "-c:a", "pcm_s16be", "-c:v", "copy", "-write_id3v2", "1", "-id3v2_version", "3",
   "-metadata", "title=AIFF 标题", "-metadata", "artist=歌手甲", "-metadata", "album=AIFF 专辑", "-metadata", "track=1",
   os.path.join(OUT, "14 aiff id3.aiff"))
ff(*sine(740), "-c:a", "wmav2", "-b:a", "192k", "-metadata", "title=WMA 标题", "-metadata", "artist=歌手甲", "-metadata", "album=WMA 专辑",
   os.path.join(OUT, "15 wma.wma"))
ff(*sine(784), "-c:a", "tta", "-metadata", "title=TTA 标题", os.path.join(OUT, "16 tta.tta"))
ff(*sine(831), "-c:a", "ac3", "-b:a", "192k", os.path.join(OUT, "17 ac3.ac3"))
ff(*sine(880), "-c:a", "aac", "-b:a", "128k", os.path.join(OUT, "18 adts.aac"))
ff(*sine(932), "-c:a", "pcm_s16le", "-f", "caf", os.path.join(OUT, "19 pcm.caf"))
ff(*sine(988), "-c:a", "libopus", "-b:a", "96k", "-f", "caf", os.path.join(OUT, "20 opus.caf"))
ff(*sine(1047), "-c:a", "flac", "-f", "mp4", "-strict", "-2", os.path.join(OUT, "21 flac-in-mp4.m4a"))
ff(*sine(1109), "-c:a", "flac", "-f", "ogg", os.path.join(OUT, "22 flac-in-ogg.oga"))

# APEv2 only, as foobar2000 tags MP3s.
items = [("Title", "APE 标题"), ("Artist", "歌手甲"), ("Album", "APE 专辑"), ("Track", "2"), ("Lyrics", "[00:01.00]APE 歌词")]
ape_body = b""
for k, v in items:
    vb = v.encode("utf-8")
    ape_body += struct.pack("<II", len(vb), 0) + k.encode() + b"\x00" + vb
def ape_header(is_header):
    flags = (1 << 31) | ((1 << 29) if is_header else 0)
    return b"APETAGEX" + struct.pack("<IIII", 2000, len(ape_body) + 32, len(items), flags) + b"\x00" * 8
write("23 ape only.mp3", raw_mp3("f", 440) + ape_header(True) + ape_body + ape_header(False))

# VBR without a Xing header whose bit rate changes halfway (noise, then a sine): the length
# AVFoundation estimates from the first frames is short.
half = max(SECONDS, 2)
ff("-f", "lavfi", "-i", f"anoisesrc=d={half}:c=pink:a=0.3", "-f", "lavfi", "-i", f"sine=frequency=300:duration={half}",
   "-filter_complex", "[0][1]concat=n=2:v=0:a=1", "-ac", "2", "-c:a", "libmp3lame", "-q:a", "2", "-write_xing", "0",
   "-id3v2_version", "0", os.path.join(OUT, "24 vbr no-xing.mp3"))

# Sidecars
open(os.path.join(OUT, "05 林俊杰 - 江南.lrc"), "w", encoding="gbk").write("[00:01.00]GBK 外挂歌词\n")
os.remove(cover)
print("ok")
