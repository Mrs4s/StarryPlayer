# Repository Guidelines

## Project Structure & Module Organization

Starry Player targets macOS 14+ using Swift 6, SwiftUI, AppKit, and AVFoundation.

- `App/StarryPlayer/Sources/`: application state, pages, playback UI, and shared views; assets and models live in `Resources/`, application tests in `Tests/`.
- `Packages/StarryKit/`: reusable modules under `Sources/<Module>` and corresponding `Tests/<Module>Tests` suites. Keep reusable playback, lyrics, library, and plugin-host logic here.
- `plugins/`: TypeScript providers, shared helpers in `common/`, and API declarations in `sdk/starry.d.ts`.
- `scripts/`: build, test, packaging, and synthetic audio utilities. See `docs/development.md` and `docs/plugin-development.md` for details.

## Build, Test, and Development Commands

Use macOS with Xcode, Swift 6, XcodeGen, and Node.js. Install supporting tools with `brew install xcodegen node python ffmpeg`.

- `scripts/bootstrap.sh`: generate `StarryPlayer.xcodeproj`; open it and run the `StarryPlayer` scheme for local development.
- `scripts/build.sh`: build the Debug app into `build/Debug/StarryPlayer.app`.
- `scripts/test.sh`: build bundled plugins, then run StarryKit tests; append `--filter LyricsCoreTests` to narrow execution.
- `xcodebuild -project StarryPlayer.xcodeproj -scheme StarryPlayer -destination 'platform=macOS' test`: run application tests after bootstrapping.
- In a plugin directory, run `npm ci`, then `npm run build` and `npm run check`; Jellyfin and Subsonic also provide `npm test`.
- `scripts/package.sh [arm64|x86_64]`: produce architecture-specific Release ZIP/DMG packages (both architectures when no argument is given).

## Coding Style & Naming Conventions

Match surrounding code: Swift uses four-space indentation, UpperCamelCase types/files, and lowerCamelCase members. Respect Swift 6 strict concurrency and existing actor isolation. TypeScript uses two-space indentation, single quotes, and semicolons. No dedicated formatter or linter is configured; plugin `npm run check` performs TypeScript checking.

## Testing Guidelines

Swift tests use Swift Testing (`@Suite`, `@Test`, `#expect`), with `*Tests.swift` files and descriptive behavior-based function names. Plugin tests use Node's test runner and `*.test.ts` files. Add regression coverage for behavior changes; no minimum coverage percentage is configured. Local-library tests require Python 3 and ffmpeg. Network tests are opt-in via `LYRICS_LIVE=1` or `PLUGINS_LIVE=1`.

## CI & Releases

- `.github/workflows/ci.yml` runs on pull requests and on manual dispatch (not on pushes): plugin build/check/test on Ubuntu, then StarryKit and app tests on the `xcode-27` runner (Homebrew `ffmpeg-full`, since the plain `ffmpeg` formula lacks libvorbis).
- The version is `MARKETING_VERSION` in `project.yml`, and the build number is `CURRENT_PROJECT_VERSION`. Release with `scripts/bump-version.sh patch|minor|major|<x.y.z> [--push]`: it writes the version, bumps the build number, commits `chore: release vX.Y.Z`, and tags `vX.Y.Z`. Without `--push`, it prints the push command instead.
- Pushing a `v*` tag runs `.github/workflows/release.yml`. It builds `scripts/package.sh arm64` and `scripts/package.sh x86_64` in parallel and publishes `StarryPlayer-<version>-arm64.dmg` and `StarryPlayer-<version>-x86_64.dmg` to the tag's GitHub release. The build fails if the tag does not match `MARKETING_VERSION`.
- The app's update check (`App/StarryPlayer/Sources/App/Updates.swift`) reads GitHub's latest release and, when GitHub is unreachable, the latest tag's version through jsDelivr (its `project.yml` `MARKETING_VERSION: "x.y.z"` line). It picks the DMG by the `-arm64.dmg` / `-x86_64.dmg` suffix, so keep that line format and the asset names when changing packaging.

## Configuration & Generated Files

Edit `project.yml`, then regenerate; do not commit generated Xcode projects or build outputs. Keep personal overrides in ignored `project.local.yml`. Preserve model-directory relative paths when changing bundled resources.
