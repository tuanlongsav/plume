#!/usr/bin/env bash
# Build, sign, notarize and staple the release artifacts for version X.Y.
#
#   bash Scripts/release_sign.sh X.Y [--skip-notarize] [--keep-tmp]
#
#   → build/Plume-X.Y.dmg   drag-to-install, for people downloading by hand
#   → build/Plume-X.Y.zip   the stapled app, the payload of the in-app updater
#
# Scripts/release.sh runs this, then signs the zip for the updater and
# publishes. Modelled on the vkey release pipeline. Every verification step is
# a hard failure: the script exits non-zero rather than letting an artifact
# that Gatekeeper will reject reach the DMG.
#
# Why each step exists:
#   - Hardened Runtime + a secure timestamp, or notarization refuses the upload.
#   - The app is notarized AND stapled, so it opens with no network round trip.
#   - The zip is made AFTER stapling: a zip of the unstapled app carries no
#     ticket, and an updated app would need a network check on first launch.
#   - The DMG is signed and notarized SEPARATELY: Gatekeeper assesses the
#     container the user downloads, not only the app inside it. An unsigned DMG
#     warns on first open even when the app inside is stapled.
set -euo pipefail

SIGN_IDENTITY="${PLUME_SIGN_IDENTITY:-Developer ID Application: Long Hoang Tuan (U4B264GM2B)}"
# One Apple ID and team covers every app; the profile is named after the first
# project that created it.
KEYCHAIN_PROFILE="${PLUME_NOTARY_PROFILE:-vkey}"
# The designated requirement the in-app updater enforces on every update
# (Updater.requirementText; UpdateVerifierTests keeps the two identical). An
# app that fails it would be rejected by every installed copy.
REQUIREMENT='anchor apple generic and identifier "com.htl.plume" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "U4B264GM2B"'

VERSION=""
SKIP_NOTARIZE=0
KEEP_TMP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --keep-tmp)      KEEP_TMP=1; shift ;;
        -*) echo "Unknown argument: $1" >&2; exit 1 ;;
        *)
            [[ -z "$VERSION" ]] || { echo "Unexpected argument: $1" >&2; exit 1; }
            VERSION="$1"; shift ;;
    esac
done
[[ -n "$VERSION" ]] || { echo "Usage: $0 X.Y [--skip-notarize] [--keep-tmp]" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Plume.app"
DMG="$ROOT/build/Plume-$VERSION.dmg"
ZIP="$ROOT/build/Plume-$VERSION.zip"
# A private temp dir per run: fixed /tmp paths let two runs delete each
# other's staging mid-build.
TMP="$(mktemp -d)"
NOTARY_ZIP="$TMP/notarize.zip"
STAGE="$TMP/stage"

step() { printf '\n=== %s ===\n' "$1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }
cleanup() { [[ "$KEEP_TMP" -eq 1 ]] && echo "Temp kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

step "Preflight"
# Capture first, then grep: piping into `grep -q` under `set -o pipefail` kills
# the producer with SIGPIPE and fails the pipeline on a SUCCESSFUL match.
IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
grep -qF "$SIGN_IDENTITY" <<<"$IDENTITIES" \
    || die "signing identity not in keychain: $SIGN_IDENTITY"

# The certificate codesign will use, picked by its SHA-1: after a renewal the
# old and new certificates share a name, and `find-certificate -c` alone
# returns whichever comes first.
CERT_SHA1="$(grep -F "\"$SIGN_IDENTITY\"" <<<"$IDENTITIES" | awk 'NR == 1 {print $2}')"
CERT_END="$(security find-certificate -a -Z -p -c "${SIGN_IDENTITY%% (*}" 2>/dev/null \
    | awk -v h="$CERT_SHA1" '/^SHA-1 hash:/ {on = ($3 == h)}
        on && /BEGIN CERTIFICATE/ {p = 1} p {print} p && /END CERTIFICATE/ {exit}' \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
if [[ -z "$CERT_END" ]]; then
    echo "WARNING: could not read the signing certificate's expiry date." >&2
else
    echo "Signing cert valid until: $CERT_END"
    # openssl prints English month names; parse them in the C locale.
    END_EPOCH="$(LC_ALL=C date -j -f '%b %e %T %Y %Z' "$CERT_END" '+%s' 2>/dev/null || echo 0)"
    [[ "$END_EPOCH" != 0 ]] || echo "WARNING: could not parse the expiry date." >&2
    NOW_EPOCH="$(date '+%s')"
    [[ "$END_EPOCH" == 0 || "$END_EPOCH" -gt "$NOW_EPOCH" ]] \
        || die "signing cert EXPIRED on $CERT_END"
    if [[ "$END_EPOCH" != 0 && $((END_EPOCH - NOW_EPOCH)) -lt 2592000 ]]; then
        echo "WARNING: signing cert expires in under 30 days ($CERT_END)." >&2
    fi
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
        || die "notarytool keychain profile '$KEYCHAIN_PROFILE' is missing or rejected.
       Recreate with: xcrun notarytool store-credentials"
fi

step "1/5 Build + sign $VERSION (universal, hardened runtime)"
rm -f "$DMG" "$ZIP"
# build_app.sh validates the version format and refuses anything else.
PLUME_VERSION="$VERSION" PLUME_UNIVERSAL=1 PLUME_SIGN_IDENTITY="$SIGN_IDENTITY" \
    bash "$ROOT/Scripts/build_app.sh" release

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$PLIST_VERSION" == "$VERSION" ]] \
    || die "Info.plist says $PLIST_VERSION, expected $VERSION."

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Plume")"
grep -q x86_64 <<<"$ARCHS" && grep -q arm64 <<<"$ARCHS" \
    || die "binary is not universal (got: $ARCHS) — Intel Macs could not run it."

SIG="$(codesign -dvv "$APP" 2>&1 || true)"
grep -qF "Authority=${SIGN_IDENTITY}" <<<"$SIG" \
    || die "app is not signed with the Developer ID. Check: codesign -dvv $APP"
grep -q 'flags=.*runtime' <<<"$SIG" \
    || die "hardened runtime is off — notarization would reject this."
codesign --verify --strict "$APP" || die "app fails signature verification."
codesign --verify --strict -R="$REQUIREMENT" "$APP" \
    || die "app does not meet the updater's Developer ID requirement (team U4B264GM2B)."

# The floor the app declares must be the one every slice was built for, and
# the SDK version it records (which AppKit and WebKit read for linked-on-or-
# after behaviour) must be the pinned one from build_app.sh, also carried in
# the signature as its Runtime Version.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
padded() { awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 }' <<<"$1"; }
EXPECTED_SDK="$(printf '%s\n%s\n' "$(padded "$MIN_OS")" "14.0.0" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
BUILD_INFO="$(vtool -show-build "$APP/Contents/MacOS/Plume")"
for want in minos sdk; do
    GOT="$(awk -v k="$want" '$1 == k { print $2 }' <<<"$BUILD_INFO" | sort -u)"
    case "$want" in
        minos) [[ "$(padded "$GOT")" == "$(padded "$MIN_OS")" ]] \
                   || die "binary minos is '$GOT', Info.plist says $MIN_OS." ;;
        sdk)   [[ "$(padded "$GOT")" == "$EXPECTED_SDK" ]] \
                   || die "binary records sdk '$GOT', expected $EXPECTED_SDK (build_app.sh SDK_STAMP)." ;;
    esac
done
grep -qF "Runtime Version=$EXPECTED_SDK" <<<"$(codesign -dvvv "$APP" 2>&1 || true)" \
    || die "the signature's Runtime Version is not $EXPECTED_SDK."
echo "Minimum macOS $MIN_OS, linked behaviour of SDK $EXPECTED_SDK"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "--skip-notarize: notarization skipped. The result is NOT shippable."
else
    step "2/5 Notarize + staple app"
    # ditto, not zip: it preserves the bundle's symlinks and extended attributes.
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP"
    # spctl is advisory: this machine may have assessments disabled, in which
    # case it accepts anything. `stapler validate` is the load-bearing check.
    spctl --assess --type exec -vv "$APP" 2>&1 | sed 's/^/  /' || true
    xcrun stapler validate "$APP" || die "app has no stapled notarization ticket."
fi

step "3/5 Updater zip"
ditto -c -k --keepParent "$APP" "$ZIP"
[[ -s "$ZIP" ]] || die "ditto produced no zip."

step "4/5 Stage + create DMG"
# Staging must start empty: `cp -R src.app dir/` MERGES into an existing bundle
# of the same name, leaving stale files that break _CodeSignature.
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
codesign --verify --strict "$STAGE/Plume.app" \
    || die "staged app fails verification — stale files in the bundle?"
ln -sfn /Applications "$STAGE/Applications"

case "${MIN_OS%%.*}" in
    13) MIN_NAME="Ventura" ;;
    14) MIN_NAME="Sonoma" ;;
    15) MIN_NAME="Sequoia" ;;
    26) MIN_NAME="Tahoe" ;;
    *)  MIN_NAME="" ;;
esac
# Unquoted heredoc, so the floor comes from the app; the text has no other
# $ or backtick.
cat > "$STAGE/Đọc trước khi cài.txt" <<NOTE
Plume — Messenger cho macOS
===========================

CÀI ĐẶT
Kéo Plume vào thư mục Applications, rồi mở từ Launchpad. Xong.

Ứng dụng đã được ký bằng chứng thư Apple Developer ID và đã qua công chứng
(notarization) của Apple, nên macOS mở bình thường, không cần chạy lệnh gì
trong Terminal, không có cảnh báo "ứng dụng bị hỏng".

Các bản sau tự cập nhật: Plume kiểm tra GitHub mỗi ngày một lần và hỏi trước
khi cài. Tắt trong menu Plume ▸ Tự động kiểm tra cập nhật.

Lần đầu vào cuộc gọi thoại hoặc video, macOS sẽ hỏi quyền micro và camera —
đó là hộp thoại của hệ điều hành, không phải của Plume.

YÊU CẦU
- macOS $MIN_OS${MIN_NAME:+ ($MIN_NAME)} trở lên. Nếu Plume không mở được, hãy
  cập nhật macOS (Cài đặt hệ thống ▸ Cập nhật phần mềm) rồi thử lại.
- Chạy trên cả máy Apple Silicon và Intel.

Plume là lớp vỏ gói Messenger (messenger.com, hoặc facebook.com/messages với
tài khoản Meta đã chuyển sang Facebook) bằng WebKit của hệ thống. Tài khoản và tin
nhắn đi thẳng tới Meta như khi dùng trình duyệt; không có máy chủ trung gian
nào của Plume, và không có dữ liệu nào được gửi đi đâu khác.
NOTE

hdiutil create -volname "Plume $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -2
[[ -f "$DMG" ]] || die "hdiutil produced no dmg."

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    step "5/5 Sign + notarize + staple DMG"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG" || die "dmg has no stapled notarization ticket."
    grep -qF "Authority=${SIGN_IDENTITY}" <<<"$(codesign -dvv "$DMG" 2>&1 || true)" \
        || die "dmg is not signed with the Developer ID."
fi

step "Done"
echo "DMG:   $DMG ($(du -h "$DMG" | cut -f1))"
echo "ZIP:   $ZIP ($(stat -f%z "$ZIP") bytes)"
echo "Archs: $ARCHS"
if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo
    echo "WARNING: built with --skip-notarize — do not share these files."
fi
