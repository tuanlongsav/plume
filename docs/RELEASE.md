# Phát hành Plume

Quy trình đưa một bản Plume lên GitHub Releases, nơi updater trong app tìm bản
mới. Mô hình giống vkey (chữ ký trên gói cập nhật + Developer ID + notarize),
nhưng không dùng Sparkle, không có `appcast.xml`: app đọc thẳng
`api.github.com/repos/tuanlongsav/plume/releases/latest`.

## 1. Quy tắc version

- `MAJOR.MINOR`, không số 0 đứng đầu, `MINOR` ≤ 99 (ví dụ `1.0`, `1.1`, … `1.12`, `2.0`).
  Không dùng cấp patch: hotfix cũng tăng `MINOR`.
- `CFBundleVersion` = `MAJOR*10000 + MINOR*100` (`1.1` → `10100`), do
  `Scripts/build_app.sh` tự tính từ `PLUME_VERSION`.
- Build cục bộ không đặt `PLUME_VERSION` là `0.0.0`: updater **không bao giờ**
  thay bản này, và cũng không thay bản ký ad-hoc.
- Tag là `vX.Y`. Release không được là draft hay prerelease (API `latest` bỏ qua chúng).

## 2. Khoá ký gói cập nhật (làm một lần)

Khoá Ed25519 riêng cho updater, khác chứng thư Developer ID. Khoá nằm trong
iCloud Drive (`iCloud Drive/Plume/`) để mọi máy Mac dùng để phát hành (Mac
Studio, MacBook…) ký bằng cùng một khoá; đó cũng là đường dẫn mặc định của
`release.sh`. Tạo **một lần, trên một máy**:

```bash
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
mkdir -p "$ICLOUD/Plume"
swift Scripts/update_sign.swift keygen "$ICLOUD/Plume/plume_update_key.pem"
```

Máy khác chỉ cần đợi iCloud đồng bộ file đó rồi kiểm tra in ra **cùng** public key:

```bash
swift Scripts/update_sign.swift pubkey "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Plume/plume_update_key.pem"
```

Bảo vệ khoá: ai có file này ký được bản cập nhật mà mọi máy đã cài Plume sẽ
chấp nhận (dù app trong gói vẫn phải ký Developer ID của anh). Bật **Advanced
Data Protection** cho iCloud để file được mã hoá đầu-cuối, và đừng chia sẻ thư
mục `Plume` trong iCloud Drive với ai.

Lệnh in ra public key (base64, 32 byte). Dán vào
`Sources/Plume/UpdateKeys.swift`:

```swift
static let publicKeyBase64 = "<giá trị vừa in>"
```

Commit dòng đó. Khi `publicKeyBase64` còn rỗng, updater tắt hẳn.

- **Không bao giờ** commit file `.pem` (`.gitignore` đã chặn `*.pem`, `*.key`).
- Ngoài iCloud, giữ thêm một bản backup ngoại tuyến (USB mã hoá, password
  manager). Xoá nhầm trong iCloud sẽ xoá trên mọi máy. Mất khoá = mọi bản đã
  cài không nhận bản mới nữa; người dùng phải tải DMG cài tay.
- In lại public key: `swift Scripts/update_sign.swift pubkey <file.pem>`.
- Đường dẫn khác: đặt `PLUME_UPDATE_KEY=/đường/dẫn/khoá.pem`.

Đối chiếu bằng OpenSSL 3 (`brew install openssl@3`; `/usr/bin/openssl` của macOS
là LibreSSL, không chắc hỗ trợ `-rawin`):

```bash
openssl pkey -in plume_update_key.pem -pubout -outform DER | tail -c 32 | base64
openssl pkeyutl -sign -rawin -inkey plume_update_key.pem -in Plume-1.1.zip | base64
```

### Đổi khoá (rotation)

App chỉ tin khoá nó đang nhúng. Muốn đổi khoá:

1. Tạo khoá mới, dán public key mới vào `UpdateKeys.swift`, commit.
2. Phát hành bản chuyển tiếp, ký bằng **khoá cũ** (khoá mọi bản đã cài tin):
   ```bash
   PLUME_UPDATE_KEY=<khoá-cũ.pem> bash Scripts/release.sh X.Y --rotating-key
   ```
3. Chờ người dùng lên `X.Y`. Từ bản sau, ký bằng khoá mới như thường lệ.

## 3. Phát hành một bản

Điều kiện trên Mac phát hành: chứng thư *Developer ID Application: Long Hoang
Tuan (U4B264GM2B)* trong keychain, notarytool profile `vkey`
(`PLUME_NOTARY_PROFILE` để đổi), `gh auth login` đã xong, khoá ở mục 2.

1. Code xong, `swift test` xanh, merge vào `main`.
2. Thêm mục đầu `CHANGELOG.md`:
   ```markdown
   ## 1.1 — 2026-11-20

   - Điều người dùng thấy, viết bằng tiếng Việt.
   ```
   Phần này thành release notes, hiện ngay trong hộp thoại cập nhật của app.
3. Commit, push `main`.
4. Chạy thử, không publish:
   ```bash
   bash Scripts/release.sh 1.1 --no-publish
   ```
5. Phát hành thật:
   ```bash
   bash Scripts/release.sh 1.1
   ```

`release.sh` làm và kiểm từng bước, dừng ngay khi một bước sai:

| Bước | Việc |
|---|---|
| Preflight | tree sạch, đang ở `main` trùng `origin/main`, version mới hơn tag cuối, tag/release chưa có, `gh` đã đăng nhập, khoá tồn tại **và khớp `UpdateKeys.swift`**, `CHANGELOG.md` có mục `## X.Y` |
| Build | `release_sign.sh X.Y`: universal, ký Developer ID + hardened runtime, notarize + staple app, zip app **sau khi staple**, DMG ký + notarize + staple |
| Manifest | ký Ed25519 toàn bộ `Plume-X.Y.zip`, tự verify, ghi `Plume-X.Y.manifest.json` |
| Publish | tag `vX.Y`, push tag, `gh release create` với 3 asset |
| Verify | `releases/latest` trả `vX.Y`, 3 URL asset trả 200, kích thước zip trên GitHub = `length` |

Asset của mỗi release:

| File | Dùng cho |
|---|---|
| `Plume-X.Y.dmg` | người tải tay, kéo vào Applications |
| `Plume-X.Y.zip` | updater trong app |
| `Plume-X.Y.manifest.json` | updater: `version`, `length`, `sha256`, `ed25519`, `minimumSystemVersion` |

**Không bao giờ build lại một version đã publish.** Bytes mới = chữ ký mới,
manifest trên GitHub không còn khớp và app từ chối. Lỗi sau khi publish thì
phát hành version kế tiếp.

## 4. Kiểm tra sau phát hành

- Mở một bản cũ hơn (Developer ID, trong `/Applications`) ▸ Plume ▸ Kiểm tra
  cập nhật… → hộp thoại hiện bản mới với release notes.
- Cập nhật → thanh tiến trình → app tự thoát, mở lại → thông báo "Đã cập nhật
  lên Plume X.Y" → Giới thiệu Plume hiện đúng version, vẫn đăng nhập.

Thử với repo nháp trước khi dùng repo thật:

```bash
defaults write com.htl.plume plume.updateRepo <owner>/plume-test
PLUME_RELEASE_REPO=<owner>/plume-test bash Scripts/release.sh 1.1
# ... thử trong app ...
defaults delete com.htl.plume plume.updateRepo
```

## 5. Lỗi hay gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| Preflight: `UpdateKeys.swift does not embed this key` | Khoá trong `PLUME_UPDATE_KEY` không phải khoá app đang nhúng. Dùng đúng khoá; đừng sửa `UpdateKeys.swift` nếu không có kế hoạch đổi khoá (mục 2). |
| `releases/latest does not report vX.Y` | Release đang là draft/prerelease, hoặc API chậm vài giây. Kiểm `gh release view vX.Y`. |
| `gh release create failed` sau khi tag đã push | Chạy lại đúng lệnh `gh release create` script in ra, **với cùng các file** — đừng build lại. |
| App báo "Gói cập nhật không hợp lệ" | Zip không khớp manifest/chữ ký, hoặc app trong zip không phải bản Developer ID đúng version. Xem asset trên GitHub có bị upload nhầm không. |
| App báo "Không thể tự cập nhật" | App chạy từ DMG / Downloads (App Translocation) hoặc tài khoản không ghi được vào thư mục chứa app. Kéo vào `/Applications`. |
| Notarize / ký lỗi | Xem `Scripts/release_sign.sh` và mục lỗi tương ứng trong `RELEASE.md` của vkey: cùng chứng thư, cùng profile `vkey`. |
