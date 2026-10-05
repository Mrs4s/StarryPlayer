#!/usr/bin/env bash
# Builds separate arm64 and x86_64 ad-hoc-signed ZIP and DMG releases in build/dist.
# `scripts/package.sh arm64` builds one architecture only (the release workflow builds each on its own).
# Not notarized; other Macs require Gatekeeper approval on first launch.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=("$@")
[ ${#ARCHS[@]} -gt 0 ] || ARCHS=(arm64 x86_64)
for ARCH in "${ARCHS[@]}"; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unknown architecture: $ARCH (expected arm64 or x86_64)" >&2; exit 1 ;;
  esac
done

# Releases are built from project.yml alone; the usual project comes back afterwards.
scripts/bootstrap.sh --spec project.yml >/dev/null
STAGE=
trap 'if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; scripts/bootstrap.sh >/dev/null' EXIT

DIST=build/dist
# CI logs keep xcodebuild's whole output; a local run shows its summary.
xcodebuild_log() { if [ -n "${CI:-}" ]; then cat; else tail -5; fi; }
ENTITLEMENTS=App/StarryPlayer/Resources/StarryPlayer.entitlements

rm -rf "$DIST"
mkdir -p "$DIST"

for ARCH in "${ARCHS[@]}"; do
  DERIVED="build/DerivedData-Release-$ARCH"
  echo "Building $ARCH release..."
  xcodebuild -project StarryPlayer.xcodeproj -scheme StarryPlayer -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    clean build | xcodebuild_log

  APP="$DERIVED/Build/Products/Release/StarryPlayer.app"
  [ -d "$APP" ] || { echo "build failed: $APP not found" >&2; exit 1; }

  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  RELEASE="$DIST/StarryPlayer-$VERSION-$ARCH"
  mkdir -p "$DIST/$ARCH"
  ditto "$APP" "$DIST/$ARCH/StarryPlayer.app"
  APP="$DIST/$ARCH/StarryPlayer.app"

  # Re-sign ad hoc so the bundle seal covers everything; arm64 refuses to run unsigned code.
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify --deep --strict "$APP"

  ditto -c -k --keepParent "$APP" "$RELEASE.zip"

  STAGE=$(mktemp -d)
  ditto "$APP" "$STAGE/StarryPlayer.app"
  ln -s /Applications "$STAGE/Applications"
  # hdiutil now and then fails with "Resource busy" on CI machines; a retry gets past it.
  for attempt in 1 2 3; do
    hdiutil create -volname "Starry Player" -srcfolder "$STAGE" -ov -format UDZO \
      "$RELEASE.dmg" >/dev/null && break
    [ "$attempt" -lt 3 ] || exit 1
    sleep 5
  done
  rm -rf "$STAGE"
  STAGE=

  echo "Architectures ($ARCH): $(lipo -archs "$APP/Contents/MacOS/StarryPlayer")"
done

ls -lh "$DIST"
