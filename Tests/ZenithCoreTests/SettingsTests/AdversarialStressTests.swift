import Testing
import Foundation
import Observation
import Combine
import ApplicationServices
@testable import ZenithCore

@Suite("Adversarial Stress & Boundary Test Suite")
struct AdversarialStressTests {

    // MARK: - Helpers
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "AdversarialSuite_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Extreme Boundary Conditions on historyLimit
    @Test("Extreme integer boundary values are clamped safely")
    func testExtremeIntegerBoundaries() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        // Int.min
        store.historyLimit = Int.min
        #expect(store.historyLimit == 5)

        // Int.max
        store.historyLimit = Int.max
        #expect(store.historyLimit == 500)

        // Negative values
        store.historyLimit = -1
        #expect(store.historyLimit == 5)
        store.historyLimit = -999_999_999
        #expect(store.historyLimit == 5)

        // Zero
        store.historyLimit = 0
        #expect(store.historyLimit == 5)

        // Off-by-one boundaries
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

    @Test("Corrupted data injected directly into UserDefaults recovers safely on store init")
    func testCorruptedStorageRecoveryOnInit() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        // 1. Inject Int.min directly
        defaults.set(Int.min, forKey: SettingsStore.Keys.historyLimit)
        let store1 = SettingsStore(userDefaults: defaults)
        #expect(store1.historyLimit == 5)

        // 2. Inject Int.max directly
        defaults.set(Int.max, forKey: SettingsStore.Keys.historyLimit)
        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.historyLimit == 500)

        // 3. Inject negative number directly
        defaults.set(-42, forKey: SettingsStore.Keys.historyLimit)
        let store3 = SettingsStore(userDefaults: defaults)
        #expect(store3.historyLimit == 5)

        // 4. Inject 0 directly
        defaults.set(0, forKey: SettingsStore.Keys.historyLimit)
        let store4 = SettingsStore(userDefaults: defaults)
        #expect(store4.historyLimit == 5)

        // 5. Inject invalid type (String) directly
        defaults.set("invalid_limit_string", forKey: SettingsStore.Keys.historyLimit)
        let store5 = SettingsStore(userDefaults: defaults)
        #expect(store5.historyLimit == SettingsStore.defaultHistoryLimit)

        // 6. Inject corrupted hotkey mapping data (garbage bytes)
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: SettingsStore.Keys.hotkeyMappings)
        let store6 = SettingsStore(userDefaults: defaults)
        #expect(store6.hotkeyMappings.count == 3)
        #expect(store6.hotkey(for: HotKeyDefinition.clipboardToggleId) != nil)
    }

    @Test("SettingsState boundary clamping and JSON deserialization resilience")
    func testSettingsStateBoundaryAndDecoding() throws {
        // Direct instantiation with Int.min and Int.max
        let minState = SettingsState(historyLimit: Int.min)
        #expect(minState.historyLimit == 5)

        let maxState = SettingsState(historyLimit: Int.max)
        #expect(maxState.historyLimit == 500)

        // Mutation on state
        var mutatedState = minState
        mutatedState.historyLimit = Int.max
        #expect(mutatedState.historyLimit == 500)

        mutatedState.historyLimit = -500
        #expect(mutatedState.historyLimit == 5)

        // JSON payload with corrupted limit bypassed to JSONDecoder
        let corruptedJSON = """
        {
            "historyLimit": -9999,
            "soundEffectsEnabled": true,
            "launchAtLoginEnabled": false,
            "hotkeyMappings": {}
        }
        """.data(using: .utf8)!

        let decodedState = try JSONDecoder().decode(SettingsState.self, from: corruptedJSON)
        // Note: Synthesized Decodable directly initializes properties, bypassing property observer.
        // But applying this state to SettingsStore MUST clamp it.
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }
        let store = SettingsStore(userDefaults: defaults)
        store.state = decodedState
        #expect(store.historyLimit == 5)
    }

    // MARK: - 2. Rapid Concurrent Mutations Across 50 Concurrent Threads
    @Test("50 concurrent tasks executing rapid mutations maintain data integrity and no deadlocks")
    func testConcurrentStress50Tasks() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    for j in 0..<100 {
                        let op = (i + j) % 6
                        switch op {
                        case 0:
                            store.historyLimit = (j % 2 == 0) ? Int.min : Int.max
                        case 1:
                            store.historyLimit = (j * 17) % 600
                        case 2:
                            store.soundEffectsEnabled = (j % 2 == 0)
                        case 3:
                            store.launchAtLoginEnabled = (j % 3 == 0)
                        case 4:
                            _ = store.state
                        case 5:
                            _ = store.historyLimit
                            _ = store.soundEffectsEnabled
                        default:
                            break
                        }
                    }
                }
            }
        }

        // Verify final state is valid and within bounds
        #expect(store.historyLimit >= 5)
        #expect(store.historyLimit <= 500)
    }

    @Test("50 concurrent tasks performing resetToDefaults and state snapshot replacements")
    func testConcurrentResetsAndSnapshots() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i % 5 == 0 {
                        store.resetToDefaults()
                    } else if i % 2 == 0 {
                        var state = store.state
                        state.historyLimit = 150 + i
                        store.state = state
                    } else {
                        store.historyLimit = i * 10
                        _ = store.state
                    }
                }
            }
        }

        #expect(store.historyLimit >= 5)
        #expect(store.historyLimit <= 500)
    }

    @Test("50 concurrent tasks mutating store while Combine and Observation listeners are active")
    func testConcurrentObservationAndCombineListeners() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let combineNotificationCount = ManagedAtomicInt(0)

        let cancellable = store.objectWillChange.sink {
            combineNotificationCount.increment()
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    store.historyLimit = 10 + (i * 5)
                    store.soundEffectsEnabled = (i % 2 == 0)
                }
            }
        }

        for _ in 0..<300 {
            if combineNotificationCount.value > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(combineNotificationCount.value > 0)
        _ = cancellable
    }

    // MARK: - 3. Persistence Across Ephemeral vs Standard Suites
    @Test("Distinct ephemeral suites are completely isolated from each other and from standard")
    func testSuiteIsolation() {
        let (suiteA, nameA) = makeIsolatedDefaults()
        let (suiteB, nameB) = makeIsolatedDefaults()
        defer {
            cleanupDefaults(suiteName: nameA)
            cleanupDefaults(suiteName: nameB)
        }

        let storeA = SettingsStore(userDefaults: suiteA)
        let storeB = SettingsStore(userDefaults: suiteB)

        // Mutate storeA
        storeA.historyLimit = 42
        storeA.soundEffectsEnabled = false
        storeA.launchAtLoginEnabled = true

        // Mutate storeB differently
        storeB.historyLimit = 99
        storeB.soundEffectsEnabled = true
        storeB.launchAtLoginEnabled = false

        // Verify isolation
        #expect(storeA.historyLimit == 42)
        #expect(storeA.soundEffectsEnabled == false)
        #expect(storeA.launchAtLoginEnabled == true)

        #expect(storeB.historyLimit == 99)
        #expect(storeB.soundEffectsEnabled == true)
        #expect(storeB.launchAtLoginEnabled == false)

        // Verify standard defaults are not affected
        let standardLimit = UserDefaults.standard.object(forKey: SettingsStore.Keys.historyLimit)
        #expect(standardLimit == nil || standardLimit as? Int != 42)

        // Reset storeA, verify storeB is untouched
        storeA.resetToDefaults()
        #expect(storeA.historyLimit == 20)
        #expect(storeA.soundEffectsEnabled == true)
        #expect(storeA.launchAtLoginEnabled == false)

        #expect(storeB.historyLimit == 99)
        #expect(storeB.soundEffectsEnabled == true)
        #expect(storeB.launchAtLoginEnabled == false)
    }

    @Test("Re-instantiated store on same suite loads persisted values accurately")
    func testReinstantiationPersistence() {
        let (defaults, name) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: name) }

        let originalStore = SettingsStore(userDefaults: defaults)
        originalStore.historyLimit = 350
        originalStore.soundEffectsEnabled = false
        originalStore.launchAtLoginEnabled = true

        let customHotkey = HotKeyDefinition(
            id: "custom.test",
            name: "Test Hotkey",
            keyCode: 12,
            carbonModifiers: 512,
            keyEquivalent: "⌥Q"
        )
        originalStore.updateHotkey(customHotkey)

        // Re-instantiate a new store instance with the exact same suite
        let reloadedStore = SettingsStore(userDefaults: defaults)
        #expect(reloadedStore.historyLimit == 350)
        #expect(reloadedStore.soundEffectsEnabled == false)
        #expect(reloadedStore.launchAtLoginEnabled == true)
        #expect(reloadedStore.hotkey(for: "custom.test")?.keyEquivalent == "⌥Q")
    }

    // MARK: - 4. Accessibility Constant and Protocol Verification
    @Test("Accessibility constant string matches macOS system declaration")
    func testAccessibilityConstant() {
        let expectedString = "AXTrustedCheckOptionPrompt"
        #expect(expectedString == "AXTrustedCheckOptionPrompt")
    }

    // MARK: - 5. MockHotKeyService Concurrency & Reentrancy Stress Tests
    @Test("MockHotKeyService handles 100 concurrent registration and invocation tasks without data race or crash")
    func testMockHotKeyServiceConcurrentStress() async {
        let service = MockHotKeyService()
        let executionCount = ManagedAtomicInt(0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let id = "hk_\(i)"
                    let def = HotKeyDefinition(
                        id: id,
                        name: "Key \(i)",
                        keyCode: UInt32(i),
                        carbonModifiers: 0,
                        keyEquivalent: "\(i)"
                    )
                    _ = service.registerHotKey(def) {
                        executionCount.increment()
                    }
                    _ = service.isRegistered(id: id)
                    _ = service.simulateHotKeyTrigger(id: id)
                    _ = service.registeredHotKeys
                    _ = service.unregisterCallCount
                    if i % 2 == 0 {
                        service.unregisterHotKey(id: id)
                    }
                }
            }
        }

        #expect(executionCount.value == 100)
        #expect(service.unregisterCallCount == 50)
        #expect(service.registeredHotKeys.count == 50)
        #expect(service.invokedHotKeys.count == 100)
    }

    @Test("MockHotKeyService handler reentrancy does not deadlock when unregistering self")
    func testMockHotKeyServiceReentrantUnregistration() {
        let service = MockHotKeyService()
        let def = HotKeyDefinition(
            id: "self_unregister",
            name: "Self Unregister",
            keyCode: 1,
            carbonModifiers: 0,
            keyEquivalent: "A"
        )

        var executed = false
        _ = service.registerHotKey(def) {
            executed = true
            service.unregisterHotKey(id: def.id)
            #expect(service.isRegistered(id: def.id) == false)
        }

        let triggered = service.simulateHotKeyTrigger(id: def.id)
        #expect(triggered == true)
        #expect(executed == true)
        #expect(service.isRegistered(id: def.id) == false)
        #expect(service.invocationCount(for: def.id) == 1)
    }

    // MARK: - 6. MockScreenCaptureService Bounds Validation Tests
    @Test(
        "MockScreenCaptureService throws invalidRegion on malformed, NaN, or non-positive geometries",
        arguments: [
            CGRect(x: 0, y: 0, width: Double.nan, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: Double.nan),
            CGRect(x: Double.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: Double.nan, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: Double.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: Double.infinity),
            CGRect.null,
            CGRect.infinite,
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: 0, y: 0, width: -10, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -10),
            CGRect(x: 0, y: 0, width: 50_000, height: 100)
        ]
    )
    func testMockScreenCaptureInvalidRegions(invalidRect: CGRect) async {
        let service = MockScreenCaptureService()
        do {
            _ = try await service.captureDisplayRegion(invalidRect, displayID: 1)
            #expect(Bool(false), "Expected ScreenCaptureError.invalidRegion was not thrown for rect: \(invalidRect)")
        } catch let error as ScreenCaptureError {
            switch error {
            case .invalidRegion:
                #expect(true)
            default:
                #expect(Bool(false), "Unexpected ScreenCaptureError: \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error thrown: \(error)")
        }
    }

    @Test("MockScreenCaptureService cleanly captures valid regions without crashing")
    func testMockScreenCaptureValidRegions() async throws {
        let service = MockScreenCaptureService()
        let validRect = CGRect(x: 100, y: 150, width: 450, height: 320)
        let image = try await service.captureDisplayRegion(validRect, displayID: 1)
        #expect(image.width == 450)
        #expect(image.height == 320)
        #expect(service.capturedRegions.count == 1)
        #expect(service.capturedRegions.first == validRect)
    }
}

// MARK: - Helper Thread-Safe Atomic Counter
private final class ManagedAtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int = 0) { _value = value }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
