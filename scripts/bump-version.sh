#!/usr/bin/env bash
# Sets a new release version in project.yml, commits it and tags it v<version>; pushing the tag
# makes the release workflow build the arm64 and x86_64 DMGs and publish a GitHub release.
#   scripts/bump-version.sh patch|minor|major|<x.y.z> [--push]
# MARKETING_VERSION becomes the new version and CURRENT_PROJECT_VERSION (the build number) goes up
# by one. Without --push it only prints the push command.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/bump-version.sh patch|minor|major|<x.y.z> [--push]" >&2; exit 1; }

BUMP=
PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    -*) usage ;;
    *) [ -z "$BUMP" ] || usage; BUMP=$arg ;;
  esac
done
[ -n "$BUMP" ] || usage

SPEC=project.yml
CURRENT=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$SPEC")
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' "$SPEC")
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "unexpected CURRENT_PROJECT_VERSION in $SPEC: '$BUILD'" >&2; exit 1; }
[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "unexpected MARKETING_VERSION in $SPEC: '$CURRENT'" >&2; exit 1; }
MAJOR=${BASH_REMATCH[1]} MINOR=${BASH_REMATCH[2]} PATCH=${BASH_REMATCH[3]}

case "$BUMP" in
  patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  *)
    # CFBundleShortVersionString takes three integers, so no pre-release suffixes.
    [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
    VERSION=$BUMP
    ;;
esac
TAG="v$VERSION"
NEXT_BUILD=$((BUILD + 1))

[ "$VERSION" != "$CURRENT" ] || { echo "version is already $CURRENT" >&2; exit 1; }
if [ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$VERSION" ]; then
  echo "$VERSION is lower than the current $CURRENT" >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "uncommitted changes; commit or stash them first" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG already exists" >&2
  exit 1
fi

sed -e "s/^\( *MARKETING_VERSION: \)\"$CURRENT\"$/\1\"$VERSION\"/" \
    -e "s/^\( *CURRENT_PROJECT_VERSION: \)\"$BUILD\"$/\1\"$NEXT_BUILD\"/" "$SPEC" > "$SPEC.tmp"
mv "$SPEC.tmp" "$SPEC"
git add "$SPEC"
git commit -q -m "chore: release $TAG"
git tag -a "$TAG" -m "Starry Player $VERSION"
echo "$CURRENT ($BUILD) -> $VERSION ($NEXT_BUILD) on $(git rev-parse --abbrev-ref HEAD), tagged $TAG"

# The local Xcode project picks up the new version too.
if [ -d StarryPlayer.xcodeproj ] && command -v xcodegen >/dev/null 2>&1; then
  scripts/bootstrap.sh >/dev/null
fi

if [ "$PUSH" = 1 ]; then
  git push --atomic origin HEAD "refs/tags/$TAG"
else
  echo "Push to start the release build: git push --atomic origin HEAD refs/tags/$TAG"
fi
