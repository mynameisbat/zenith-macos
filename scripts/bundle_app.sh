#!/bin/bash
set -e

# Zenith macOS Application Bundler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/release"
APP_DIR="$PROJECT_ROOT/Zenith.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# The version is declared once, in ZenithVersion.swift.
VERSION_FILE="$PROJECT_ROOT/Sources/ZenithCore/Models/ZenithVersion.swift"
VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' "$VERSION_FILE")"
BUILD="$(sed -n 's/.*build = "\(.*\)".*/\1/p' "$VERSION_FILE")"
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    echo "error: could not read the version from $VERSION_FILE" >&2
    exit 1
fi
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building Zenith in Release configuration..."
cd "$PROJECT_ROOT"
swift build -c release

echo "==> Constructing Zenith.app bundle structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "==> Copying binary..."
if [ -f "$BUILD_DIR/Zenith" ]; then
    cp "$BUILD_DIR/Zenith" "$MACOS_DIR/Zenith"
elif [ -f "$BUILD_DIR/ZenithApp" ]; then
    cp "$BUILD_DIR/ZenithApp" "$MACOS_DIR/Zenith"
else
    echo "error: the build produced no Zenith executable in $BUILD_DIR" >&2
    exit 1
fi
chmod +x "$MACOS_DIR/Zenith"

# The Now Playing adapter is loaded by /usr/bin/perl, never by Zenith itself (see Sources/ZenithNowPlayingAdapter).
echo "==> Copying the Now Playing adapter..."
ADAPTER_NAME="libZenithNowPlayingAdapter.dylib"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
if [ ! -f "$BUILD_DIR/$ADAPTER_NAME" ]; then
    echo "error: $BUILD_DIR/$ADAPTER_NAME was not built" >&2
    exit 1
fi
mkdir -p "$FRAMEWORKS_DIR"
cp "$BUILD_DIR/$ADAPTER_NAME" "$FRAMEWORKS_DIR/$ADAPTER_NAME"

echo "==> Copying Zenith AppIcon.icns..."
if [ -f "$PROJECT_ROOT/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "==> Copying localizations (Localization/*.lproj)..."
for lproj in "$PROJECT_ROOT"/Localization/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
done

echo "==> Generating Info.plist for Zenith..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Zenith</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>vi</string>
        <string>zh-Hans</string>
        <string>ja</string>
        <string>ko</string>
        <string>fr</string>
        <string>de</string>
        <string>es</string>
    </array>
    <key>CFBundleIdentifier</key>
    <string>com.zenith.workspace</string>
    <key>CFBundleName</key>
    <string>Zenith</string>
    <key>CFBundleDisplayName</key>
    <string>Zenith</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Zenith uses Apple Events to see what Music and Spotify are playing, to control playback from the Dynamic Island, and to ask Finder to move to the Trash a leftover folder that macOS does not let other apps move.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Zenith records your microphone into a screen recording, only when you turn on Microphone in the recording bar.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Zenith shows your next calendar event in the Dynamic Island when you turn on the Calendar widget. Events are only read on this Mac.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Zenith shows your next calendar event in the Dynamic Island when you turn on the Calendar widget. Events are only read on this Mac.</string>
</dict>
</plist>
EOF

echo "==> Stamping version $VERSION (build $BUILD)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$CONTENTS_DIR/Info.plist"

# "Zenith Local Signing" (scripts/setup_signing.sh) if this Mac has it, so permissions survive rebuilds; ad hoc otherwise.
# Signs the adapter library first (perl refuses to load it unsigned), then the app, and verifies both.
"$SCRIPT_DIR/sign_app.sh" "$APP_DIR"

echo "==> Registering with macOS LaunchServices & refreshing icon cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" || true
touch "$APP_DIR"

echo "==> Zenith.app created successfully at: $APP_DIR"
echo "==> You can now launch it via: open Zenith.app"
