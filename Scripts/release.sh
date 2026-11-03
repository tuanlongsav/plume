#!/usr/bin/env bash
# Publish Plume X.Y to GitHub Releases, where the in-app updater finds it.
#
#   bash Scripts/release.sh X.Y [--skip-notarize] [--no-publish] [--rotating-key]
#
#   1. preflight     clean tree on an up-to-date main, new version, gh logged
#                    in, signing key present and matching UpdateKeys.swift,
#                    CHANGELOG.md has a "## X.Y" section
#   2. build         Scripts/release_sign.sh X.Y → Plume-X.Y.dmg + .zip
#   3. manifest      Ed25519-sign the zip → Plume-X.Y.manifest.json
#   4. publish       tag vX.Y, push, gh release create with the three assets
#   5. verify        releases/latest is vX.Y, every asset URL answers 200
#
# --no-publish stops after step 3 (dry run; artifacts stay in build/).
# --skip-notarize implies --no-publish: an unnotarized build must never ship.
# --rotating-key is for the one release that ships a NEW public key in
# UpdateKeys.swift while still being signed with the OLD key (the one every
# installed copy trusts); see docs/RELEASE.md before using it.
#
# Never rebuild a version after publishing it: new bytes mean a new
# signature, and the manifest already on GitHub would no longer match.
set -euo pipefail

# In iCloud Drive, so every Mac that releases signs with the same key.
KEY="${PLUME_UPDATE_KEY:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Plume/plume_update_key.pem}"
REPO="${PLUME_RELEASE_REPO:-tuanlongsav/plume}"

VERSION=""
SKIP_NOTARIZE=0
PUBLISH=1
ROTATING=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; PUBLISH=0; shift ;;
        --no-publish)    PUBLISH=0; shift ;;
        --rotating-key)  ROTATING=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; exit 1 ;;
        *)
            [[ -z "$VERSION" ]] || { echo "Unexpected argument: $1" >&2; exit 1; }
            VERSION="$1"; shift ;;
    esac
done

step() { printf '\n=== %s ===\n' "$1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

[[ -n "$VERSION" ]] || die "usage: $0 X.Y [--skip-notarize] [--no-publish] [--rotating-key]"
# Same rule as build_app.sh, checked here so preflight fails before a build.
[[ "$VERSION" =~ ^([1-9][0-9]*|0)\.([1-9]?[0-9])$ ]] \
    || die "version must be MAJOR.MINOR, no leading zeros, MINOR ≤ 99 (got: $VERSION)"
TAG="v$VERSION"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SIGN_TOOL=(swift "$ROOT/Scripts/update_sign.swift")
APP="$ROOT/build/Plume.app"
DMG="$ROOT/build/Plume-$VERSION.dmg"
ZIP="$ROOT/build/Plume-$VERSION.zip"
MANIFEST="$ROOT/build/Plume-$VERSION.manifest.json"
NOTES="$ROOT/build/notes-$VERSION.md"

step "Preflight"
[[ -f "$KEY" ]] || die "signing key not found: $KEY (set PLUME_UPDATE_KEY)"
PUB="$("${SIGN_TOOL[@]}" pubkey "$KEY")"
# The app only accepts archives signed by the key it embeds. Publishing with
# any other key would ship an update every existing install rejects.
if grep -qF "publicKeyBase64 = \"$PUB\"" Sources/Plume/UpdateKeys.swift; then
    [[ "$ROTATING" -eq 0 ]] \
        || die "--rotating-key, but UpdateKeys.swift already embeds the signing key: nothing is rotating."
elif [[ "$ROTATING" -eq 1 ]]; then
    echo "WARNING: key rotation release — signed with the old key ($PUB)," >&2
    echo "         shipping the new key in UpdateKeys.swift." >&2
else
    die "Sources/Plume/UpdateKeys.swift does not embed this key's public half ($PUB)."
fi

mkdir -p build
# The section under "## X.Y" up to the next "## " heading becomes the notes.
awk -v head="## $VERSION" '
    index($0, head) == 1 && (length($0) == length(head) || substr($0, length(head) + 1, 1) == " ") { on = 1; next }
    on && /^## / { exit }
    on { print }
' CHANGELOG.md > "$NOTES"
grep -q '[^[:space:]]' "$NOTES" || die "CHANGELOG.md has no '## $VERSION' section with text under it."

LATEST="$(git tag -l 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n | tail -1 || true)"
if [[ -n "$LATEST" ]]; then
    TOP="$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -t. -k1,1n -k2,2n | tail -1)"
    [[ "$TOP" == "$VERSION" && "$LATEST" != "$VERSION" ]] \
        || die "$VERSION is not newer than the latest tag v$LATEST."
fi

if [[ "$PUBLISH" -eq 1 ]]; then
    [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean."
    [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "not on main."
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || die "main is not the same commit as origin/main — pull or push first."
    [[ -z "$(git tag -l "$TAG")" ]] || die "tag $TAG already exists locally."
    [[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ]] || die "tag $TAG already exists on origin."
    gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)."
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        die "release $TAG already exists on $REPO."
    fi
fi

step "Build, sign, notarize"
if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    bash "$ROOT/Scripts/release_sign.sh" "$VERSION" --skip-notarize
else
    bash "$ROOT/Scripts/release_sign.sh" "$VERSION"
fi
[[ -s "$ZIP" && -s "$DMG" ]] || die "release_sign.sh did not produce $ZIP and $DMG."

step "Updater manifest"
SIG="$("${SIGN_TOOL[@]}" sign "$KEY" "$ZIP")"
"${SIGN_TOOL[@]}" verify "$PUB" "$ZIP" "$SIG" >/dev/null || die "the fresh signature does not verify."
LENGTH="$(stat -f%z "$ZIP")"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
# Every value is digits, hex or base64, so nothing needs JSON escaping.
cat > "$MANIFEST" <<JSON
{
  "format": 1,
  "version": "$VERSION",
  "build": $BUILD,
  "minimumSystemVersion": "$MIN_OS",
  "asset": "Plume-$VERSION.zip",
  "length": $LENGTH,
  "sha256": "$SHA256",
  "ed25519": "$SIG"
}
JSON
cat "$MANIFEST"

if [[ "$PUBLISH" -eq 0 ]]; then
    step "Done (not published)"
    echo "Artifacts: $DMG"
    echo "           $ZIP"
    echo "           $MANIFEST"
    echo "Notes:     $NOTES"
    exit 0
fi

step "Tag + publish"
git tag -a "$TAG" -m "Plume $VERSION"
git push origin "$TAG"
if ! gh release create "$TAG" -R "$REPO" --title "Plume $VERSION" --notes-file "$NOTES" \
        "$DMG" "$ZIP" "$MANIFEST"; then
    # The tag is already public. Retry the upload with the SAME files rather
    # than rebuilding, which would change the signed bytes.
    die "gh release create failed. Retry with the same files:
  gh release create $TAG -R $REPO --title \"Plume $VERSION\" --notes-file $NOTES $DMG $ZIP $MANIFEST"
fi

step "Verify"
API="https://api.github.com/repos/$REPO/releases/latest"
LATEST_JSON=""
for _ in 1 2 3 4 5 6; do
    LATEST_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API" || true)"
    grep -q "\"tag_name\": *\"$TAG\"" <<<"$LATEST_JSON" && break
    sleep 5
done
grep -q "\"tag_name\": *\"$TAG\"" <<<"$LATEST_JSON" \
    || die "$API does not report $TAG — is the release a draft or a prerelease?"
for name in "Plume-$VERSION.dmg" "Plume-$VERSION.zip" "Plume-$VERSION.manifest.json"; do
    URL="https://github.com/$REPO/releases/download/$TAG/$name"
    CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")"
    [[ "$CODE" == "200" ]] || die "$URL answered $CODE."
    echo "200  $URL"
done
UPLOADED="$(gh release view "$TAG" -R "$REPO" --json assets \
    -q ".assets[] | select(.name == \"Plume-$VERSION.zip\") | .size")"
[[ "$UPLOADED" == "$LENGTH" ]] || die "uploaded zip is $UPLOADED bytes, manifest says $LENGTH."

step "Released $TAG"
echo "https://github.com/$REPO/releases/tag/$TAG"
