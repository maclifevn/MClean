<p align="center">
  <img src="screenshot.png" alt="Bảng điều khiển MClean — vòng dung lượng và biểu đồ thành phần bộ nhớ" width="820">
</p>

<p align="center">
  <b>Tiếng Việt</b> |
  <a href="docs/README.en.md">English</a> |
  <a href="docs/README.ar.md">العربية</a> |
  <a href="docs/README.es.md">Español</a> |
  <a href="docs/README.ja.md">日本語</a> |
  <a href="docs/README.zh-Hans.md">简体中文</a> |
  <a href="docs/README.zh-Hant.md">繁體中文</a>
</p>

<h1 align="center">MClean</h1>

<p align="center">
  <b>Giành lại dung lượng máy Mac của bạn.</b><br>
  Trình gỡ ứng dụng và dọn dẹp macOS, miễn phí và mã nguồn mở. Không thuê bao, không thu thập dữ liệu, không quảng cáo mời mua.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/theo%20dõi-không-success?style=flat-square" alt="Không theo dõi">
  <a href="LICENSE"><img src="https://img.shields.io/badge/giấy%20phép-MIT-green?style=flat-square" alt="Giấy phép MIT"></a>
</p>

<p align="center">
  <a href="#cài-đặt">Cài đặt</a> ·
  <a href="#vì-sao-có-mclean">Vì sao có MClean</a> ·
  <a href="#tính-năng">Tính năng</a> ·
  <a href="#cam-kết-của-chúng-tôi">Cam kết</a> ·
  <a href="#quyền-truy-cập">Quyền truy cập</a> ·
  <a href="#đóng-góp">Đóng góp</a>
</p>

---

## Cài đặt

Hiện tại bạn xây dựng (build) trực tiếp từ mã nguồn — cần **Xcode 16+** và **macOS 13 trở lên**:

```bash
brew install xcodegen
git clone https://github.com/maclifevn/MClean.git
cd MClean
xcodegen generate
xcodebuild -project MClean.xcodeproj -scheme MClean -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/MClean.app
```

> Bản cài sẵn (`.dmg`) sẽ được phát hành ở mục **Releases** khi có phiên bản chính thức đầu tiên.

## Vì sao có MClean

Apple bán các máy Mac bản tiêu chuẩn với SSD 256 GB không thể nâng cấp — ổ đĩa được hàn chết vào bo mạch, và mức dung lượng cao hơn có giá đắt hơn cả một chiếc laptop Windows tầm trung. Khi đã trả tiền cho từng gigabyte, mỗi GB đều đáng giá.

Phần lớn ứng dụng dọn Mac là dạng thuê bao: giấu dung lượng đĩa sau tường phí, mặc định gửi dữ liệu về máy chủ, và hù dọa người dùng ("Phát hiện 47 GB rác!"). MClean thì ngược lại:

- **Cài một lần.** Không thuê bao, không dùng thử, không cần tài khoản.
- **Không thu thập dữ liệu.** Không hề "gọi về nhà". Nó thậm chí không biết bạn tồn tại.
- **Mã nguồn mở theo giấy phép MIT.** Đọc mã, fork, tự kiểm tra.
- **Quét trung thực.** "Rác" đúng nghĩa là rác: thư mục cache mà chính hệ điều hành cũng sẽ dọn, tệp mồ côi từ ứng dụng bạn đã xoá, biên nhận cài đặt hỏng, khối DerivedData 4 GB của Xcode từ 2023.
- **Gỡ ứng dụng đúng cách.** Kéo một ứng dụng, thấy mọi tệp preference, thư mục cache, container, launch agent và nhật ký nó rải khắp thư viện — rồi xoá tất cả cùng lúc.

## Tính năng

### Gỡ ứng dụng
Quét toàn bộ `/Applications` và `~/Applications`, dùng bộ máy đối chiếu 10 tầng (bundle ID, mã định danh nhóm, entitlements, metadata Spotlight, phát hiện container, suy đoán theo tên công ty, khớp một phần đường dẫn) để tìm mọi tệp ứng dụng để lại. Ba mức độ nhạy — **Nghiêm ngặt, Nâng cao, Sâu**. Ứng dụng hệ thống của Apple tự động bị loại khỏi danh sách gỡ. Bạn cũng có thể chuột phải một ứng dụng trong Finder → **Dịch vụ → Uninstall with MClean** để nhảy thẳng vào quá trình quét tệp liên quan.

### Tìm tệp mồ côi
Duyệt `~/Library` và phát hiện các tệp còn sót lại từ những ứng dụng không còn trên máy. Bộ đối chiếu so với bundle ID và tên chuẩn hoá của mọi ứng dụng đã cài, nên một `~/Library/Containers/com.foo.bar` sót lại từ ứng dụng bạn xoá năm 2022 sẽ hiện rõ.

### Dọn dẹp hệ thống
Quét thông minh chạy tất cả hạng mục song song, mỗi hạng mục là một bộ quét riêng:

- **Rác hệ thống** — cache hệ thống, nhật ký, tệp tạm
- **Cache người dùng** — phát hiện động, không dùng danh sách ứng dụng cứng
- **Ứng dụng AI** — nhật ký, cache, và lịch sử (tuỳ chọn) của Ollama và LM Studio
- **Tệp Mail** — tệp đính kèm email đã tải
- **Thùng rác** — dọn mọi thùng rác, kể cả ổ đĩa ngoài
- **Tệp lớn & cũ** — trên 100 MB hoặc cũ hơn 1 năm (không bao giờ tự chọn sẵn)
- **Rác Xcode** — DerivedData, Archives, cache trình giả lập
- **Cache Brew** — tôn trọng `HOMEBREW_CACHE` tuỳ chỉnh
- **Cache Node** — npm, yarn classic, kho content-addressable của pnpm
- **Cache Docker** — image, container, cache build

> **Về "dung lượng có thể giải phóng":** MClean hiển thị dung lượng purgeable của APFS trong bảng phân tích để minh bạch, nhưng **cố ý không** liệt kê nó là rác để xoá. Purgeable do chính macOS dự trữ và tự giải phóng khi cần — không ứng dụng bên thứ ba nào có thể giải phóng nó một cách đáng tin cậy. Những app tuyên bố "thu hồi dung lượng purgeable" là đang hứa hão. Chúng tôi thà trung thực còn hơn gây ấn tượng.

### Space Lens
Quét bất kỳ thư mục nào (hoặc cả thư mục Nhà) và xem nội dung dưới dạng bản đồ bong bóng tương tác — mỗi bong bóng có kích thước tỉ lệ với số byte nó chiếm. Nhấp vào bong bóng thư mục để đi sâu vào, dùng thanh breadcrumb để quay ra, và tick các mục ở danh sách bên để chuyển vào Thùng rác. Kích thước là số byte cấp phát thật: hard link được loại trùng, symlink không bao giờ được đi theo, tệp ẩn được tính, và gói ứng dụng được coi là một mục như Finder. Thư mục không đọc được đầy đủ khi thiếu Toàn quyền Truy cập Đĩa sẽ được đánh dấu thay vì âm thầm tính thiếu.

### Dọn dẹp theo lịch
Tuỳ chọn. Chu kỳ linh hoạt (từng giờ đến từng tháng), có ngưỡng tự dọn để các lần chạy nền chỉ kích hoạt khi thực sự có thứ đáng xoá.

## Cam kết của chúng tôi

Một app dọn Mac xin quyền sâu nhất mà macOS cấp — Toàn quyền Truy cập Đĩa — rồi xoá tệp của bạn. Đó là mức độ tin tưởng mà cả ngành này đã đánh mất suốt hai mươi năm. Đây là những điều MClean tự ràng buộc, và bạn có thể kiểm chứng từng dòng trong mã nguồn:

- **Luôn dùng Thùng rác, không bao giờ `rm`.** Mọi thứ MClean xoá đều vào Thùng rác qua `FileManager.trashItem`. Xoá nhầm thì kéo lại. Không có gì bị huỷ vĩnh viễn.
- **Không bao giờ thu thập dữ liệu.** Không phân tích, không báo cáo sự cố, không "thống kê ẩn danh", không gọi mạng về chúng tôi.
- **Không hù dọa giả tạo.** Không huy hiệu "47 GB rác!", không bộ đếm báo động đỏ, không "máy Mac của bạn đang gặp nguy". Chúng tôi đưa sự thật trung tính và để bạn quyết định.
- **Bạn xem lại trước khi bất cứ thứ gì bị xoá.** Không tự động xoá. Mỗi mục hiện đường dẫn thật với Hiện-trong-Finder, các đường dẫn hệ thống rủi ro cao được loại cứng trong mã.
- **Kiểm tra được.** Giấy phép MIT. Mã quyết định xoá gì nằm ở [`MClean/Services`](MClean/Services) và [`MClean/Logic/Scanning`](MClean/Logic/Scanning). Đọc. Fork. Tự phát hành bản của bạn.

## Quyền truy cập

MClean cần **Toàn quyền Truy cập Đĩa** để đọc các vị trí mà macOS mặc định ẩn khỏi mọi ứng dụng — tệp Mail tải về, dữ liệu Safari, cơ sở dữ liệu TCC, các container ứng dụng được bảo vệ. Thiếu quyền này, việc dọn dẹp bỏ sót khoảng 70% và gỡ ứng dụng sẽ để lại mọi thứ trong `~/Library/Containers`.

Màn hình khởi động lần đầu sẽ hướng dẫn bạn cấp quyền. Nếu một thao tác dọn thất bại vì thiếu quyền, MClean mở Cài đặt Hệ thống, hiện app trong Finder để bạn kéo vào danh sách, theo dõi trạng thái quyền mỗi giây và tự thử lại đúng lô bị lỗi ngay khi bạn cấp quyền — bạn không phải chọn lại gì cả.

MClean **không** làm những việc sau:
- Không thu thập dữ liệu theo dõi, báo cáo sự cố hay phân tích sử dụng.
- Không cần kết nối mạng để hoạt động.
- Không chuyển dữ liệu đi đâu ngoài Thùng rác.

## Kiến trúc

```
MClean/
  Logic/Scanning/     - Bộ máy quét suy đoán, cơ sở dữ liệu vị trí, điều kiện
  Logic/Utilities/    - Ghi nhật ký có cấu trúc, tính kích thước tệp
  Models/             - Mô hình dữ liệu, lỗi có kiểu
  Services/           - Bộ quét, bộ dọn, điều phối quyền, bộ lập lịch, Space Lens
  ViewModels/         - Trạng thái ứng dụng tập trung
  Views/              - Giao diện SwiftUI thuần
```

## Bảo mật

- Chống tấn công symlink: đường dẫn được phân giải trước khi kiểm tra, phân giải lại ngay trước khi xoá để đóng khe hở TOCTOU.
- Dọn theo danh sách cho phép: đường dẫn nằm ngoài thư mục an toàn được chỉ định sẽ bị từ chối.
- Bảo vệ ứng dụng hệ thống: không thể gỡ các gói của Apple.
- Mọi thao tác xoá đều yêu cầu xác nhận rõ ràng theo mặc định.

Nếu bạn phát hiện lỗ hổng, vui lòng mở một security advisory riêng tư thay vì issue công khai.

## Đóng góp

Rất hoan nghênh pull request. Xem [CONTRIBUTING.md](CONTRIBUTING.md).

Đặc biệt mong muốn:
- Bộ lọc kích thước/ngày theo hạng mục
- Mở rộng phạm vi kiểm thử XCTest cho `AppState` và bộ máy quét
- Thêm ngôn ngữ (hiện có: vi, en, ja, zh-Hans, zh-Hant)

## Giấy phép

MIT. Xem [LICENSE](LICENSE). Dùng, fork, phát hành dưới tên bạn nếu muốn — điều duy nhất giấy phép yêu cầu là giữ lại thông báo bản quyền.
