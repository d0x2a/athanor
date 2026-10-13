#!/usr/bin/env bash
# Builds a signed, notarized and stapled Athanor.app and Athanor-<version>.dmg
# under ./build/. The binaries are Apple silicon only (arm64).
#
# Optional env vars
# -----------------
#   VERSION       Defaults to the version below. Goes into
#                 CFBundleShortVersionString.
#   BUILD_NUMBER  Defaults to one derived from VERSION. Goes into
#                 CFBundleVersion.
#   BUNDLE_ID     Defaults to com.d0x2a.athanor.
#   NOTARY_PROFILE  The notarytool keychain profile. Defaults to kuddo-notary:
#                 the profile holds Apple ID credentials, not anything
#                 app-specific, so Kuddo's works for Athanor too.
#   NOTARIZE=0    Sign but skip notarization and stapling, for a quick local
#                 check. Gatekeeper rejects such a build on other Macs.

set -euo pipefail

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Dox2A Labs LLC (7JD669BMB4)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kuddo-notary}"
BUNDLE_ID="${BUNDLE_ID:-com.d0x2a.athanor}"
VERSION="${VERSION:-0.1.0}"
NOTARIZE="${NOTARIZE:-1}"

# CFBundleVersion is what macOS ranks copies of an app by, so it has to rise
# with every release: major·10000 + minor·100 + patch, so 0.1.0 is 100.
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
V_PATCH="${V_PATCH:-0}"
(( V_MINOR < 100 && V_PATCH < 100 )) || {
    echo "✗ $VERSION doesn't fit the build-number scheme" >&2
    exit 1
}
BUILD_NUMBER="${BUILD_NUMBER:-$(( V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH ))}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
APP="$BUILD/Athanor.app"
DMG="$BUILD/Athanor-$VERSION.dmg"
ZIP="$BUILD/Athanor.zip"

echo "▶ cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "▶ testing"
swift test --package-path "$ROOT" 2>&1 | tail -1

echo "▶ building release binaries (arm64)"
# The arch is spelled out so the result doesn't depend on which Mac builds
# it, and it has to be on --show-bin-path too or that answers for a
# different build.
source "$ROOT/scripts/swift-flags.sh"
BUILD_FLAGS=(-c release --arch arm64 "${SWIFT_FLAGS[@]}")
swift build --package-path "$ROOT" "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build --package-path "$ROOT" "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "▶ bundling (bundle=$BUNDLE_ID, version=$VERSION, build=$BUILD_NUMBER)"
"$ROOT/scripts/bundle.sh" "$BIN_DIR" "$APP" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER"
for binary in Athanor athanor-shim; do
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/$binary")"
    [[ "$ARCHS" == "arm64" ]] || {
        echo "✗ expected an arm64 $binary, got: $ARCHS" >&2
        exit 1
    }
done

echo "▶ codesigning (hardened runtime)"
# Inside out: the shim first, then the app that seals it.
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP/Contents/MacOS/athanor-shim"
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

if [[ "$NOTARIZE" == 1 ]]; then
    echo "▶ submitting .app for notarization (this can take a few minutes)"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

echo "▶ creating DMG"
# create-dmg (from Homebrew) lays out the window: the app on the left, an
# Applications link on the right. It can exit non-zero when a Finder
# AppleScript step hiccups, so what counts is whether the DMG got written.
create-dmg \
    --volname "Athanor $VERSION" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 560 340 \
    --icon-size 112 \
    --icon "Athanor.app" 150 160 \
    --app-drop-link 410 160 \
    --no-internet-enable \
    "$DMG" \
    "$APP" || true
test -f "$DMG"

echo "▶ codesigning DMG"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"

if [[ "$NOTARIZE" == 1 ]]; then
    echo "▶ submitting DMG for notarization"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"

    echo "▶ verifying Gatekeeper acceptance"
    spctl --assess --type execute --verbose "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo
echo "✓ built: $DMG"
