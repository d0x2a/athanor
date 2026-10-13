#!/usr/bin/env bash
# Assembles Athanor.app from a `swift build` products folder. Shared by
# run-dev.sh and build-release.sh; not meant to be run on its own.
#
#   bundle.sh BIN_DIR APP BUNDLE_ID VERSION BUILD_NUMBER

set -euo pipefail

BIN_DIR="$1"
APP="$2"
BUNDLE_ID="$3"
VERSION="$4"
BUILD_NUMBER="$5"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The shim sits beside the app's executable: Athanor looks for it there.
cp "$BIN_DIR/Athanor" "$APP/Contents/MacOS/Athanor"
cp "$BIN_DIR/athanor-shim" "$APP/Contents/MacOS/athanor-shim"

sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/Athanor" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
