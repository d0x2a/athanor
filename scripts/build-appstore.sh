#!/usr/bin/env bash
# Builds Athanor for the Mac App Store: a sandboxed Athanor.app signed with
# Apple Distribution, in an Athanor-<version>.pkg signed for upload, under
# ./build/appstore/. Apple silicon only (arm64), like the DMG.
#
# The binaries are the DMG's; the sandbox entitlements are what make this the
# store build (see Sources/Athanor/Sandbox.swift).
#
# Needs, once
# -----------
#   - The "Apple Distribution" and "3rd Party Mac Developer Installer"
#     certificates in the keychain. Xcode makes the second: Settings →
#     Accounts → Manage Certificates → + → Mac Installer Distribution.
#   - A Mac App Store Connect provisioning profile for com.d0x2a.athanor, saved
#     as Resources/AppStore/Athanor.provisionprofile (git ignores it), or
#     wherever PROFILE says.
#
# Optional env vars
# -----------------
#   VERSION       Defaults to the version below.
#   BUILD_NUMBER  Defaults to the DMG's scheme (0.1.0 is 100). App Store Connect
#                 takes each build number once per version, so a second upload
#                 of the same version needs another: 100.1, 100.2 and so on.
#   PROFILE       The provisioning profile.
#   UPLOAD=1      Upload the pkg with altool, using the App Store Connect API
#                 key ASC_KEY_ID from ASC_ISSUER_ID (altool finds the key file
#                 in ~/.appstoreconnect/private_keys). Or drop the pkg on
#                 Apple's Transporter app.
#   LOCAL=1       Sign ad hoc as com.d0x2a.athanor.sandbox, with no profile and
#                 no pkg, to try the sandboxed app on this Mac.

set -euo pipefail

TEAM_ID="7JD669BMB4"
APP_IDENTITY="${APP_IDENTITY:-Apple Distribution: Dox2A Labs LLC ($TEAM_ID)}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Dox2A Labs LLC ($TEAM_ID)}"
BUNDLE_ID="com.d0x2a.athanor"
VERSION="${VERSION:-0.1.0}"
LOCAL="${LOCAL:-0}"
UPLOAD="${UPLOAD:-0}"

IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
V_PATCH="${V_PATCH:-0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(( V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH ))}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${PROFILE:-$ROOT/Resources/AppStore/Athanor.provisionprofile}"
BUILD="$ROOT/build/appstore"
APP="$BUILD/Athanor.app"
PKG="$BUILD/Athanor-$VERSION.pkg"
ENTITLEMENTS="$BUILD/Athanor.entitlements"

if [[ "$LOCAL" == 1 ]]; then
    # A bundle ID of its own, so its sandbox container, settings and lock
    # don't mix with a store install.
    BUNDLE_ID="com.d0x2a.athanor.sandbox"
else
    [[ -f "$PROFILE" ]] || {
        echo "✗ no provisioning profile at $PROFILE" >&2
        exit 1
    }
    for identity in "$APP_IDENTITY" "$INSTALLER_IDENTITY"; do
        security find-identity -v | grep -qF "\"$identity\"" || {
            echo "✗ no \"$identity\" certificate in the keychain" >&2
            exit 1
        }
    done
fi

echo "▶ cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "▶ testing"
swift test --package-path "$ROOT" 2>&1 | tail -1

echo "▶ building release binaries (arm64)"
source "$ROOT/scripts/swift-flags.sh"
BUILD_FLAGS=(-c release --arch arm64 "${SWIFT_FLAGS[@]}")
swift build --package-path "$ROOT" "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build --package-path "$ROOT" "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "▶ bundling (bundle=$BUNDLE_ID, version=$VERSION, build=$BUILD_NUMBER)"
"$ROOT/scripts/bundle.sh" "$BIN_DIR" "$APP" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER"

cp "$ROOT/Resources/AppStore/Athanor.entitlements" "$ENTITLEMENTS"
if [[ "$LOCAL" == 1 ]]; then
    echo "▶ codesigning ad hoc, sandboxed"
    codesign --force --sign - \
        --entitlements "$ROOT/Resources/AppStore/athanor-shim.entitlements" \
        "$APP/Contents/MacOS/athanor-shim"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo
    echo "✓ built: $APP"
    echo "  Its files live in ~/Library/Containers/$BUNDLE_ID."
    exit 0
fi

echo "▶ embedding the provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
/usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
    "$ENTITLEMENTS"

# A downloaded profile carries the browser's quarantine flag, which App Store
# Connect refuses anywhere in the app. Signing seals the files as they are, so
# clear it first.
xattr -cr "$APP"

echo "▶ codesigning (Apple Distribution)"
# Inside out: the shim first, then the app that seals it.
codesign --force --timestamp --sign "$APP_IDENTITY" \
    --entitlements "$ROOT/Resources/AppStore/athanor-shim.entitlements" \
    "$APP/Contents/MacOS/athanor-shim"
codesign --force --timestamp --sign "$APP_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "▶ packaging"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

if [[ "$UPLOAD" == 1 ]]; then
    : "${ASC_KEY_ID:?UPLOAD=1 needs ASC_KEY_ID}" "${ASC_ISSUER_ID:?UPLOAD=1 needs ASC_ISSUER_ID}"
    echo "▶ uploading to App Store Connect"
    xcrun altool --upload-package "$PKG" --type macos \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi

echo
echo "✓ built: $PKG"
