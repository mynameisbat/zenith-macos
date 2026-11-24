# Nghiên cứu: điều khiển màn hình trong Zenith

Ngày 23/11/2026. Đây là nghiên cứu, chưa có code. Các nhận định dưới đây dựa trên việc đọc mã nguồn năm dự án tham khảo (clone ngày 23/11/2026) và các phép thử **chỉ đọc** trên máy phát triển (MacBook Pro M1 Pro, macOS 27.2.1, một màn LG 1080p cắm vào cổng HDMI của máy).

## 1. Kết luận ngắn

| Tính năng | API | Đã kiểm chứng trên máy | Nên làm? |
|---|---|---|---|
| Độ sáng / tương phản / âm lượng màn ngoài | DDC/CI qua `IOAVService` (private, IOKit) | Có: đọc được độ sáng 70/100, tương phản 60/100, âm lượng 30 | **Có, giai đoạn 1** |
| Độ sáng màn tích hợp và màn Apple | `DisplayServicesGet/SetBrightness` (private) | Symbol có mặt | Có, cùng giai đoạn 1 |
| Làm tối bằng phần mềm (màn không có DDC) | Gamma `CGSetDisplayTransferByTable` (public) hoặc cửa sổ phủ đen | API có | Có, làm phương án dự phòng |
| Độ phân giải / tần số quét | `CGDisplayCopyAllDisplayModes` + `CGConfigureDisplayWithDisplayMode` (public) | 74 mode, 50/60/75 Hz trên màn LG | **Có, giai đoạn 2** |
| Vị trí màn, mirror | `CGConfigureDisplayOrigin`, `CGConfigureDisplayMirrorOfDisplay` (public) | API có | Giai đoạn 2, tùy chọn |
| Xoay màn | `MPDisplay setOrientation:` (MonitorPanel, private) | Lớp có mặt | Để sau |
| Bật/tắt một màn | `CGSConfigureDisplayEnabled` (SkyLight, private) | Symbol có mặt | **Không**: có thể tắt luôn màn duy nhất |
| Màn ảo / ép HiDPI | `CGVirtualDisplay*` (private, CoreGraphics) | Bốn lớp có mặt | Giai đoạn 3, thử nghiệm |

## 2. Các dự án tham khảo: những gì thực sự có trong repo

| Repo | License (đã đọc file) | Ghi chú sau khi đọc code |
|---|---|---|
| `waydabber/m1ddc` | MIT, © 2021 waydabber | Khoảng 1.150 dòng C/ObjC, cập nhật 21/11/2026. **Là nguồn nên port**: biết chip MCDP29xx (địa chỉ `0xB7`), kiểm tra checksum trả lời, phân biệt "không hỗ trợ" với "trả lời hỏng", đọc EDID để nhận diện màn. |
| `MonitorControl/MonitorControl` | MIT, © 2017 (`License.txt`) | Kiến trúc app đầy đủ, nhưng `Arm64DDC.swift` **luôn dùng địa chỉ `0x37`** và không có chữ MCDP nào. Trên máy thử, `0x37` chỉ nhận về "null message" (`6E 80 BE`). Nên lấy kiến trúc (ghép màn với service bằng điểm khớp, gamma, cửa sổ phủ), không lấy lớp I2C. |
| `jakehilborn/displayplacer` | MIT, © 2015 | Dùng `CGSConfigureDisplayMode` (private) để đổi mode và `MPDisplay` để xoay. Đổi mode thì API public là đủ; chỉ xoay mới cần private. Cập nhật lần cuối 05/2024. |
| `Stengo/DeskPad` | MIT, © 2022 Bastian Andelefski | `CGVirtualDisplayPrivate.h` (72 dòng) là thứ đáng giá nhất. Phần hiển thị màn ảo trong cửa sổ dùng `CGDisplayStream`, **đã bị obsolete từ macOS 15 (`SCREEN_CAPTURE_OBSOLETE(10.8,14.0,15.0)`) nên không biên dịch được với target macOS 26**; Zenith sẽ phải dùng `SCStream`, như `NativeScreenCaptureBackend` đã làm. |
| `waydabber/BetterDummy` | MIT, © 2021 Istvan T. | **HEAD hiện chỉ có README trỏ sang BetterDisplay (mã đóng).** Code Swift vẫn còn trong lịch sử, ở commit `827b81c` (14/12/2021): `Model/Dummy.swift` cho thấy cách dựng `CGVirtualDisplay` với nhiều mode `hiDPI = 1`. |

Code MIT được phép port. Cần giữ thông báo copyright, ví dụ trong file `THIRD_PARTY_NOTICES.md` và ở đầu các file đã port.

## 3. Kết quả đo trên máy (chỉ đọc)

- Màn ngoài nằm trên một `DCPAVServiceProxy` có `Location = External`. `Transport` là `Upstream = DP, Downstream = HDMI`, nhà cung cấp là `AppleDCPMCDP29XX` (chip chuyển DP sang HDMI tích hợp của MacBook Pro).
- Đọc EDID 128 byte ở `0x50` thành công, header hợp lệ.
- Gửi "Get VCP Feature" (không bao giờ "Set"):
  - chip `0x37`: lần nào cũng nhận null message ⇒ **cách của MonitorControl không chạy trên cổng HDMI này**;
  - chip `0xB7`: độ sáng `70/100`, tương phản `60/100`, âm lượng `30/255`, input `4`. Chờ 50 ms trước khi đọc là đủ.
- Màn LG có 74 mode (36 dùng được cho desktop), 34 mode HiDPI nhưng mode HiDPI lớn nhất chỉ là "trông như 960×540". Muốn có "trông như 1920×1080" sắc nét trên màn 1080p thì phải làm màn ảo, tức giai đoạn 3.
- Có mặt trên macOS 27.2.1: `IOAVServiceCreateWithService/ReadI2C/WriteI2C`, `DisplayServicesGet/SetBrightness/CanChangeBrightness`, `CoreDisplay_DisplayCreateInfoDictionary`, `CGSConfigureDisplayMode`, `CGSConfigureDisplayEnabled`, `CGVirtualDisplay{,Descriptor,Settings,Mode}`, `MPDisplay`.

Script thử nằm trong scratchpad của phiên, không nằm trong repo. Lớp DDC thật phải có test với màn giả (mục 5).

## 4. Đặt tính năng vào Zenith ở đâu

Tuân theo các quy tắc đã có trong `CLAUDE.md`:

- **Không vẽ OSD độ sáng/âm lượng, không bắt phím độ sáng**: `IslandLevelHUDService` đã bị gỡ theo yêu cầu. Độ sáng màn ngoài chỉ chỉnh bằng slider.
- **Island không rộng quá 380 pt.** Một trang `IslandPage.displays` (380 × khoảng 90 pt mỗi màn) là vừa: tên màn, một slider độ sáng, và nếu màn hỗ trợ DDC thì thêm âm lượng ở menu ngữ cảnh. Mở trang bằng tool mới `IslandTool.displays` trong nhóm "System" (hiện có 3 tool, thêm một là đủ 4 ô). Dock vẫn giữ `maxPinned = 6`.
- **Độ phân giải, Hz, vị trí** cần nhiều chỗ, nên đặt trong một tab Settings mới `SettingsTab.displays`, và cho `IslandTool.displays` (hoặc một tool riêng) có `opensSettingsWindow`, giống Cleaner hay Ports.
- Trang System (`ZenithCommandHubView(inIsland: true)`) **không** thêm gì, để tránh trùng lặp (người dùng đã phàn nàn về chuyện này).

### Kiến trúc đề xuất (tất cả logic ở `ZenithCore` để test được)

```
Sources/ZenithCore/Displays/
  DDCPacket.swift            // mã hóa "Get/Set VCP", kiểm checksum, giải mã trả lời: hàm thuần, test kỹ
  EDID.swift                 // parse 128 byte: hãng, model, serial, tên (theo avservice.m của m1ddc)
  DDCTransport.swift         // protocol: write(chip:, data:), read(chip:, count:) -> [UInt8]
  IOAVServiceTransport.swift // bản thật: dlopen/dlsym IOKit, như FullscreenSpaceProbe
  DisplayInventory.swift     // CGGetOnlineDisplayList + DCPAVServiceProxy, ghép bằng EDID; chọn chip 0x37/0xB7
  DisplayBrightnessService.swift // @MainActor ObservableObject: mỗi màn một DisplayControl (.ddc, .appleNative, .gamma, .none)
  DisplayModeService.swift   // liệt kê/đặt mode qua seam DisplayConfiguring
Sources/ZenithCore/Mocks/
  SimulatedDDCMonitor.swift  // màn giả trả lời VCP: null message, unsupported, checksum hỏng, chậm
```

Lưu ý khi cài đặt:

1. **I2C chặn luồng.** Mỗi lệnh mất 50 đến 150 ms (`usleep`). Phải chạy trên một serial `DispatchQueue` riêng cho từng màn, không chạy trên main, không chạy trên cooperative pool. Khi kéo slider thì gộp lệnh, chỉ gửi giá trị mới nhất, khoảng 10 lần/giây. Nhiều màn ghi mỗi lệnh Set vào EEPROM, nên không gửi theo tốc độ của chuột.
2. **Chọn chip theo thứ tự**: nhà cung cấp là `AppleDCPMCDP29XX` thì `0xB7`, ngược lại `0x37`; thử lại với chip kia nếu nhận null message. Ghi nhớ kết quả theo EDID.
3. **Không đọc lại độ sáng liên tục.** Đọc một lần khi màn xuất hiện (`didChangeScreenParametersNotification`, island đã nghe thông báo này) và khi trang mở. Đây là điều Zenith đã học với Now Playing: không thêm timer.
4. **Gamma**: lưu bảng gốc (`CGGetDisplayTransferByTable`) và trả lại khi tắt, khi thoát app và khi màn biến mất. Nếu app chết, macOS khôi phục gamma khi process kết thúc (cần kiểm chứng trên máy trước khi tin vào điều này).
5. **Đổi mode phải xác nhận rồi mới giữ**: áp dụng bằng `CGCompleteDisplayConfiguration(.forSession)`, hiện hộp thoại "Giữ thiết lập này? Tự quay lại sau 15 giây", chỉ khi người dùng bấm Giữ mới áp dụng `.permanently`. Một mode màn không hiển thị được thì người dùng không bấm được gì, và hộp thoại đếm ngược là lối thoát duy nhất.
6. **Seam cho test** (test không được đổi máy đang chạy): `DDCTransport`, `DisplayConfiguring` (bọc `CGBeginDisplayConfiguration…`), `GammaControlling`. Bản thật không bao giờ chạy trong test. Nếu cần thử trên máy thật, thêm suite opt-in `ZENITH_E2E_DISPLAY=1`, chỉ đọc.
7. **Đa ngôn ngữ**: mọi chuỗi mới đi qua `String(localized:)` và có bản dịch trong 7 `.lproj`, sau đó chạy `scripts/check_localization.sh`.
8. **Quyền**: DDC, DisplayServices và gamma không cần quyền TCC. Nếu giai đoạn 3 hiển thị màn ảo trong cửa sổ thì cần Screen Recording (đã có trang Permissions).
9. Gọi C/ObjC: các hàm C (`IOAVService*`, `DisplayServices*`) dùng `dlsym` cùng kiểu `@convention(c)`, như `FullscreenSpaceProbe`, không cần thêm target. Riêng `CGVirtualDisplay` là lớp ObjC: cần một target C/ObjC nhỏ (`ZenithDisplayPrivate`, chỉ chứa header kiểu `CGVirtualDisplayPrivate.h` và một file `.m` rỗng) để Swift thấy được interface.

## 5. Lộ trình

**Giai đoạn 1: độ sáng (ĐÃ XONG)**
- `DDCPacket`, `EDID`, `DDCTransport` + `SimulatedDDCMonitor`, kèm test: checksum, null message, unsupported, chip `0xB7`, gộp lệnh slider.
- `DisplayBrightnessService` với ba backend: DDC, DisplayServices (màn tích hợp/Apple), gamma (dự phòng). Lưu giá trị cuối theo EDID; mọi thay đổi gọi `objectWillChange.send()`.
- `IslandPage.displays` + `IslandTool.displays`; thêm render `island-page-displays` vào `--render-screenshots` với màn giả.

**Giai đoạn 2: độ phân giải và tần số quét (ĐÃ XONG)**
- `DisplayModeService` qua API public (`CGDisplayCopyAllDisplayModes`, `CGConfigureDisplayWithDisplayMode`), lọc `isUsableForDesktopGUI`, gom mode HiDPI và mode thường.
- Tab Settings "Displays" (`DisplaysSettingsTab` trong `SettingsTab.displays`) với cơ chế an toàn: tự hoàn tác sau 15 giây nếu không xác nhận "Keep Changes".
- Tích hợp liên kết "Display Settings…" từ trang Displays trên Island để mở trực tiếp tab Displays trong Settings.
- Đầy đủ unit tests (`DisplayModeServiceTests`) bọc qua seam `DisplayConfiguring` cách ly phần cứng.

**Giai đoạn 3 (thử nghiệm, sau một switch mặc định tắt): màn ảo / HiDPI**
- Màn ảo 3840×2160 với `hiDPI = 1`, mirror màn thật vào nó để có "trông như 1920×1080" sắc nét trên màn 1080p. Màn ảo chỉ sống cùng process Zenith: thoát app thì mirror biến mất và cửa sổ bị sắp xếp lại. Cần kiểm chứng trên máy macOS 27 trước khi hứa với người dùng.

## 6. Rủi ro

- **Private API có thể đổi theo mỗi bản macOS** (MediaRemote đã từng "đóng cửa" ở 15.4). Mỗi backend phải tự phát hiện khi symbol vắng mặt (`dlsym` trả nil) và báo màn "không điều khiển được", không được crash.
- **Không hỗ trợ**: dock DisplayLink, nhiều hub USB-C/KVM rẻ, màn tắt DDC/CI trong menu OSD. Khi đó dùng gamma.
- Màn ảo và việc tắt màn là phần dễ làm mất màn hình nhất. Không làm mặc định, và không bao giờ tắt màn cuối cùng.
- Phân phối: Zenith đã nằm ngoài Mac App Store và ký bằng identity "Zenith Local Signing", và updater tin vào đúng chữ ký đó. Tính năng này không bắt buộc phải chuyển sang Developer ID; **không đổi certificate** vì đổi sẽ làm gãy auto-update.
