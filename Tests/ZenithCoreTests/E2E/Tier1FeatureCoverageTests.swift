import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

private final class AtomicBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    init(_ value: T? = nil) { self._value = value }
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

@Suite("Tier 1 - Feature Coverage Test Suite")
struct Tier1FeatureCoverageTests {

    // MARK: - Test Helpers
    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suiteName = "Tier1Suite_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeTestBitmapContext(width: Int = 400, height: Int = 300) -> CGContext {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context
    }

    // =========================================================================
    // FEATURE 1: Clipboard History Management & Ingestion (R1, F01-F05, F08-F12)
    // =========================================================================

    @Test("T1.F1.1: Plain text clipboard item creation, preview text, and byte size calculation")
    func testPlainTextClipboardItemCreation() {
        let textContent = "Hello GoldenGate Clipboard"
        let item = ClipboardItem.text(textContent)

        #expect(item.itemType == .plainText)
        #expect(item.plainTextContent == textContent)
        #expect(item.previewText == textContent)
        #expect(item.byteSize == textContent.utf8.count)
        #expect(item.rawImageData == nil)
        #expect(item.isPinned == false)
    }

    @Test("T1.F1.2: Rich text clipboard item creation with RTF data payload")
    func testRichTextClipboardItemCreation() {
        let plain = "Rich Text Note"
        let rtfData = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Arial;}}\\f0\\fs24 Rich Text Note}".data(using: .utf8)!
        let item = ClipboardItem.richText(rtfData: rtfData, plainText: plain)

        #expect(item.itemType == .richText)
        #expect(item.plainTextContent == plain)
        #expect(item.previewText == plain)
        #expect(item.byteSize == rtfData.count)
        #expect(item.rawImageData == nil)
    }

    @Test("T1.F1.3: Raster image clipboard item creation with dimension preview")
    func testImageClipboardItemCreation() {
        let dummyData = Data(repeating: 0xFF, count: 1024)
        let item = ClipboardItem.image(data: dummyData, width: 640, height: 480)

        #expect(item.itemType == .image)
        #expect(item.plainTextContent == nil)
        #expect(item.previewText == "Image (640 × 480)")
        #expect(item.byteSize == 1024)
        #expect(item.rawImageData == dummyData)
    }

    @Test("T1.F1.4: MockPasteboardService active monitoring and change event dispatch")
    func testMockPasteboardServiceMonitoring() {
        let service = MockPasteboardService()
        let receivedItem = ClipboardItem.text("Dynamic pasteboard update")
        let capturedBox = AtomicBox<ClipboardItem>()

        service.startMonitoring { item in
            capturedBox.value = item
        }

        #expect(service.isMonitoring == true)
        service.simulateExternalCopy(receivedItem)

        #expect(capturedBox.value == receivedItem)
        #expect(service.changeCount == 1)
        #expect(service.items.first == receivedItem)

        service.stopMonitoring()
        #expect(service.isMonitoring == false)
    }

    @Test("T1.F1.5: MockPasteboardService restoration to pasteboard and history clearing")
    func testMockPasteboardServiceRestorationAndClear() {
        let service = MockPasteboardService()
        let item = ClipboardItem.text("Item to restore")

        service.copyItemToPasteboard(item)
        #expect(service.copiedItems.count == 1)
        #expect(service.copiedItems.first == item)
        #expect(service.items.count == 1)

        service.clear()
        #expect(service.items.isEmpty)
        #expect(service.changeCount == 2)
    }

    // =========================================================================
    // FEATURE 2: Screen Capture & Loupe Geometry (R2, F13-F20)
    // =========================================================================

    @Test("T1.F2.1: MockScreenCaptureService captures primary display surface")
    func testCaptureMainDisplay() async throws {
        let service = MockScreenCaptureService()
        let captured = try await service.captureMainDisplay()

        #expect(captured.width == 1920)
        #expect(captured.height == 1080)
        #expect(service.captureMainDisplayCallCount == 1)
    }

    @Test("T1.F2.2: MockScreenCaptureService captures specific display subregion")
    func testCaptureDisplayRegion() async throws {
        let service = MockScreenCaptureService()
        let cropRect = CGRect(x: 50, y: 75, width: 300, height: 200)

        let cropped = try await service.captureDisplayRegion(cropRect, displayID: 1)

        #expect(cropped.width == 300)
        #expect(cropped.height == 200)
        #expect(service.capturedRegions.count == 1)
        #expect(service.capturedRegions.first == cropRect)
    }

    @Test("T1.F2.3: Synthetic bitmap pattern generation produces valid CGImage buffer")
    func testSyntheticPatternGeneration() {
        let image = MockScreenCaptureService.makeSyntheticPattern(width: 500, height: 400)

        #expect(image.width == 500)
        #expect(image.height == 400)
        #expect(image.bitsPerPixel == 32)
        #expect(image.bitsPerComponent == 8)
    }

    @Test("T1.F2.4: MockScreenCaptureService respects stubbed image override")
    func testStubbedImageOverride() async throws {
        let service = MockScreenCaptureService()
        let stubbedImage = MockScreenCaptureService.makeSyntheticPattern(width: 64, height: 64)
        service.stubbedMainDisplayImage = stubbedImage

        let result = try await service.captureMainDisplay()
        #expect(result.width == 64)
        #expect(result.height == 64)
    }

    @Test("T1.F2.5: MockScreenCaptureService screen recording permission query")
    func testScreenRecordingPermissionQuery() {
        let service = MockScreenCaptureService()
        #expect(service.hasScreenRecordingPermission == true)

        service.hasScreenRecordingPermission = false
        #expect(service.hasScreenRecordingPermission == false)
    }

    // =========================================================================
    // FEATURE 3: Image Annotation Commands & Canvas (R3, F21-F32, F48)
    // =========================================================================

    @Test("T1.F3.1: PenAnnotationCommand renders smoothed bezier path onto CGContext")
    func testPenAnnotationCommandApplication() {
        let context = makeTestBitmapContext()
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 80)]
        let command = PenAnnotationCommand(points: points, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1), strokeWidth: 4.0)

        #expect(command.points.count == 3)
        #expect(command.strokeWidth == 4.0)
        command.apply(to: context, scale: 1.0)
    }

    @Test("T1.F3.2: ArrowAnnotationCommand renders directional stem and arrow wings")
    func testArrowAnnotationCommandApplication() {
        let context = makeTestBitmapContext()
        let command = ArrowAnnotationCommand(
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 120, y: 120),
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            strokeWidth: 3.0,
            arrowHeadLength: 15.0
        )

        #expect(command.start == CGPoint(x: 20, y: 20))
        #expect(command.end == CGPoint(x: 120, y: 120))
        command.apply(to: context, scale: 1.0)
    }

    @Test("T1.F3.3: RectangleAnnotationCommand renders stroked and filled rectangles")
    func testRectangleAnnotationCommandApplication() {
        let context = makeTestBitmapContext()
        let strokedRect = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 100, height: 60),
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            strokeWidth: 2.0,
            isFilled: false
        )
        let filledRect = RectangleAnnotationCommand(
            rect: CGRect(x: 120, y: 10, width: 80, height: 80),
            color: CGColor(red: 1, green: 1, blue: 0, alpha: 0.5),
            strokeWidth: 1.0,
            isFilled: true
        )

        #expect(strokedRect.isFilled == false)
        #expect(filledRect.isFilled == true)
        strokedRect.apply(to: context, scale: 1.0)
        filledRect.apply(to: context, scale: 2.0)
    }

    @Test("T1.F3.4: TextAnnotationCommand renders text label via CoreText")
    func testTextAnnotationCommandApplication() {
        let context = makeTestBitmapContext()
        let command = TextAnnotationCommand(
            origin: CGPoint(x: 30, y: 50),
            text: "Annotation Bug #42",
            fontSize: 18.0,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        #expect(command.text == "Annotation Bug #42")
        #expect(command.fontSize == 18.0)
        command.apply(to: context, scale: 1.0)
    }

    @Test("T1.F3.5: BlurAnnotationCommand applies privacy mosaic tint mask")
    func testBlurAnnotationCommandApplication() {
        let context = makeTestBitmapContext()
        let command = BlurAnnotationCommand(
            rect: CGRect(x: 40, y: 40, width: 150, height: 40),
            pixelSize: 12.0
        )

        #expect(command.rect.width == 150)
        #expect(command.pixelSize == 12.0)
        command.apply(to: context, scale: 1.0)
    }

    // =========================================================================
    // FEATURE 4: Audio Feedback & Sound Effects (R4, F33-F36)
    // =========================================================================

    @Test("T1.F4.1: MockSoundService plays new copy sound effect and updates history")
    func testPlayNewCopySound() {
        let service = MockSoundService()
        #expect(service.newCopySoundCount == 0)

        service.playNewCopySound()

        #expect(service.newCopySoundCount == 1)
        #expect(service.playedSounds == [.newCopy])
    }

    @Test("T1.F4.2: MockSoundService plays paste selection sound effect")
    func testPlayPasteSound() {
        let service = MockSoundService()
        #expect(service.pasteSoundCount == 0)

        service.playPasteSound()

        #expect(service.pasteSoundCount == 1)
        #expect(service.playedSounds == [.paste])
    }

    @Test("T1.F4.3: MockSoundService plays camera shutter sound on screen capture")
    func testPlayShutterSound() {
        let service = MockSoundService()
        #expect(service.shutterSoundCount == 0)

        service.playShutterSound()

        #expect(service.shutterSoundCount == 1)
        #expect(service.playedSounds == [.shutter])
    }

    @Test("T1.F4.4: MockSoundService suppresses all playback when isMuted is true")
    func testSoundMuteSuppression() {
        let service = MockSoundService(isMuted: true)
        #expect(service.isMuted == true)

        service.playNewCopySound()
        service.playPasteSound()
        service.playShutterSound()

        #expect(service.newCopySoundCount == 0)
        #expect(service.pasteSoundCount == 0)
        #expect(service.shutterSoundCount == 0)
        #expect(service.playedSounds.isEmpty)
    }

    @Test("T1.F4.5: MockSoundService reset clears counters and event logs")
    func testSoundServiceReset() {
        let service = MockSoundService()
        service.playNewCopySound()
        service.playPasteSound()
        #expect(service.playedSounds.count == 2)

        service.reset()

        #expect(service.newCopySoundCount == 0)
        #expect(service.pasteSoundCount == 0)
        #expect(service.shutterSoundCount == 0)
        #expect(service.playedSounds.isEmpty)
    }

    // =========================================================================
    // FEATURE 5: Global HotKey Management (R1, R2, R6, F06, F13, F14, F46)
    // =========================================================================

    @Test("T1.F5.1: Default HotKey definitions match macOS standards")
    func testDefaultHotKeyDefinitions() {
        let defaults = HotKeyDefinition.defaultDictionary

        #expect(defaults[HotKeyDefinition.clipboardToggleId]?.keyEquivalent == "⌘⇧V")
        #expect(defaults[HotKeyDefinition.captureAreaId]?.keyEquivalent == "⌘⇧2")
        #expect(defaults[HotKeyDefinition.captureFullscreenId]?.keyEquivalent == "⌘⇧1")
    }

    @Test("T1.F5.2: MockHotKeyService registers hotkey and dispatches simulated trigger")
    func testHotKeyRegistrationAndTrigger() {
        let service = MockHotKeyService()
        let hotkey = HotKeyDefinition.defaultClipboard
        var triggered = false

        let success = service.registerHotKey(hotkey) {
            triggered = true
        }

        #expect(success == true)
        #expect(service.isRegistered(id: hotkey.id) == true)
        #expect(service.registeredHotKeys[hotkey.id]?.name == "Toggle Clipboard History")

        service.simulateHotKeyTrigger(id: hotkey.id)
        #expect(triggered == true)
        #expect(service.invocationCount(for: hotkey.id) == 1)
    }

    @Test("T1.F5.3: Alternative HotKey definitions Option+V and Cmd+Shift+X configuration")
    func testAlternativeHotKeyDefinitions() {
        let optV = HotKeyDefinition.alternativeClipboardOptionV
        #expect(optV.keyEquivalent == "⌥V")
        #expect(optV.carbonModifiers == CarbonModifierFlags.option.rawValue)

        let cmdShiftX = HotKeyDefinition.alternativeAreaCaptureX
        #expect(cmdShiftX.keyEquivalent == "⌘⇧X")
        #expect(cmdShiftX.keyCode == 7)
    }

    @Test("T1.F5.4: MockHotKeyService unregisters hotkey by identifier")
    func testHotKeyUnregistration() {
        let service = MockHotKeyService()
        let hotkey = HotKeyDefinition.defaultAreaCapture

        _ = service.registerHotKey(hotkey) {}
        #expect(service.isRegistered(id: hotkey.id) == true)

        service.unregisterHotKey(hotkey)
        #expect(service.isRegistered(id: hotkey.id) == false)
        #expect(service.unregisterCallCount == 1)
    }

    @Test("T1.F5.5: MockHotKeyService unregisterAll purges all active shortcuts")
    func testUnregisterAllHotKeys() {
        let service = MockHotKeyService()
        _ = service.registerHotKey(HotKeyDefinition.defaultClipboard) {}
        _ = service.registerHotKey(HotKeyDefinition.defaultAreaCapture) {}
        #expect(service.registeredHotKeys.count == 2)

        service.unregisterAll()
        #expect(service.registeredHotKeys.isEmpty)
        #expect(service.unregisterCallCount == 1)
    }

    // =========================================================================
    // FEATURE 6: Settings & Permissions (R6, F44, F45, F47)
    // =========================================================================

    @Test("T1.F6.1: SettingsStore default values initialize correctly")
    func testSettingsStoreDefaults() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.historyLimit == 20)
        #expect(store.soundEffectsEnabled == true)
        #expect(store.launchAtLoginEnabled == false)
        #expect(store.hotkeyMappings.count == 3)
    }

    @Test("T1.F6.2: SettingsStore history limit clamps to valid range")
    func testSettingsStoreHistoryLimitClamping() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)

        store.historyLimit = 100
        #expect(store.historyLimit == 100)

        store.historyLimit = 1
        #expect(store.historyLimit == 5)

        store.historyLimit = 999
        #expect(store.historyLimit == 500)
    }

    @Test("T1.F6.3: SettingsState value snapshot serialization and restoration")
    func testSettingsStateSnapshot() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        store.historyLimit = 50
        store.soundEffectsEnabled = false
        store.launchAtLoginEnabled = true

        let state = store.state
        #expect(state.historyLimit == 50)
        #expect(state.soundEffectsEnabled == false)
        #expect(state.launchAtLoginEnabled == true)
    }

    @Test("T1.F6.4: MockPermissionsService simulates screen recording and accessibility states")
    func testMockPermissionsServiceQueries() {
        let permissions = MockPermissionsService(screenRecordingGranted: false, accessibilityGranted: false)

        #expect(permissions.checkScreenRecordingPermission() == false)
        #expect(permissions.checkAccessibilityPermission() == false)

        permissions.screenRecordingGranted = true
        permissions.accessibilityGranted = true

        #expect(permissions.checkScreenRecordingPermission() == true)
        #expect(permissions.checkAccessibilityPermission() == true)
    }

    @Test("T1.F6.5: MockPermissionsService deep links track invocation call counts")
    func testMockPermissionsServiceDeepLinks() {
        let permissions = MockPermissionsService()

        #expect(permissions.openScreenRecordingSettings() == true)
        #expect(permissions.openScreenRecordingSettingsCallCount == 1)

        #expect(permissions.openAccessibilitySettings() == true)
        #expect(permissions.openAccessibilitySettingsCallCount == 1)
    }
}
