# MClean 1.0.6 — phát hành 11/10/2026

**[Version 1.0.6 / build 7 đã phát hành trên GitHub](https://github.com/maclifevn/MClean/releases/tag/v1.0.6).** [PR #9](https://github.com/maclifevn/MClean/pull/9) đã merge, sửa khung nền Dashboard phía sau unified toolbar khi cửa sổ rộng và khi đưa con trỏ lên thanh tiêu đề. Bố cục các card được giữ nguyên. Tag `v1.0.6` trỏ tới source **`d916e1f5a79ecbd5476b7995622f5db1b9c7f88f`**.

- [Build CI](https://github.com/maclifevn/MClean/actions/runs/38123158041) đạt trên macOS 15 Apple Silicon, macOS 15 Intel và macOS 14, kèm x86_64 qua Rosetta.
- [Pipeline ký/notarize](https://github.com/maclifevn/MClean/actions/runs/38123161270) đạt trên cùng source. Dùng chính artifact CI cho release; không rebuild hay thay byte sau kiểm chứng.
- QA giao diện của PR #9 dùng app thử riêng với `MainWindow`/`DashboardView` thực tế, dữ liệu giả, cửa sổ rộng và con trỏ ở toolbar, ở System/Light/Dark trên macOS 27.0. CI không thay thế QA giao diện thủ công trên macOS 14/15.

| Mục | Kết quả |
|---|---|
| Bundle / version | `com.maclife.mclean`, `1.0.6` / build `7`, minimum macOS `13.0` |
| Chữ ký | Developer ID Application Team `CF5PGH3KGK`, certificate SHA-1 `1D07FE9B5F100897730FD6545760C1D3237C6E77`, hardened runtime, secure timestamp |
| Kiến trúc | `arm64` và `x86_64`; CLI version chạy đúng trên cả hai |
| App notarization | **Accepted**, `336aa233-96d9-4c0d-bc5e-77f6e19978c5`, không có issues |
| DMG notarization | **Accepted**, `b190ad9a-9df8-4c28-9d6f-cea9a6ad04c1`, không có issues |
| Ticket / Gatekeeper | App và DMG được staple; strict codesign, stapler validate, Gatekeeper và hdiutil verify đạt |
| Đóng gói | ZIP và DMG chứa cùng app đã ký/staple; đối chiếu mọi file và symlink đạt |
| Sparkle | Giữ public key của 1.0.5; SDK xác minh feed/ZIP và CryptoKit xác minh ZIP bằng key trong app; feed chứa build 7 và giữ nguyên URL/chữ ký ZIP build 6 |
| Tải công khai | Bốn asset của release tải về không dùng authentication, byte/checksum khớp artifact đã kiểm chứng |

```text
744dc260c04ef5fde2e78c77d066879da3ba8268273ba6cb821ca41c1ca5f6c2  MClean-1.0.6.dmg
47bb693bd0cbef407dceff8884829450e545b15447c96129531abf2fa7a85fec  MClean-1.0.6.zip
```

Feed đã ký được upload lên release `appcast` sau khi asset `v1.0.6` công khai và tải được. `homebrew/mclean.rb` dùng checksum ZIP 1.0.6; repo tap riêng chưa được tạo. Bằng chứng nằm trong `/Users/maclife/.codex/backups/MClean-release-1.0.6-20261011-145709/`: artifact CI, notary logs, log Gatekeeper/staple/codesign, hash nội dung app và `publication/`.

Các hồ sơ 1.0.5 bên dưới được giữ nguyên theo thời điểm kiểm tra; không coi việc phát hành 1.0.6 là đã hoàn tất các phép thử FDA/Settings thủ công còn ghi trong hồ sơ cũ.

---

# MClean 1.0.5 — phát hành 11/10/2026

**[Version 1.0.5 / build 6 đã phát hành trên GitHub](https://github.com/maclifevn/MClean/releases/tag/v1.0.5).** Tag `v1.0.5` trỏ tới source build `0e33e42c831b87ee3db382d6ae545fd8bcc656a8`, gồm [PR #7](https://github.com/maclifevn/MClean/pull/7) và bộ nhận diện mới của [PR #8](https://github.com/maclifevn/MClean/pull/8). [CI của đúng commit trên main](https://github.com/maclifevn/MClean/actions/runs/38120654772) đạt trên macOS 15 Apple Silicon, macOS 15 Intel và macOS 14 Apple Silicon, kèm x86_64 qua Rosetta trên macOS 14. Đủ **6/6 secrets**; macOS 13 đã được bỏ khỏi phạm vi QA theo yêu cầu chủ dự án.

Nhận diện mới được chọn là **mẫu 04 — Clean M**: chữ M kết hợp nét chổi, màu xanh–ngọc, icon ứng dụng có nền bo góc và icon menubar template đơn sắc 18/36 px. Master PNG trong `docs/assets/branding/`; chạy `swift scripts/generate-appicon.swift` để xuất lại bộ asset, và `swift scripts/preview-brand-assets.swift` để xem các kích thước thực. Logo riêng dùng trong About; onboarding và popover dùng icon của bundle.

## Artifact đã phát hành với bộ nhận diện mới

Phát hành chính DMG/ZIP local đã chuẩn bị để chủ dự án test; không rebuild hoặc thay byte giữa bản test và release. Feed production đã ký được publish sau các asset phiên bản; `homebrew/mclean.rb` dùng checksum ZIP bên dưới.

| Mục | Kết quả |
|---|---|
| Bundle / version | `com.maclife.mclean`, `1.0.5` / build `6` |
| Chữ ký | `Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)`, hardened runtime, secure timestamp |
| Kiến trúc | `arm64` và `x86_64` |
| App notarization | **Accepted**, `cf667f63-cba9-4ad5-8bbb-c9e7add442d2`, không có issues |
| DMG notarization | **Accepted**, `9579e025-8f96-4fb5-a0d9-c5b68a52b000`, không có issues |
| Ticket / Gatekeeper | App và DMG được staple; strict codesign, stapler validate và Gatekeeper đạt |
| Đóng gói | Mở DMG chỉ đọc và giải nén ZIP: cùng app đã ký/staple, so sánh toàn bộ file và symlink đạt |
| Nhận diện | AppIcon mới; BrandMark màu và MenuBarIcon template 18 pt được đọc từ bundle export |
| Sparkle | Ed25519 của ZIP được CryptoKit xác minh bằng public key trong app; feed và ZIP được Sparkle SDK xác minh |

```text
acbb003e5d11cabcbc759830d2d85b7982e3154527e8785803cb71a6c8d2f957  MClean-1.0.5.dmg
556f49178a7bb70d2c87f2de3199c41de752a5a44310dcb9e64763ab21ba0a0f  MClean-1.0.5.zip
```

Bằng chứng local: `/Users/maclife/.codex/backups/MClean-1.0.5-icon04-localtest-20261011-141741/`, gồm `BUILD-INFO.json`, logs ký/notary/staple/Gatekeeper, hash nội dung app và `publication/` chứa feed/release notes cùng kiểm chứng upload.

## Hồ sơ chuẩn bị trước phát hành

**Các phần bên dưới giữ bằng chứng lịch sử trước khi thay bộ nhận diện**, với notary ID và checksum riêng của các build cũ. [Release dry run trước đổi icon](https://github.com/maclifevn/MClean/actions/runs/38117213521) đạt trên `c12a70c` với 200 test. Các phép thử thủ công chưa hoàn tất được ghi trong PR #7: đọc thư mục được bảo vệ sau cấp FDA với SIP bật, chuyển quyền từ bản 1.0.4 công khai và hoàn tất Settings trên candidate cuối; không coi việc ký/notarize hoặc phát hành là bằng chứng các phép thử này đã đạt.

Giao diện MClean hiện có được giữ. Lượt này tăng version/build trong `project.yml`, project Xcode và fallback CLI; sửa preflight credentials và thứ tự đóng gói trong pipeline. Các bản sửa chức năng thuộc lượt audit ngay trước đó, được ghi tại [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md). Host đã build/archive lại version production; CI chạy lại đầy đủ XCTest trên macOS 15 arm64.

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

## Artifact local ban đầu

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

`HOMEBREW_TAP_TOKEN` là tùy chọn nếu muốn tự cập nhật repo tap riêng. Chi tiết thiết lập tại [scripts/SECRETS.md](../scripts/SECRETS.md). Credentials và pipeline đã được xác nhận bằng runner GitHub thật.

## GitHub CI đã đạt

Revision được kiểm tra: **`a825fcc875ff40cd7b9e8ee9b358d61ff3fc12c9`** trên nhánh `codex/sync-puremac-keep-interface`.

| Workflow / bước | Kết quả |
|---|---|
| [Build](https://github.com/maclifevn/MClean/actions/runs/38114818221) | **Success**, 198 test / 0 lỗi và build Universal |
| [Release dry run](https://github.com/maclifevn/MClean/actions/runs/38114820763) | **Success**, 198 test / 0 lỗi; import certificate, xác thực Apple ID, archive/export, notarize/staple và upload artifact đạt |
| App notarization CI | **Accepted**, ID `e69d2c61-8275-467a-8d13-3f83ebf6898a` |
| DMG notarization CI | **Accepted**, ID `4a5428e6-6f0d-4445-b785-fd61ed363db2` |
| Sparkle / Gatekeeper | Feed/ZIP được SDK xác minh; app/DMG staple và Gatekeeper đạt |
| Xuất bản | Bốn bước tạo release, publish feed và bump Homebrew đều **skipped** vì dry run |
| Cleanup | Keychain chứa signing/notarization và các file secret tạm được xóa |

Lượt CI đầu cũng đạt tại [Build 38114314449](https://github.com/maclifevn/MClean/actions/runs/38114314449) và [Release 38114377280](https://github.com/maclifevn/MClean/actions/runs/38114377280), revision `b36a370`. Runner báo Node 20 deprecation ở hai Actions cũ, nên đã đổi sang SHA cố định của [checkout 7.0.1](https://github.com/actions/checkout/blob/v7.0.1/action.yml) và [upload-artifact 7.0.2](https://github.com/actions/upload-artifact/blob/v7.0.2/action.yml), đều dùng Node 24, rồi chạy lại hai workflow nêu trên thành công. Cảnh báo Node 20 đã hết. Các cảnh báo deployment của thư viện XCTest chỉ thuộc test bundle; app vẫn hỗ trợ macOS 13.0.

Artifact từ lượt CI cuối được lưu tại:

`/Users/maclife/.codex/backups/MClean-production-prep-20261011-114702/CI-38114820763/`

```text
195e2492e62b7e6329cb0ecba2b75a07adda22aadeb5bb7480235542580cdcdd  MClean-1.0.5.dmg
00bccb708847d1200cbaa92c6d794e7bff0ecd47e6a29125465661e080fc28f4  MClean-1.0.5.zip
```

Sau tải về đã kiểm tra lại checksum, version/build, bundle ID, public key Sparkle, hai kiến trúc, hardened runtime, strict codesign, staple và Gatekeeper của app/DMG. CLI chạy đúng 1.0.5; SDK Sparkle xác minh chữ ký feed và ZIP. Bằng chứng: `ci-artifact-verification-38114820763.log`; logs workflow: `ci-build-38114818221.log`, `ci-release-38114820763.log`, `ci-final-run.json`. VM đã dừng sau kiểm tra mở app, các artifact và snapshot được giữ.

Dùng ZIP, DMG và `appcast/appcast.xml` **cùng một lượt build** khi xuất bản để chữ ký và checksum khớp nhau. Artifact GitHub lưu 14 ngày; bản sao local được giữ. Log CI đầy đủ, JSON kết quả và bằng chứng xác minh sau tải nằm trong thư mục backup. Lượt local và CI tạo các checksum khác nhau vì là các build riêng.

## Nâng cấp từ 1.0.4 và kiểm tra trước xuất bản

Đã tải ZIP của release **v1.0.4** trên GitHub và kiểm tra chữ ký thực tế: app dùng **Apple Development**, còn 1.0.5 dùng **Developer ID Application**. Designated requirement thay đổi; cùng Team ID không đủ để bảo đảm giữ nguyên quyền Full Disk Access. Người dùng nâng cấp có thể cần thêm/bật lại **MClean mới trong Applications** tại System Settings → Privacy & Security → Full Disk Access, rồi khởi động lại app. Cần ghi rõ điều này trong release notes và kiểm tra trên máy có quyền đã cấp cho bản cũ.

Người dùng bản chưa tích hợp Sparkle cần tải/cài bản 1.0.5 một lần. Sau khi feed production được xuất bản, các bản có Sparkle mới nhận các update tiếp theo. Feed local hiện trỏ tới asset tương lai; chưa có URL tải production hoạt động cho 1.0.5.

Trước khi xuất bản:

1. Review/merge PR nháp #7 vào `main` sau khi hoàn tất QA. Nếu source thay đổi so với revision đã kiểm tra, chạy lại dry run cho thay đổi đó. Publication chỉ chạy từ `main`.
2. Kiểm tra tải bộ cài qua trình duyệt, cài mới và nâng cấp từ 1.0.4; xác minh Full Disk Access sau relaunch. VM hiện kiểm tra ticket/Gatekeeper bằng bản app có quarantine để mô phỏng file tải về, không thay thế phép thử tải thật qua trình duyệt.
3. Kiểm tra thủ công Settings relaunch trên macOS 15 và chạy smoke test Intel/macOS thấp nhất còn hỗ trợ. Audit đã thử breadcrumb và Sparkle install/relaunch trong VM; chưa thử runtime trên Intel/macOS 13/14 hoặc quét/dọn toàn ổ dữ liệu cá nhân với Full Disk Access.
4. Chỉ tạo release phiên bản mới khi các kiểm tra đạt; upload ZIP/DMG trước, feed đã ký sau. Không ghi đè asset của version đã phát hành. Lấy lại feed hiện hành và xác minh lịch sử trước khi xuất bản nếu repo đã có thêm update.

`homebrew/mclean.rb` vẫn trỏ tới bản đã phát hành **1.0.4** cho đến khi asset 1.0.5 có thật. Nhánh chuẩn bị được đưa lên GitHub để review và chạy dry run; chưa tạo release hoặc thay app của người dùng trong `/Applications`. Source và patch sau chuẩn bị được lưu cùng backup để đối chiếu và phục hồi.
