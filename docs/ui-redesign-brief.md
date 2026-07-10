# Plume — UI Redesign Brief

> Tài liệu này dùng làm **input cho Claude (design)** để thiết kế lại giao diện
> app **Plume**. Nội dung mô tả bằng tiếng Việt; tên component, design token,
> thuật ngữ kỹ thuật và code giữ nguyên tiếng Anh.
>
> **Cách dùng:** dán toàn bộ file này vào Claude và yêu cầu tạo mockup (artifact
> HTML/CSS) + design token spec theo phần **Deliverables** ở cuối. Có thể yêu
> cầu từng phần một (ví dụ chỉ làm "Offline / error state" trước).

---

## 1. Sản phẩm là gì

**Plume** là một client **native macOS** cho Facebook Messenger — nhẹ như
Caprine nhưng **không dùng Electron**. Thay vì đóng gói cả Chromium, Plume bọc
`messenger.com` trong **`WKWebView`** của hệ thống. Kết quả: app chỉ vài MB,
khởi động nhanh, cuộn có momentum native, dùng chung bản vá bảo mật WebKit của
macOS. Toàn bộ là **Swift + AppKit**, không có runtime dependency.

Tên **"Plume"** = *lông vũ* → tinh thần thương hiệu: **nhẹ, thanh thoát, tối
giản, mượt**. Icon hiện tại là một chiếc lông vũ trên gradient **blue → indigo**.

## 2. Tech stack & ràng buộc (design phải tôn trọng)

| Yếu tố | Chi tiết |
|---|---|
| Nền tảng | macOS 14+ (Sonoma), Apple Silicon + Intel |
| UI framework | **AppKit** (không phải SwiftUI, không phải web app) |
| Lõi nội dung | `WKWebView` render `messenger.com` — **ta không sở hữu UI này**, chỉ can thiệp được qua **CSS/JS injection** |
| Cửa sổ | 1 `NSWindow`, `styleMask` gồm `.fullSizeContentView`; min size 420×520; nhớ vị trí/kích thước qua frame autosave |
| Không có | design system sẵn, asset catalog, storyboard — mọi thứ dựng bằng code |

**Hệ quả quan trọng cho design:** app có **2 tầng UI tách biệt**, hãy thiết kế
riêng cho từng tầng:

- **Tầng A — Native chrome (AppKit):** title bar, toolbar, các *app state*
  (loading / offline / error), notifications, dock badge, menu. Đây là nơi
  design tự do nhất.
- **Tầng B — Web content (Messenger):** chỉ chỉnh được bằng **injected CSS/JS**.
  Không được phá vỡ layout/login/call của Messenger. Thiết kế ở đây phải là
  *lớp phủ nhẹ* (theming, density, accent), không phải dựng lại UI.

## 3. Giao diện hiện tại (baseline)

- `NSWindow` title "Plume", title bar **mờ đục mặc định**, `WKWebView` chiếm
  toàn bộ content view.
- Khi load: `drawsBackground = false` để tránh flash trắng → thực chất là **màn
  hình trống** cho tới khi trang lên.
- Khi mất mạng: (sau bản fix mới) **tự retry mỗi 3s** nhưng **không có UI phản
  hồi** — người dùng chỉ thấy cửa sổ trống.
- Badge unread trên Dock lấy từ `(N)` trong `document.title`.
- Menu bar chuẩn (App / Edit / View / Window). Không có toolbar.
- Không có dark-mode tùy biến, không có density toggle (đang nằm ở roadmap).

**Vấn đề cần giải quyết bằng design:** trạng thái trống lúc load & lỗi trông
"hỏng"; chrome chưa có bản sắc Plume; chưa tận dụng vibrancy để hòa với sidebar
tối của Messenger.

## 4. Mục tiêu & nguyên tắc thiết kế

1. **Content-first** — chrome phải "lùi lại" cho Messenger nổi bật; điểm nhấn
   thương hiệu là *tinh tế* (accent, vibrancy), không phô trương.
2. **Native đến từng chi tiết** — bám **macOS HIG**: vibrancy/materials, SF
   symbols, traffic lights đúng vị trí, motion nhẹ. Phải trông như app Apple
   viết, không như web nhồi vào khung.
3. **Không màn hình trống** — mọi khoảnh khắc (launch, load, offline, lỗi) đều
   có trạng thái visual có chủ đích.
4. **Nhẹ = bản sắc** — tinh thần "plume/feather": nhiều khoảng thở, chuyển động
   mềm, gradient blue→indigo dùng *rất tiết chế*.
5. **Light + Dark ngang hàng** — thiết kế cả hai; dark là mặc định nhiều người
   dùng Messenger ban đêm.
6. **Không phá chức năng** — login, voice/video call, upload file, notification
   phải nguyên vẹn.

## 5. Phạm vi thiết kế (chia theo khối)

### A. Native window chrome
- **Title bar:** đề xuất `titlebarAppearsTransparent = true` + hợp nhất với nội
  dung; traffic lights nổi trên một dải **vibrancy/blur** (`NSVisualEffectView`,
  material `.sidebar` hoặc `.headerView`) để ăn nhập với sidebar tối của
  Messenger. Cho phương án **có** và **không** dải title bar.
- **Toolbar (tùy chọn, cần cân nhắc trùng lặp):** Messenger web đã có sidebar +
  search riêng. Nếu thêm toolbar native, chỉ nên gồm điều khiển mà web **không**
  có: `Back` / `Forward` / `Reload`, và (tùy chọn) toggle **Dark** / **Compact**
  (tầng B). Thiết kế toolbar **slim, icon-only (SF Symbols)**, có thể ẩn/hiện.
  Cần một biến thể "**zero-chrome**" (chỉ traffic lights, không toolbar) cho
  người thích tối giản.
- **Trạng thái focus/inactive** của chrome.

### B. App states (giá trị lớn nhất — web không làm được)
Thiết kế các full-window state sau, cả light & dark:
1. **Launch / first paint** — thay cho màn trống: splash tối giản với **feather
   mark** Plume + hiệu ứng *shimmer/breathing* nhẹ (không spinner ồn ào). Phải
   hòa nền với `drawsBackground=false` (không flash trắng).
2. **Loading / reconnecting** — chỉ báo mảnh, không chặn (ví dụ thanh progress
   mảnh dưới title bar, hoặc pill "Đang kết nối…").
3. **Offline / error** — màn hình thân thiện: icon, tiêu đề ngắn (vd *"Mất kết
   nối"*), phụ đề, nút **"Thử lại"** (map tới `WebViewController.load()`), và
   dòng nhỏ báo *"Tự thử lại sau vài giây…"* (khớp auto-retry hiện có). Cần cả
   bản tiếng Việt & tiếng Anh cho copy.
4. (Tùy chọn) **Empty / logged-out** — nếu muốn khung thương hiệu quanh trang
   login.

### C. Web theming qua injected CSS (Tầng B — khớp roadmap)
Roadmap đã có *"Custom dark-mode / compact-density CSS toggles"*. Thiết kế và
cung cấp **CSS injectable** (sẽ nhét vào `InjectedScript.swift`) cho:
- **Compact density** — giảm padding danh sách hội thoại & bong bóng để hiện
  nhiều tin hơn.
- **Accent Plume** — nhuộm nhẹ các điểm nhấn sang indigo của Plume (tiết chế,
  không đè bản sắc Messenger).
- **Custom scrollbar** mảnh, bo tròn bong bóng chat, tinh chỉnh bóng đổ.
- Lưu ý kỹ thuật: Messenger dùng **class hash động** → ưu tiên selector theo
  thuộc tính bền (`[role=...]`, `[aria-...]`, data attrs). Ghi rõ **giả định
  selector** để dễ bảo trì; ưu tiên biến CSS & `:root` overrides.

### D. Notifications & badge (native)
- **Dock badge**: đề xuất ngưỡng hiển thị (vd `99+`), style số.
- **Notification banner**: nội dung do `UNUserNotificationCenter` render (không
  custom nhiều được), nhưng cần **notification icon/attachment** thống nhất
  branding.

### E. Icon & branding polish (tùy chọn)
- Tinh chỉnh **feather mark** + gradient blue→indigo cho: app icon, splash,
  empty/error states. Cần một **glyph đơn sắc** dùng ở kích thước nhỏ.

## 6. Design system đề xuất (điểm khởi đầu — Claude design tinh chỉnh & mở rộng)

> Đây là *starting tokens*, không phải chốt hạ. Hãy trả về bảng token hoàn chỉnh
> (light + dark) để map thẳng sang `NSColor` / `NSFont`.

**Color — brand**
| Token | Hex (gợi ý) | Ghi chú |
|---|---|---|
| `plume/indigo-600` | `#4F46E5` | accent chính |
| `plume/blue-500` | `#3B82F6` | đầu gradient |
| `plume/indigo-700` | `#4338CA` | cuối gradient |
| `plume/gradient` | `blue-500 → indigo-700` | dùng cực tiết chế (splash, icon, hover nhỏ) |

**Color — surfaces (điền cả light & dark, ưu tiên dùng system materials)**
| Vai trò | Light | Dark |
|---|---|---|
| `chrome/bg` | vibrancy `.headerView` | vibrancy `.headerView` |
| `state/bg` (splash/error) | ? | ? |
| `text/primary` / `text/secondary` | ? | ? |

**Typography** — **SF Pro** (system). Đề xuất scale: `display` (splash),
`title`, `body`, `caption`. Nêu size/weight/line-height cụ thể.

**Spacing** — lưới **4pt** (4 / 8 / 12 / 16 / 24 / 32). Radius: `sm 6` /
`md 10` / `lg 16`. Elevation: định nghĩa 1–2 mức shadow mềm.

**Motion** — nhẹ & nhanh: 150–250ms, ease-out; shimmer/breathing cho splash;
tránh chuyển động phô trương.

## 7. Deliverables mong muốn từ Claude (design)

1. **Visual mockups** (artifact HTML/CSS, responsive, hỗ trợ light/dark) cho:
   - Main window — 2 biến thể chrome (**có toolbar** & **zero-chrome**), light + dark.
   - **Launch/splash**, **Loading/reconnecting**, **Offline/error** states.
   - (Tùy chọn) Compact vs comfortable density minh hoạ.
2. **Design token spec** — bảng đầy đủ (color/type/space/radius/elevation/motion)
   cho light + dark, **kèm gợi ý map sang AppKit** (`NSColor`,
   `NSVisualEffectView.Material`, `NSFont`).
3. **Injected CSS mẫu** cho tầng B (dark tuỳ biến + compact density + accent),
   ghi rõ giả định selector.
4. (Tùy chọn) **Feather mark** refresh dạng SVG (full-color + mono).
5. Với mỗi mockup: **ghi chú map sang code** — component này thuộc file nào ở
   phần 9, dựng bằng AppKit gì.

## 8. Non-goals / ràng buộc (đừng làm)

- ❌ Không dựng lại UI nội bộ của Messenger (danh sách chat, khung soạn tin) —
  đó là web của Meta; chỉ theming nhẹ ở tầng B.
- ❌ Không đề xuất SwiftUI-rewrite hay thêm dependency nặng; giữ AppKit + nhẹ.
- ❌ Không thêm chrome trùng chức năng đã có trong Messenger web (search, compose
  đã nằm trong trang).
- ❌ Không phá login/call/upload/notification.
- ⚠️ Selector CSS tầng B phải phòng thủ (class Messenger là hash động).

## 9. Bản đồ code (để map design → implementation)

| Khối UI | File hiện tại | Ghi chú cho design |
|---|---|---|
| Boot `NSApplication` | `Sources/Plume/main.swift` | — |
| Window, title bar, menu, notification routing | `Sources/Plume/AppDelegate.swift` | nơi cấu hình `NSWindow`, thêm `NSVisualEffectView`/toolbar |
| `WKWebView`, nav, **app states**, badge | `Sources/Plume/WebViewController.swift` | nơi thêm splash/loading/error overlay views; `load()` = nút Thử lại; `didFailProvisionalNavigation` đã có auto-retry |
| Injected JS + **CSS tầng B** | `Sources/Plume/InjectedScript.swift` | nơi nhét CSS theming/density/accent |
| URLs, UA, internal hosts | `Sources/Plume/Constants.swift` | — |
| App icon (feather / blue→indigo) | `Scripts/icon_gen.swift`, `Resources/Plume.icns` | tham chiếu branding |

---

### Ưu tiên đề xuất (nếu làm dần)
1. **Offline/error + Launch/splash states** (tác động lớn nhất, web không làm được).
2. **Chrome + vibrancy title bar** (bản sắc native).
3. **Dark/compact CSS toggles** (tầng B, đã có trong roadmap).
4. Icon/branding polish.
