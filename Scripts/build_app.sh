#!/bin/bash
# Build Plume and assemble a proper macOS .app bundle from the SwiftPM
# executable. Notifications, camera and mic require a bundled, signed app
# with a real bundle identifier — a bare `swift run` binary won't do.
set -euo pipefail

CONFIG="${1:-release}"          # debug | release
# PLUME_UNIVERSAL=1 builds arm64 + x86_64. Off by default because it roughly
# doubles build time; on for anything handed to someone else, since an arm64
# binary simply does not launch on an Intel Mac.
UNIVERSAL="${PLUME_UNIVERSAL:-0}"
# PLUME_SIGN_IDENTITY="Developer ID Application: …" switches from an ad-hoc
# signature to a real one with the Hardened Runtime, which is what
# notarization requires. Empty means ad-hoc, which is fine locally and useless
# for anything that leaves this machine.
SIGN_IDENTITY="${PLUME_SIGN_IDENTITY:-}"
APP_NAME="Plume"
BUNDLE_ID="com.htl.plume"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

ARCH_ARGS=()
if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    echo "▸ swift build ($CONFIG, universal arm64 + x86_64)…"
else
    echo "▸ swift build ($CONFIG)…"
fi
cd "$ROOT"
swift build -c "$CONFIG" "${ARCH_ARGS[@]}"
BIN_PATH="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)/$APP_NAME"

echo "▸ assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

ICON_SRC="$ROOT/Resources/Plume.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/Plume.icns"
else
    echo "  (no Resources/Plume.icns — run Scripts/make_icon.sh to generate it)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>Plume</string>
    <key>CFBundleIconName</key>        <string>Plume</string>
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

ENTITLEMENTS="$ROOT/Resources/Plume.entitlements"
if [[ -n "$SIGN_IDENTITY" ]]; then
    # --options runtime is the load-bearing flag: notarization rejects anything
    # without the Hardened Runtime. --timestamp is equally required, and needs
    # network access to Apple's timestamp server.
    echo "▸ codesign (Developer ID + hardened runtime)…"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc signature: enough for local notifications / TCC prompts.
    echo "▸ codesign (ad-hoc)…"
    codesign --force --sign - "$APP" >/dev/null
fi

echo "✓ built: $APP"
echo "  run:  open \"$APP\""
