# Changelog

Mỗi bản phát hành có một mục `## X.Y — YYYY-MM-DD`. `Scripts/release.sh X.Y`
lấy phần dưới tiêu đề đó làm release notes, và app hiện nó trong hộp thoại
cập nhật — viết cho người dùng, bằng tiếng Việt.

## 1.2 — chưa phát hành

- Chạy được trên macOS 13.3 (Ventura) trở lên, gồm các máy Mac 2017. Máy
  macOS 13.0–13.2 cần cập nhật macOS trước.
- Plume không mời cập nhật lên một bản mà máy của bạn không chạy được.
- Plume ▸ Kiểm tra cập nhật… luôn trả lời, kể cả khi bấm đúng lúc Plume đang
  tự kiểm tra.
- Plume ▸ Giới thiệu Plume ghi phiên bản WebKit và macOS, giúp báo lỗi dễ hơn.
- Tuỳ chọn ẩn số chưa đọc trên Dock, trên thanh menu và trên bong bóng (menu
  Plume ▸ Ẩn số chưa đọc), khi con số đang chờ cũng là thứ gây phân tâm. Thông
  báo vẫn đến như thường.
- Chặn các trình theo dõi và quảng cáo bên thứ ba (Google Analytics,
  DoubleClick…) mà nội dung nhúng trong đoạn chat có thể tải về. Không đụng tới
  Messenger. Tắt trong menu Xem nếu cần.
- ⌘N mở khung soạn tin nhắn mới (menu Đoạn chat).
- Tuỳ chọn biểu tượng Plume trên thanh menu, kèm số đoạn chat chưa đọc: bấm
  để mở hoặc ẩn Plume, bấm chuột phải để có menu. Khi bật, đóng cửa sổ chính
  Plume vẫn chạy và vẫn báo tin nhắn. Bật trong menu Plume.
- Tuỳ chọn phím tắt toàn cục ⌃⌥⌘M để mở hoặc ẩn Plume từ bất kỳ ứng dụng nào
  (ở chế độ bong bóng: mở hoặc gập bong bóng). Bật trong menu Plume.
- Phóng to, thu nhỏ trang Messenger bằng ⌘+ / ⌘− (menu Xem), ⌘0 về kích
  thước thật; Plume nhớ mức đã chọn cho cửa sổ chính.
- ⌘W đóng cửa sổ (trình xem PDF, cửa sổ cuộc gọi, cửa sổ chính).
- Trên messenger.com, số chưa đọc trên Dock không còn nhấp nháy về 0 khi có
  tin nhắn mới.
- Thông báo cùng một đoạn chat gộp làm một thay vì xếp chồng; thông báo từ
  cửa sổ cuộc gọi nay cũng hiện ra.
- Mở tệp đính kèm hết hạn không còn làm tải lại Messenger (và mất bong bóng).

## 1.1 — 2026-11-04

- Chạy được với tài khoản Meta đã chuyển Messenger sang Facebook
  (facebook.com/messages): danh sách đoạn chat, chế độ bong bóng, phím tắt
  đoạn chat và xoá đoạn chat. Sau khi đăng nhập Facebook, Plume tự về trang
  Đoạn chat; menu Xem ▸ Về Đoạn chat (⇧⌘H) đưa về đó bất cứ lúc nào.
- Trên Facebook, số trên biểu tượng Dock đếm các đoạn chat chưa đọc, không
  tính thông báo của Facebook.
- Bong bóng hiện được trên ứng dụng khác đang toàn màn hình (macOS 14).

## 1.0 — 2026-11-04

- Bản phát hành đầu tiên qua GitHub Releases.
- Tự cập nhật: Plume kiểm tra bản mới mỗi ngày một lần và hỏi trước khi cài.
  Tắt trong menu Plume ▸ Tự động kiểm tra cập nhật. Nếu lần kiểm tra bị lỗi
  mạng, Plume thử lại trong ngày thay vì đợi sang hôm sau.
- Gói cập nhật được ký và kiểm chữ ký trước khi cài; app đã ký Developer ID và
  qua công chứng (notarization) của Apple.
- Menu bong bóng ở cửa sổ chính và trên chip ứng dụng giờ giống hệt nhau.
- Trình xem PDF: nút tìm kết quả trước/sau có nhãn tiếng Việt cho VoiceOver.
