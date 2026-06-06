#!/bin/bash
# Regenerate Resources/Plume.icns from Scripts/icon_gen.swift. Run this only
# when the icon design changes; build_app.sh just copies the committed .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
ICONSET="$TMP/Plume.iconset"
mkdir -p "$ICONSET"

echo "▸ rendering iconset…"
swift "$ROOT/Scripts/icon_gen.swift" "$ICONSET"

echo "▸ iconutil → Resources/Plume.icns…"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/Plume.icns"
rm -rf "$TMP"

echo "✓ Resources/Plume.icns"
