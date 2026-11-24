#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "TokSpeed requires macOS and Xcode Command Line Tools." >&2
    exit 1
fi

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
APP="$BUILD_DIR/TokSpeed.app"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$HELPERS" "$RESOURCES/Logos" "$ICONSET"

# Build all standard and Retina icon sizes from the checked-in source image.
# Only macOS system tools are used; the desktop original is never needed.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$RESOURCES/AppIcon.icns"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

APP_SLICES=()
HOOK_SLICES=()
for arch in "${ARCHS[@]}"; do
    SWIFT_ARGS=(--configuration release --scratch-path "$BUILD_DIR/SwiftPM/$arch" --arch "$arch")
    swift build "${SWIFT_ARGS[@]}"
    BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
    APP_SLICES+=("$BIN_DIR/TokSpeed")
    HOOK_SLICES+=("$BIN_DIR/tokspeed-cursor-hook")
done

package_binary() {
    local output="$1"
    shift
    if [[ $# -eq 1 ]]; then
        cp "$1" "$output"
    else
        lipo -create "$@" -output "$output"
    fi
}

# Production binaries omit all test code; the Cursor hook helper avoids AppKit and SQLite3.
package_binary "$APP/Contents/MacOS/TokSpeed" "${APP_SLICES[@]}"
package_binary "$HELPERS/tokspeed-cursor-hook" "${HOOK_SLICES[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# Remove artwork that no longer ships when reusing a build directory.
rsync -a --delete Resources/Logos/ "$RESOURCES/Logos/"
mkdir -p "$RESOURCES/HermesPlugin"
cp Resources/HermesPlugin/plugin.yaml Resources/HermesPlugin/__init__.py "$RESOURCES/HermesPlugin/"
for localization in Resources/*.lproj; do
    mkdir -p "$RESOURCES/$(basename "$localization")"
    cp "$localization/Localizable.strings" "$RESOURCES/$(basename "$localization")/"
done
cp LICENSE "$RESOURCES/LICENSE"
plutil -lint "$APP/Contents/Info.plist"

# Local ad-hoc signing only; no developer certificate or notarization is needed.
codesign --force --sign - --timestamp=none "$HELPERS/tokspeed-cursor-hook"
codesign --force --sign - --timestamp=none "$APP"
# Finder displays the bundle directory's timestamp, not the executable's.
touch "$APP"
echo "Built: $APP"
