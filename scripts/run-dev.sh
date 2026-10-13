#!/usr/bin/env bash
# Builds a debug Athanor.app under ./build/dev, signs it ad hoc, and opens it.
#
# It has its own bundle id (com.d0x2a.athanor.dev), so it keeps its settings
# apart from an installed release, and can run beside one.
#
# Optional env vars
# -----------------
#   ATHANOR_HOME  Keep scripts.toml, logs and run state in this folder instead
#                 of ~/.config/athanor and ~/Library. Use it to try things
#                 without touching your real scripts.
#   NO_OPEN=1     Build only.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/dev/Athanor.app"

echo "▶ building (debug)"
swift build --package-path "$ROOT"
BIN_DIR="$(swift build --package-path "$ROOT" --show-bin-path)"

echo "▶ bundling $APP"
"$ROOT/scripts/bundle.sh" "$BIN_DIR" "$APP" com.d0x2a.athanor.dev 0.0.0-dev 1

echo "▶ signing ad hoc"
codesign --force --sign - "$APP/Contents/MacOS/athanor-shim"
codesign --force --sign - "$APP"

if [[ "${NO_OPEN:-0}" != 1 ]]; then
    # Quit a running dev copy first; scripts it started keep running.
    osascript -e 'tell application id "com.d0x2a.athanor.dev" to quit' >/dev/null 2>&1 || true
    sleep 0.5
    if [[ -n "${ATHANOR_HOME:-}" ]]; then
        open -n "$APP" --env "ATHANOR_HOME=$ATHANOR_HOME"
    else
        open "$APP"
    fi
    echo "✓ running $APP"
fi
