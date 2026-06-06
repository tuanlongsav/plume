#!/bin/bash
# Build Plume.app and package it into a compressed, drag-to-install DMG
# (the volume contains the app plus an /Applications symlink).
#
#   bash Scripts/make_dmg.sh [debug|release]   # → build/Plume.dmg
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Plume.app"
DMG="$ROOT/build/Plume.dmg"

bash "$ROOT/Scripts/build_app.sh" "$CONFIG"

echo "▸ staging DMG contents…"
STAGE="$(mktemp -d)/Plume"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ hdiutil create → ${DMG} …"
rm -f "$DMG"
hdiutil create -volname "Plume" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "✓ built: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/  size: /'
