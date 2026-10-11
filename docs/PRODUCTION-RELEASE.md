# Chuẩn bị MClean 1.0.5 — 11/10/2026

**Version 1.0.5 / build 6** đã archive/export Universal, ký Developer ID và được Apple chấp nhận notarization cho cả app và DMG. App/DMG đã staple và Gatekeeper chấp nhận trên host lẫn máy ảo macOS 15.7.7. Đã tạo ZIP và signed Sparkle appcast. GitHub đã có **6/6 secrets bắt buộc** sau khi chủ tài khoản nhập credentials trong Terminal. Bộ cài được giữ local, chưa tạo GitHub release hoặc xuất bản feed.

Giao diện MClean hiện có được giữ. Lượt này tăng version/build trong `project.yml`, project Xcode và fallback CLI; sửa preflight credentials và thứ tự đóng gói trong pipeline. Các bản sửa chức năng và **198 test / 0 lỗi** thuộc lượt audit ngay trước đó, được ghi tại [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md). Lượt chuẩn bị không chạy lại toàn bộ XCTest; đã build/archive lại đúng version production và kiểm tra artifact thực tế.

## Chữ ký và notarization

| Mục | Kết quả |
|---|---|
| Bundle ID | `com.maclife.mclean` |
| Certificate | `Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)` |
| SHA-1 certificate | `1D07FE9B5F100897730FD6545760C1D3237C6E77` |
| Kiến trúc | `arm64` và `x86_64`, hardened runtime, timestamp |
| App notarization | **Accepted**, ID `8f7e98e3-1bb9-4c4d-b5fe-27d9effaab1c` |
| DMG notarization | **Accepted**, ID `e67ed9aa-7680-4346-8efb-5448c40592a7` |
| Notary logs | Cả hai không có issues |
| Ticket / chữ ký | `stapler validate`, strict deep codesign đạt |
| Gatekeeper | App và DMG: **accepted — Notarized Developer ID** trên host và macOS **15.7.7 (24G720)** |
| Mở lần đầu trong VM | App có quarantine mở bằng Finder, hộp xác nhận ghi Apple đã kiểm tra; onboarding tiếng Việt và Dashboard đạt. Process đang chạy đúng bundle production **1.0.5 / build 6**, strict codesign vẫn đạt. |
| Sparkle | SDK **2.10.0** xác minh feed và chữ ký ZIP; public key cũ được giữ |

Đã tìm lại profile Keychain cũ **`mdrivehealth`** trên chính máy này và dùng thành công. Việc không tìm thấy tên `AC_NOTARY` ở lượt audit chỉ cho biết profile đó không tồn tại; không chứng minh app chưa từng được notarize. Không tạo lại hoặc ghi đè các profile cũ.

ZIP cuối cùng được tạo **sau khi staple app**. DMG cũng chứa bản app đã staple đó và được ký/notarize/staple riêng. CI và `release-local.sh` đã đổi sang cùng thứ tự này. Local script nhận tên profile bằng argument thứ hai hoặc `MCLEAN_NOTARY_PROFILE`, kiểm tra credentials trước khi build:

```bash
scripts/release-local.sh 1.0.5 mdrivehealth
```

## Artifact đã chuẩn bị

Thư mục riêng ngoài Git:

`/Users/maclife/.codex/backups/MClean-production-prep-20261011-114702/`

| File | Mục đích |
|---|---|
| `MClean-1.0.5.dmg` | Bộ cài có app và liên kết Applications, ký/notarize/staple |
| `MClean-1.0.5.zip` | App đã staple, dùng cho Sparkle và Homebrew |
| `appcast/appcast.xml` | Feed đã ký, trỏ đến URL dự kiến của release `v1.0.5` |
| `MClean-1.0.5.xcarchive` / `Export/MClean.app` | Archive, dSYM và app production |
| `CHECKSUMS.md` | SHA-256 của hai bộ cài cuối |

```text
1b5d60046f4f52391bd615a27f4d792f7ae812859d9196d0dc5ef8156f771363  MClean-1.0.5.dmg
926529e268a42fbca3128f3c90061b9e4fc08a451842bf60dd714e230150c48e  MClean-1.0.5.zip
```

Logs chính: `archive.log`, `export.log`, `export-verification.log`, `notarize-app.json`, `notarize-dmg.json`, `notarize-app-log.json`, `notarize-dmg-log.json`, `appcast-generation.log`, `vm-gatekeeper.log`, `vm-launch-verification.log`, `workflow-verification.log` và `setup-notarization-verification.log`. Thư mục credentials chỉ chứa export đúng một Developer ID cùng mật khẩu riêng; không được đưa thư mục backup hoặc credentials vào release artifact.

## Secrets và CI

Đã cấu hình trên `maclifevn/MClean`:

- `BUILD_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `SPARKLE_PRIVATE_KEY`
- `NOTARIZATION_APPLE_ID`
- `NOTARIZATION_APP_PASSWORD`

Export `.p12` được xác minh trong bộ nhớ: đúng **một identity** và đúng certificate nêu trên. Secret được gửi qua stdin, private seed được giữ ngoài repository. Pipeline kiểm tra đủ tên secrets trước khi cài tools/build và chỉ báo tên còn thiếu. CI dùng Apple ID và app-specific password theo lựa chọn của chủ tài khoản, lưu profile trong keychain tạm của runner, xác minh với Apple trước archive và xóa keychain sau chạy.

Chủ tài khoản đã chạy lệnh trong Terminal, nhập credentials và cấu hình hai secrets notarization thành công lúc **05:13 UTC ngày 11/10/2026**. Khi cần thiết lập lại, dùng:

```bash
python3 /Volumes/DATA/Code/MLClean/scripts/setup-notarization.py
```

Script ẩn password, kiểm tra quyền notarization Team **CF5PGH3KGK** với Apple rồi cấu hình hai GitHub secrets qua stdin. Không tạo file credentials, không ghi password vào shell history và che credentials trong lỗi. Đã kiểm tra luồng thành công, từ chối credentials sai trước khi đổi secrets và từ chối input không tương tác. Không gửi password qua chat. Runner GitHub không truy cập được Keychain profile trên Mac; notarization local đã đạt không đồng nghĩa CI đã có credentials.

YAML, **24 Bash blocks**, shell/Python syntax, ca đủ credentials và sáu ca thiếu từng secret đều đạt. Mock kiểm tra profile notarization dùng keychain tạm, đúng signing team và dừng khi Apple từ chối; hai bước submit dùng cùng profile. Publication chỉ được chạy từ `main`; nhánh chuẩn bị dùng `dry_run=true`.

`HOMEBREW_TAP_TOKEN` là tùy chọn nếu muốn tự cập nhật repo tap riêng. Chi tiết thiết lập tại [scripts/SECRETS.md](../scripts/SECRETS.md). Cần kết quả Release dry run trên runner GitHub thật trước xuất bản.

## Nâng cấp từ 1.0.4 và kiểm tra trước xuất bản

Đã tải ZIP của release **v1.0.4** trên GitHub và kiểm tra chữ ký thực tế: app dùng **Apple Development**, còn 1.0.5 dùng **Developer ID Application**. Designated requirement thay đổi; cùng Team ID không đủ để bảo đảm giữ nguyên quyền Full Disk Access. Người dùng nâng cấp có thể cần thêm/bật lại **MClean mới trong Applications** tại System Settings → Privacy & Security → Full Disk Access, rồi khởi động lại app. Cần ghi rõ điều này trong release notes và kiểm tra trên máy có quyền đã cấp cho bản cũ.

Người dùng bản chưa tích hợp Sparkle cần tải/cài bản 1.0.5 một lần. Sau khi feed production được xuất bản, các bản có Sparkle mới nhận các update tiếp theo. Feed local hiện trỏ tới asset tương lai; chưa có URL tải production hoạt động cho 1.0.5.

Trước khi xuất bản:

1. Lưu source đã kiểm tra lên repo và chạy Release với `dry_run=true` trên đúng revision; kiểm tra ký/notarization bằng runner thật.
2. Kiểm tra tải bộ cài qua trình duyệt, cài mới và nâng cấp từ 1.0.4; xác minh Full Disk Access sau relaunch. VM hiện kiểm tra ticket/Gatekeeper bằng bản app có quarantine để mô phỏng file tải về, không thay thế phép thử tải thật qua trình duyệt.
3. Kiểm tra thủ công Settings relaunch trên macOS 15 và chạy smoke test Intel/macOS thấp nhất còn hỗ trợ. Audit đã thử breadcrumb và Sparkle install/relaunch trong VM; chưa thử runtime trên Intel/macOS 13/14 hoặc quét/dọn toàn ổ dữ liệu cá nhân với Full Disk Access.
4. Chỉ tạo release phiên bản mới khi các kiểm tra đạt; upload ZIP/DMG trước, feed đã ký sau. Không ghi đè asset của version đã phát hành. Lấy lại feed hiện hành và xác minh lịch sử trước khi xuất bản nếu repo đã có thêm update.

`homebrew/mclean.rb` vẫn trỏ tới bản đã phát hành **1.0.4** cho đến khi asset 1.0.5 có thật. Nhánh chuẩn bị được đưa lên GitHub để review và chạy dry run; chưa tạo release hoặc thay app của người dùng trong `/Applications`. Source và patch sau chuẩn bị được lưu cùng backup để đối chiếu và phục hồi.
