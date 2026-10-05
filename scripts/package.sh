#!/usr/bin/env bash
# Builds separate arm64 and x86_64 ad-hoc-signed ZIP and DMG releases in build/dist.
# Not notarized; other Macs require Gatekeeper approval on first launch.
set -euo pipefail
cd "$(dirname "$0")/.."

# Releases are built from project.yml alone; the usual project comes back afterwards.
scripts/bootstrap.sh --spec project.yml >/dev/null
STAGE=
trap 'if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; scripts/bootstrap.sh >/dev/null' EXIT

DIST=build/dist
ENTITLEMENTS=App/StarryPlayer/Resources/StarryPlayer.entitlements

rm -rf "$DIST"
mkdir -p "$DIST"

for ARCH in arm64 x86_64; do
  DERIVED="build/DerivedData-Release-$ARCH"
  echo "Building $ARCH release..."
  xcodebuild -project StarryPlayer.xcodeproj -scheme StarryPlayer -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    clean build | tail -5

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
  hdiutil create -volname "Starry Player" -srcfolder "$STAGE" -ov -format UDZO \
    "$RELEASE.dmg" >/dev/null
  rm -rf "$STAGE"
  STAGE=

  echo "Architectures ($ARCH): $(lipo -archs "$APP/Contents/MacOS/StarryPlayer")"
done

ls -lh "$DIST"
