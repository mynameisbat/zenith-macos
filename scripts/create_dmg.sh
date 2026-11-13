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

# Installed copies update themselves only to a build signed with the SAME certificate (the running app's designated
# requirement pins it). An ad-hoc signed release can never be verified, so everyone who installs it is left to update
# by hand forever after: refuse to package one. ZENITH_ALLOW_ADHOC_DMG=1 builds it anyway, for local testing only.
echo "==> Checking the signature of Zenith.app..."
SIGNING_INFO="$(/usr/bin/codesign -d --verbose=2 "$APP_PATH" 2>&1 || true)"
if printf '%s\n' "$SIGNING_INFO" | grep -q '^Signature=adhoc' || ! printf '%s\n' "$SIGNING_INFO" | grep -q '^Authority='; then
    if [ "${ZENITH_ALLOW_ADHOC_DMG:-}" = "1" ]; then
        echo "WARNING: ****************************************************************************" >&2
        echo "WARNING: Zenith.app is signed AD HOC. Do NOT publish this DMG: whoever installs it can" >&2
        echo "WARNING: never install an update automatically. (ZENITH_ALLOW_ADHOC_DMG=1 was set.)" >&2
        echo "WARNING: ****************************************************************************" >&2
    else
        echo "error: Zenith.app is signed ad hoc, so copies installed from this DMG could never verify an update." >&2
        echo "       Run scripts/setup_signing.sh (or import the release identity's .p12) and build again." >&2
        echo "       Every release must be signed with the same certificate. For a local test DMG only, set ZENITH_ALLOW_ADHOC_DMG=1." >&2
        exit 1
    fi
else
    /usr/bin/codesign --verify --deep --strict "$APP_PATH" || { echo "error: Zenith.app does not verify." >&2; exit 1; }
    echo "    $(printf '%s\n' "$SIGNING_INFO" | grep -m1 '^Authority=')"
    echo "    $(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1 | grep '^designated')"
    echo "    (the certificate leaf hash above must be the same for every release)"
fi

echo "==> Preparing DMG staging environment..."
rm -rf "$TEMP_DMG_DIR"
mkdir -p "$TEMP_DMG_DIR"

echo "==> Copying Zenith.app to staging..."
cp -R "$APP_PATH" "$TEMP_DMG_DIR/Zenith.app"

echo "==> Creating /Applications symlink for drag-and-drop installation..."
ln -s /Applications "$TEMP_DMG_DIR/Applications"

echo "==> Removing old DMG if present..."
rm -f "$DMG_OUTPUT"

# HFS+ on purpose. Without -fs, a Mac on a recent macOS makes the image APFS, which an older macOS may refuse to mount
# ("no mountable file systems"); Zenith runs on macOS 13, and an app this size gains nothing from APFS.
echo "==> Building compressed DMG image using hdiutil..."
hdiutil create \
    -fs HFS+ \
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
