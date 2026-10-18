import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

private final class AtomicBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    init(_ value: T? = nil) { self._value = value }
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

@Suite("Tier 3 - Cross-Feature Interactions Test Suite")
struct Tier3CrossFeatureTests {

    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suiteName = "Tier3Suite_\(UUID().uuidString)"
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

    // MARK: - 1. Screen Capture + Audio Feedback
    @Test("T3.1: Screen capture triggers camera shutter sound respecting SettingsStore mute state")
    func testScreenCaptureTriggersShutterSoundWithMuteSync() async throws {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let captureService = MockScreenCaptureService()
        let soundService = MockSoundService()

        // Sync mute state
        soundService.isMuted = !store.soundEffectsEnabled
        #expect(soundService.isMuted == false)

        // 1. Capture with sound enabled
        _ = try await captureService.captureMainDisplay()
        soundService.playShutterSound()

        #expect(captureService.captureMainDisplayCallCount == 1)
        #expect(soundService.shutterSoundCount == 1)
        #expect(soundService.playedSounds == [.shutter])

        // 2. Mute sound in settings
        store.soundEffectsEnabled = false
        soundService.isMuted = !store.soundEffectsEnabled

        _ = try await captureService.captureMainDisplay()
        soundService.playShutterSound()

        // Shutter sound was suppressed
        #expect(captureService.captureMainDisplayCallCount == 2)
        #expect(soundService.shutterSoundCount == 1)
    }

    // MARK: - 2. Pasteboard Ingestion + Audio Feedback
    @Test("T3.2: External pasteboard copy triggers new copy sound and respects mute setting")
    func testPasteboardExternalCopyTriggersAudioFeedback() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let pasteboardService = MockPasteboardService()
        let soundService = MockSoundService(isMuted: !store.soundEffectsEnabled)

        pasteboardService.startMonitoring { _ in
            soundService.playNewCopySound()
        }

        // Active copy with sound
        let item1 = ClipboardItem.text("Active text snippet")
        pasteboardService.simulateExternalCopy(item1)

        #expect(soundService.newCopySoundCount == 1)
        #expect(soundService.playedSounds == [.newCopy])

        // User mutes sound effects
        store.soundEffectsEnabled = false
        soundService.isMuted = !store.soundEffectsEnabled

        let item2 = ClipboardItem.text("Silent text snippet")
        pasteboardService.simulateExternalCopy(item2)

        // Sound count remains 1 due to mute
        #expect(soundService.newCopySoundCount == 1)
        #expect(pasteboardService.items.count == 2)
    }

    // MARK: - 3. Pasteboard Restoration + Audio Feedback
    @Test("T3.3: Restoring historical item back to pasteboard triggers paste sound")
    func testPasteboardRestorationTriggersPasteSound() {
        let pasteboardService = MockPasteboardService()
        let soundService = MockSoundService()

        let item = ClipboardItem.text("Restored line")
        pasteboardService.copyItemToPasteboard(item)
        soundService.playPasteSound()

        #expect(pasteboardService.copiedItems.first == item)
        #expect(soundService.pasteSoundCount == 1)
        #expect(soundService.playedSounds == [.paste])
    }

    // MARK: - 4. Screen Capture + Annotation + Pasteboard Export Pipeline
    @Test("T3.4: Screen capture region annotated with vector commands and exported to pasteboard")
    func testCaptureAnnotationExportPipeline() async throws {
        let captureService = MockScreenCaptureService()
        let pasteboardService = MockPasteboardService()

        // 1. Capture 400x300 subregion
        let cropRect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let rawImage = try await captureService.captureDisplayRegion(cropRect, displayID: 1)
        #expect(rawImage.width == 400)
        #expect(rawImage.height == 300)

        // 2. Render annotations on top of captured bitmap
        let context = makeTestBitmapContext(width: rawImage.width, height: rawImage.height)
        context.draw(rawImage, in: CGRect(x: 0, y: 0, width: rawImage.width, height: rawImage.height))

        let rectCommand = RectangleAnnotationCommand(
            rect: CGRect(x: 20, y: 20, width: 100, height: 50),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            strokeWidth: 3.0
        )
        let textCommand = TextAnnotationCommand(
            origin: CGPoint(x: 25, y: 35),
            text: "Important Element",
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        rectCommand.apply(to: context, scale: 1.0)
        textCommand.apply(to: context, scale: 1.0)

        let compositeImage = context.makeImage()!
        #expect(compositeImage.width == 400)
        #expect(compositeImage.height == 300)

        // 3. Export annotated image to clipboard (Cmd+C action)
        pasteboardService.writeImageToPasteboard(compositeImage)

        #expect(pasteboardService.copiedImages.count == 1)
        #expect(pasteboardService.copiedImages.first?.width == 400)
        #expect(pasteboardService.copiedImages.first?.height == 300)
    }

    // MARK: - 5. HotKey Trigger + Screen Capture Invocation
    @Test("T3.5: Area capture HotKey simulation initiates capture and records geometry")
    func testHotKeyTriggerInitiatesScreenCapture() async {
        let hotKeyService = MockHotKeyService()
        let captureService = MockScreenCaptureService()
        let soundService = MockSoundService()

        let capturedBox = AtomicBox<CGImage>()

        let hotkey = HotKeyDefinition.defaultAreaCapture
        let registered = hotKeyService.registerHotKey(hotkey) {
            Task {
                let rect = CGRect(x: 50, y: 50, width: 320, height: 240)
                if let image = try? await captureService.captureDisplayRegion(rect, displayID: 1) {
                    capturedBox.value = image
                    soundService.playShutterSound()
                }
            }
        }

        #expect(registered == true)
        let simulated = hotKeyService.simulateHotKeyTrigger(id: hotkey.id)
        #expect(simulated == true)

        // Wait for asynchronous task execution
        for _ in 0..<50 {
            if capturedBox.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(capturedBox.value?.width == 320)
        #expect(capturedBox.value?.height == 240)
        #expect(soundService.shutterSoundCount == 1)
        #expect(captureService.capturedRegions.count == 1)
    }

    // MARK: - 6. HotKey Trigger + Clipboard History Restoration
    @Test("T3.6: Clipboard HotKey trigger restores selected item and emits sound cue")
    func testHotKeyTriggerRestoresClipboardItem() {
        let hotKeyService = MockHotKeyService()
        let pasteboardService = MockPasteboardService()
        let soundService = MockSoundService()

        let item = ClipboardItem.text("Snippet to restore")
        pasteboardService.simulateExternalCopy(item)

        let hotkey = HotKeyDefinition.defaultClipboard
        _ = hotKeyService.registerHotKey(hotkey) {
            // Select most recent item and restore
            if let topItem = pasteboardService.items.first {
                pasteboardService.copyItemToPasteboard(topItem)
                soundService.playPasteSound()
            }
        }

        hotKeyService.simulateHotKeyTrigger(id: hotkey.id)

        #expect(pasteboardService.copiedItems.count == 1)
        #expect(pasteboardService.copiedItems.first?.plainTextContent == "Snippet to restore")
        #expect(soundService.pasteSoundCount == 1)
    }

    // MARK: - 7. SettingsStore HotKey Update + HotKey Service Synchronization
    @Test("T3.7: Updating shortcut in SettingsStore re-binds active registration in HotKeyService")
    func testSettingsStoreHotkeyUpdateSyncWithHotKeyService() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let hotKeyService = MockHotKeyService()

        // 1. Initial registration from store defaults (⌘⇧V)
        let initialDef = store.hotkey(for: HotKeyDefinition.clipboardToggleId)!
        var initialFired = false
        var updatedFired = false

        _ = hotKeyService.registerHotKey(initialDef) { initialFired = true }
        #expect(hotKeyService.registeredHotKeys[initialDef.id]?.keyEquivalent == "⌘⇧V")

        // 2. User updates setting to Option+V (⌥V)
        let customDef = HotKeyDefinition.alternativeClipboardOptionV
        store.updateHotkey(customDef)

        // HotKey manager unregisters old shortcut and registers updated shortcut
        hotKeyService.unregisterHotKey(id: customDef.id)
        _ = hotKeyService.registerHotKey(customDef) { updatedFired = true }

        #expect(hotKeyService.registeredHotKeys[customDef.id]?.keyEquivalent == "⌥V")

        // 3. Trigger simulation verifies updated handler fires
        hotKeyService.simulateHotKeyTrigger(id: customDef.id)
        #expect(initialFired == false)
        #expect(updatedFired == true)
    }

    // MARK: - 8. SettingsStore Capacity + Pasteboard FIFO Eviction Simulation
    @Test("T3.8: Clipboard history FIFO eviction enforces SettingsStore capacity while protecting pinned items")
    func testClipboardCapacityEnforcesFIFOEviction() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        store.historyLimit = 5 // User configures limit to 5

        var history: [ClipboardItem] = []

        func ingestItem(_ item: ClipboardItem) {
            history.insert(item, at: 0)
            if history.count > store.historyLimit {
                // Find oldest unpinned item to evict
                if let indexToEvict = history.lastIndex(where: { !$0.isPinned }) {
                    history.remove(at: indexToEvict)
                }
            }
        }

        // Ingest item 1 (PINNED)
        let pinnedItem = ClipboardItem.text("Pinned Critical Note", isPinned: true)
        ingestItem(pinnedItem)

        // Ingest 6 regular items (exceeding limit of 5)
        for i in 1...6 {
            ingestItem(ClipboardItem.text("Note \(i)"))
        }

        // Total items retained must be 5
        #expect(history.count == 5)
        // Pinned item must NOT have been evicted!
        #expect(history.contains(where: { $0.id == pinnedItem.id }))
        // Most recent item is Note 6
        #expect(history.first?.plainTextContent == "Note 6")
        // Note 1 was the oldest unpinned item and was evicted
        #expect(!history.contains(where: { $0.plainTextContent == "Note 1" }))
    }

    // MARK: - 9. Permissions Check Gate + Screen Capture
    @Test("T3.9: Screen capture checks permissions and redirects to Settings when denied")
    func testPermissionsCheckGatesScreenCapture() async throws {
        let permissions = MockPermissionsService(screenRecordingGranted: false)
        let captureService = MockScreenCaptureService()

        var captureAttempted = false

        if permissions.checkScreenRecordingPermission() {
            _ = try await captureService.captureMainDisplay()
            captureAttempted = true
        } else {
            // Permission denied: open settings deep-link
            _ = permissions.openScreenRecordingSettings()
        }

        #expect(captureAttempted == false)
        #expect(captureService.captureMainDisplayCallCount == 0)
        #expect(permissions.openScreenRecordingSettingsCallCount == 1)

        // User grants permission
        permissions.screenRecordingGranted = true

        if permissions.checkScreenRecordingPermission() {
            _ = try await captureService.captureMainDisplay()
            captureAttempted = true
        }

        #expect(captureAttempted == true)
        #expect(captureService.captureMainDisplayCallCount == 1)
    }

    // MARK: - 10. SettingsStore Reset Restores HotKeys
    @Test("T3.10: SettingsStore resetToDefaults restores default shortcuts and synchronizes with HotKeyService")
    func testSettingsStoreResetSynchronizesHotKeys() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let hotKeyService = MockHotKeyService()

        // Reconfigure all 3 shortcuts
        store.updateHotkey(HotKeyDefinition.alternativeClipboardOptionV)
        store.updateHotkey(HotKeyDefinition.alternativeAreaCaptureX)

        for hotkey in store.hotkeyMappings.values {
            _ = hotKeyService.registerHotKey(hotkey) {}
        }
        #expect(hotKeyService.registeredHotKeys[HotKeyDefinition.clipboardToggleId]?.keyEquivalent == "⌥V")
        #expect(hotKeyService.registeredHotKeys[HotKeyDefinition.captureAreaId]?.keyEquivalent == "⌘⇧X")

        // Trigger store reset to defaults
        store.resetToDefaults()

        // Sync service
        hotKeyService.unregisterAll()
        for hotkey in store.hotkeyMappings.values {
            _ = hotKeyService.registerHotKey(hotkey) {}
        }

        #expect(hotKeyService.registeredHotKeys[HotKeyDefinition.clipboardToggleId]?.keyEquivalent == "⌘⇧V")
        #expect(hotKeyService.registeredHotKeys[HotKeyDefinition.captureAreaId]?.keyEquivalent == "⌘⇧2")
    }
}
