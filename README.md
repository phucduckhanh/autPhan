# AutoTap – tweak tự bấm (autoclick) để học hỏi

## Dùng
1. Sửa `AutoTap.plist`: thay `com.example.target` bằng bundle ID app cần bấm (không lọc cả hệ thống để tránh lỗi SpringBoard).
2. Cài Theos, rồi `make package` (rootless: bỏ comment dòng `THEOS_PACKAGE_SCHEME`).
3. Cài deb, mở app: thấy thanh dock nổi.
   - ＋ thêm chấm số (ở giữa màn hình) → kéo đến vị trí cần bấm; thêm nhiều chấm sẽ bấm lần lượt 1→2→3…
   - ▶/■ chạy / dừng. Khi chạy, chấm mờ đi và cho chạm xuyên qua.
   - ⚙ chỉnh khoảng cách, giữ, jitter, ngẫu nhiên, tự dừng.
   - 🗑 xoá hết chấm. Kéo dock để dời chỗ.

## Cấu trúc (học từ AutoClicker_v1.1)
Config (NSUserDefaults `AutoTap.cfg.v1`) → Engine (dispatch_after, khoảng cách ngẫu nhiên) → Touch (IOHID digitizer, `_enqueueHIDEvent:`) → Overlay (UIWindow xuyên chạm + dock + chấm kéo thả).

## Chưa có / hướng mở rộng
Điểm vuốt (cần thêm sự kiện di chuyển giữa down và up), ghi–phát macro, nhiều hồ sơ, đo CPS, tự chạy khi mở app, fallback UIKit khi IOHID không dùng được.
Chưa biên dịch/thử thiết bị: nếu lỗi biên dịch hoặc không nhận chạm, gửi log để chỉnh.

## Trạng thái build
Đã kiểm tra: biên dịch (clang, iPhoneOS14.5.sdk, arm64) và liên kết thành dylib thành công, không cảnh báo. Chưa ký (cần `ldid -S`) và chưa chạy thử trên thiết bị.
Build thật: cài Theos (https://theos.dev/docs/installation), rồi trong thư mục dự án chạy `make package`.
