# Audit trước production — 11/10/2026

> Đây là hồ sơ của lượt audit trước khi tăng version. Lượt chuẩn bị tiếp theo đã nâng **1.0.5 / build 6**, cấu hình đủ sáu secrets GitHub và notarize app/DMG thành công bằng profile cũ trên máy. Trạng thái hiện tại, artifact và kiểm chứng CI nằm ở [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md). Các kết quả và điều kiện dưới đây được giữ theo thời điểm audit.

**Kết quả:** đã sửa các vấn đề tìm thấy trong code và pipeline, đạt **198 test / 0 lỗi**, archive/export Release Universal bằng Developer ID thành công. **Chưa đủ điều kiện phát hành:** GitHub chưa có secrets ký/notarization, local chưa có profile notarization và source vẫn là **1.0.4 / build 5**. Không tạo release, push Git hay thay ứng dụng trong `/Applications` trong lượt audit này.

Phạm vi là working tree trên nhánh `codex/sync-puremac-keep-interface`, gồm toàn bộ thay đổi đồng bộ PureMac, giao diện MClean hiện có, Space Lens và Sparkle. Các thay đổi trước audit được giữ; bản sao trước sửa nằm ngoài Git. Mốc upstream và phạm vi ghép được ghi ở [UPSTREAM-SYNC.md](UPSTREAM-SYNC.md).

## Các vấn đề đã sửa

| Mức | Vấn đề và hậu quả | Bản sửa / kiểm chứng |
|---|---|---|
| P1 | Công cụ chạy độc lập có thể đang chuyển file, xóa snapshot hoặc nâng cấp app khi Sparkle/quit/relaunch/lịch quét coi app là rảnh. View đóng không đồng nghĩa worker đã kết thúc. | `FileOperationTracker` cấp token riêng cho từng thao tác, giữ đến khi worker hoàn tất. Batch duplicate giữ một token cho toàn bộ batch. Sparkle và lịch quét kiểm tra tracker; AppDelegate trì hoãn quit. Test token chồng nhau, kết thúc lặp và 100 worker đồng thời. |
| P1 | Timeout/cancel Homebrew có thể kết thúc parent và báo hoàn tất trong khi child bỏ qua TERM vẫn chạy. Công cụ hiệu năng dùng pipe đọc không giới hạn và timeout có thể chờ child giữ pipe. | Dừng nhóm tiến trình đã xác minh thuộc process được chạy, có TERM → KILL, giữ continuation đến khi dừng. Đóng stdin, giới hạn đầu ra, dùng chung runner cho hiệu năng. CommandRunner đồng bộ cũng dừng child khi timeout. Test hồi quy tái hiện child bỏ qua TERM thất bại trước sửa, đạt sau sửa; kiểm tra cả cancellation và stdin EOF. |
| P1 | Các đường dọn trực tiếp/Space Lens/duplicate chưa áp dụng đầy đủ loại trừ mới, symlink ở thư mục cha và cloud placeholder khi thực thi. Chọn một thư mục cha có thể tác động vào nhánh đã loại trừ. | Kiểm tra lại trước Trash/cleanup, từ chối symlink theo từng thành phần, placeholder `.icloud`, cloud/provider, immutable/SIP và exclusions. Bảo vệ các root Library dùng chung. Duplicate kiểm tra lại identity/hash và bảo vệ đường dẫn sau scan. Fixture xác nhận file không bị tác động khi thêm exclusion hoặc thay parent bằng symlink. |
| P1 | `SURequireSignedFeed` có cơ chế nới yêu cầu mặc định sau thời gian feed lỗi; cấu hình ban đầu chưa tắt thời hạn đó. | Đặt `SUSignedFeedFailureExpirationInterval=0`, giữ xác thực feed và archive trước giải nén. Test cấu hình; kiểm tra plist của app export. Theo [tài liệu Sparkle](https://sparkle-project.org/documentation/customization/). |
| P1 | Ghi đè ZIP một release đã phát hành có thể làm feed cũ trỏ tới dữ liệu khác chữ ký hoặc làm mất khả năng phục hồi. | CI kiểm tra version chưa tồn tại, dừng nếu API không xác nhận được; chỉ tạo release mới, bỏ fallback upload `--clobber` cho ZIP/DMG phiên bản. Chỉ asset feed ổn định được thay sau khi asset phiên bản đã có. |
| P2 | Retry quyền có thể chen vào scan đang chạy; cooldown cũ có thể đặt `.idle` đè trạng thái scan mới. | Chặn retry khi có tác vụ, giữ mục chờ; kiểm tra generation và trạng thái trước kết thúc cooldown. Hai test hồi quy kiểm tra các cuộc đua này. |
| P2 | Relaunch mở app trước khi instance cũ thoát hoặc đợi một thời gian cố định, không phù hợp khi quit phải chờ worker. | Helper chờ PID cũ thực sự kết thúc rồi dùng `open`; truyền PID/path bằng argument riêng. Settings dùng cùng helper với Full Disk Access. |
| P2 | Tạo feed ngay trong output có thể nhập ZIP tồn dư; QA bundle, archive sai chữ ký/config hoặc khóa không khớp có thể đến bước xuất bản. | Tạo feed trong staging riêng, xác minh lịch sử và build tăng dần, kiểm tra bundle ID production và các cờ Sparkle so với source. Feed được thay nguyên tử sau mọi kiểm tra. Dùng SDK chính thức để xác minh chữ ký; ca âm không thay feed trước đó. |
| P2 | Hướng dẫn export toàn bộ private key, team không đúng và secret truyền trên command line làm setup dễ sai. Thiếu kiểm tra staple/codesign/Gatekeeper sau notarization app. | Viết lại [SECRETS.md](../scripts/SECRETS.md) để export đúng một Developer ID, stdin cho secrets, giữ private seed ngoài Git; khóa quyền file CI, thu hẹp app được phép dùng key và xóa P12/key/tap tạm. Pipeline kiểm tra team, staple, strict codesign và Gatekeeper sau notarization; giữ dSYM. Local kiểm tra từng kiến trúc với cú pháp `lipo` đã chạy thực tế. |
| P2 | Một số mô tả còn khẳng định mọi thao tác đều qua Trash hoặc không dùng mạng. | Sửa README, FAQ/structured data, llms và privacy: file thường qua Trash; Trash emptying/runtime/Docker/snapshot là thao tác vĩnh viễn có xác nhận; Sparkle và Homebrew dùng mạng, không có telemetry. |

## Kiểm chứng trên bản cuối

| Kiểm tra | Kết quả |
|---|---|
| XCTest trên host macOS arm64 | **198 test, 0 lỗi**, gồm 16 test bổ sung so với mốc Sparkle 182 test. |
| Xcode Release archive → Developer ID export | Đạt; dùng Team **CF5PGH3KGK**, hardened runtime, timestamp. App và helper Sparkle cùng team; strict deep codesign đạt. |
| Universal / deployment / tài nguyên | Có **arm64 + x86_64**; cả hai Mach-O đặt minimum macOS **13.0**; đủ 14 language bundles và Sparkle license. CLI `--version` chạy được. |
| VM macOS **15.7.7 (24G720)** | Bản QA từ export cuối mở được, onboarding và Dashboard/bubble layout cũ giữ nguyên. Quét fixture riêng, đi vào Library/Application Support, bấm breadcrumb Library rồi root: quay lại đúng. |
| Sparkle thực tế trong VM | Menu tải feed, phát hiện **1.0.5**, tải/cài và tự mở lại từ **1.0.4/build 5 → 1.0.5/build 6**. Version/build và strict codesign sau cài đạt. QA dùng bundle ID riêng `com.maclife.mclean.productionqa` và feed loopback, không sửa cấu hình production. |
| Settings relaunch trên host macOS 27 | Bản QA riêng cuộn được tới nút Relaunch Now; bấm nút khiến PID cũ kết thúc, app tự mở lại bằng PID mới và hiển thị tiếng Việt. Strict codesign vẫn đạt. |
| Tool appcast trên archive ký thật | Feed 5 → 6 giữ URL cũ; từ chối build bằng/thấp hơn và sai khóa; ZIP build 7 tồn dư không vào feed. Archive sai codesign, config khác source và QA bundle đều bị từ chối. Feed trước đó không đổi sau thất bại. Feed/ZIP hợp lệ được SDK Sparkle chính thức xác minh. |
| Kiểm tra tĩnh | YAML hai workflow, **23 Bash block release / 4 block build**, shell scripts, Ruby cask, Package.resolved, JSON website và `git diff --check` đạt. |
| Bí mật trong source / kết thúc QA | Kiểm tra 188 file repository: không chứa các private seed dùng trong audit hoặc nội dung PEM private key. App QA trên host, VM, SSH tunnel và HTTP server thử đã dừng; VM và artifact được giữ để kiểm tra lại. |

Log XCTest có cảnh báo XCTest framework mới hơn deployment target của **test bundle** và AppIntents metadata bị bỏ qua vì app không dùng framework đó; không có lỗi test hay Swift compiler warning. Deployment target của app giữ 13.0. Các thông báo `com.apple.linkd.autoShortcut` đến từ hệ thống host, không phải lỗi build MClean.

VM/fixture kiểm chứng hành vi cụ thể, không chứng minh mọi cấu hình máy người dùng. Chưa chạy runtime trên Intel hoặc macOS 13/14; Universal build không thay thế kiểm thử đó. Chưa quét/dọn dữ liệu cá nhân toàn ổ với Full Disk Access. Test timeout kiểm soát nhóm tiến trình con trực tiếp, không cam kết hủy công việc đã được một daemon hệ thống nhận riêng.

Thao tác cuộn Settings qua công cụ điều khiển Tart chưa đưa được phần cuối Form vào màn hình VM, nên chưa xác nhận Settings relaunch trên macOS 15. Trên host, cùng bản QA có vùng cuộn qua accessibility và relaunch đạt; chưa đủ bằng chứng kết luận hiện tượng cuộn trong VM là lỗi của MClean. Cần kiểm tra thủ công Settings trên macOS 15 trước phát hành.

## Điều kiện còn thiếu trước phát hành

1. Thiết lập **7 secrets bắt buộc** trong [SECRETS.md](../scripts/SECRETS.md). `gh secret list --repo maclifevn/MClean` ngày 11/10/2026 trả về rỗng. Token Homebrew tap là tùy chọn nếu cần tự cập nhật tap.
2. Tăng marketing version và build vượt **1.0.4 / 5**, lưu code đã duyệt lên repo. Không phát hành lại cùng version/ZIP.
3. Chạy workflow Release với `dry_run=true` bằng certificate/API key thật. Chỉ tiếp tục khi notarization app/DMG, staple và Gatekeeper đều đạt. Local hiện báo **“No Keychain password item found for profile: AC_NOTARY”**; bản audit đã ký nhưng **chưa notarize**, nên không được gọi là artifact production hoàn chỉnh.
4. Kiểm tra bản notarized tải qua trình duyệt trên máy sạch, gồm cài mới, Full Disk Access sau relaunch và nâng cấp từ bản đã phát hành. Người dùng bản chưa có Sparkle cần cài bản có Sparkle một lần. Khuyến nghị thêm smoke test Intel và macOS thấp nhất còn hỗ trợ.

Nếu cần rút một bản lỗi khỏi feed, giữ nguyên ZIP đã ký của các bản cũ, sửa feed và ký lại bằng khóa đang dùng. Bản sửa tiếp theo phải có build cao hơn; Sparkle không tự rollback về build thấp hơn. Không thay public key nếu chưa có kế hoạch chuyển khóa tương thích.

## Artifact và phục hồi

Backup, patch đầu audit, archive/export, scripts fixture và logs: `/Users/maclife/.codex/backups/MClean-production-audit-20261011-105857/` (thư mục `0700`). Bản export để kiểm tra: `Export-Final/MClean.app`; logs chính: `tests-final.log`, `archive-final.log`, `export-final.log`, `export-verification.log`, `fixtures.log`, `vm-update-verification.log`, `host-relaunch-verification.log`. Artifact version 1.0.5/6 trong backup là **fixture QA**, không phải release đã phát hành.

`after/` và `after.patch` lưu source cuối audit, gồm cả file mới chưa được Git theo dõi; `secret-and-diff-check.log` lưu kiểm tra cuối. Các file `dist/` đã bị xóa trước audit được giữ nguyên trạng thái trong working tree, không reset thay đổi của phiên trước.

Các lượt QA breadcrumb và chữ ký feed/ZIP bị sửa trước audit vẫn được ghi riêng tại [SPACE-LENS-MACOS15-QA.md](SPACE-LENS-MACOS15-QA.md) và [SPARKLE-UPDATES.md](SPARKLE-UPDATES.md). Giữ private signing seed ở nơi quản lý bí mật ngoài repository; không đưa backup này vào release artifact.
