#!/usr/bin/env bash
# Assembles Athanor.app from a `swift build` products folder. Shared by
# run-dev.sh, build-release.sh and build-appstore.sh; not meant to be run on
# its own.
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

# Built against the SDK it says it was (see swift-flags.sh).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for BINARY in Athanor athanor-shim; do
    LINKED_SDK="$(vtool -show-build "$APP/Contents/MacOS/$BINARY" | awk '$1 == "sdk" { print $2 }')"
    [[ "$LINKED_SDK" == "$SDK_VERSION" ]] || {
        echo "✗ $BINARY records SDK $LINKED_SDK, not $SDK_VERSION: build it with the flags in scripts/swift-flags.sh" >&2
        exit 1
    }
done

PLIST="$APP/Contents/Info.plist"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    "$ROOT/Resources/Info.plist" > "$PLIST"

# What Xcode writes into every app's Info.plist about the build. App Store
# Connect reads the SDK and Xcode versions from here.
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
XCODE_BUILD="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
IFS=. read -r X_MAJOR X_MINOR X_PATCH <<< "$XCODE_VERSION"
plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$PLIST"
plutil -insert BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$PLIST"
plutil -insert DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$PLIST"
plutil -insert DTPlatformName -string macosx "$PLIST"
plutil -insert DTPlatformVersion -string "$SDK_VERSION" "$PLIST"
plutil -insert DTPlatformBuild -string "$SDK_BUILD" "$PLIST"
plutil -insert DTSDKName -string "macosx$SDK_VERSION" "$PLIST"
plutil -insert DTSDKBuild -string "$SDK_BUILD" "$PLIST"
plutil -insert DTXcode -string "$(printf '%02d%d%d' "$X_MAJOR" "${X_MINOR:-0}" "${X_PATCH:-0}")" "$PLIST"
plutil -insert DTXcodeBuild -string "$XCODE_BUILD" "$PLIST"

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
