#!/bin/bash
# Build Plume and assemble a proper macOS .app bundle from the SwiftPM
# executable. Notifications, camera and mic require a bundled, signed app
# with a real bundle identifier — a bare `swift run` binary won't do.
set -euo pipefail

CONFIG="${1:-release}"          # debug | release
APP_NAME="Plume"
BUNDLE_ID="com.htl.plume"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

echo "▸ swift build ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "▸ assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSCameraUsageDescription</key>     <string>Plume needs the camera for video calls.</string>
    <key>NSMicrophoneUsageDescription</key> <string>Plume needs the microphone for calls.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local notifications / TCC prompts.
echo "▸ codesign (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null

echo "✓ built: $APP"
echo "  run:  open \"$APP\""
