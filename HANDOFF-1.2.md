# Handoff: Plume 1.2, việc còn dở, chạy tiếp ở máy local (Mac)

> File này **không commit**: dùng để chuyển giao rồi xoá. Ngày ghi: 2026-11-05.

## 1. Trạng thái hiện tại

- `main` = **`38097d5`**. CI `macos-15` xanh cho mọi commit đã merge.
- Đã merge từ 1.1 đến nay, đều squash, theo thứ tự:

  | PR | Nội dung |
  |---|---|
  | #5 | Sửa 10 lỗi review: badge nhấp nháy, `tag` thông báo, `AttachmentNavTracker`, open panel, camera/mic theo frame, `Updater.swap`, `AppVersion` ≤ 99, mouse poll của bong bóng |
  | #4 | Hỗ trợ macOS 13.3 |
  | #7 | Zoom trang ⌘+ / ⌘− / ⌘0 |
  | #8 | Icon thanh menu + phím tắt toàn cục ⌃⌥⌘M |
  | #9 | ⌘N Tin nhắn mới |
  | #10 | Chặn tracker bên thứ ba (`WKContentRuleList`) |
  | #11 | Ẩn số chưa đọc |

- Branch làm việc `claude/fervent-tesla-n87wit` có nội dung giống hệt `main`; lịch sử cũ được nối bằng merge `-s ours`. Không còn PR nào mở.
- `CHANGELOG.md` có mục `## 1.2 — chưa phát hành`, đã liệt kê đủ các mục trên. **Chưa đặt ngày.**
- **Chưa có gì được thử trên Mac thật.** Code được viết trên Linux; chỉ có CI compile và chạy unit test.

## 2. Việc đang dở: review toàn bộ v1.1..main

Đợt review nhiều góc (updater/release, macOS 13.3, web view, bong bóng, vòng đời app/menu, tương tác chéo) đang chạy trong phiên cloud. Khi ghi file này, nó **chưa xong**. Các lỗi ứng viên bên dưới **chưa qua kiểm chứng**, và một số đã bị lượt kiểm chứng bác. Dùng chúng như danh sách để tự đọc lại code, đừng sửa ngay.

| Mức | Chỗ | Nghi vấn |
|---|---|---|
| bug | `WebViewController.swift:~592`, `InjectedScript.swift:~425` | Đóng (`close()`) một thông báo cũ cùng `tag` sẽ xoá luôn banner mới đã thay nó, vì cả hai cùng identifier `plume-tag-<tag>`. |
| bug | `AppDelegate.swift:~116` | Ở bubble mode, icon thanh menu và ⌃⌥⌘M chỉ gập/mở card, không `unhide`. Sau Hide Others hoặc Dock ▸ Ẩn, các bong bóng vẫn mất. |
| bug | `ChatBubbleController.swift:~1672` | Việc nhảy sang màn hình theo con trỏ giờ chỉ chạy khi poll thấy chuột di chuyển. Mouse monitor có thể đã ghi nhận chuyển động đó, nên poll không bắt được. |
| minor | `AppDelegate.swift:~393` | Thoát bubble mode từ menu của icon dùng `activate()` kiểu hợp tác, nên cửa sổ chính có thể hiện sau app khác. |
| minor | `AppDelegate.swift:~175` | ⌃⌥⌘M đăng ký thất bại âm thầm lúc khởi động mà mục menu vẫn có dấu tick. Lần bấm sau tắt nó đi thay vì thử đăng ký lại. |
| minor | `Updater.swift:~85` | "Kiểm tra cập nhật" không làm gì khi lượt kiểm tra tự động đang tải manifest (`busy`). |
| minor | `Updater.swift:~259` | Khi bản mới nhất cần macOS mới hơn, Mac cũ được báo là "đang dùng bản mới nhất", dù có thể có bản trung gian chạy được. |

Chạy lại review ở local với Claude Code (nếu muốn), ví dụ:

```bash
claude "/code-review high v1.1..main"
```

Hoặc yêu cầu Claude kiểm từng dòng trong bảng trên và chỉ sửa những dòng tái hiện được.

## 3. Trên Mac: build và test

```bash
git fetch origin && git checkout main && git pull
```

```bash
swift test
```

```bash
bash Scripts/build_app.sh release
```

```bash
bash Scripts/install.sh
```

`install.sh` cài bản local `0.0.0`. Nó từ chối thay bản release đã cài, trừ khi đặt `PLUME_REPLACE_RELEASE=1`. Bản debug bật `WKWebView.isInspectable`, nên có thể dùng Safari ▸ Develop để soi trang.

## 4. Checklist thử tay trước khi phát hành 1.2

**macOS 13.x** (checklist đầy đủ ở `docs/RELEASE.md` mục 4)
- [ ] App mở được, đăng nhập được, bong bóng chạy (timer 60 Hz thay cho display link).
- [ ] Badge, bóng đổ và nút "Thử lại" hiển thị đúng.

**#5: các bản sửa lỗi**
- [ ] ⌘W đóng được cửa sổ PDF, cửa sổ cuộc gọi và cửa sổ chính.
- [ ] Badge Dock không nhấp nháy về 0 khi có tin mới trên messenger.com.
- [ ] Nhiều tin trong cùng một chat chỉ hiện một banner, không chồng nhiều banner.
- [ ] Mở tệp đính kèm đã hết hạn không reload inbox, không mất bong bóng.
- [ ] Bubble mode khi idle không tốn Energy (Activity Monitor).

**#7: zoom**
- [ ] ⌘+, ⌘−, ⌘0 và ⌘= hoạt động; mức zoom còn sau khi mở lại app.
- [ ] Card bong bóng luôn ở mức 1.
- [ ] ⌘+ không làm gì khi đang mở cửa sổ PDF.

**#8: icon thanh menu + ⌃⌥⌘M** (bật trong menu Plume)
- [ ] Icon có số chưa đọc; chuột trái mở/ẩn, chuột phải ra menu.
- [ ] Đóng cửa sổ chính thì app không thoát.
- [ ] ⌃⌥⌘M từ app khác hoặc Desktop khác đưa Plume lên; bấm lại thì ẩn.
- [ ] Trên macOS 14, Plume thật sự lên trước (đường dự phòng `activate(ignoringOtherApps:)`).
- [ ] Ở bubble mode, ⌃⌥⌘M mở/gập card và menu chuột phải nằm trên các bong bóng.
- [ ] Icon trông ổn trên thanh menu sáng, tối và khi được highlight.

**#9: ⌘N**
- [ ] Trên messenger.com và facebook.com/messages, ⌘N mở khung soạn tin, danh sách chat không reload.
- [ ] Đang ở trang Facebook khác thì ⌘N chuyển sang trang soạn tin.
- [ ] Mục này bị tắt ở bubble mode.

**#10: chặn tracker** (Xem ▸ Chặn trình theo dõi bên thứ ba, mặc định bật)
- [ ] Tin nhắn, ảnh, tệp và cuộc gọi chạy bình thường.
- [ ] Bật/tắt không làm hỏng trang.
- [ ] Trong Web Inspector thấy request tới doubleclick/google-analytics bị chặn.

**#11: Ẩn số chưa đọc** (menu Plume)
- [ ] Số biến mất ở Dock, thanh menu và chip ứng dụng; tắt thì số quay lại.
- [ ] Thông báo vẫn đến.

## 5. Phát hành 1.2 (theo `docs/RELEASE.md`)

1. Sửa các lỗi tìm được ở mục 2 và 4, rồi đặt ngày cho `## 1.2` trong `CHANGELOG.md`.
2. Tạo bản ứng viên đã notarize từ một tree sạch ở `origin/main`:
   ```bash
   bash Scripts/release.sh 1.2 --no-publish
   ```
3. Thử chính bản ứng viên đó trên Mac 14 và Mac 13, theo checklist mục 4.
4. Phát hành đúng những file đã thử:
   ```bash
   bash Scripts/release.sh 1.2 --from-build
   ```

Lưu ý: 1.2 hạ mức macOS tối thiểu xuống 13.3. `release.sh` chỉ đòi `--raise-floor` khi **nâng** mức này, nên ở đây không cần.

## 6. Quyết định đã chốt (để không làm lại)

- **⌃⌥⌘M:** không dùng ⌃Space hoặc ⌃⌥Space vì đó là phím đổi bộ gõ. Trên macOS 14 có gọi API deprecated `activate(ignoringOtherApps:)`; CI sẽ báo warning, điều này là có chủ ý.
- **Zoom** chỉ áp dụng cho cửa sổ chính. Card bong bóng cần viewport rộng ít nhất khoảng 900 CSS px.
- **Chặn tracker:** danh sách hẹp, không có host nào của Meta. Có test `TrackerRulesTests` giữ điều này. Mặc định bật.
- **Ẩn số chưa đọc** là công tắc tay. Đọc trạng thái Focus cần entitlement riêng, nên không làm.
- **Cửa sổ đăng nhập riêng** (dò cookie `c_user`) chưa làm. `main` đã xử lý luồng đăng nhập trong cửa sổ chính.
- **Không làm:** MutationObserver toàn trang (rule 2), reload định kỳ (rule 4), chặn "đang gõ"/"đã xem" (WebSocket), chuyển sang Sparkle.
