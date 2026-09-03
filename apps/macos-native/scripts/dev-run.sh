#!/usr/bin/env bash
# Fast local dev loop: builds the current working tree (uncommitted changes included)
# as a real, unsigned Debug .app via xcodebuild - proper CFBundleIdentifier and a
# compiled String Catalog, unlike `swift run` - and launches it. No signing, no DMG,
# no zip, so it's much faster than package-macos.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-dev}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Metria.app"

osascript -e 'quit app "Metria"' >/dev/null 2>&1 || true

xcodebuild \
    -project "$ROOT_DIR/apps/macos-native/Metria.xcodeproj" \
    -scheme Metria \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

open "$APP_PATH"
