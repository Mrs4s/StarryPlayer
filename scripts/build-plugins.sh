#!/usr/bin/env bash
# Builds the plugins the app comes with from their TypeScript projects in plugins/, minified, to
# build/plugins/<name>.js. `scripts/build-plugins.sh <dir>` then copies them into <dir> as well:
# the Xcode build runs it with the app's Resources/builtin. Installs a project's npm packages
# first when it has none yet (or its package-lock.json changed).
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGINS=(netease jellyfin subsonic qqmusic-lyrics kugou-lyrics)
OUT=build/plugins

# Xcode runs build phases with a bare PATH; look where Homebrew puts Node too.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm not found; the built-in plugins are built with Node.js (brew install node)" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
for name in "${PLUGINS[@]}"; do
  project=plugins/$name
  if [ ! -d "$project/node_modules" ] || [ "$project/package-lock.json" -nt "$project/node_modules/.package-lock.json" ]; then
    (cd "$project" && npm ci --no-audit --no-fund --loglevel=error)
  fi
  (cd "$project" && npm run --silent build)
  [ -f "$OUT/$name.js" ] || { echo "error: $project did not build $OUT/$name.js" >&2; exit 1; }
done

# Only these files are replaced there: other build phases may add plugins of their own.
if [ $# -gt 0 ]; then
  mkdir -p "$1"
  for name in "${PLUGINS[@]}"; do cp "$OUT/$name.js" "$1/"; done
fi
