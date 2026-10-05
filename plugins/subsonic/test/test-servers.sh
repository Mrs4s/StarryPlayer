#!/bin/bash
# Subsonic servers to test the plugin against, in Docker on 127.0.0.1:
#   plugins/subsonic/test/test-servers.sh <directory> [navidrome] [gonic] [airsonic] [lms]   (all four when none is named)
# <directory> gets the test library (music/, from make-library.py) and each server's data. Then:
#   Navidrome 0.64   http://127.0.0.1:14533   admin / starry, family / pw
#   gonic 0.22       http://127.0.0.1:14747   admin / admin
#   Airsonic-Adv. 11 http://127.0.0.1:14040   admin / admin, family / pw (a new user: no tokens, the password goes as enc:)
#   LMS 3.81         http://127.0.0.1:15082   its first administrator is made on its web page (steps printed below)
#   SUBSONIC_LIVE=127.0.0.1:14533 SUBSONIC_USER=family SUBSONIC_PASSWORD=pw swift test --filter SubsonicPluginLive
# Needs docker, ffmpeg and python3 (mutagen goes in <directory>/.venv). Stop them with
# `docker stop starry-subsonic-<name>`, start them again with `docker start`.
set -euo pipefail

DIR=${1:?usage: test-servers.sh <directory> [navidrome] [gonic] [airsonic] [lms]}
shift
SERVERS=${*:-navidrome gonic airsonic lms}
mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)

if [ ! -d "$DIR/music" ]; then
  [ -x "$DIR/.venv/bin/python" ] || python3 -m venv "$DIR/.venv"
  "$DIR/.venv/bin/pip" install -q --disable-pip-version-check mutagen
  "$DIR/.venv/bin/python" "$HERE/make-library.py" "$DIR"
fi

# Runs the container `name` unless it exists (then starts it).
container() {
  local name=$1
  shift
  if [ -z "$(docker ps -aq --filter "name=^$name\$")" ]; then
    docker run -d --name "$name" "$@" > /dev/null
  else
    docker start "$name" > /dev/null
  fi
}

# Waits for a `ping` without credentials to answer as Subsonic.
wait_for() {
  for _ in $(seq 1 60); do
    curl -s -m 2 "$1/rest/ping?v=1.16.1&c=test&f=json" | grep -q subsonic-response && return 0
    sleep 2
  done
  echo "no answer from $1" >&2
  return 1
}

ping_as() {
  curl -s "$1/rest/ping?v=$4&c=test&f=json&u=$2&p=$3" | grep -q '"status":"ok"\|"status" : "ok"'
}

for server in $SERVERS; do
  case $server in
  navidrome)
    mkdir -p "$DIR/navidrome"
    container starry-subsonic-navidrome -p 127.0.0.1:14533:4533 -e ND_ENABLEINSIGHTSCOLLECTOR=false -v "$DIR/navidrome:/data" -v "$DIR/music:/music:ro" deluan/navidrome:latest
    N=http://127.0.0.1:14533
    wait_for $N
    if ! ping_as $N family pw 1.16.1; then
      token=$(curl -sf -X POST $N/auth/createAdmin -H 'Content-Type: application/json' -d '{"username":"admin","password":"starry"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')
      curl -sf -o /dev/null -X POST $N/api/user -H "x-nd-authorization: Bearer $token" -H 'Content-Type: application/json' -d '{"userName":"family","name":"Family","password":"pw","isAdmin":false}'
    fi
    echo "navidrome: $N (admin / starry, family / pw)"
    ;;
  gonic)
    mkdir -p "$DIR/gonic/data" "$DIR/gonic/cache" "$DIR/gonic/podcasts" "$DIR/gonic/playlists"
    container starry-subsonic-gonic -p 127.0.0.1:14747:80 -e GONIC_SCAN_AT_START_ENABLED=true -e GONIC_MUSIC_PATH=/music \
      -e GONIC_PODCAST_PATH=/podcasts -e GONIC_PLAYLISTS_PATH=/playlists -e GONIC_CACHE_PATH=/cache \
      -v "$DIR/gonic/data:/data" -v "$DIR/gonic/cache:/cache" -v "$DIR/gonic/podcasts:/podcasts" -v "$DIR/gonic/playlists:/playlists" -v "$DIR/music:/music:ro" sentriz/gonic:latest
    wait_for http://127.0.0.1:14747
    echo "gonic: http://127.0.0.1:14747 (admin / admin)"
    ;;
  airsonic)
    mkdir -p "$DIR/airsonic"
    container starry-subsonic-airsonic -p 127.0.0.1:14040:4040 -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ=Asia/Shanghai \
      -v "$DIR/airsonic:/config" -v "$DIR/music:/music:ro" lscr.io/linuxserver/airsonic-advanced:latest
    A=http://127.0.0.1:14040
    wait_for $A
    if ! ping_as $A family pw 1.15.0; then
      curl -sf -o /dev/null "$A/rest/startScan?u=admin&p=admin&v=1.15.0&c=test&f=json"
      for _ in $(seq 1 60); do
        sleep 2
        curl -s "$A/rest/getScanStatus?u=admin&p=admin&v=1.15.0&c=test&f=json" | grep -q '"scanning" : false' && break
      done
      curl -sf -o /dev/null "$A/rest/createUser?u=admin&p=admin&v=1.15.0&c=test&f=json&username=family&password=pw&email=family@example.com&streamRole=true&playlistRole=true"
    fi
    echo "airsonic-advanced: $A (admin / admin, family / pw)"
    ;;
  lms)
    mkdir -p "$DIR/lms"
    container starry-subsonic-lms -p 127.0.0.1:15082:5082 -v "$DIR/lms:/var/lms" -v "$DIR/music:/music:ro" epoupon/lms:latest
    wait_for http://127.0.0.1:15082
    cat <<'STEPS'
lms: http://127.0.0.1:15082 — the first time, in a browser:
  1. create the administrator (admin and a password of your choice);
  2. Administration › Music libraries › Add: name Music, root directory /music;
  3. Administration › Scanner › Scan now;
  4. User › Subsonic API › Generate: the API key is the password for the plugin (user admin).
STEPS
    ;;
  *)
    echo "unknown server: $server" >&2
    exit 1
    ;;
  esac
done
