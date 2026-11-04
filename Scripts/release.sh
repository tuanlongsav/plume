#!/usr/bin/env bash
# Publish Plume X.Y to GitHub Releases, where the in-app updater finds it.
#
#   bash Scripts/release.sh X.Y [--skip-notarize] [--no-publish] [--from-build]
#                               [--rotating-key] [--raise-floor]
#
#   1. preflight     clean tree on an up-to-date main, new version, gh logged
#                    in, signing key present and matching UpdateKeys.swift,
#                    CHANGELOG.md has a "## X.Y" section
#   2. build         Scripts/release_sign.sh X.Y → Plume-X.Y.dmg + .zip
#   3. manifest      Ed25519-sign the zip → Plume-X.Y.manifest.json
#   4. publish       tag vX.Y, push, gh release create with the three assets
#   5. verify        releases/latest is vX.Y, every asset URL answers 200
#
# --no-publish stops after step 3 (dry run; artifacts stay in build/). From a
#   clean tree that matches origin/main it also records the commit in
#   build/Plume-X.Y.commit, which makes the artifacts a release candidate.
# --from-build publishes that candidate as it is, skipping steps 2-3, after
#   checking it: same commit as HEAD, stapled DMG and app, the updater's
#   Developer ID requirement, and a manifest that matches the zip and verifies
#   with the trusted key. So what was tested is byte for byte what ships.
# --skip-notarize implies --no-publish: an unnotarized build must never ship.
# --raise-floor allows a release whose minimum macOS is above the previous
#   release's. Without it a publish refuses: Macs between the two floors
#   would stop getting updates.
# --rotating-key is for the one release that ships a NEW public key in
# UpdateKeys.swift while still being signed with the OLD key (the one every
# installed copy trusts); see docs/RELEASE.md before using it.
#
# Never rebuild a version after publishing it: new bytes mean a new
# signature, and the manifest already on GitHub would no longer match.
set -euo pipefail

# In iCloud Drive, so every Mac that releases signs with the same key.
KEY="${PLUME_UPDATE_KEY:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Plume/plume_update_key.pem}"
DEFAULT_REPO="tuanlongsav/plume"
REPO="${PLUME_RELEASE_REPO:-$DEFAULT_REPO}"
# A dry run against a test repository must not tag the real one: the tag
# would block the real release of that version.
TAG_ORIGIN=1
[[ "$REPO" == "$DEFAULT_REPO" ]] || TAG_ORIGIN=0

VERSION=""
SKIP_NOTARIZE=0
PUBLISH=1
ROTATING=0
FROM_BUILD=0
RAISE_FLOOR=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; PUBLISH=0; shift ;;
        --no-publish)    PUBLISH=0; shift ;;
        --rotating-key)  ROTATING=1; shift ;;
        --from-build)    FROM_BUILD=1; shift ;;
        --raise-floor)   RAISE_FLOOR=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        -*) echo "Unknown argument: $1" >&2; exit 1 ;;
        *)
            [[ -z "$VERSION" ]] || { echo "Unexpected argument: $1" >&2; exit 1; }
            VERSION="$1"; shift ;;
    esac
done

step() { printf '\n=== %s ===\n' "$1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

[[ -n "$VERSION" ]] || die "usage: $0 X.Y [--skip-notarize] [--no-publish] [--from-build] [--rotating-key] [--raise-floor]"
[[ "$FROM_BUILD" -eq 0 || "$PUBLISH" -eq 1 ]] \
    || die "--from-build publishes; it cannot be combined with --no-publish or --skip-notarize."
# Same rule as build_app.sh, checked here so preflight fails before a build.
[[ "$VERSION" =~ ^([1-9][0-9]*|0)\.([1-9]?[0-9])$ ]] \
    || die "version must be MAJOR.MINOR, no leading zeros, MINOR ≤ 99 (got: $VERSION)"
# 0.0 is what local builds report; the updater treats it as a dev build.
[[ "$VERSION" != "0.0" ]] || die "0.0 is reserved for local builds."
TAG="v$VERSION"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SIGN_TOOL=(swift "$ROOT/Scripts/update_sign.swift")
APP="$ROOT/build/Plume.app"
DMG="$ROOT/build/Plume-$VERSION.dmg"
ZIP="$ROOT/build/Plume-$VERSION.zip"
MANIFEST="$ROOT/build/Plume-$VERSION.manifest.json"
NOTES="$ROOT/build/notes-$VERSION.md"
CANDIDATE="$ROOT/build/Plume-$VERSION.commit"

step "Preflight"
[[ -f "$KEY" ]] || die "signing key not found: $KEY (set PLUME_UPDATE_KEY)"
case "$(cd "$(dirname "$KEY")" && pwd)/" in
    "$ROOT"/*) die "the signing key is inside the repository ($KEY): one git clean deletes it. Keep it outside." ;;
esac
PUB="$("${SIGN_TOOL[@]}" pubkey "$KEY")"

# Tags on origin decide what "newer" means and which key installs trust;
# local tags may be stale.
if ! git fetch -q --tags origin; then
    [[ "$PUBLISH" -eq 0 ]] || die "cannot fetch tags from origin."
    echo "WARNING: offline — comparing against local tags only." >&2
fi
LATEST="$(git tag -l 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n | tail -1 || true)"
if [[ -n "$LATEST" ]]; then
    TOP="$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -t. -k1,1n -k2,2n | tail -1)"
    [[ "$TOP" == "$VERSION" && "$LATEST" != "$VERSION" ]] \
        || die "$VERSION is not newer than the latest tag v$LATEST."
fi

# The app only accepts archives signed by the key it embeds, so the key that
# matters is the one in the LATEST RELEASE, which is what installs run. HEAD
# may embed a new key only in a rotation release (docs/RELEASE.md).
embedded_key() { sed -n 's/.*publicKeyBase64 = "\([^"]*\)".*/\1/p'; }
HEAD_KEY="$(embedded_key < Sources/Plume/UpdateKeys.swift)"
[[ -n "$HEAD_KEY" ]] || die "UpdateKeys.swift embeds no key: this build could never update itself."
TRUSTED=""
if [[ -n "$LATEST" ]]; then
    TRUSTED="$(git show "v$LATEST:Sources/Plume/UpdateKeys.swift" 2>/dev/null | embedded_key || true)"
fi
[[ -n "$TRUSTED" ]] || TRUSTED="$HEAD_KEY"   # first release with a key
[[ "$PUB" == "$TRUSTED" ]] \
    || die "this key ($PUB) is not the one installed copies trust ($TRUSTED)."
if [[ "$HEAD_KEY" == "$TRUSTED" ]]; then
    [[ "$ROTATING" -eq 0 ]] \
        || die "--rotating-key, but HEAD embeds the key installs already trust: nothing is rotating."
elif [[ "$ROTATING" -eq 1 ]]; then
    echo "WARNING: key rotation release — signed with the trusted key ($PUB)," >&2
    echo "         shipping the new key $HEAD_KEY in UpdateKeys.swift." >&2
else
    die "UpdateKeys.swift embeds a different key from v$LATEST; that is a rotation (--rotating-key)."
fi

mkdir -p build
# The section under "## X.Y" up to the next "## " heading becomes the notes.
awk -v head="## $VERSION" '
    index($0, head) == 1 && (length($0) == length(head) || substr($0, length(head) + 1, 1) == " ") { on = 1; next }
    on && /^## / { exit }
    on { print }
' CHANGELOG.md > "$NOTES"
grep -q '[^[:space:]]' "$NOTES" || die "CHANGELOG.md has no '## $VERSION' section with text under it."
# The heading ships with the release (and a candidate is what ships), so a
# placeholder such as "chưa phát hành" must have become a date by now.
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    grep -qE "^## ${VERSION//./\\.} — [0-9]{4}-[0-9]{2}-[0-9]{2}\$" CHANGELOG.md \
        || die "CHANGELOG.md: date the heading, '## $VERSION — YYYY-MM-DD' (the day the candidate is built)."
fi

if [[ "$PUBLISH" -eq 1 ]]; then
    [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean."
    [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "not on main."
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || die "main is not the same commit as origin/main — pull or push first."
    if [[ "$TAG_ORIGIN" -eq 1 ]]; then
        [[ -z "$(git tag -l "$TAG")" ]] || die "tag $TAG already exists locally."
        [[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ]] || die "tag $TAG already exists on origin."
    fi
    gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)."
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        die "release $TAG already exists on $REPO."
    fi
fi

if [[ "$FROM_BUILD" -eq 1 ]]; then
    step "Check the release candidate"
    for f in "$DMG" "$ZIP" "$MANIFEST" "$CANDIDATE"; do
        [[ -s "$f" ]] || die "missing $f — run: bash Scripts/release.sh $VERSION --no-publish"
    done
    [[ "$(cat "$CANDIDATE")" == "$(git rev-parse HEAD)" ]] \
        || die "the candidate was built from $(cat "$CANDIDATE"), HEAD is $(git rev-parse HEAD)."
    xcrun stapler validate "$DMG" >/dev/null || die "$DMG has no stapled notarization ticket."
    # Check the app the updater will unpack, not whatever build/Plume.app is now.
    REQUIREMENT="$(sed -n "s/^REQUIREMENT='\(.*\)'$/\1/p" "$ROOT/Scripts/release_sign.sh")"
    [[ -n "$REQUIREMENT" ]] || die "cannot read REQUIREMENT from release_sign.sh."
    UNPACK="$(mktemp -d)"
    trap 'rm -rf "$UNPACK"' EXIT
    ditto -x -k "$ZIP" "$UNPACK"
    [[ -d "$UNPACK/Plume.app" ]] || die "$ZIP does not contain Plume.app at its top level."
    xcrun stapler validate "$UNPACK/Plume.app" >/dev/null || die "the zipped app is not stapled."
    codesign --verify --strict -R="$REQUIREMENT" "$UNPACK/Plume.app" \
        || die "the zipped app does not meet the updater's Developer ID requirement."
    APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$UNPACK/Plume.app/Contents/Info.plist")"
    [[ "$APP_VERSION" == "$VERSION" ]] || die "the zipped app is version $APP_VERSION."
    MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$UNPACK/Plume.app/Contents/Info.plist")"
    field() { plutil -extract "$1" raw -o - "$MANIFEST"; }
    LENGTH="$(stat -f%z "$ZIP")"
    [[ "$(field version)" == "$VERSION" ]] || die "manifest version is $(field version)."
    [[ "$(field asset)" == "Plume-$VERSION.zip" ]] || die "manifest names asset $(field asset)."
    [[ "$(field length)" == "$LENGTH" ]] || die "manifest length $(field length), zip is $LENGTH bytes."
    [[ "$(field sha256)" == "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" ]] || die "manifest sha256 does not match the zip."
    [[ "$(field minimumSystemVersion)" == "$MIN_OS" ]] || die "manifest minimum macOS differs from the app's."
    "${SIGN_TOOL[@]}" verify "$PUB" "$ZIP" "$(field ed25519)" >/dev/null \
        || die "the manifest's signature does not verify with the trusted key."
    cat "$MANIFEST"
else
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

    # A candidate is only what a publish could have built: a clean tree at
    # origin/main, notarized. Anything else stays a local test build.
    rm -f "$CANDIDATE"
    if [[ "$SKIP_NOTARIZE" -eq 0 && -z "$(git status --porcelain)" ]] \
        && git fetch -q origin main \
        && [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]]; then
        git rev-parse HEAD > "$CANDIDATE"
    fi
fi

step "Minimum macOS"
# Compared with what the last release's manifest says, which is what
# installed copies were told; padded to three numbers for a numeric sort.
padded() { awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 }' <<<"$1"; }
PREV_MIN=""
if [[ -n "$LATEST" ]]; then
    PREV_MIN="$(curl -fsSL "https://github.com/$REPO/releases/download/v$LATEST/Plume-$LATEST.manifest.json" 2>/dev/null \
        | plutil -extract minimumSystemVersion raw -o - - 2>/dev/null || true)"
fi
if [[ -z "$PREV_MIN" ]]; then
    if [[ -n "$LATEST" && "$PUBLISH" -eq 1 && "$TAG_ORIGIN" -eq 1 ]]; then
        die "cannot read the minimum macOS from v$LATEST's manifest."
    fi
    echo "$VERSION needs macOS $MIN_OS (no previous release to compare with)."
else
    echo "v$LATEST needs macOS $PREV_MIN; $VERSION needs macOS $MIN_OS."
    TOP="$(printf '%s\n%s\n' "$(padded "$PREV_MIN")" "$(padded "$MIN_OS")" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    if [[ "$TOP" == "$(padded "$MIN_OS")" && "$TOP" != "$(padded "$PREV_MIN")" ]]; then
        if [[ "$RAISE_FLOOR" -eq 1 ]]; then
            echo "WARNING: raising the minimum macOS; Macs below $MIN_OS stay on v$LATEST." >&2
        elif [[ "$PUBLISH" -eq 1 ]]; then
            die "$VERSION raises the minimum macOS from $PREV_MIN to $MIN_OS; Macs in between would stop updating. Use --raise-floor if that is intended."
        else
            echo "WARNING: this raises the minimum macOS; publishing will need --raise-floor." >&2
        fi
    fi
fi

if [[ "$PUBLISH" -eq 0 ]]; then
    step "Done (not published)"
    echo "Artifacts: $DMG"
    echo "           $ZIP"
    echo "           $MANIFEST"
    echo "Notes:     $NOTES"
    if [[ -s "$CANDIDATE" ]]; then
        echo "Candidate: $(cat "$CANDIDATE") — publish exactly these files with:"
        echo "           bash Scripts/release.sh $VERSION --from-build"
    else
        echo "Not a release candidate (unnotarized, uncommitted or unpushed)."
    fi
    exit 0
fi

step "Tag + publish"
if [[ "$TAG_ORIGIN" -eq 1 ]]; then
    git tag -a "$TAG" -m "Plume $VERSION"
    git push origin "$TAG"
else
    echo "Test repository $REPO: not tagging origin; gh creates $TAG there."
fi
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
