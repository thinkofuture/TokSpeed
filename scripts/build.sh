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
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES/Logos" "$BUILD_DIR/ModuleCache" "$ICONSET"

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

# Compile a relative source path so #filePath does not embed the builder's home.
# Swift 5 language mode matches the existing AppKit application's threading model.
xcrun swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -framework AppKit -lsqlite3 \
    main.swift -o "$APP/Contents/MacOS/TokSpeed"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Logos/*.svg Resources/Logos/NOTICE.md "$RESOURCES/Logos/"
cp LICENSE "$RESOURCES/LICENSE"
plutil -lint "$APP/Contents/Info.plist"

# Local ad-hoc signing only; no developer certificate or notarization is needed.
codesign --force --sign - --timestamp=none "$APP"
echo "Built: $APP"
