#!/usr/bin/env python3
"""A small, realistic local library for trying the app: albums with covers, discs, a compilation,
GBK tags, an untagged file, lyric files."""
import os, struct, subprocess, sys
OUT = sys.argv[1]
SECS = 20
def ff(*a): subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *a], check=True)
def syncsafe(n): return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
def frame(fid, body): return fid.encode() + struct.pack(">I", len(body)) + b"\x00\x00" + body
def text(fid, s, gbk=False):
    return frame(fid, b"\x00" + s.encode("gbk")) if gbk else frame(fid, b"\x01\xff\xfe" + s.encode("utf-16-le"))
def apic(data): return frame("APIC", b"\x00image/jpeg\x00\x03\x00" + data)
def id3(frames):
    body = b"".join(frames) + b"\x00" * 512
    return b"ID3\x03\x00\x00" + syncsafe(len(body)) + body
def cover(color, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ff("-f", "lavfi", "-i", f"color=c={color}:s=600x600", "-f", "lavfi", "-i", "color=c=white@0.4:s=300x300", "-filter_complex", "[0][1]overlay=150:150", "-frames:v", "1", path)
    return open(path, "rb").read()
def mp3(path, freq, frames):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    raw = path + ".raw.mp3"
    ff("-f", "lavfi", "-i", f"sine=frequency={freq}:duration={SECS}", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "0", "-write_id3v1", "0", raw)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(id3(frames) + open(raw, "rb").read())
    os.remove(raw)
def song(path, title, artist, album, track, freq, art=None, albumartist=None, gbk=False, disc=None):
    frames = [text("TIT2", title, gbk), text("TPE1", artist, gbk), text("TALB", album, gbk), text("TRCK", str(track))]
    if albumartist: frames.append(text("TPE2", albumartist, gbk))
    if disc: frames.append(text("TPOS", str(disc)))
    frames.append(text("TYER", "2003"))
    if art: frames.append(apic(art))
    mp3(os.path.join(OUT, path), freq, frames)

os.makedirs(OUT, exist_ok=True)
tmp = os.path.join(OUT, "_c.jpg")
blue = cover("0x2f6fd6", tmp)
for i, t in enumerate(["以父之名", "懦夫", "晴天", "三年二班", "东风破"]):
    song(f"周杰伦/叶惠美/{i+1:02d} {t}.mp3", t, "周杰伦", "叶惠美", i + 1, 300 + i * 40, art=blue)
open(os.path.join(OUT, "周杰伦/叶惠美/03 晴天.lrc"), "w", encoding="gbk").write(
    "[ti:晴天]\n[00:00.50]外挂歌词第一行\n[00:03.00]这是 GBK 编码的文件\n[00:06.00]窗外的云慢慢飘过\n[00:09.00]午后的阳光照进来\n[00:12.00]Do Re Mi Fa So La Si\n[00:15.00]最后一行\n")
# Folder picture, no embedded art.
os.makedirs(os.path.join(OUT, "陈奕迅/U87"), exist_ok=True)
cover("0xd6532f", os.path.join(OUT, "陈奕迅/U87/cover.jpg"))
for i, t in enumerate(["浮夸", "爱情转移", "阿怪"]):
    song(f"陈奕迅/U87/{i+1:02d} {t}.mp3", t, "陈奕迅", "U87", i + 1, 500 + i * 30)
# GBK tags.
for i, t in enumerate(["江南", "美人鱼"]):
    song(f"林俊杰/第二天堂/{i+1:02d}.mp3", t, "林俊杰", "第二天堂", i + 1, 600 + i * 30, gbk=True)
# Two discs.
green = cover("0x2fae6b", tmp)
song("Band/Double Album/CD1/01 Opening.mp3", "Opening", "The Band", "Double Album", 1, 700, art=green, disc=None)
song("Band/Double Album/CD1/02 Middle.mp3", "Middle", "The Band", "Double Album", 2, 720, art=green)
song("Band/Double Album/CD2/01 Closing.mp3", "Closing", "The Band", "Double Album", 1, 740, art=green)
# A compilation.
purple = cover("0x7a3fd6", tmp)
for i, (t, a) in enumerate([("夜空中最亮的星", "逃跑计划"), ("平凡之路", "朴树"), ("成都", "赵雷")]):
    song(f"合辑/华语金曲/{i+1:02d}.mp3", t, a, "华语金曲", i + 1, 800 + i * 30, art=purple)
# Featuring and a slash.
song("单曲/周杰伦 费玉清 - 千里之外.mp3", "千里之外", "周杰伦/费玉清", "依然范特西", 3, 900, art=blue)
# Untagged.
raw = os.path.join(OUT, "单曲/未整理/03 五月天 - 倔强.mp3")
os.makedirs(os.path.dirname(raw), exist_ok=True)
ff("-f", "lavfi", "-i", f"sine=frequency=950:duration={SECS}", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "0", "-write_id3v1", "0", raw)
# Lossless.
gold = cover("0xd6a62f", os.path.join(OUT, "Hi-Res/Studio/folder.jpg"))
for i, t in enumerate(["Morning", "Evening"]):
    p = os.path.join(OUT, f"Hi-Res/Studio/{i+1:02d} {t}.flac")
    ff("-f", "lavfi", "-i", f"sine=frequency={1000 + i * 50}:sample_rate=96000:duration={SECS}", "-ac", "2", "-c:a", "flac", "-sample_fmt", "s32",
       "-metadata", f"title={t}", "-metadata", "artist=Quartet", "-metadata", "album=Studio", "-metadata", f"tracknumber={i+1}", "-metadata", "date=2022", "-metadata", "genre=Classical", p)
p = os.path.join(OUT, "M4A/Album/01 Track.m4a")
os.makedirs(os.path.dirname(p), exist_ok=True)
ff("-f", "lavfi", "-i", f"sine=frequency=1100:duration={SECS}", "-ac", "2", "-c:a", "aac", "-b:a", "256k", "-metadata", "title=AAC Track", "-metadata", "artist=Someone", "-metadata", "album=Album M4A", "-metadata", "track=1", p)
# Something the system cannot play.
ff("-f", "lavfi", "-i", "sine=frequency=1200:duration=2", "-c:a", "wavpack", os.path.join(OUT, "M4A/Album/02 skipped.wv"))
os.remove(tmp)
print("ok")
