#!/bin/bash
# Render Resources/Plume.icns from Scripts/icon_gen.swift. build_app.sh runs
# this when the file is missing; rerun it by hand after changing the design.
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
