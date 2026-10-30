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
    cp "$BUILD_DIR/GoldenGateApp" "$MACOS_DIR/Zenith"
fi
chmod +x "$MACOS_DIR/Zenith"

echo "==> Copying Zenith AppIcon.icns..."
if [ -f "$PROJECT_ROOT/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "==> Generating Info.plist for Zenith..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Zenith</string>
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
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Zenith uses Apple Events to see what Music, Spotify and your browser are playing and to control playback from the Dynamic Island.</string>
</dict>
</plist>
EOF

echo "==> Stamping version $VERSION (build $BUILD)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$CONTENTS_DIR/Info.plist"

echo "==> Performing ad-hoc code signature..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Mirroring to GoldenGate.app for backwards compatibility..."
rm -rf "$PROJECT_ROOT/GoldenGate.app"
cp -R "$APP_DIR" "$PROJECT_ROOT/GoldenGate.app"
# Also provide GoldenGateApp executable in GoldenGate.app for legacy scripts
cp "$MACOS_DIR/Zenith" "$PROJECT_ROOT/GoldenGate.app/Contents/MacOS/GoldenGateApp"
codesign --force --deep --sign - "$PROJECT_ROOT/GoldenGate.app"

echo "==> Registering with macOS LaunchServices & refreshing icon cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" || true
touch "$APP_DIR"
touch "$PROJECT_ROOT/GoldenGate.app"

echo "==> Zenith.app created successfully at: $APP_DIR"
echo "==> You can now launch it via: open Zenith.app"
