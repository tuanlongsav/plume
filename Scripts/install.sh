#!/bin/bash
# Build Plume and install (or update) it in /Applications on this Mac.
#
#   bash Scripts/install.sh            # release build for this Mac's CPU
#
# Login, cookies and preferences are keyed by the bundle id, so they survive
# the update. A fresh ad-hoc signature can make macOS ask for camera/mic again.
#
# This is a local build (version 0.0.0, ad-hoc signed), which never updates
# itself. Replacing an installed release with it would stop updates on this
# Mac, so that needs PLUME_REPLACE_RELEASE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/build/Plume.app"
DEST_DIR="${PLUME_INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/Plume.app"

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$DEST/Contents/Info.plist" 2>/dev/null || true)"
# Releases are stamped MAJOR.MINOR; local builds (and pre-release ones) are not.
if [[ "$INSTALLED" =~ ^[0-9]+\.[0-9]+$ && "${PLUME_REPLACE_RELEASE:-0}" != "1" ]]; then
    echo "$DEST is release $INSTALLED, which updates itself. A local build would not." >&2
    echo "Run again with PLUME_REPLACE_RELEASE=1 to replace it anyway." >&2
    exit 1
fi

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
# Copy beside the old app first (same volume), so a failed copy never leaves
# you with none, then exchange the two in one atomic rename: `rm -rf; mv` left
# no app at all if interrupted between the two. After the swap, $STAGED holds
# the old app.
STAGED="$DEST_DIR/.Plume.app.new"
rm -rf "$STAGED" "$STAGED.old"
ditto "$APP_SRC" "$STAGED"
swift "$ROOT/Scripts/swap_bundle.swift" "$STAGED" "$DEST"
rm -rf "$STAGED"

echo "✓ installed: $DEST"
open "$DEST"
