#!/bin/bash
set -e

# Zenith macOS DMG Packaging Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_PATH="$PROJECT_ROOT/Zenith.app"
VERSION_FILE="$PROJECT_ROOT/Sources/ZenithCore/Models/ZenithVersion.swift"
VERSION="${1:-$(sed -n 's/.*current = "\(.*\)".*/\1/p' "$VERSION_FILE")}"
DMG_NAME="Zenith-${VERSION}.dmg"
DMG_OUTPUT="$PROJECT_ROOT/$DMG_NAME"
TEMP_DMG_DIR="$PROJECT_ROOT/.build/dmg_staging"

echo "==> Ensuring Zenith.app is freshly built..."
"$SCRIPT_DIR/bundle_app.sh"

echo "==> Preparing DMG staging environment..."
rm -rf "$TEMP_DMG_DIR"
mkdir -p "$TEMP_DMG_DIR"

echo "==> Copying Zenith.app to staging..."
cp -R "$APP_PATH" "$TEMP_DMG_DIR/Zenith.app"

echo "==> Creating /Applications symlink for drag-and-drop installation..."
ln -s /Applications "$TEMP_DMG_DIR/Applications"

echo "==> Removing old DMG if present..."
rm -f "$DMG_OUTPUT"

echo "==> Building compressed DMG image using hdiutil..."
hdiutil create \
    -volname "Zenith" \
    -srcfolder "$TEMP_DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

echo "==> Cleaning up staging..."
rm -rf "$TEMP_DMG_DIR"

echo "==> Successfully created release DMG at:"
echo "    $DMG_OUTPUT"
echo "    Size: $(du -h "$DMG_OUTPUT" | cut -f1)"
