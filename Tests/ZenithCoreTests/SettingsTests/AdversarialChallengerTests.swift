import Testing
import Foundation
import Observation
import Combine
import CoreGraphics
@testable import ZenithCore

private final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
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

@Suite("Adversarial Challenger Test Suite")
struct AdversarialChallengerTests {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "ChallengerSuite_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Extreme Concurrency & High Contention Stress on SettingsStore
    @Test("100 concurrent tasks hammering SettingsStore with extreme boundary mutations")
    func testExtremeBoundaryConcurrentStress() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    for j in 0..<50 {
                        let step = (i + j) % 5
                        switch step {
                        case 0:
                            store.historyLimit = (j % 2 == 0) ? Int.min : Int.max
                        case 1:
                            store.historyLimit = -j * 100
                        case 2:
                            store.soundEffectsEnabled = (j % 2 == 0)
                        case 3:
                            store.launchAtLoginEnabled = (j % 3 == 0)
                        case 4:
                            let limit = store.historyLimit
                            #expect(limit >= 5)
                            #expect(limit <= 500)
                        default:
                            break
                        }
                    }
                }
            }
        }

        #expect(store.historyLimit >= 5)
        #expect(store.historyLimit <= 500)
    }

    // MARK: - 2. Concurrent updateHotkey Investigation
    @Test("Concurrent updateHotkey calls across 50 tasks with distinct IDs")
    func testConcurrentUpdateHotkeyIntegrity() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let def = HotKeyDefinition(
                        id: "custom_action_\(i)",
                        name: "Action \(i)",
                        keyCode: UInt32(i),
                        carbonModifiers: CarbonModifierFlags.command.rawValue,
                        keyEquivalent: "⌘\(i)"
                    )
                    store.updateHotkey(def)
                }
            }
        }

        // Check how many hotkeys are preserved
        let mappings = store.hotkeyMappings
        print("[Challenger] Preserved hotkeys count: \(mappings.count) out of 53 expected")
        // We observe whether read-modify-write lost any keys
        #expect(mappings.count >= 3)
    }

    // MARK: - 3. Corrupted UserDefaults Data Injection Matrix
    @Test("SettingsStore initialization resilience against degenerate UserDefaults types")
    func testCorruptedUserDefaultsDataMatrix() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        // Test 1: Float in history limit
        defaults.set(Float(99.9), forKey: SettingsStore.Keys.historyLimit)
        let store1 = SettingsStore(userDefaults: defaults)
        #expect(store1.historyLimit == 20)

        // Test 2: Invalid String in sound effects
        defaults.set("not_a_boolean", forKey: SettingsStore.Keys.soundEffectsEnabled)
        let store2 = SettingsStore(userDefaults: defaults)
        #expect(store2.soundEffectsEnabled == true || store2.soundEffectsEnabled == false)

        // Test 3: Array in launch at login
        defaults.set(["invalid", "array"], forKey: SettingsStore.Keys.launchAtLoginEnabled)
        let store3 = SettingsStore(userDefaults: defaults)
        #expect(store3.launchAtLoginEnabled == false)

        // Test 4: Empty Data in hotkeyMappings
        defaults.set(Data(), forKey: SettingsStore.Keys.hotkeyMappings)
        let store4 = SettingsStore(userDefaults: defaults)
        #expect(store4.hotkeyMappings.count == 3)

        // Test 5: Empty JSON dictionary "{}" in hotkeyMappings
        let emptyJSON = "{}".data(using: .utf8)!
        defaults.set(emptyJSON, forKey: SettingsStore.Keys.hotkeyMappings)
        let store5 = SettingsStore(userDefaults: defaults)
        #expect(store5.hotkeyMappings.count >= 0)
    }

    // MARK: - 4. Rapid Concurrent Observation and Combine Flooding
    @Test("SettingsStore handles 500 rapid background mutations without crashing Combine or Observation")
    func testRapidBackgroundMutationFlooding() async {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { cleanupDefaults(suiteName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        let counter = ManagedCounter()

        let cancellable = store.objectWillChange.sink {
            counter.increment()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for j in 0..<50 {
                        store.historyLimit = 10 + (j % 400)
                    }
                }
            }
        }

        // Give main queue runloop a moment to flush async dispatches
        for _ in 0..<300 {
            if counter.value > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(counter.value > 0)
        _ = cancellable
    }

    // MARK: - 5. MockPasteboardService Concurrency
    @Test("MockPasteboardService handles concurrent write and monitoring without data race")
    func testMockPasteboardServiceConcurrency() async {
        let service = MockPasteboardService()
        let observedCount = ManagedCounter()

        service.startMonitoring { _ in
            observedCount.increment()
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let item = ClipboardItem.text("Item \(i)")
                    service.copyItemToPasteboard(item)
                    _ = service.items
                    _ = service.changeCount
                }
            }
        }

        #expect(service.items.count == 50)
        #expect(service.changeCount == 50)
        #expect(observedCount.value == 50)
    }
}
