import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Tier 2 - Boundary & Corner Cases Test Suite")
struct Tier2BoundaryCornerTests {

    // MARK: - Test Helpers
    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suiteName = "Tier2Suite_\(UUID().uuidString)"
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
    // FEATURE 1: Clipboard Boundaries (R1, F01-F05, F08-F12)
    // =========================================================================

    @Test("T2.F1.1: Empty and whitespace-only text handling")
    func testEmptyAndWhitespaceTextHandling() {
        let emptyItem = ClipboardItem.text("")
        #expect(emptyItem.previewText == "(Empty Text)")
        #expect(emptyItem.byteSize == 0)
        #expect(emptyItem.plainTextContent == "")

        let whitespaceItem = ClipboardItem.text("   \n\t   ")
        #expect(whitespaceItem.previewText == "(Empty Text)")
        #expect(whitespaceItem.byteSize > 0)
        #expect(whitespaceItem.plainTextContent == "   \n\t   ")
    }

    @Test("T2.F1.2: Massive text payload preview truncation and byte calculation")
    func testMassiveTextPayload() {
        let largeString = String(repeating: "A", count: 100_000)
        let item = ClipboardItem.text(largeString)

        #expect(item.byteSize == 100_000)
        #expect(item.previewText.count == 103) // 100 chars + "..."
        #expect(item.previewText.hasSuffix("..."))
        #expect(item.plainTextContent?.count == 100_000)
    }

    @Test("T2.F1.3: Zero dimension and empty binary image payload handling")
    func testZeroDimensionImageHandling() {
        let emptyData = Data()
        let item = ClipboardItem.image(data: emptyData, width: 0, height: 0)

        #expect(item.previewText == "Image (0 × 0)")
        #expect(item.byteSize == 0)
        #expect(item.rawImageData?.isEmpty == true)
    }

    @Test("T2.F1.4: Pinned status modification maintains identity and payload integrity")
    func testPinnedStatusToggle() {
        var item = ClipboardItem.text("Important snippet", isPinned: false)
        #expect(item.isPinned == false)

        item.isPinned = true
        #expect(item.isPinned == true)
        #expect(item.plainTextContent == "Important snippet")
    }

    @Test("T2.F1.5: Multiple consecutive identical copies register accurately on pasteboard")
    func testConsecutiveIdenticalCopies() {
        let service = MockPasteboardService()
        let item = ClipboardItem.text("Duplicated Item")

        service.copyItemToPasteboard(item)
        service.copyItemToPasteboard(item)
        service.copyItemToPasteboard(item)

        #expect(service.changeCount == 3)
        #expect(service.copiedItems.count == 3)
        #expect(service.items.count == 3)
    }

    // =========================================================================
    // FEATURE 2: Screen Capture Boundaries (R2, F13-F20)
    // =========================================================================

    @Test("T2.F2.1: Minimal 1x1 pixel region capture")
    func testMinimal1x1RegionCapture() async throws {
        let service = MockScreenCaptureService()
        let miniRect = CGRect(x: 100, y: 100, width: 1, height: 1)

        let captured = try await service.captureDisplayRegion(miniRect, displayID: 1)

        #expect(captured.width == 1)
        #expect(captured.height == 1)
        #expect(service.capturedRegions.first == miniRect)
    }

    @Test("T2.F2.2: Extreme valid 8K resolution display capture")
    func testLargeDimensionCapture() async throws {
        let service = MockScreenCaptureService()
        let rect8K = CGRect(x: 0, y: 0, width: 7680, height: 4320)

        let captured = try await service.captureDisplayRegion(rect8K, displayID: 1)

        #expect(captured.width == 7680)
        #expect(captured.height == 4320)
    }

    @Test("T2.F2.3: Malformed, non-positive, NaN, and Infinite rects throw invalidRegion")
    func testMalformedRegionRejection() async {
        let service = MockScreenCaptureService()
        let malformedRects = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: 0, y: 0, width: -50, height: 100),
            CGRect(x: 0, y: 0, width: Double.nan, height: 100),
            CGRect(x: 0, y: 0, width: Double.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 40_000, height: 100) // Exceeds 32768 limit
        ]

        for rect in malformedRects {
            do {
                _ = try await service.captureDisplayRegion(rect, displayID: 1)
                #expect(Bool(false), "Expected invalidRegion error for rect: \(rect)")
            } catch let error as ScreenCaptureError {
                switch error {
                case .invalidRegion:
                    #expect(true)
                default:
                    #expect(Bool(false), "Unexpected ScreenCaptureError: \(error)")
                }
            } catch {
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        }
    }

    @Test("T2.F2.4: Permission denied error handling")
    func testPermissionDeniedErrorThrowing() async {
        let service = MockScreenCaptureService()
        service.stubbedError = ScreenCaptureError.permissionDenied

        do {
            _ = try await service.captureMainDisplay()
            #expect(Bool(false), "Expected permissionDenied error")
        } catch let error as ScreenCaptureError {
            #expect(error == .permissionDenied)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("T2.F2.5: Display not found error handling")
    func testDisplayNotFoundErrorThrowing() async {
        let service = MockScreenCaptureService()
        service.stubbedError = ScreenCaptureError.displayNotFound(displayID: 999)

        do {
            _ = try await service.captureDisplayRegion(CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 999)
            #expect(Bool(false), "Expected displayNotFound error")
        } catch let error as ScreenCaptureError {
            #expect(error == .displayNotFound(displayID: 999))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // =========================================================================
    // FEATURE 3: Image Annotation Boundaries (R3, F21-F32, F48)
    // =========================================================================

    @Test("T2.F3.1: Degenerate PenAnnotationCommand with 0 or 1 point is safe no-op")
    func testDegeneratePenCommands() {
        let context = makeTestBitmapContext()
        let emptyPen = PenAnnotationCommand(points: [], color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let singlePointPen = PenAnnotationCommand(points: [CGPoint(x: 50, y: 50)], color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))

        #expect(emptyPen.points.isEmpty)
        #expect(singlePointPen.points.count == 1)

        emptyPen.apply(to: context, scale: 1.0)
        singlePointPen.apply(to: context, scale: 1.0)
    }

    @Test("T2.F3.2: Zero-length ArrowAnnotationCommand (start == end) applies safely")
    func testZeroLengthArrowCommand() {
        let context = makeTestBitmapContext()
        let zeroArrow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100, y: 100),
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        )

        #expect(zeroArrow.start == zeroArrow.end)
        zeroArrow.apply(to: context, scale: 1.0)
    }

    @Test("T2.F3.3: Zero-dimension and negative rectangle annotations apply safely")
    func testZeroAndNegativeRectangles() {
        let context = makeTestBitmapContext()
        let zeroRect = RectangleAnnotationCommand(
            rect: CGRect(x: 50, y: 50, width: 0, height: 0),
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let negativeOriginRect = RectangleAnnotationCommand(
            rect: CGRect(x: -50, y: -50, width: 100, height: 100),
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )

        zeroRect.apply(to: context, scale: 1.0)
        negativeOriginRect.apply(to: context, scale: 1.0)
    }

    @Test("T2.F3.4: Text command with empty string and Unicode emojis applies safely")
    func testSpecialCharactersTextAnnotation() {
        let context = makeTestBitmapContext()
        let emptyText = TextAnnotationCommand(
            origin: CGPoint(x: 10, y: 10),
            text: "",
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let emojiText = TextAnnotationCommand(
            origin: CGPoint(x: 10, y: 30),
            text: "🚀 Swift Testing 🍏 ⌘⌥⇧⌃",
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        emptyText.apply(to: context, scale: 1.0)
        emojiText.apply(to: context, scale: 1.0)
    }

    @Test("T2.F3.5: Scaling command application at high Retina factors (3x, 4x)")
    func testHighRetinaScaleFactors() {
        let context = makeTestBitmapContext(width: 800, height: 600)
        let pen = PenAnnotationCommand(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)],
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            strokeWidth: 5.0
        )

        pen.apply(to: context, scale: 3.0)
        pen.apply(to: context, scale: 4.0)
    }

    // =========================================================================
    // FEATURE 4: Audio Boundaries (R4, F33-F36)
    // =========================================================================

    @Test("T2.F4.1: Dynamic mute toggling immediately suppresses and restores audio cues")
    func testDynamicMuteToggling() {
        let service = MockSoundService()

        service.playNewCopySound()
        #expect(service.newCopySoundCount == 1)

        service.isMuted = true
        service.playNewCopySound()
        service.playPasteSound()
        #expect(service.newCopySoundCount == 1)
        #expect(service.pasteSoundCount == 0)

        service.isMuted = false
        service.playPasteSound()
        #expect(service.pasteSoundCount == 1)
    }

    @Test("T2.F4.2: Rapid consecutive audio cue bursts")
    func testRapidAudioCueBurst() {
        let service = MockSoundService()

        for _ in 0..<100 {
            service.playShutterSound()
        }

        #expect(service.shutterSoundCount == 100)
        #expect(service.playedSounds.count == 100)
        #expect(service.playedSounds.allSatisfy { $0 == .shutter })
    }

    @Test("T2.F4.3: Reset preserves subsequent playback capability")
    func testResetPreservesSubsequentPlayback() {
        let service = MockSoundService()
        service.playNewCopySound()
        service.reset()

        #expect(service.playedSounds.isEmpty)
        service.playPasteSound()

        #expect(service.pasteSoundCount == 1)
        #expect(service.playedSounds == [.paste])
    }

    @Test("T2.F4.4: Sound service default initialization is unmuted")
    func testDefaultInitializationUnmuted() {
        let service = MockSoundService()
        #expect(service.isMuted == false)

        service.playNewCopySound()
        #expect(service.newCopySoundCount == 1)
    }

    @Test("T2.F4.5: Mixed playback sequence preserves chronological order")
    func testMixedPlaybackSequencePreservation() {
        let service = MockSoundService()

        service.playNewCopySound()
        service.playPasteSound()
        service.playShutterSound()
        service.playNewCopySound()

        #expect(service.playedSounds == [.newCopy, .paste, .shutter, .newCopy])
    }

    // =========================================================================
    // FEATURE 5: Global HotKey Boundaries (R1, R2, R6, F06, F13, F14, F46)
    // =========================================================================

    @Test("T2.F5.1: Duplicate hotkey registration overrides previous definition and handler")
    func testDuplicateHotKeyRegistration() {
        let service = MockHotKeyService()
        var v1Fired = false
        var v2Fired = false

        let def1 = HotKeyDefinition(id: "test.action", name: "Version 1", keyCode: 1, carbonModifiers: 0, keyEquivalent: "A")
        let def2 = HotKeyDefinition(id: "test.action", name: "Version 2", keyCode: 2, carbonModifiers: 0, keyEquivalent: "B")

        _ = service.registerHotKey(def1) { v1Fired = true }
        _ = service.registerHotKey(def2) { v2Fired = true }

        #expect(service.registeredHotKeys.count == 1)
        #expect(service.registeredHotKeys["test.action"]?.name == "Version 2")

        service.simulateHotKeyTrigger(id: "test.action")
        #expect(v1Fired == false)
        #expect(v2Fired == true)
    }

    @Test("T2.F5.2: Simulated registration failure handling")
    func testRegistrationFailureHandling() {
        let service = MockHotKeyService()
        service.shouldRegistrationSucceed = false

        let success = service.registerHotKey(HotKeyDefinition.defaultClipboard) {}

        #expect(success == false)
        #expect(service.registeredHotKeys.isEmpty)
        #expect(service.isRegistered(id: HotKeyDefinition.clipboardToggleId) == false)
    }

    @Test("T2.F5.3: Multiple modifier flags bitwise mask synthesis")
    func testMultiModifierFlagsBitwiseMask() {
        let allModifiers = CarbonModifierFlags.command.rawValue
            | CarbonModifierFlags.shift.rawValue
            | CarbonModifierFlags.option.rawValue
            | CarbonModifierFlags.control.rawValue

        let complexHotKey = HotKeyDefinition(
            id: "super.shortcut",
            name: "Super Shortcut",
            keyCode: 42,
            carbonModifiers: allModifiers,
            keyEquivalent: "⌃⌥⇧⌘*"
        )

        #expect(complexHotKey.carbonModifiers & CarbonModifierFlags.command.rawValue != 0)
        #expect(complexHotKey.carbonModifiers & CarbonModifierFlags.shift.rawValue != 0)
        #expect(complexHotKey.carbonModifiers & CarbonModifierFlags.option.rawValue != 0)
        #expect(complexHotKey.carbonModifiers & CarbonModifierFlags.control.rawValue != 0)
    }

    @Test("T2.F5.4: Unregistering non-existent hotkey is a safe no-op")
    func testUnregisterNonExistentHotKey() {
        let service = MockHotKeyService()
        service.unregisterHotKey(id: "does.not.exist")

        #expect(service.unregisterCallCount == 1)
        #expect(service.registeredHotKeys.isEmpty)
    }

    @Test("T2.F5.5: Triggering unregistered hotkey returns false safely")
    func testSimulateTriggerUnregisteredReturnsFalse() {
        let service = MockHotKeyService()
        let result = service.simulateHotKeyTrigger(id: "unknown.action")
        #expect(result == false)
    }

    // =========================================================================
    // FEATURE 6: Settings Boundaries (R6, F44, F45, F47)
    // =========================================================================

    @Test("T2.F6.1: Extreme integer values clamp strictly to 5 and 500")
    func testExtremeIntegerHistoryLimit() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)

        store.historyLimit = Int.min
        #expect(store.historyLimit == 5)

        store.historyLimit = Int.max
        #expect(store.historyLimit == 500)

        store.historyLimit = -9999
        #expect(store.historyLimit == 5)
    }

    @Test("T2.F6.2: Off-by-one transitions at capacity boundaries")
    func testExactCapacityBoundaries() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)

        store.historyLimit = 4
        #expect(store.historyLimit == 5)

        store.historyLimit = 5
        #expect(store.historyLimit == 5)

        store.historyLimit = 6
        #expect(store.historyLimit == 6)

        store.historyLimit = 499
        #expect(store.historyLimit == 499)

        store.historyLimit = 500
        #expect(store.historyLimit == 500)

        store.historyLimit = 501
        #expect(store.historyLimit == 500)
    }

    @Test("T2.F6.3: Corrupted user defaults keys recover on store initialization")
    func testCorruptedUserDefaultsRecovery() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        // Inject string into history limit
        defaults.set("not_a_number", forKey: SettingsStore.Keys.historyLimit)
        let store = SettingsStore(userDefaults: defaults)

        #expect(store.historyLimit == SettingsStore.defaultHistoryLimit)
    }

    @Test("T2.F6.4: Permissions granted and denied state transitions")
    func testPermissionsStateTransitions() {
        let permissions = MockPermissionsService()

        #expect(permissions.checkScreenRecordingPermission() == false)
        permissions.screenRecordingGranted = true
        #expect(permissions.checkScreenRecordingPermission() == true)
        permissions.screenRecordingGranted = false
        #expect(permissions.checkScreenRecordingPermission() == false)
    }

    @Test("T2.F6.5: Deep link URLs maintain valid macOS system preferences scheme")
    func testDeepLinkURLsValidity() {
        let screenURL = SystemPermissions.screenRecordingSettingsURL
        let accessURL = SystemPermissions.accessibilitySettingsURL

        #expect(screenURL.scheme == "x-apple.systempreferences")
        #expect(accessURL.scheme == "x-apple.systempreferences")
        #expect(!screenURL.pathComponents.isEmpty)
        #expect(!accessURL.pathComponents.isEmpty)
    }
}
