#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d StarryPlayer.xcodeproj ] || scripts/bootstrap.sh
xcodebuild -project StarryPlayer.xcodeproj -scheme StarryPlayer -configuration Debug \
  -derivedDataPath build/DerivedData SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO \
  build | tail -5
