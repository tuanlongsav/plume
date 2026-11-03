# Changelog

Mỗi bản phát hành có một mục `## X.Y — YYYY-MM-DD`. `Scripts/release.sh X.Y`
lấy phần dưới tiêu đề đó làm release notes, và app hiện nó trong hộp thoại
cập nhật — viết cho người dùng, bằng tiếng Việt.

## 1.0 — 2026-11-03

- Bản phát hành đầu tiên qua GitHub Releases.
- Tự cập nhật: Plume kiểm tra bản mới mỗi ngày một lần và hỏi trước khi cài.
  Tắt trong menu Plume ▸ Tự động kiểm tra cập nhật. Nếu lần kiểm tra bị lỗi
  mạng, Plume thử lại trong ngày thay vì đợi sang hôm sau.
- Gói cập nhật được ký và kiểm chữ ký trước khi cài; app đã ký Developer ID và
  qua công chứng (notarization) của Apple.
- Menu bong bóng ở cửa sổ chính và trên chip ứng dụng giờ giống hệt nhau.
- Trình xem PDF: nút tìm kết quả trước/sau có nhãn tiếng Việt cho VoiceOver.
