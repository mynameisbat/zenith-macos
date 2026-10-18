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

@Suite("Tier 4 - Real-World Application Scenarios Test Suite")
struct Tier4ApplicationScenarioTests {

    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suiteName = "Tier4Suite_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeTestBitmapContext(width: Int = 1280, height: Int = 720) -> CGContext {
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
    // SCENARIO 1: Bug Reporting Screenshot Workflow (R2, R3, R4)
    // =========================================================================
    @Test("T4.1: Bug reporting workflow: hotkey trigger -> area capture -> shutter sound -> vector annotation -> Cmd+C pasteboard export")
    func testBugReportingScreenshotWorkflow() async throws {
        let hotKeyService = MockHotKeyService()
        let captureService = MockScreenCaptureService()
        let soundService = MockSoundService()
        let pasteboardService = MockPasteboardService()

        let editorBaseImageBox = AtomicBox<CGImage>()
        var editorDismissed = false

        // Step 1: User registers area capture shortcut
        let areaHotkey = HotKeyDefinition.defaultAreaCapture
        let registered = hotKeyService.registerHotKey(areaHotkey) {
            Task {
                let captureRect = CGRect(x: 100, y: 100, width: 1280, height: 720)
                if let image = try? await captureService.captureDisplayRegion(captureRect, displayID: 1) {
                    editorBaseImageBox.value = image
                    soundService.playShutterSound()
                }
            }
        }
        #expect(registered == true)

        // Step 2: User triggers global hotkey
        hotKeyService.simulateHotKeyTrigger(id: areaHotkey.id)

        // Wait for async capture
        for _ in 0..<50 {
            if editorBaseImageBox.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(editorBaseImageBox.value != nil)
        #expect(soundService.shutterSoundCount == 1)
        #expect(soundService.playedSounds == [.shutter])

        // Step 3: User annotates screenshot in editor
        guard let base = editorBaseImageBox.value else { return }
        let context = makeTestBitmapContext(width: base.width, height: base.height)
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        let penCommand = PenAnnotationCommand(
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150), CGPoint(x: 300, y: 100)],
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            strokeWidth: 4.0
        )
        let arrowCommand = ArrowAnnotationCommand(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 100, y: 100),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let blurCommand = BlurAnnotationCommand(
            rect: CGRect(x: 400, y: 200, width: 250, height: 60),
            pixelSize: 16.0
        )
        let textCommand = TextAnnotationCommand(
            origin: CGPoint(x: 100, y: 80),
            text: "Fix Needed Here!",
            color: CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        )

        penCommand.apply(to: context, scale: 1.0)
        arrowCommand.apply(to: context, scale: 1.0)
        blurCommand.apply(to: context, scale: 1.0)
        textCommand.apply(to: context, scale: 1.0)

        let composite = context.makeImage()!
        #expect(composite.width == 1280)
        #expect(composite.height == 720)

        // Step 4: User presses Cmd+C to copy annotated image to pasteboard and close editor
        pasteboardService.writeImageToPasteboard(composite)
        editorDismissed = true

        #expect(editorDismissed == true)
        #expect(pasteboardService.copiedImages.count == 1)
        #expect(pasteboardService.copiedImages.first?.width == 1280)
        #expect(pasteboardService.copiedImages.first?.height == 720)
    }

    // =========================================================================
    // SCENARIO 2: Developer Clipboard Session with Eviction & Search (R1, R4, R6)
    // =========================================================================
    @Test("T4.2: Developer coding session: 15 copies with limit 10, pinned item protection, search, and restore")
    func testDeveloperClipboardSessionWithEvictionAndSearch() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        store.historyLimit = 10

        let soundService = MockSoundService()
        let pasteboardService = MockPasteboardService()

        var history: [ClipboardItem] = []

        func ingest(_ item: ClipboardItem) {
            history.insert(item, at: 0)
            if history.count > store.historyLimit {
                if let evictIndex = history.lastIndex(where: { !$0.isPinned }) {
                    history.remove(at: evictIndex)
                }
            }
            soundService.playNewCopySound()
        }

        // 1. Ingest normal items
        for i in 1...3 {
            ingest(ClipboardItem.text("Code snippet \(i)"))
        }

        // 2. Ingest critical DB secret and PIN it
        let pinnedItem = ClipboardItem.text("postgres://user:secret@localhost:5432/db", isPinned: true)
        ingest(pinnedItem)

        // 3. Ingest 12 more snippets (total 16 items ingested, limit is 10)
        for i in 4...15 {
            ingest(ClipboardItem.text("func processRequest_\(i)() -> Bool"))
        }

        // 4. Verify history size adheres to store.historyLimit
        #expect(history.count == 10)
        #expect(soundService.newCopySoundCount == 16)

        // 5. Verify pinned item survived eviction
        #expect(history.contains(where: { $0.id == pinnedItem.id }))

        // 6. Developer searches for query "processRequest_14"
        let searchQuery = "processRequest_14"
        let searchResults = history.filter { item in
            item.plainTextContent?.localizedCaseInsensitiveContains(searchQuery) ?? false
        }
        #expect(searchResults.count == 1)
        let selectedItem = searchResults.first!

        // 7. Developer restores item via Enter
        pasteboardService.copyItemToPasteboard(selectedItem)
        soundService.playPasteSound()

        #expect(pasteboardService.copiedItems.first == selectedItem)
        #expect(soundService.pasteSoundCount == 1)
        #expect(soundService.playedSounds.last == .paste)
    }

    // =========================================================================
    // SCENARIO 3: Global HotKey Customization & Rebinding Lifecycle (R1, R6)
    // =========================================================================
    @Test("T4.3: HotKey customization lifecycle: inspect defaults -> remap shortcut -> persist -> trigger -> reset to defaults")
    func testHotKeyCustomizationAndRebindingLifecycle() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let hotKeyService = MockHotKeyService()

        // 1. App starts with defaults (⌘⇧V)
        let initialClipboardDef = store.hotkey(for: HotKeyDefinition.clipboardToggleId)!
        #expect(initialClipboardDef.keyEquivalent == "⌘⇧V")

        var clipboardPanelOpenCount = 0
        _ = hotKeyService.registerHotKey(initialClipboardDef) {
            clipboardPanelOpenCount += 1
        }

        // Trigger default shortcut
        hotKeyService.simulateHotKeyTrigger(id: initialClipboardDef.id)
        #expect(clipboardPanelOpenCount == 1)

        // 2. User rebinds shortcut to Option+V (⌥V)
        let customDef = HotKeyDefinition.alternativeClipboardOptionV
        store.updateHotkey(customDef)

        // Re-sync service
        hotKeyService.unregisterHotKey(id: initialClipboardDef.id)
        var customPanelOpenCount = 0
        _ = hotKeyService.registerHotKey(customDef) {
            customPanelOpenCount += 1
        }

        #expect(hotKeyService.registeredHotKeys[customDef.id]?.keyEquivalent == "⌥V")

        // 3. User triggers new Option+V shortcut
        hotKeyService.simulateHotKeyTrigger(id: customDef.id)
        #expect(customPanelOpenCount == 1)
        #expect(clipboardPanelOpenCount == 1) // Old handler did not fire

        // 4. Persistence check: new store instance retains custom shortcut
        let reloadedStore = SettingsStore(userDefaults: defaults)
        #expect(reloadedStore.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌥V")

        // 5. User clicks Reset to Defaults
        reloadedStore.resetToDefaults()
        #expect(reloadedStore.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌘⇧V")
    }

    // =========================================================================
    // SCENARIO 4: First-Time Onboarding & Permissions Flow (R2, R6)
    // =========================================================================
    @Test("T4.4: First launch onboarding: permission denied -> guidance URL opened -> user grants access -> capture succeeds")
    func testFirstTimeOnboardingAndPermissionGuidanceFlow() async throws {
        let permissions = MockPermissionsService(screenRecordingGranted: false, accessibilityGranted: false)
        let captureService = MockScreenCaptureService()

        // 1. Initial attempt fails because permission is denied
        #expect(permissions.checkScreenRecordingPermission() == false)
        var guidanceShown = false

        if !permissions.checkScreenRecordingPermission() {
            guidanceShown = permissions.openScreenRecordingSettings()
        }

        #expect(guidanceShown == true)
        #expect(permissions.openScreenRecordingSettingsCallCount == 1)

        // 2. User grants Screen Recording permission in System Settings
        permissions.screenRecordingGranted = true
        #expect(permissions.checkScreenRecordingPermission() == true)

        // 3. Capture retry succeeds immediately
        let captured = try await captureService.captureMainDisplay()
        #expect(captured.width == 1920)
        #expect(captured.height == 1080)
        #expect(captureService.captureMainDisplayCallCount == 1)
    }

    // =========================================================================
    // SCENARIO 5: Silent Meeting / Do Not Disturb Mode Workflow (R4, R6)
    // =========================================================================
    @Test("T4.5: Meeting mode workflow: normal audio cues -> user enables mute -> silent operations -> un-mute resumes sound")
    func testSilentMeetingModeAudioSuppressionWorkflow() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suite) }

        let store = SettingsStore(userDefaults: defaults)
        let soundService = MockSoundService(isMuted: !store.soundEffectsEnabled)
        let pasteboardService = MockPasteboardService()

        // Phase 1: Regular office mode (audible feedback)
        pasteboardService.copyItemToPasteboard(ClipboardItem.text("Office note"))
        soundService.playNewCopySound()
        soundService.playShutterSound()

        #expect(soundService.newCopySoundCount == 1)
        #expect(soundService.shutterSoundCount == 1)

        // Phase 2: User joins Zoom meeting and toggles Mute in Settings
        store.soundEffectsEnabled = false
        soundService.isMuted = !store.soundEffectsEnabled
        #expect(soundService.isMuted == true)

        // During meeting, user takes 3 screenshots and copies 4 items
        for _ in 0..<3 { soundService.playShutterSound() }
        for _ in 0..<4 { soundService.playNewCopySound() }

        // Counts remain unchanged due to mute suppression!
        #expect(soundService.shutterSoundCount == 1)
        #expect(soundService.newCopySoundCount == 1)

        // Phase 3: Meeting ends, user restores audio in Settings
        store.soundEffectsEnabled = true
        soundService.isMuted = !store.soundEffectsEnabled
        #expect(soundService.isMuted == false)

        soundService.playPasteSound()
        #expect(soundService.pasteSoundCount == 1)
        #expect(soundService.playedSounds.last == .paste)
    }

    // =========================================================================
    // SCENARIO 6: Multi-Format Media Pipeline with Mixed Content Ingestion (R1, R3)
    // =========================================================================
    @Test("T4.6: Multi-format media pipeline: plain text, rich text RTF, and bitmap image ingestion and retrieval")
    func testMultiFormatMediaClipboardPipeline() {
        let pasteboardService = MockPasteboardService()

        // 1. Plain text item
        let plainItem = ClipboardItem.text("https://developer.apple.com/macos")
        pasteboardService.copyItemToPasteboard(plainItem)

        // 2. Rich text item
        let rtfData = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs28 macOS Sonoma}".data(using: .utf8)!
        let richItem = ClipboardItem.richText(rtfData: rtfData, plainText: "macOS Sonoma")
        pasteboardService.copyItemToPasteboard(richItem)

        // 3. Image item
        let dummyImageData = Data(repeating: 0x88, count: 2048)
        let imageItem = ClipboardItem.image(data: dummyImageData, width: 800, height: 600)
        pasteboardService.copyItemToPasteboard(imageItem)

        // Verify ingestion order (LIFO: newest item at index 0)
        let items = pasteboardService.items
        #expect(items.count == 3)

        // Image item verification
        #expect(items[0].itemType == .image)
        #expect(items[0].previewText == "Image (800 × 600)")
        #expect(items[0].byteSize == 2048)
        #expect(items[0].rawImageData == dummyImageData)
        #expect(items[0].plainTextContent == nil)

        // Rich text item verification
        #expect(items[1].itemType == .richText)
        #expect(items[1].plainTextContent == "macOS Sonoma")
        #expect(items[1].byteSize == rtfData.count)

        // Plain text item verification
        #expect(items[2].itemType == .plainText)
        #expect(items[2].plainTextContent == "https://developer.apple.com/macos")
    }
}
