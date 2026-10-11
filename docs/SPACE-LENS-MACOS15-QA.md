# Space Lens: breadcrumb trên macOS 15

Kiểm chứng ngày **11/10/2026**, trên nhánh `codex/sync-puremac-keep-interface`.

## Kết quả

**Tái hiện được lỗi ở bản trước khi sửa**: vào `Library` qua danh sách bên phải, bấm breadcrumb thư mục gốc nhiều lần vẫn ở `Library`. Vào tiếp `Application Support`, bấm breadcrumb `Library` cũng không quay về. Cùng fixture và guest, bản sửa dùng `NSScrollView` + `NSButton` quay về đúng thư mục bằng một click.

Guest là **macOS 15.7.7, build 24G720, arm64**, chạy bằng Tart 2.40.1, 4 CPU / 8 GB RAM / màn hình 1024 × 768. VM `mclean-breadcrumb-qa-20261011` là bản clone riêng từ `sequoia`. Dùng thư mục fixture, không cấp thêm Full Disk Access và không chuyển file vào Thùng rác.

## Chẩn đoán và bản sửa

Workaround cũ ở commit `0a680f569c4a181992622e6a432cf5473afac5c6` đổi SwiftUI `Button` thành `onTapGesture` nhưng vẫn lỗi trong guest này. Thử chỉ thay từng breadcrumb bằng `NSButton`, giữ SwiftUI `ScrollView` ngang bên ngoài, cũng không giải quyết được thao tác chuột. Nút Back nằm ngoài vùng cuộn hoạt động. Kết quả đối chiếu cho thấy container cuộn SwiftUI có liên quan đến việc nhận click; đây là suy luận từ thực nghiệm, chưa phải kết luận về lỗi nội bộ của Apple.

Bản cuối chuyển toàn bộ dải breadcrumb sang `NSScrollView` và các `NSButton` native. SwiftUI chỉ vẽ nhãn theo font, màu và capsule hiện có của MClean; nhãn không nhận hit-test, toàn bộ chữ và padding thuộc về nút. Nút có tooltip đường dẫn, tên accessibility, con trỏ bàn tay và hỗ trợ nhận click đầu tiên. Breadcrumb hiện tại không kích hoạt. Cập nhật cây quét thay callback theo node mới.

Dải cuộn tự đưa thư mục hiện tại vào vùng nhìn thấy khi đổi đường dẫn. Nút Back luôn nằm ngoài vùng cuộn, giúp quay lại khi breadcrumb gốc đã khuất. Giữ nguyên bản đồ bong bóng, danh sách, sidebar và giao diện sáng/tối. Điều hướng dùng cây đã quét; việc quay lại không cần xin lại quyền đọc ổ đĩa.

Các tệp chính: `MClean/Views/SpaceLens/SpaceLensView.swift`, `MClean/Views/SpaceLens/SpaceLensBreadcrumb.swift`, `MCleanTests/SpaceLensBreadcrumbTests.swift`.

## Kiểm thử thao tác trong VM

| Tình huống | Kết quả |
|---|---|
| Bản cũ: Library → breadcrumb gốc; Application Support → breadcrumb Library | Tái hiện lỗi: click không điều hướng |
| Bản sửa: Library → breadcrumb gốc | Một click, hiện lại Library và Downloads |
| Application Support → breadcrumb Library | Một click, hiện lại Application Support |
| Chọn ZaloData rồi bấm breadcrumb Library | Quay về đúng thư mục, footer về “Chưa chọn mục nào” |
| Đi sâu đến ZaloDownloads/group | Breadcrumb hiện tại tự hiện ở mép phải |
| Bấm breadcrumb hiện tại | Giữ đúng thư mục đang xem |
| Nút Back khi breadcrumb gốc đã khuất | Quay về cha bằng một click |
| Quét lại khi đang ở group rồi bấm ZaloData | Giữ đường dẫn sau quét; breadcrumb cha hoạt động |
| Chuyển sidebar rồi trở lại Space Lens | Giữ cây quét và đường dẫn |
| Bản Release cuối đã ký: breadcrumb gốc và Library ở Light/Dark | Đạt; nhãn đọc được sau đổi appearance |
| Click mép padding breadcrumb gốc trong Dark | Quay về gốc; tooltip hiện đúng đường dẫn |

Những lượt sâu/quét lại được chạy trên bản Release có cùng mã chuột/cuộn; lượt cuối chạy lại breadcrumb gốc, thư mục cha, lựa chọn và Light/Dark bằng chính binary đóng gói bên dưới. Binary host và guest có cùng SHA-256.

Fixture trong guest:

```text
/Users/admin/MCleanFixture/
├── Downloads/fixture.bin (2 MiB)
└── Library/Application Support/ZaloData/media/
    1565612244229178290/ZaloDownloads/group/fixture.bin (3 MiB)
```

Để tái kiểm tra: mở Space Lens → Chọn thư mục → chọn fixture → Quét; vào Library rồi Application Support bằng danh sách bên phải; chọn ZaloData; bấm breadcrumb Library, sau đó breadcrumb gốc. Kiểm tra đường dẫn, danh sách và selection cùng thay đổi đúng. Đi sâu, quét lại, bấm một breadcrumb cha còn nhìn thấy; dùng Back nếu đường dẫn gốc đã khuất.

## Kiểm thử tự động và artifact

- **180 test, 0 lỗi** trên host macOS 27.0, arm64. Thêm 5 test hồi quy cho action gốc/cha và selection, trạng thái current/disabled, callback của control tái sử dụng, hit-test chữ/padding trong strip thật, đường dẫn dài và resize.
- Build Release Universal **arm64 + x86_64** đạt. Guest chạy slice arm64; chưa chạy slice Intel.
- App giữ version **1.0.4, build 5**, ký Developer ID Application, Team ID `CF5PGH3KGK`. `codesign --verify --deep --strict` đạt cả host và guest.
- SHA-256 của executable đã ký: `1327ab0d05b3dfe5bc81804b78cb96f93291f87ef578fe38b51a8440c48d5ad6`.

Artifact và log ngoài repo, tại `/Users/maclife/.codex/backups/MClean-breadcrumb-20261011-100131/`:

- `Review/MClean.app` và `Review/MClean-space-lens-fix.zip`.
- `host-tests-final.log`, `release-final.log` và `.xcresult` trong `DerivedData/Logs/Test/`.
- `before.patch` và bản sao source trước sửa; `VMShare/` giữ các bản đối chiếu.
- `tools/tart.app` là tool từ nguồn chính thức. VM riêng được giữ để tái kiểm tra và tắt sau QA.

## Phạm vi còn chưa kiểm chứng

Đã kiểm chứng **15.7.7 arm64**, chưa chạy các bản 15.x khác hoặc máy Intel. Tổ hợp Command, wheel/trackpad và drag scrollbar qua lớp điều khiển Tart không tạo được hành vi guest đáng tin cậy; không tính những thao tác đó là đã đạt QA. Layout tự cuộn và resize đã được kiểm tra tự động, tự hiện breadcrumb cuối đã được quan sát trong VM. Không thêm phím tắt mới chưa được kiểm chứng.

Chưa thử Full Disk Access hoặc quét toàn ổ vì đây là lỗi nhận click ở cây đã quét. Không thay app trong `/Applications`, không tăng version hoặc phát hành bản mới.
