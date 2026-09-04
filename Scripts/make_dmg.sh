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

# Anything leaving this machine is built for both architectures.
PLUME_UNIVERSAL=1 bash "$ROOT/Scripts/build_app.sh" "$CONFIG"

echo "▸ staging DMG contents…"
STAGE="$(mktemp -d)/Plume"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Plume is signed ad-hoc, not with a Developer ID, and is not notarised. macOS
# quarantines anything downloaded and refuses to launch an ad-hoc-signed app
# that carries the quarantine flag — with a message claiming the app is
# "damaged", which it is not. Ship the fix alongside it.
cat > "$STAGE/ĐỌC TRƯỚC KHI CÀI.txt" <<'NOTE'
Plume — Messenger cho macOS
===========================

CÀI ĐẶT
1. Kéo Plume vào thư mục Applications.
2. Mở Terminal, dán đúng dòng này rồi Enter:

     xattr -dr com.apple.quarantine /Applications/Plume.app

3. Mở Plume từ Launchpad hoặc Applications.

TẠI SAO PHẢI CHẠY DÒNG LỆNH ĐÓ
Plume chưa được ký bằng chứng thư Apple Developer (mất phí thường niên) và
chưa qua công chứng (notarization) của Apple. Vì vậy macOS sẽ gắn cờ cách ly
cho mọi bản tải về và từ chối mở, kèm thông báo nói rằng ứng dụng "bị hỏng".
Ứng dụng KHÔNG hỏng — dòng lệnh trên chỉ gỡ cờ cách ly đó.

Nếu bạn không tự tin chạy lệnh trên thì đừng cài. Đó là lời khuyên đúng cho
mọi phần mềm chưa ký, kể cả phần mềm này.

YÊU CẦU
- macOS 14 (Sonoma) trở lên.
- Chạy được trên cả máy Apple Silicon và Intel.

Plume chỉ là lớp vỏ gói messenger.com — dữ liệu đăng nhập nằm trên máy bạn,
không đi qua máy chủ nào khác.
NOTE

echo "▸ hdiutil create → ${DMG} …"
rm -f "$DMG"
hdiutil create -volname "Plume" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "✓ built: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/  size: /'
