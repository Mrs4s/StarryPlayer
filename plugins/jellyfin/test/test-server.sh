#!/bin/bash
# A Jellyfin server to test the plugin against, in Docker on 127.0.0.1:
#   plugins/jellyfin/test/test-server.sh <directory> [port 18096] [container starry-jellyfin-test]
# <directory> gets the test library (music/: ten songs of 60 s in MP3, AAC, ALAC, FLAC, 24/96 FLAC,
# WAV, Opus, WavPack, AIFF, WMA, one of 400 s; a plain LRC, an enhanced LRC, a TXT; two covers),
# and the server's config/ and cache/. The setup wizard is done for you: the administrator is
# admin / starry, the library is "Music" (with LUFS scanning, its loudness measured), and a second
# user family / pw has a password.
# Then: JELLYFIN_LIVE=127.0.0.1:<port> JELLYFIN_USER=family JELLYFIN_PASSWORD=pw swift test --filter JellyfinPluginLive
# Needs docker and ffmpeg. Stop it with `docker stop <container>`; start it again with `docker start`.
set -euo pipefail

DIR=${1:?usage: test-server.sh <directory> [port] [container]}
PORT=${2:-18096}
NAME=${3:-starry-jellyfin-test}
J="http://127.0.0.1:$PORT"
JSON='Content-Type: application/json'
DEVICE='MediaBrowser Client="StarryTest", Device="Mac", DeviceId="starry-test-server", Version="1"'

mkdir -p "$DIR/config" "$DIR/cache"
DIR=$(cd "$DIR" && pwd)

if [ ! -d "$DIR/music" ]; then
  A="$DIR/music/测试歌手/格式测试专辑"
  B="$DIR/music/Second Artist/Lossless Odds"
  mkdir -p "$A" "$B"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0x3366cc:s=600x600" -frames:v 1 "$A/cover.jpg"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0xcc6633:s=600x600" -frames:v 1 "$B/folder.jpg"
  # frequency seconds sample-rate file artist album-artist album title track disc codec-arguments…
  song() {
    local frequency=$1 seconds=$2 rate=$3 file=$4 artist=$5 albumArtist=$6 album=$7 title=$8 track=$9 disc=${10}
    shift 10
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=$frequency:sample_rate=$rate:duration=$seconds" -ac 2 \
      -metadata "artist=$artist" -metadata "album_artist=$albumArtist" -metadata "album=$album" -metadata "title=$title" \
      -metadata "track=$track" -metadata "disc=$disc" -metadata "date=2024" -metadata "genre=Test" "$@" "$file"
  }
  song 330 60 44100 "$A/01 MP3 歌曲.mp3" 测试歌手 测试歌手 格式测试专辑 "MP3 歌曲" 1 1 -c:a libmp3lame -b:a 320k
  song 350 60 44100 "$A/02 AAC 歌曲.m4a" 测试歌手 测试歌手 格式测试专辑 "AAC 歌曲" 2 1 -c:a aac -b:a 256k
  song 370 60 44100 "$A/03 ALAC 歌曲.m4a" 测试歌手 测试歌手 格式测试专辑 "ALAC 歌曲" 3 1 -c:a alac
  song 392 400 44100 "$A/04 FLAC 长歌.flac" 测试歌手 测试歌手 格式测试专辑 "FLAC 长歌" 4 1 -c:a flac
  song 415 60 96000 "$A/05 Hi-Res FLAC.flac" 测试歌手 测试歌手 格式测试专辑 "Hi-Res FLAC" 5 1 -c:a flac -sample_fmt s32
  song 440 60 44100 "$A/06 WAV 歌曲.wav" 测试歌手 测试歌手 格式测试专辑 "WAV 歌曲" 6 1 -c:a pcm_s16le
  song 466 60 48000 "$A/07 Opus 歌曲.opus" "测试歌手; 合作歌手" 测试歌手 格式测试专辑 "Opus 歌曲" 1 2 -c:a libopus -b:a 160k
  song 494 60 44100 "$B/01 WavPack Song.wv" "Second Artist" "Second Artist" "Lossless Odds" "WavPack Song" 1 1 -c:a wavpack
  song 523 60 44100 "$B/02 AIFF Song.aiff" "Second Artist" "Second Artist" "Lossless Odds" "AIFF Song" 2 1 -c:a pcm_s16be -write_id3v2 1
  song 554 60 44100 "$B/03 WMA Song.wma" "Second Artist" "Second Artist" "Lossless Odds" "WMA Song" 3 1 -c:a wmav2 -b:a 192k
  printf '[ar:测试歌手]\n[ti:MP3 歌曲]\n[offset:0]\n[00:01.00]第一行歌词\n[00:05.50]第二行歌词\n[00:10.00]第三行 third line\n' > "$A/01 MP3 歌曲.lrc"
  printf '[00:01.00]<00:01.00>Word <00:01.50>by <00:02.00>word\n[00:04.00]<00:04.00>逐<00:04.40>字<00:04.80>歌<00:05.20>词\n' > "$A/04 FLAC 长歌.lrc"
  printf 'Plain text lyric line one\nline two\n' > "$B/02 AIFF Song.txt"
  echo "library: $DIR/music"
fi

if [ -z "$(docker ps -aq --filter "name=^$NAME\$")" ]; then
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8096" -v "$DIR/config:/config" -v "$DIR/cache:/cache" -v "$DIR/music:/music:ro" jellyfin/jellyfin:latest > /dev/null
else
  docker start "$NAME" > /dev/null
fi
for _ in $(seq 1 60); do
  info=$(curl -s -m 2 "$J/System/Info/Public" || true)
  case "$info" in \{*) break ;; esac
  sleep 2
done
echo "server: $info"

if echo "$info" | grep -q '"StartupWizardCompleted":false'; then
  curl -sf -o /dev/null -X POST "$J/Startup/Configuration" -H "$JSON" -d '{"UICulture":"zh-CN","MetadataCountryCode":"CN","PreferredMetadataLanguage":"zh"}'
  curl -sf -o /dev/null "$J/Startup/User"
  curl -sf -o /dev/null -X POST "$J/Startup/User" -H "$JSON" -d '{"Name":"admin","Password":"starry"}'
  curl -sf -o /dev/null -X POST "$J/Startup/RemoteAccess" -H "$JSON" -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
  curl -sf -o /dev/null -X POST "$J/Startup/Complete"
  token=$(curl -sf -X POST "$J/Users/AuthenticateByName" -H "$JSON" -H "Authorization: $DEVICE" -d '{"Username":"admin","Pw":"starry"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["AccessToken"])')
  ADMIN="$DEVICE, Token=\"$token\""
  curl -sf -o /dev/null -X POST "$J/Library/VirtualFolders?name=Music&collectionType=music&paths=%2Fmusic&refreshLibrary=true" -H "Authorization: $ADMIN" -H "$JSON" \
    -d '{"LibraryOptions":{"EnableRealtimeMonitor":false,"EnableLUFSScan":true,"PathInfos":[{"Path":"/music"}]}}'
  curl -sf -o /dev/null -X POST "$J/Users/New" -H "Authorization: $ADMIN" -H "$JSON" -d '{"Name":"family","Password":"pw"}'
  for _ in $(seq 1 60); do
    count=$(curl -s "$J/Items?Recursive=true&IncludeItemTypes=Audio&Limit=0" -H "Authorization: $ADMIN" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("TotalRecordCount", 0))' || echo 0)
    [ "$count" -ge 10 ] && break
    sleep 2
  done
  # The songs are listed before their tags are read: wait for the scan to end.
  for _ in $(seq 1 60); do
    status=$(curl -s "$J/Library/VirtualFolders" -H "Authorization: $ADMIN" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0].get("RefreshStatus"))')
    [ "$status" = Idle ] && break
    sleep 2
  done
  # The audio normalization task runs once a day: now, so the songs and albums have their NormalizationGain.
  task=$(curl -s "$J/ScheduledTasks" -H "Authorization: $ADMIN" | python3 -c 'import json, sys; print(next(t["Id"] for t in json.load(sys.stdin) if t.get("Key") == "AudioNormalization"))')
  curl -sf -o /dev/null -X POST "$J/ScheduledTasks/Running/$task" -H "Authorization: $ADMIN"
  for _ in $(seq 1 60); do
    sleep 2
    state=$(curl -s "$J/ScheduledTasks/$task" -H "Authorization: $ADMIN" | python3 -c 'import json, sys; print(json.load(sys.stdin)["State"])')
    [ "$state" = Idle ] && break
  done
  echo "set up: admin / starry, family / pw, $count songs"
fi
echo "ready: $J"
