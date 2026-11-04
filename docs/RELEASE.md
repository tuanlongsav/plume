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
`release.sh`.

**Đã tạo ngày 2026-11-03 trên MacBook**; public key đã nhúng trong
`UpdateKeys.swift` từ bản 1.0. **Không tạo lại**: khoá mới làm mọi bản đã cài
từ chối bản cập nhật (muốn đổi thì theo mục "Đổi khoá" bên dưới). Lệnh đã dùng,
để tham khảo:

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

`keygen` in public key (base64, 32 byte), giá trị nằm ở
`Sources/Plume/UpdateKeys.swift`:

```swift
static let publicKeyBase64 = "<giá trị keygen in ra>"
```

Khi `publicKeyBase64` rỗng, updater tắt hẳn; test `testEmbeddedPublicKeyIsUsable`
và preflight của `release.sh` đều chặn trường hợp đó.

- **Không bao giờ** commit file `.pem` (`.gitignore` đã chặn `*.pem`, `*.key`).
- Ngoài iCloud, giữ thêm một bản backup ngoại tuyến (USB mã hoá, password
  manager). Xoá nhầm trong iCloud sẽ xoá trên mọi máy. Mất khoá = mọi bản đã
  cài không nhận bản mới nữa; người dùng phải tải DMG cài tay.
- In lại public key: `swift Scripts/update_sign.swift pubkey <file.pem>`.
- Đường dẫn khác: đặt `PLUME_UPDATE_KEY=/đường/dẫn/khoá.pem`. `release.sh` từ
  chối khoá nằm trong thư mục repo: một lần `git clean -xfd` là mất.
- Một bản sao nằm trong két `KhoaKy` (xem `~/Desktop/Claude/KHOA-KY.md`).
- iCloud có thể "dọn" file khỏi ổ khi bật *Optimize Mac Storage*: file vẫn hiện
  nhưng đọc khi offline thì `update_sign.swift` báo `cannot read`. Mở thư mục
  `Plume` trong Finder và chọn *Download Now* (hoặc *Keep Downloaded*) trước khi
  phát hành.
- Nếu iCloud tạo bản xung đột (`plume_update_key 2.pem`), giữ bản có public key
  trùng `UpdateKeys.swift`; preflight sẽ từ chối bản sai.

Đối chiếu bằng OpenSSL 3 (`brew install openssl@3`; `/usr/bin/openssl` của macOS
là LibreSSL, không chắc hỗ trợ `-rawin`):

```bash
KEY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Plume/plume_update_key.pem"
openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64
openssl pkeyutl -sign -rawin -inkey "$KEY" -in build/Plume-1.1.zip | base64
```

### Đổi khoá (rotation)

App chỉ tin khoá nó đang nhúng, nên `release.sh` so khoá ký với khoá trong
**tag phát hành cuối** (thứ người dùng đang chạy), không phải với HEAD. Muốn đổi khoá:

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
4. Build bản ứng viên (notarize thật, không publish). Từ tree sạch trùng
   `origin/main`, script ghi commit vào `build/Plume-1.1.commit`:
   ```bash
   bash Scripts/release.sh 1.1 --no-publish
   ```
   Ngày trong `CHANGELOG.md` phải đúng từ bước này: sửa gì sau đó là commit
   khác, ứng viên không còn hợp lệ. Script từ chối tiêu đề chưa có ngày
   (`## 1.1 — YYYY-MM-DD`).

   Mức macOS tối thiểu lấy từ `Package.swift`. Nếu bản mới *nâng* mức này
   so với bản trước, `release.sh` từ chối phát hành trừ khi thêm
   `--raise-floor`: máy nằm giữa hai mức sẽ ngừng nhận cập nhật, nên ghi rõ
   trong CHANGELOG bản nào là bản cuối cho họ.
5. Thử `build/Plume-1.1.dmg` trên máy thật (checklist ở mục 4).
6. Phát hành **đúng các file đã thử**, không build lại:
   ```bash
   bash Scripts/release.sh 1.1 --from-build
   ```
   Script kiểm: commit ghi lúc build trùng HEAD; DMG và app trong zip đã
   staple; app đúng requirement Developer ID mà updater đòi; manifest khớp zip
   (độ dài, SHA-256) và chữ ký Ed25519 đúng khoá các bản đã cài tin.

   `bash Scripts/release.sh 1.1` (không cờ) vẫn build và phát hành trong một
   lần, khi không cần thử trước.

`release.sh` làm và kiểm từng bước, dừng ngay khi một bước sai:

| Bước | Việc |
|---|---|
| Preflight | version đúng dạng và khác `0.0`, khoá tồn tại ngoài repo **và khớp khoá trong tag phát hành cuối** (HEAD khác thì phải `--rotating-key`), HEAD có khoá, version mới hơn tag cuối trên origin, `CHANGELOG.md` có mục `## X.Y`; khi publish: tree sạch, đang ở `main` trùng `origin/main`, tag/release chưa có, `gh` đã đăng nhập |
| Build | `release_sign.sh X.Y`: universal, ký Developer ID + hardened runtime, kiểm app **đúng requirement updater đòi** (team U4B264GM2B), notarize + staple app, zip app **sau khi staple**, DMG ký + notarize + staple |
| Manifest | ký Ed25519 toàn bộ `Plume-X.Y.zip`, tự verify, ghi `Plume-X.Y.manifest.json` |
| Publish | tag `vX.Y`, push tag, `gh release create` với 3 asset |
| Verify | `releases/latest` trả `vX.Y`, 3 URL asset trả 200, kích thước zip trên GitHub = `length` |

Asset của mỗi release:

| File | Dùng cho |
|---|---|
| `Plume-X.Y.dmg` | người tải tay, kéo vào Applications |
| `Plume-X.Y.zip` | updater trong app |
| `Plume-X.Y.manifest.json` | updater: `format` (1), `version`, `build`, `asset` (tên zip), `length`, `sha256`, `ed25519`, `minimumSystemVersion` |

**Không bao giờ build lại một version đã publish.** Bytes mới = chữ ký mới,
manifest trên GitHub không còn khớp và app từ chối. Lỗi sau khi publish thì
phát hành version kế tiếp.

## 4. Kiểm tra bản ứng viên trên máy thật

Cài `build/Plume-X.Y.dmg` (kéo vào Applications, thay bản cũ). Nếu tài khoản
đã bị Meta chuyển sang Facebook thì kiểm thêm phần Facebook.

- [ ] Mở app: không có cảnh báo Gatekeeper; Plume ▸ Giới thiệu hiện đúng version.
- [ ] Đăng nhập (Facebook nếu được hỏi): app tự về trang Đoạn chat, không đứng ở feed.
- [ ] Bấm sang một trang Facebook khác (logo, hồ sơ) rồi Xem ▸ Về Đoạn chat (⇧⌘H).
- [ ] ⌘1…⌘9, ⌃Tab/⌃⇧Tab, ⌘K (con trỏ vào ô tìm *đoạn chat*, không phải "Tìm trên Facebook").
- [ ] Cửa sổ ▸ Bong bóng (⌥⌘B): vào được bong bóng, đúng các người gần nhất.
- [ ] Bấm từng bong bóng: card mở đúng người, không có thanh xanh Facebook hay khoảng trống phía trên.
- [ ] Đổi qua lại vài bong bóng; mở danh sách (chip app) và chọn một người khác.
- [ ] Ảnh trong card: card không tự phóng to toàn màn hình khi chỉ đang xem cuộc trò chuyện.
- [ ] Trong card, bấm vào tên/ảnh đại diện một người (mở hồ sơ), rồi bấm một bong bóng khác: card về lại đúng cuộc trò chuyện.
- [ ] Mở một ứng dụng khác ở chế độ toàn màn hình: bong bóng vẫn nổi bên trên.
- [ ] Chuột phải một hàng trong danh sách ▸ Xoá đoạn chat… (dùng một đoạn chat thử): xoá được, hoặc báo lỗi mà không xoá gì.
- [ ] Nhờ người khác nhắn tin khi Plume đang ẩn: có thông báo; bấm vào thông báo mở đúng đoạn chat (cả ở chế độ cửa sổ lẫn bong bóng).
- [ ] Số trên Dock bằng số đoạn chat chưa đọc, về 0 khi đã đọc hết.
- [ ] Gửi một link có chữ tiếng Việt và bấm vào: mở đúng trang trong trình duyệt.

Trên máy **macOS 13.x** (mức thấp nhất được hỗ trợ là 13.3), thêm:

- [ ] Plume ▸ Giới thiệu: dòng "WebKit … · macOS 13.x" hiện đúng.
- [ ] Trang Messenger/Facebook hiện đầy đủ, không trắng, không báo "Your request couldn't be processed".
- [ ] Bong bóng kéo mượt, nảy về chỗ cũ; rê chuột phóng to như Dock.
- [ ] Chuột phải chip ứng dụng: menu hiện *trên* bong bóng, không bị che.
- [ ] Badge đỏ trên bong bóng không bị cắt góc; nút "Thử lại" (khi mất mạng) còn viền sáng.
- [ ] Bong bóng nổi trên một app khác đang toàn màn hình và trong Stage Manager.
- [ ] Gọi thoại/video: macOS hỏi quyền micro/camera, cuộc gọi chạy.
- [ ] Kiểm tra cập nhật thủ công: báo đúng (đã mới nhất, hoặc "bản mới nhất cho máy này").

Vòng khung hình của macOS 13 (Timer) thử được trên máy mới hơn bằng bản Debug:
`defaults write com.htl.plume plume.debugTimerFrames -bool YES`, rồi
`defaults delete com.htl.plume plume.debugTimerFrames` khi xong.

## 5. Kiểm tra sau phát hành

- Mở một bản cũ hơn (Developer ID, trong `/Applications`) ▸ Plume ▸ Kiểm tra
  cập nhật… → hộp thoại hiện bản mới với release notes.
- Cập nhật → thanh tiến trình → app tự thoát, mở lại → thông báo "Đã cập nhật
  lên Plume X.Y" → Giới thiệu Plume hiện đúng version, vẫn đăng nhập.

Thử với repo nháp trước khi dùng repo thật. Khi `PLUME_RELEASE_REPO` khác repo
mặc định, `release.sh` **không** tạo hay push tag lên origin (`gh` tạo tag trên
repo nháp). Vẫn nên dùng một version sẽ không phát hành thật, vì version đó
cũng phải mới hơn tag cuối:

```bash
defaults write com.htl.plume plume.updateRepo <owner>/plume-test
PLUME_RELEASE_REPO=<owner>/plume-test bash Scripts/release.sh 9.98
# ... thử trong app ...
defaults delete com.htl.plume plume.updateRepo
```

### Bản đầu tiên trên một máy

Updater không thay bản build cục bộ (`0.0.0`, ký ad-hoc) hay bản cũ `0.1.0`.
Máy đang dùng bản đó cài tay một lần: mở `Plume-X.Y.dmg` và kéo vào
Applications. Từ đó trở đi máy tự cập nhật. `install.sh` sẽ từ chối ghi đè bản
phát hành này (`PLUME_REPLACE_RELEASE=1` để ép).

## 6. Lỗi hay gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| Preflight: `this key … is not the one installed copies trust` | Khoá trong `PLUME_UPDATE_KEY` không phải khoá bản phát hành cuối nhúng. Dùng đúng khoá; đừng sửa `UpdateKeys.swift` nếu không có kế hoạch đổi khoá (mục 2). |
| Preflight: `UpdateKeys.swift embeds a different key from vX.Y` | HEAD đổi public key. Nếu cố ý: đó là bản chuyển khoá, chạy với `--rotating-key`. Nếu không: trả `UpdateKeys.swift` về như cũ. |
| `cannot read …plume_update_key.pem` | iCloud đã dọn file khỏi ổ. Tải lại trong Finder (mục 2). |
| `releases/latest does not report vX.Y` | Release đang là draft/prerelease, hoặc API chậm vài giây. Kiểm `gh release view vX.Y`. |
| `gh release create failed` sau khi tag đã push | Chạy lại đúng lệnh `gh release create` script in ra, **với cùng các file** — đừng build lại. |
| App báo "Gói cập nhật không hợp lệ" | Zip không khớp manifest/chữ ký, hoặc app trong zip không phải bản Developer ID đúng version. Xem asset trên GitHub có bị upload nhầm không. |
| App báo "Không thể tự cập nhật" | App chạy từ DMG / Downloads (App Translocation) hoặc tài khoản không ghi được vào thư mục chứa app. Kéo vào `/Applications`. |
| `app does not meet the updater's Developer ID requirement` | App ký bằng chứng thư của team khác (`PLUME_SIGN_IDENTITY`). Dùng *Developer ID Application: Long Hoang Tuan (U4B264GM2B)*. |
| Notarize / ký lỗi | `xcrun notarytool history --keychain-profile vkey` phải chạy được; nếu không, tạo lại profile bằng `xcrun notarytool store-credentials vkey`. Xem log một lần nộp: `xcrun notarytool log <id> --keychain-profile vkey`. |
