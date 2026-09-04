#!/usr/bin/env bash
# Build, sign, notarize and staple a shippable Plume.dmg.
#
#   bash Scripts/release_sign.sh [--skip-notarize] [--keep-tmp]
#
# Modelled on the vkey release pipeline. Every verification step is a hard
# failure: the script exits non-zero rather than letting an artifact that
# Gatekeeper will reject reach the DMG.
#
# Why each step exists:
#   - Hardened Runtime + a secure timestamp, or notarization refuses the upload.
#   - The app is notarized AND stapled, so it opens with no network round trip.
#   - The DMG is signed and notarized SEPARATELY: Gatekeeper assesses the
#     container the user downloads, not only the app inside it. An unsigned DMG
#     warns on first open even when the app inside is stapled.
set -euo pipefail

SIGN_IDENTITY="${PLUME_SIGN_IDENTITY:-Developer ID Application: Long Hoang Tuan (U4B264GM2B)}"
# One Apple ID and team covers every app; the profile is named after the first
# project that created it.
KEYCHAIN_PROFILE="${PLUME_NOTARY_PROFILE:-vkey}"

SKIP_NOTARIZE=0
KEEP_TMP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --keep-tmp)      KEEP_TMP=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Plume.app"
DMG="$ROOT/build/Plume.dmg"
ZIP="/tmp/plume-notarize.zip"
STAGE="/tmp/plume-dmg-staging"

step() { printf '\n=== %s ===\n' "$1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

step "Preflight"
# Capture first, then grep: piping into `grep -q` under `set -o pipefail` kills
# the producer with SIGPIPE and fails the pipeline on a SUCCESSFUL match.
IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
grep -qF "$SIGN_IDENTITY" <<<"$IDENTITIES" \
    || die "signing identity not in keychain: $SIGN_IDENTITY"

CERT_END="$(security find-certificate -c "${SIGN_IDENTITY%% (*}" -p 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
if [[ -n "$CERT_END" ]]; then
    echo "Signing cert valid until: $CERT_END"
    END_EPOCH="$(date -j -f '%b %e %T %Y %Z' "$CERT_END" '+%s' 2>/dev/null || echo 0)"
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

step "1/5 Build + sign (universal, hardened runtime)"
rm -rf "$STAGE" "$ZIP"
PLUME_UNIVERSAL=1 PLUME_SIGN_IDENTITY="$SIGN_IDENTITY" \
    bash "$ROOT/Scripts/build_app.sh" release

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Plume")"
grep -q x86_64 <<<"$ARCHS" && grep -q arm64 <<<"$ARCHS" \
    || die "binary is not universal (got: $ARCHS) — Intel Macs could not run it."

SIG="$(codesign -dvv "$APP" 2>&1 || true)"
grep -qF "Authority=${SIGN_IDENTITY}" <<<"$SIG" \
    || die "app is not signed with the Developer ID. Check: codesign -dvv $APP"
grep -q 'flags=.*runtime' <<<"$SIG" \
    || die "hardened runtime is off — notarization would reject this."
codesign --verify --strict "$APP" || die "app fails signature verification."

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "--skip-notarize: steps 2 and 5 skipped. The result is NOT shippable."
else
    step "2/5 Notarize + staple app"
    # ditto, not zip: it preserves the bundle's symlinks and extended attributes.
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP"
    # spctl is advisory: this machine may have assessments disabled, in which
    # case it accepts anything. `stapler validate` is the load-bearing check.
    spctl --assess --type exec -vv "$APP" 2>&1 | sed 's/^/  /' || true
    xcrun stapler validate "$APP" || die "app has no stapled notarization ticket."
fi

step "3/5 Stage DMG"
# Staging must start empty: `cp -R src.app dir/` MERGES into an existing bundle
# of the same name, leaving stale files that break _CodeSignature.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
codesign --verify --strict "$STAGE/Plume.app" \
    || die "staged app fails verification — stale files in the bundle?"
ln -sfn /Applications "$STAGE/Applications"

cat > "$STAGE/Đọc trước khi cài.txt" <<'NOTE'
Plume — Messenger cho macOS
===========================

CÀI ĐẶT
Kéo Plume vào thư mục Applications, rồi mở từ Launchpad. Xong.

Ứng dụng đã được ký bằng chứng thư Apple Developer ID và đã qua công chứng
(notarization) của Apple, nên macOS mở bình thường, không cần chạy lệnh gì
trong Terminal, không có cảnh báo "ứng dụng bị hỏng".

Lần đầu vào cuộc gọi thoại hoặc video, macOS sẽ hỏi quyền micro và camera —
đó là hộp thoại của hệ điều hành, không phải của Plume.

YÊU CẦU
- macOS 14 (Sonoma) trở lên.
- Chạy trên cả máy Apple Silicon và Intel.

Plume là lớp vỏ gói messenger.com bằng WebKit của hệ thống. Tài khoản và tin
nhắn đi thẳng tới Meta như khi dùng trình duyệt; không có máy chủ trung gian
nào của Plume, và không có dữ liệu nào được gửi đi đâu khác.
NOTE

step "4/5 Create DMG"
rm -f "$DMG"
hdiutil create -volname "Plume" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -2
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

[[ "$KEEP_TMP" -eq 1 ]] || rm -rf "$STAGE" "$ZIP"

step "Done"
echo "DMG:   $DMG"
echo "Size:  $(du -h "$DMG" | cut -f1)"
echo "Archs: $ARCHS"
if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo
    echo "WARNING: built with --skip-notarize — do not share this file."
fi
