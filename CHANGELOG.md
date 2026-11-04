# Changelog

Mỗi bản phát hành có một mục `## X.Y — YYYY-MM-DD`. `Scripts/release.sh X.Y`
lấy phần dưới tiêu đề đó làm release notes, và app hiện nó trong hộp thoại
cập nhật — viết cho người dùng, bằng tiếng Việt.

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
