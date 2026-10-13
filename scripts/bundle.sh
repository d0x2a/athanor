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

# The icon as Xcode ships it: an asset catalog (Assets.car), which the App
# Store, Transporter and the Finder read, and a small AppIcon.icns beside it
# for anything that only knows CFBundleIconFile.
WORK="$(mktemp -d)"
ICONSET="$WORK/Assets.xcassets/AppIcon.appiconset"
"$APP/Contents/MacOS/Athanor" --export-iconset "$ICONSET"
{
    echo '{"info": {"author": "xcode", "version": 1}, "images": ['
    SEP=""
    for POINTS in 16 32 128 256 512; do
        for SCALE in 1 2; do
            SUFFIX=""
            [[ "$SCALE" == 2 ]] && SUFFIX="@2x"
            printf '%s{"idiom": "mac", "size": "%sx%s", "scale": "%sx", "filename": "icon_%sx%s%s.png"}\n' \
                "$SEP" "$POINTS" "$POINTS" "$SCALE" "$POINTS" "$POINTS" "$SUFFIX"
            SEP=","
        done
    done
    echo ']}'
} > "$ICONSET/Contents.json"
xcrun actool "$WORK/Assets.xcassets" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/partial.plist" > /dev/null
test -f "$APP/Contents/Resources/Assets.car"
rm -rf "$WORK"
