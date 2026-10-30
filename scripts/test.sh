#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-plugins.sh
cd Packages/StarryKit
swift test "$@"
