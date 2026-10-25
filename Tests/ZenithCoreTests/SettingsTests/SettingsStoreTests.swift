import Testing
import Foundation
import Observation
import Combine
@testable import ZenithCore

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool = false) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

private final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int = 0) { _value = value }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

@Suite("SettingsStore & Permissions Test Suite")
struct SettingsStoreTests {

    // MARK: - Helper to Generate Isolated Ephemeral UserDefaults
    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suiteName = "SettingsStoreTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Test 1: Default Values
    @Test("SettingsStore initializes with safe default values")
    func testDefaultValues() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.historyLimit == 20)
        #expect(store.soundEffectsEnabled == true)
        #expect(store.launchAtLoginEnabled == false)
        #expect(store.launchAtLogin == false)

        let mappings = store.hotkeyMappings
        #expect(mappings.count == 3)
        #expect(mappings[HotKeyDefinition.clipboardToggleId]?.keyEquivalent == "⌘⇧V")
        #expect(mappings[HotKeyDefinition.captureAreaId]?.keyEquivalent == "⌘⇧2")
        #expect(mappings[HotKeyDefinition.captureFullscreenId]?.keyEquivalent == "⌘⇧1")
    }

    // MARK: - Test 2: History Capacity Boundary Clamping
    @Test(
        "History capacity strictly clamps to range [5, 500] across boundary edge cases",
        arguments: [
            (-100, 5),
            (-5, 5),
            (-1, 5),
            (0, 5),
            (1, 5),
            (4, 5),
            (5, 5),
            (6, 6),
            (20, 20),
            (100, 100),
            (250, 250),
            (499, 499),
            (500, 500),
            (501, 500),
            (1000, 500),
            (99999, 500)
        ]
    )
    func testCapacityClamping(input: Int, expected: Int) {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        store.historyLimit = input
        #expect(store.historyLimit == expected)
    }

    // MARK: - Test 3: History Limit Persistence Across Instances
    @Test("History limit persists across distinct store instances on the same suite")
    func testHistoryLimitPersistence() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)
        store1.historyLimit = 75
        #expect(store1.historyLimit == 75)

        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.historyLimit == 75)
    }

    // MARK: - Test 4: Sound Effects Persistence & Mute Toggling
    @Test("Sound effects enabled persists across distinct store instances")
    func testSoundEffectsPersistence() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)
        #expect(store1.soundEffectsEnabled == true)

        store1.soundEffectsEnabled = false
        #expect(store1.soundEffectsEnabled == false)

        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.soundEffectsEnabled == false)

        store2.soundEffectsEnabled = true
        let store3 = SettingsStore(userDefaults: defaults)
        #expect(store3.soundEffectsEnabled == true)
    }

    // MARK: - Test 5: Launch At Login Persistence
    @Test("Launch at login setting persists across store instances")
    func testLaunchAtLoginPersistence() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)
        #expect(store1.launchAtLoginEnabled == false)

        store1.launchAtLoginEnabled = true
        #expect(store1.launchAtLogin == true)

        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.launchAtLoginEnabled == true)
    }

    // MARK: - Test 6: HotKey Mappings Customization and Persistence
    @Test("Custom hotkey definitions update and persist accurately")
    func testHotkeyMappingsPersistence() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)
        let customClipboard = HotKeyDefinition(
            id: HotKeyDefinition.clipboardToggleId,
            name: "Custom Shortcut",
            keyCode: 9, // 'V'
            carbonModifiers: CarbonModifierFlags.option.rawValue,
            keyEquivalent: "⌥V"
        )

        store1.updateHotkey(customClipboard)
        #expect(store1.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌥V")

        let store2 = SettingsStore(userDefaults: defaults)
        let loaded = store2.hotkey(for: HotKeyDefinition.clipboardToggleId)
        #expect(loaded != nil)
        #expect(loaded?.keyEquivalent == "⌥V")
        #expect(loaded?.carbonModifiers == CarbonModifierFlags.option.rawValue)
    }

    // MARK: - Test 7: Reset to Defaults
    @Test("resetToDefaults() restores all values in-memory and on disk")
    func testResetToDefaults() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)

        // Mutate every setting away from defaults
        store1.historyLimit = 150
        store1.soundEffectsEnabled = false
        store1.launchAtLoginEnabled = true
        store1.updateHotkey(HotKeyDefinition.alternativeClipboardOptionV)

        #expect(store1.historyLimit == 150)
        #expect(store1.soundEffectsEnabled == false)
        #expect(store1.launchAtLoginEnabled == true)
        #expect(store1.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌥V")

        // Trigger reset
        store1.resetToDefaults()

        #expect(store1.historyLimit == 20)
        #expect(store1.soundEffectsEnabled == true)
        #expect(store1.launchAtLoginEnabled == false)
        #expect(store1.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌘⇧V")

        // Verify fresh reload from disk also reflects defaults
        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.historyLimit == 20)
        #expect(store2.soundEffectsEnabled == true)
        #expect(store2.launchAtLoginEnabled == false)
        #expect(store2.hotkey(for: HotKeyDefinition.clipboardToggleId)?.keyEquivalent == "⌘⇧V")
    }

    // MARK: - Test 8: SettingsState Snapshot Roundtrip
    @Test("SettingsState snapshot captures and restores state atomically")
    func testStateSnapshotRoundTrip() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        store.historyLimit = 120
        store.soundEffectsEnabled = false
        store.launchAtLoginEnabled = true

        let snapshot = store.state
        #expect(snapshot.historyLimit == 120)
        #expect(snapshot.soundEffectsEnabled == false)
        #expect(snapshot.launchAtLoginEnabled == true)

        var modifiedSnapshot = snapshot
        modifiedSnapshot.historyLimit = 240
        modifiedSnapshot.soundEffectsEnabled = true

        store.state = modifiedSnapshot
        #expect(store.historyLimit == 240)
        #expect(store.soundEffectsEnabled == true)
    }

    // MARK: - Test 9: Swift Observation Tracking
    @Test("Swift Observation tracks property access and changes")
    func testObservationTracking() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let observedLimitChanged = AtomicBool(false)

        withObservationTracking {
            _ = store.historyLimit
        } onChange: {
            observedLimitChanged.value = true
        }

        store.historyLimit = 45
        #expect(observedLimitChanged.value == true)
        #expect(store.historyLimit == 45)
    }

    // MARK: - Test 10: ObservableObject objectWillChange Publisher
    @Test("ObservableObject objectWillChange emits on mutation")
    @MainActor
    func testObservableObjectPublisher() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let changeCount = AtomicInt(0)

        let cancellable = store.objectWillChange.sink {
            changeCount.increment()
        }

        store.soundEffectsEnabled = false
        store.historyLimit = 90

        #expect(changeCount.value >= 2)
        _ = cancellable // retain cancellable
    }

    // MARK: - Test 11: Thread Safety Under Concurrent Load
    @Test("SettingsStore handles concurrent multithreaded mutations safely")
    func testConcurrentAccessStress() async {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    store.historyLimit = i * 15
                    _ = store.historyLimit
                    store.soundEffectsEnabled = (i % 2 == 0)
                    _ = store.soundEffectsEnabled
                    _ = store.state
                }
            }
        }

        #expect(store.historyLimit >= 5)
        #expect(store.historyLimit <= 500)
    }

    // MARK: - Test 12: MockSoundService Conformance & Sync
    @Test("MockSoundService syncs with SettingsStore soundEffectsEnabled state")
    func testMockSoundServiceSync() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let mockSound = MockSoundService()

        // When sound effects enabled, sound service is not muted
        mockSound.isMuted = !store.soundEffectsEnabled
        #expect(mockSound.isMuted == false)

        mockSound.playNewCopySound()
        #expect(mockSound.playedSounds.count == 1)
        #expect(mockSound.playedSounds.first == .newCopy)

        // When user mutes sound effects
        store.soundEffectsEnabled = false
        mockSound.isMuted = !store.soundEffectsEnabled
        #expect(mockSound.isMuted == true)

        mockSound.playPasteSound()
        // Sound was suppressed due to mute!
        #expect(mockSound.playedSounds.count == 1)
    }

    // MARK: - Test 13: MockHotKeyService Registration
    @Test("MockHotKeyService successfully registers hotkeys from SettingsStore")
    func testMockHotKeyServiceRegistration() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let mockHotKey = MockHotKeyService()

        let fired = AtomicBool(false)
        let clipboardDef = store.hotkey(for: HotKeyDefinition.clipboardToggleId)!
        let success = mockHotKey.registerHotKey(clipboardDef) {
            fired.value = true
        }

        #expect(success == true)
        #expect(mockHotKey.registeredHotKeys[clipboardDef.id]?.keyEquivalent == "⌘⇧V")

        mockHotKey.simulateTrigger(hotKeyId: clipboardDef.id)
        #expect(fired.value == true)
    }

    // MARK: - Test 14: MockPermissionsService Headless Verification
    @Test("MockPermissionsService simulates permissions states without OS dialogs")
    func testMockPermissionsService() {
        let mockPermissions = MockPermissionsService(screenRecordingGranted: false, accessibilityGranted: false)

        #expect(mockPermissions.checkScreenRecordingPermission() == false)
        #expect(mockPermissions.checkAccessibilityPermission() == false)

        #expect(mockPermissions.openScreenRecordingSettings() == true)
        #expect(mockPermissions.openScreenRecordingSettingsCallCount == 1)

        mockPermissions.screenRecordingGranted = true
        #expect(mockPermissions.checkScreenRecordingPermission() == true)
    }

    // MARK: - Test 15: SystemPermissions URLs Integrity
    @Test("SystemPermissions URL constants are valid system preferences schemes")
    func testSystemPermissionsURLs() {
        let screenURL = SystemPermissions.screenRecordingSettingsURL
        let accessURL = SystemPermissions.accessibilitySettingsURL

        #expect(screenURL.scheme == "x-apple.systempreferences")
        #expect(screenURL.absoluteString.contains("Privacy_ScreenCapture"))

        #expect(accessURL.scheme == "x-apple.systempreferences")
        #expect(accessURL.absoluteString.contains("Privacy_Accessibility"))
    }

    // MARK: - Test 16: Background Thread Notification Safety
    @Test("SettingsStore dispatches objectWillChange on main thread when mutated from background thread")
    func testBackgroundThreadNotificationDispatchesOnMain() async {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let notificationDeliveredOnMain = AtomicBool(false)
        let deliveryCount = AtomicInt(0)

        let cancellable = store.objectWillChange.sink {
            if Thread.isMainThread {
                notificationDeliveredOnMain.value = true
            }
            deliveryCount.increment()
        }

        // Trigger mutation strictly from a detached background task
        await Task.detached {
            store.soundEffectsEnabled = false
            store.historyLimit = 120
        }.value

        // Allow main queue loop to deliver async notifications under heavy parallel test stress
        for _ in 0..<300 {
            if deliveryCount.value >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        #expect(deliveryCount.value >= 2)
        #expect(notificationDeliveredOnMain.value == true)
        _ = cancellable
    }

    // MARK: - Test 15: Sound Volume Clamping and Persistence
    @Test("Sound volume persists and clamps between 0.0 and 1.0")
    func testSoundVolumeClampingAndPersistence() {
        let (defaults, suiteName) = makeEphemeralDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store1 = SettingsStore(userDefaults: defaults)
        #expect(store1.soundVolume == 0.8)

        // Clamping upper bound
        store1.soundVolume = 1.5
        #expect(store1.soundVolume == 1.0)

        // Clamping lower bound
        store1.soundVolume = -0.2
        #expect(store1.soundVolume == 0.0)

        // Valid level
        store1.soundVolume = 0.65
        #expect(abs(store1.soundVolume - 0.65) < 0.001)

        // Persistence across store instance
        let store2 = SettingsStore(userDefaults: defaults)
        #expect(abs(store2.soundVolume - 0.65) < 0.001)

        // Reset to default
        store2.resetToDefaults()
        #expect(store2.soundVolume == 0.8)
    }
}
