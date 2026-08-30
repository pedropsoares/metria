#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/dist}"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || true)}"
VERSION="${VERSION:-dev}"
RELEASE_VERSION="${VERSION#v}"
ARCH="$(uname -m)"
APP_NAME="Metria"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$ARCH.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$ARCH.dmg"

cd "$ROOT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$DMG_PATH" "$BUILD_DIR/dmg-root"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
ditto --norsrc "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ -d "$BIN_DIR/Metria_Metria.bundle" ]]; then
    ditto --norsrc "$BIN_DIR/Metria_Metria.bundle" "$APP_BUNDLE/Contents/Resources/Metria_Metria.bundle"
fi

sparkle_framework="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$sparkle_framework" ]]; then
    ditto --norsrc "$sparkle_framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

rm -f "$APP_BUNDLE"/._* "$APP_BUNDLE/Contents"/._* "$APP_BUNDLE/Contents/MacOS"/._* "$APP_BUNDLE/Contents/Resources"/._* "$APP_BUNDLE/Contents/Resources/Metria_Metria.bundle"/._*

plutil -create xml1 "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Metria" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Metria" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.metria.app" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Metria" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $RELEASE_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $RELEASE_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "${SPARKLE_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$APP_BUNDLE/Contents/Info.plist"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --deep --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
    printf '%s\n' "Warning: CODESIGN_IDENTITY is not set; this archive is unsigned."
fi

ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

mkdir -p "$BUILD_DIR/dmg-root"
ditto --norsrc "$APP_BUNDLE" "$BUILD_DIR/dmg-root/$APP_NAME.app"
ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
    rm "$ZIP_PATH"
    ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    rm "$DMG_PATH"
    rm -rf "$BUILD_DIR/dmg-root"
    mkdir -p "$BUILD_DIR/dmg-root"
    ditto --norsrc "$APP_BUNDLE" "$BUILD_DIR/dmg-root/$APP_NAME.app"
    ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

rm -rf "$BUILD_DIR/dmg-root"
printf 'Created %s\nCreated %s\n' "$ZIP_PATH" "$DMG_PATH"
