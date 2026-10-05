#!/usr/bin/env bash
# Runs the StarryKit package tests, after building the built-in plugins they load.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-plugins.sh
cd Packages/StarryKit
swift test "$@"
