# Đồng bộ PureMac vào MClean, giữ giao diện hiện có

Ngày đối chiếu: **11/10/2026**. Nhánh: `codex/sync-puremac-keep-interface`.

Nguồn: [momenbasel/PureMac](https://github.com/momenbasel/PureMac), app **3.1.0**, revision [`0eca648d48986b7ea91f56ffe816f817a719c421`](https://github.com/momenbasel/PureMac/commit/0eca648d48986b7ea91f56ffe816f817a719c421). Lấy lại remote trước khi ghép; không chỉ dùng snapshot 3.0 của lần audit trước. MClean bắt đầu tại `4604fe9`, có các chỉnh sửa chưa commit được giữ lại. Hai repo không có merge-base chung; ghép theo từng phần và kiểm thử hành vi của fork.

## Giao diện được giữ

- Giữ Dashboard với gauge, biểu đồ, hero và quick actions của MClean; không nhập Smart Care của PureMac.
- Giữ bộ màu xanh/tím, gradient, card, checkbox và animation cũ. Sửa cách áp dụng chế độ System/Light/Dark bằng AppKit, không đổi palette.
- Giữ sidebar và bố cục cửa sổ cũ; bổ sung nhóm Tools để sử dụng chức năng mới.
- Giữ Settings dạng tab và cửa sổ 480 × 430; thêm tab Updates và quản lý loại trừ trong tab Cleaning. Không nhập trang Settings/sidebar mới của upstream.
- Giữ bản đồ bong bóng và bố cục chia đôi của Space Lens. BubbleMapView, BubbleLayout, DashboardCharts, AppearancePill, EmptyStateView và Theme.swift không thay đổi so với bản đầu phiên.
- Giữ onboarding, icon, branding, Finder Service và menu bar MClean. Sheet quyền truy cập có hướng dẫn mở lại app sau khi bật quyền.
- Các màn hình chức năng mới dùng card, màu và control hiện có của MClean.

## Cập nhật chức năng

| Phần | Nội dung ghép |
|---|---|
| Quét và dọn cache | Cache container, HTTPStorages tùy chọn, DeviceSupport/XCTest/Previews/SourcePackages, runtime simulator, pnpm và OrbStack. Nhận thêm danh mục cache Puppeteer, Playwright, node-gyp, Electron và Hugging Face từ catalog CLI upstream. Hugging Face chỉ đưa các thư mục tải vào kết quả, không đưa token hay cả thư mục cha; bỏ chọn mặc định. |
| XcodeBuildMCP/MobileBuildMCP | DerivedData riêng mỗi workspace và root cũ; bỏ chọn mặc định, không quét logs/state/locks/results. Chuẩn hóa home và alias hệ thống; từ chối symlink; giành khóa vòng đời trước khi chuyển vào Thùng rác. Không nhập cơ chế xóa qua quyền quản trị. |
| Duplicate Finder | Gom theo kích thước rồi SHA-256, loại symlink/hard link/package/cloud; giữ bản gốc và kiểm tra lại identity/nội dung trước khi đưa bản dư vào Thùng rác. Không tự chọn bản xóa. |
| Similar Photos | Phân tích thumbnail cục bộ; giới hạn số ảnh/entry, thông báo khi kết quả chưa đầy đủ. Chỉ xem và mở Finder; không tải ảnh lên mạng hoặc tự xóa. |
| Protection | Gatekeeper, FileVault, firewall, SIP và XProtect. Firewall State 2 là đang bật; kết quả chưa xác nhận được là Unknown. |
| Performance | CPU/RAM hệ thống, startup agents/daemons và snapshot. Theo dõi CPU/RAM theo app, gom helper, sort/search và giữ mẫu cuối khi tạm dừng. Lấy mẫu tiến trình chỉ khi disclosure mở và cửa sổ đang hoạt động. Startup items có thể thu gọn. Snapshot Time Machine có timestamp hợp lệ mới được xóa, với xác nhận. |
| App Updates | Homebrew cask, pin, xác nhận danh sách, validate token/executable và timeout. App Store và app tải trực tiếp dùng kênh riêng. |
| Cập nhật MClean | Sparkle 2.10.0 kiểm tra signed appcast của maclifevn/MClean, xác thực feed/ZIP trước khi giải nén và cài; có kiểm tra/tải-cài tự động theo lựa chọn người dùng. Menu Updates và tab Updates cũ dùng cùng updater. Lỗi mạng/chữ ký/feed không tương thích không báo đang dùng bản mới nhất. |
| Duyệt kết quả | Bộ lọc tên/kích thước/tuổi; chọn và bỏ chọn chỉ ảnh hưởng dòng đang hiện; hiển thị lựa chọn bị ẩn; danh sách loại trừ dùng cho cả quét và dọn. Batch xác nhận được chụp cố định. |
| Space Lens | Tích hợp hành vi duyệt dung lượng của Space Explorer vào engine hiện có; byte cấp phát, hard link/device/inode, package, placeholder, thư mục rỗng và kết quả partial. Sắp xếp, xem tệp nhỏ, giữ breadcrumb khi quét lại; generation guard khi hủy/quét mới. Chỉ một cây quét và một selection. |
| Quét/lịch dọn | Giữ giới hạn quét và progress tách khỏi AppState; loại kết quả trùng/cha-con; kết quả đã hủy không ghi đè lần mới. Lịch dọn chờ cửa sổ/scan/uninstall/Space Lens/permission/confirmation; không chạy Trash/runtime/Docker prune. Dữ liệu MCP còn có điều kiện tuổi và khóa. |
| Bảo vệ thao tác file | Chặn structural root, credential/sensitive trees, FileProvider/cloud, immutable/SIP và symlink; kiểm tra lại sát thời điểm xử lý. Sửa báo kết quả dọn bị đảo điều kiện; giữ mục chưa xử lý và thông báo đúng. Dung lượng xử lý không được mô tả là byte đã giải phóng nếu file còn trong Thùng rác. |
| CLI nhúng | Validate option/category, exit 2 cho yêu cầu sai; task tách khỏi MainActor để không deadlock; JSON hợp lệ và thứ tự ổn định. Vẫn chỉ đọc. |
| Bản dịch | 14 locale: vi/en/ja/zh-Hans/zh-Hant và ar/de/es/fr/it/pl/pt-BR/ru/uk. Giữ các chuỗi Việt cũ; dịch 151 chuỗi upstream mới và các thông báo bổ sung. Parity key và kiểu đối số format được kiểm tra. Các chuỗi MClean cũ chưa có bản dịch upstream dùng English fallback ở locale mới. |
| Build/Homebrew | Test bundle có identifier/plist/entitlements riêng. Giữ version/checksum đã phát hành; đổi cask sang postflight_steps. Giữ attribution MIT PureMac. |

## Các phần giữ riêng cho fork

- Tệp thường, gỡ app, orphan và tệp trùng vẫn dùng Thùng rác. Không nhập việc xóa vĩnh viễn hoặc escalation bằng AppleScript/admin của upstream.
- Runtime simulator, Docker prune, dọn mục đã trong Thùng rác và snapshot Time Machine là thao tác riêng có xác nhận; không chạy bằng lịch dọn.
- Binary thinning và xóa ngôn ngữ app bundle đã bị upstream rút. Chỉ giữ enum để đọc dữ liệu cũ; không có scanner hoặc UI cho những thao tác này.
- Purgeable vẫn chỉ là thông tin; không thêm lệnh diskutil purgePurgeable không được hỗ trợ.
- Phạm vi đồng bộ là ứng dụng MClean và CLI nhúng. Không nhập giao diện terminal và sản phẩm CLI độc lập của PureMac; danh mục cache mới của CLI được đưa vào scanner MClean.
- Không đổi phiên bản phát hành, tạo release, push Git hoặc thay ứng dụng đã cài trong /Applications.

## Kiểm chứng

- **175 test, 0 lỗi**, macOS arm64. Bao gồm scan/cancel/selection/scheduler, cleanup/cloud/symlink/structural roots, MCP lifecycle locks, duplicate/photo, Space Lens, Homebrew, protection/firewall, process-resource sampling, release parsing/network errors và 14 localization catalogs.
- CLI smoke: help/version, option/category sai exit 2; scan JSON một danh mục hoàn tất và parse được, không deadlock MainActor.
- git diff --check, Ruby cask và Bash release script đạt.
- Kiểm tra trực tiếp giao diện tiếng Việt: Dashboard cũ, Space Lens chia đôi và Settings dạng tab giữ nguyên. Quét fixture Space Lens, xem CPU/RAM theo tiến trình và kiểm tra release MClean trên GitHub hoạt động.
- Sửa parser snapshot để loại dòng tiêu đề `Snapshots for volume group containing disk /:`; bổ sung kiểm thử hồi quy.
- Build Release Universal **arm64 + x86_64** đạt; tài nguyên tiếng Việt cuối cùng đã được đưa vào bundle.
- Bản test riêng tại `Review/MClean.app` trong thư mục backup có chữ ký **Developer ID Application**, Team ID `CF5PGH3KGK`; `codesign --verify --deep --strict` đạt. Giữ phiên bản MClean **1.0.4, build 5**; không thay ứng dụng đã cài.

Bản sao đầu phiên và log nằm ngoài project tại `/Users/maclife/.codex/backups/MClean-sync-logic-20261011-093747/`. Bản test và build không cần truy cập dữ liệu cá nhân; test filesystem dùng fixture riêng. Chưa kiểm chứng quyền Full Disk Access bằng quét toàn ổ hoặc dọn dữ liệu người dùng.

Kiểm chứng bổ sung cho báo cáo breadcrumb Space Lens: tái hiện lỗi ở bản cũ trong VM **macOS 15.7.7 (24G720)**, sửa bằng dải cuộn và nút AppKit, giữ giao diện MClean. Bộ test sau sửa: **180 test, 0 lỗi**; Release Universal đã ký chạy lại trong guest. Chi tiết, artifact và giới hạn kiểm chứng tại [SPACE-LENS-MACOS15-QA.md](SPACE-LENS-MACOS15-QA.md).

Sau tích hợp Sparkle: **182 test, 0 lỗi**; cập nhật và khởi động lại thực tế trong VM macOS 15 thành công, feed/ZIP bị sửa đều bị chặn. Pipeline tạo signed appcast sau ký/notarization và publish feed sau các release asset. Chưa cấu hình GitHub secrets hoặc phát hành bản mới. Chi tiết tại [SPARKLE-UPDATES.md](SPARKLE-UPDATES.md).

Audit trước production tiếp theo: **198 test / 0 lỗi**, sửa các cuộc đua retry/quit/update với thao tác file, bảo vệ symlink/cloud/exclusions lúc dọn, dừng tiến trình con khi timeout/cancel và siết quy trình appcast/release. Archive/export Universal Developer ID và chạy lại breadcrumb/cập nhật trong VM macOS 15 đạt. Chưa đủ điều kiện phát hành do secrets/notarization và version/build chưa tăng. Chi tiết tại [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md).
