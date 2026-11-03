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
# PLUME_VERSION=MAJOR.MINOR stamps a release (Scripts/release.sh sets it).
# 0.0.0 marks a local build, which the in-app updater never replaces.
VERSION="${PLUME_VERSION:-0.0.0}"
if [[ "$VERSION" == "0.0.0" ]]; then
    BUILD=1
elif [[ "$VERSION" =~ ^([1-9][0-9]*|0)\.([1-9]?[0-9])$ ]]; then
    # Same scheme as vkey: strictly increasing and derived from the version
    # alone, so it does not depend on how much git history a clone has.
    # No leading zeros (bash reads 08 as octal) and MINOR ≤ 99, so builds
    # never overlap between majors.
    BUILD=$(( ${BASH_REMATCH[1]} * 10000 + ${BASH_REMATCH[2]} * 100 ))
else
    echo "PLUME_VERSION must be MAJOR.MINOR, no leading zeros, MINOR ≤ 99 (got: $VERSION)" >&2
    exit 1
fi
APP_NAME="Plume"
BUNDLE_ID="com.htl.plume"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

ARCH_ARGS=()
if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
    echo "▸ swift build ($CONFIG, $VERSION, universal arm64 + x86_64)…"
else
    echo "▸ swift build ($CONFIG, $VERSION)…"
fi
cd "$ROOT"
swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/$APP_NAME"

echo "▸ assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
if [[ "$CONFIG" == "release" ]]; then
    # Local symbols only matter to a debugger; dropping them shrinks the
    # binary. Done before codesign, which re-signs the result below.
    strip -x "$APP/Contents/MacOS/$APP_NAME"
fi

# The .icns is generated, not committed: it is 1.2 MB of pixels that
# Scripts/icon_gen.swift reproduces exactly. Rendered once, then reused.
ICON_SRC="$ROOT/Resources/Plume.icns"
if [[ ! -f "$ICON_SRC" ]]; then
    bash "$ROOT/Scripts/make_icon.sh"
fi
cp "$ICON_SRC" "$APP/Contents/Resources/Plume.icns"

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
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
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
