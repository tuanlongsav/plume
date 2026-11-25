# Phát hành Plume

Quy trình đưa một bản Plume lên `ota.htl-8.com` (máy chủ cập nhật chung, repo
`htl-ota`, hợp đồng ở `htl-ota/docs/OTA.md`), nơi updater trong app tìm bản mới.
Mô hình giống vkey (chữ ký trên gói cập nhật + Developer ID + notarize), nhưng
không dùng Sparkle, không có `appcast.xml`: app đọc
`https://ota.htl-8.com/plume/stable/latest.json` mỗi ngày một lần.

Máy chủ không được tin: app chỉ cài zip có chữ ký Ed25519 (trường `ed25519`
trong `latest.json`) đúng khoá nhúng trong `UpdateKeys.swift`, và app giải ra
phải ký Developer ID team U4B264GM2B, đúng bundle id, đúng version.

Bản cài trước khi chuyển sang ota vẫn hỏi GitHub `releases/latest`: một release
GitHub cuối (cầu nối, cùng file) đưa họ sang bản đọc ota. Sau đó không phát
hành lên GitHub nữa.

## 1. Quy tắc version

- `MAJOR.MINOR`, không số 0 đứng đầu, `MINOR` ≤ 99 (ví dụ `1.0`, `1.1`, … `1.12`, `2.0`).
  Không dùng cấp patch: hotfix cũng tăng `MINOR`.
- `CFBundleVersion` = `MAJOR*10000 + MINOR*100` (`1.1` → `10100`), do
  `Scripts/build_app.sh` tự tính từ `PLUME_VERSION`.
- Build cục bộ không đặt `PLUME_VERSION` là `0.0.0`: updater **không bao giờ**
  thay bản này, và cũng không thay bản ký ad-hoc.
- Tag git là `vX.Y` (vẫn tạo và push: tag quyết định "mới hơn" và khoá các bản
  đã cài tin). Trên ota, `build` trong `latest.json` = `CFBundleVersion`; app
  so version và đòi `build` khớp version.

## 2. Khoá ký gói cập nhật (làm một lần)

Khoá Ed25519 riêng cho updater, khác chứng thư Developer ID. Khoá nằm trong
iCloud Drive (`iCloud Drive/Plume/`) để mọi máy Mac dùng để phát hành (Mac
Studio, MacBook…) ký bằng cùng một khoá; đó cũng là đường dẫn mặc định của
`release.sh` (và của `htl-ota publish --sign-key`).

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
`Sources/PlumeUpdater/UpdateKeys.swift`:

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
(`PLUME_NOTARY_PROFILE` để đổi), khoá ở mục 2, repo `htl-ota` cạnh repo này
(`HTL_OTA_DIR` để đổi) có `node` và `npx wrangler` đã đăng nhập đúng tài khoản
Cloudflare (`npx wrangler whoami` trong thư mục `htl-ota`).

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
   (độ dài, SHA-256) và chữ ký Ed25519 đúng khoá các bản đã cài tin. Rồi gọi
   `htl-ota publish plume build/Plume-X.Y.zip --version X.Y --build N
   --notes build/notes-X.Y.md --min-os <LSMinimumSystemVersion> --sign-key <khoá>
   --attach build/Plume-X.Y.dmg`.

   `bash Scripts/release.sh 1.1` (không cờ) vẫn build và phát hành trong một
   lần, khi không cần thử trước.

`release.sh` làm và kiểm từng bước, dừng ngay khi một bước sai:

| Bước | Việc |
|---|---|
| Preflight | version đúng dạng và khác `0.0`, khoá tồn tại ngoài repo **và khớp khoá trong tag phát hành cuối** (HEAD khác thì phải `--rotating-key`), HEAD có khoá, version mới hơn tag cuối trên origin, `CHANGELOG.md` có mục `## X.Y`; khi publish: tree sạch, đang ở `main` trùng `origin/main`, tag chưa có, có CLI `htl-ota` và `node` |
| Build | `release_sign.sh X.Y`: universal, ký Developer ID + hardened runtime, kiểm app **đúng requirement updater đòi** (team U4B264GM2B), notarize + staple app, zip app **sau khi staple**, DMG ký + notarize + staple |
| Manifest | ký Ed25519 toàn bộ `Plume-X.Y.zip`, tự verify, ghi `Plume-X.Y.manifest.json` (chỉ để cầu nối GitHub) |
| Mức macOS | so `LSMinimumSystemVersion` với `minOs` của `latest.json` hiện tại trên ota (bản ota đầu tiên: manifest release GitHub cuối) |
| Publish | tag `vX.Y`, push tag, `htl-ota publish plume` (tải zip + DMG lên `plume/<build>/`, ghi `latest.json` cuối cùng) |
| Verify | `latest.json` trả đúng `version`, `build`, `url`, `size`, `sha256`, `minOs`; chữ ký `ed25519` đúng khoá các bản đã cài tin; zip và DMG trên ota trả 200 |

`latest.json` của Plume (`https://ota.htl-8.com/plume/stable/latest.json`):

| Trường | Updater dùng |
|---|---|
| `app`, `channel` | phải là `plume`, `stable` |
| `version`, `build` | mới hơn bản đang chạy; `build` = `MAJOR*10000 + MINOR*100` |
| `url` | zip, https, tên đúng `Plume-X.Y.zip` |
| `size`, `sha256` | kiểm sau khi tải (như `length`, `sha256` của manifest cũ) |
| `ed25519` | bắt buộc: chữ ký toàn bộ zip, kiểm bằng `UpdateKeys` |
| `minOs` | bắt buộc: máy thấp hơn thì không mời cập nhật |
| `notes` | hiện trong hộp thoại cập nhật |
| `attachments[]` `Plume-X.Y.dmg` | nút "Mở trang tải về" khi cập nhật lỗi |

Ngoài ota, `build/` vẫn giữ `Plume-X.Y.dmg`, `.zip`, `.manifest.json` cho release
GitHub cầu nối (cuối `release.sh` in sẵn lệnh `gh release create`; chỉ chạy khi
còn cần đưa bản cài cũ sang ota).

**Không bao giờ build lại một version đã publish.** Tệp trên ota bất biến theo
`build`, bytes mới = chữ ký mới. Lỗi sau khi publish thì phát hành version kế
tiếp. Quay lui `latest.json`: xem mục "Quay lui" trong `htl-ota/docs/OTA.md`
(không hạ được máy đã lên bản mới).

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
- [ ] Kiểm tra cập nhật thủ công: báo đúng ("Bạn đang dùng bản mới nhất", hoặc "Plume X.Y cần macOS … trở lên" khi bản mới nhất cần macOS mới hơn).

Vòng khung hình của macOS 13 (Timer) thử được trên máy mới hơn bằng bản Debug:
`defaults write com.htl.plume plume.debugTimerFrames -bool YES`, rồi
`defaults delete com.htl.plume plume.debugTimerFrames` khi xong.

## 5. Kiểm tra sau phát hành

- Mở một bản cũ hơn (Developer ID, trong `/Applications`) ▸ Plume ▸ Kiểm tra
  cập nhật… → hộp thoại hiện bản mới với release notes.
- Cập nhật → thanh tiến trình → app tự thoát, mở lại → thông báo "Đã cập nhật
  lên Plume X.Y" → Giới thiệu Plume hiện đúng version, vẫn đăng nhập.

Thử đường phát hành mà không đụng bản thật: đặt `PLUME_OTA_CHANNEL` khác
`stable` (app chỉ đọc `stable`); `release.sh` khi đó **không** tạo hay push tag.
Vẫn dùng một version sẽ không phát hành thật, vì version đó cũng phải mới hơn
tag cuối:

```bash
PLUME_OTA_CHANNEL=test bash Scripts/release.sh 9.98
curl -s https://ota.htl-8.com/plume/test/latest.json
```

Xem bản đã cài báo gì khi kiểm: `npx wrangler tail htl-ota` (trong `htl-ota`),
User-Agent `plume/X.Y (build)`.

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
| `htl-ota publish failed` sau khi tag đã push | Chạy lại đúng lệnh script in ra, **với cùng các file** — đừng build lại. `latest.json` vẫn là bản cũ cho tới khi publish xong. Lỗi `wrangler`: `npx wrangler login` trong `htl-ota`. |
| `latest.json reports …` / `does not verify` | Bản khác vừa ghi đè, hoặc publish nhầm tệp/khoá. Xem `history/` trên R2 (`htl-ota/docs/OTA.md`). |
| `htl-ota` từ chối vì `build` ≤ hiện tại | Version đã có trên ota; phát hành version kế tiếp (không dùng `--force` khi đã có máy tải). |
| App báo "Gói cập nhật không hợp lệ" | Zip không khớp `latest.json`/chữ ký, hoặc app trong zip không phải bản Developer ID đúng version. Kiểm `latest.json` và tệp `plume/<build>/` trên ota. |
| App báo "Không thể tự cập nhật" | App chạy từ DMG / Downloads (App Translocation) hoặc tài khoản không ghi được vào thư mục chứa app. Kéo vào `/Applications`. |
| `app does not meet the updater's Developer ID requirement` | App ký bằng chứng thư của team khác (`PLUME_SIGN_IDENTITY`). Dùng *Developer ID Application: Long Hoang Tuan (U4B264GM2B)*. |
| Notarize / ký lỗi | `xcrun notarytool history --keychain-profile vkey` phải chạy được; nếu không, tạo lại profile bằng `xcrun notarytool store-credentials vkey`. Xem log một lần nộp: `xcrun notarytool log <id> --keychain-profile vkey`. |
