#!/usr/bin/env bash
# Requires XcodeGen. Uses project.local.yml when present; `--spec` overrides it.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found; install with: brew install xcodegen" >&2
  exit 1
fi
spec=project.yml
[ -f project.local.yml ] && spec=project.local.yml
if [ "${1:-}" = "--spec" ]; then spec=$2; fi
xcodegen generate --spec "$spec" --project .
echo "Generated StarryPlayer.xcodeproj from $spec — open it with: open StarryPlayer.xcodeproj"
