# Cập nhật MClean bằng Sparkle

> Trạng thái chuẩn bị mới nhất: **1.0.5 / build 6** đã ký Developer ID, notarize/staple app và DMG, tạo feed/ZIP được SDK Sparkle xác minh. GitHub đã có đủ sáu secrets, gồm credentials notarization nhập qua Terminal. Xem [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md) để biết kiểm chứng CI. Những mục kiểm chứng bên dưới ghi lại các lượt tích hợp/audit trước đó; feed production chưa được xuất bản.

Tích hợp ngày **11/10/2026**. Dùng Sparkle **2.10.0**, pin cả Swift Package Manager và tool tạo appcast theo cùng bản. `Package.resolved` được lưu để CI dùng đúng revision.

## Hành vi trong app

Sau onboarding, một `SPUStandardUpdaterController` tồn tại cùng app và kiểm tra appcast. Sparkle hỏi người dùng có muốn bật kiểm tra tự động; tùy chọn được lưu bằng chính Sparkle, không đặt lại mỗi lần mở app. Tab Settings → Updates giữ bố cục cũ, có nút kiểm tra và hai tùy chọn kiểm tra/tải-cài tự động. Khi bật, chu kỳ mặc định là 24 giờ; bản tải tự động được cài lúc thoát app. Nút menu Updates và phím tắt hiện có dùng cùng updater. CLI và XCTest không khởi động scheduler cập nhật.

Sparkle xử lý tải, xác thực, cài và mở lại MClean. Delegate chờ các tác vụ quét/dọn/gỡ app và xác nhận hiện có hoàn tất trước khi tiếp tục khởi động lại. Tracker riêng giữ cả batch duplicate, Homebrew, Trash và snapshot đến khi worker kết thúc; quit cũng chờ các thao tác này. Lỗi mạng, chữ ký, feed trống hoặc phiên bản không tương thích không được báo là “đang dùng bản mới nhất”.

Appcast production: `https://github.com/maclifevn/MClean/releases/download/appcast/appcast.xml`. Mỗi enclosure trỏ tới ZIP ở release `vX.Y.Z`. Release `appcast` được đánh dấu prerelease và không đặt làm Latest. Cả feed lẫn ZIP phải có chữ ký Ed25519; archive được kiểm chứng trước khi giải nén. `SUSignedFeedFailureExpirationInterval=0` giữ yêu cầu chữ ký feed ngay cả sau thời gian dài feed lỗi. Chữ ký Developer ID và notarization vẫn thuộc pipeline phát hành.

Đây là cơ chế kiểm tra appcast định kỳ: khi phát hành bản mới, pipeline cập nhật feed và các máy đã bật cập nhật sẽ nhận bản mới ở lần kiểm tra kế tiếp. Người dùng có thể kiểm tra ngay từ menu.

## Khóa ký: chỉ thiết lập một lần

Khóa riêng cho MClean đã được tạo trong login Keychain, account **`com.maclife.mclean`**. Public key trong app: `uG9oyQv95UqnmgJdLQsaHjHwphJ65HvcbGbAhIluoy0=`. Bản sao private seed nằm ngoài Git tại `/Users/maclife/.codex/backups/MClean-sparkle-20261011-103249/sparkle-private-key.txt`, quyền file `0600` và thư mục `0700`. Giữ bản sao ở nơi quản lý bí mật; mất khóa sẽ ảnh hưởng các bản app đã phát hành với public key này.

Cấu hình secret cho GitHub Actions trước lần phát hành đầu tiên:

```bash
gh secret set SPARKLE_PRIVATE_KEY --repo maclifevn/MClean \
  < /Users/maclife/.codex/backups/MClean-sparkle-20261011-103249/sparkle-private-key.txt
```

Các secret Developer ID/notarization còn lại được liệt kê ở [scripts/SECRETS.md](../scripts/SECRETS.md). Tại thời điểm tích hợp, `gh secret list` chưa trả về secret nào cho repo; chưa cấu hình hoặc chạy release production trong phiên này.

## Phát hành các bản sau

1. Tăng `MARKETING_VERSION` và **`CURRENT_PROJECT_VERSION`** trong `project.yml`. Build phải là số nguyên tăng dần; Sparkle so build, không chỉ tên phiên bản.
2. Chạy test, lưu code đã duyệt lên repo, rồi chạy workflow Release với version khớp `project.yml`; dùng `dry_run=true` trước để kiểm tra ký/notarization.
3. Pipeline archive Universal, ký Developer ID, notarize/staple, tạo ZIP cuối cùng. `generate-sparkle-appcast.sh` ký ZIP và feed bằng Sparkle, giữ lịch sử tối đa 5 bản, tắt delta ở lần tích hợp này.
4. Pipeline xác thực feed cũ và từ chối build bằng/thấp hơn build đã phát hành. Lỗi lấy feed cũ khác HTTP 404 sẽ dừng phát hành. Lần đầu HTTP 404 tạo feed mới. Feed được tạo trong staging riêng; bundle QA, config khác production, chữ ký sai và ZIP tồn dư trong output không được xuất bản.
5. Upload ZIP/DMG vào release phiên bản trước, sau đó thay asset `appcast.xml` ở release `appcast`. Version đã tồn tại bị từ chối; không ghi đè ZIP/DMG đã phát hành. Không sửa XML sau ký. `dry_run` không upload hoặc thay feed.

Workflow hiện dùng `workflow_dispatch`. Ví dụ sau khi đã cập nhật version/build và đẩy code:

```bash
gh workflow run release.yml --repo maclifevn/MClean -f version=1.0.5 -f dry_run=true
# Khi dry run đạt:
gh workflow run release.yml --repo maclifevn/MClean -f version=1.0.5 -f dry_run=false
```

Đường phát hành local (`scripts/release-local.sh`) tạo signed appcast tương tự bằng account Keychain `com.maclife.mclean`; có thể truyền `SPARKLE_PRIVATE_KEY_FILE` để dùng file private seed. Script chỉ tạo artifact, việc upload thực hiện sau khi kiểm tra:

```bash
gh release create v1.0.5 build/MClean-1.0.5.zip build/MClean-1.0.5.dmg \
  build/appcast/appcast.xml --repo maclifevn/MClean --title 'MClean v1.0.5' --notes-file release-notes.md
# Release appcast đã có sau lần phát hành đầu qua CI:
gh release upload appcast build/appcast/appcast.xml --clobber --repo maclifevn/MClean
```

## Bản đầu tiên và kiểm chứng

Người đang dùng bản MClean chưa có Sparkle cần tải/cài **bản có Sparkle một lần**. Các bản sau mới được cập nhật trong app. Feed production chỉ hoạt động sau lần phát hành đầu với ZIP và appcast hợp lệ.

Kiểm chứng ngày 11/10/2026:

- **182 test, 0 lỗi** trên macOS arm64. Có kiểm thử scheduler không chạy trong XCTest, phân loại lỗi/up-to-date, trì hoãn khởi động lại khi đang quét/dọn/gỡ app và cấu hình xác thực feed/ZIP.
- Build Release Universal **arm64 + x86_64** đạt; bản test ký Developer ID Application, `codesign --verify --deep --strict` đạt. CLI `--version` chạy bình thường. Bản test này chưa được notarize trong phiên tích hợp.
- Trong VM **macOS 15.7.7 (24G720)**, kiểm tra bằng menu, tải và cài bản QA **1.0.4/build 5 → 1.0.5/build 6**, rồi khởi động lại thành công. Kiểm tra lại version/build và chữ ký bundle sau cài đều đạt. Hộp hỏi kiểm tra tự động và Settings Updates tiếng Việt hiển thị đúng trong bố cục cũ.
- Thử trực tiếp trong VM: feed bị sửa sau ký bị từ chối; ZIP bị sửa một byte bị từ chối với thông báo chữ ký không hợp lệ, app vẫn ở **1.0.4/build 5**. Không giải nén/cài bản sai chữ ký.
- Tool Sparkle chính thức xác nhận feed và ZIP hợp lệ, từ chối nội dung bị sửa và khóa ký không khớp. Kiểm tra lịch sử từ chối build bằng/thấp hơn, chấp nhận build cao hơn và giữ URL các bản cũ. Feed thiếu chữ ký cũng bị từ chối.
- YAML hai workflow, cú pháp Bash của 22 block release/4 block build và `git diff --check` đạt. Chưa chạy workflow ký/notarization trên GitHub vì secret chưa được cấu hình.

VM dùng bundle ID QA riêng `com.maclife.mclean.sparkleqa` và feed localhost qua tunnel chỉ cho test. Bundle production vẫn dùng HTTPS GitHub và public key nêu trên. Việc kiểm thử không thay app trong `/Applications` và không phát hành artifact QA.

Artifact/log riêng nằm tại `/Users/maclife/.codex/backups/MClean-sparkle-20261011-103249/`. Version release trong source vẫn là **1.0.4, build 5**; phiên này chưa tạo release mới. Cần tăng version/build và chạy dry run ký/notarization trước khi phát hành bản có Sparkle đầu tiên.

Audit bổ sung trước production cùng ngày đạt **198 test / 0 lỗi**, archive/export Developer ID Universal và kiểm tra lại cập nhật 5 → 6 trên macOS 15. Đã bổ sung guards cho thao tác file độc lập, process cancellation, ký feed bắt buộc, history staging và release asset không ghi đè. Chưa có secrets CI/profile notarization local. Kết quả cuối và điều kiện phát hành tại [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md); các số 182 và 22 block ở trên là bằng chứng của lượt tích hợp ban đầu.

Tài liệu tham khảo: [Sparkle setup](https://sparkle-project.org/documentation/), [SwiftUI setup](https://sparkle-project.org/documentation/programmatic-setup/), [Publishing](https://sparkle-project.org/documentation/publishing/).
