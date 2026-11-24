#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -gt 0 ]]; then
    if [[ $# != 2 || "$1" != --preview-directory || -z "$2" ]]; then
        echo "Usage: $0 [--preview-directory PATH]" >&2
        exit 2
    fi
    export TOKSPEED_TEST_PREVIEW_DIRECTORY="$2"
fi

bash scripts/build.sh
BUILD_DIR="$(cd "${BUILD_DIR:-$ROOT/build}" && pwd)"
APP="$BUILD_DIR/TokSpeed.app"
codesign --verify --deep --strict "$APP"

for strings in Resources/*.lproj/Localizable.strings; do
    plutil -lint "$strings" >/dev/null
done
echo "Localization plutil lint: passed"

TOKSPEED_TEST_APP_BUNDLE="$APP" \
TOKSPEED_TEST_CURSOR_HELPER="$APP/Contents/Helpers/tokspeed-cursor-hook" \
    swift test --scratch-path "$BUILD_DIR/SwiftPM/$(uname -m)"
python3 scripts/test-hermes-plugin.py --binary "$APP/Contents/MacOS/TokSpeed"
