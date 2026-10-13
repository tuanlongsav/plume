#!/bin/bash
# Build Plume and install (or update) it in /Applications on this Mac.
#
#   bash Scripts/install.sh            # release build for this Mac's CPU
#
# Login, cookies and preferences are keyed by the bundle id, so they survive
# the update. A fresh ad-hoc signature can make macOS ask for camera/mic again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/build/Plume.app"
DEST_DIR="${PLUME_INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/Plume.app"

bash "$ROOT/Scripts/build_app.sh" release

# Quit a running copy so the bundle can be replaced, and give it a moment to
# save its window frame and cookies.
running() { pgrep -xq -U "$(id -u)" Plume; }
if running; then
    echo "▸ quitting the running Plume…"
    osascript -e 'tell application id "com.htl.plume" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        running || break
        sleep 0.5
    done
    if running; then
        echo "  Plume is still running — quit it, then run this again." >&2
        exit 1
    fi
fi

echo "▸ installing → $DEST …"
# Copy beside the old app first, so a failed copy never leaves you with none.
STAGED="$DEST_DIR/.Plume.app.new"
rm -rf "$STAGED"
ditto "$APP_SRC" "$STAGED"
rm -rf "$DEST"
mv "$STAGED" "$DEST"
# A local build carries no quarantine flag, but an older copy dragged in from
# the DMG may have left one behind; clearing it is harmless either way.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ installed: $DEST"
open "$DEST"
