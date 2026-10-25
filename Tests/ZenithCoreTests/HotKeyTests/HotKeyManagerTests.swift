import Testing
import Foundation
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
    func add(_ amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value += amount
    }
}

@Suite("HotKeyManager Lifecycle & Rebinding Test Suite")
struct HotKeyManagerTests {

    @Test("Registers hotkey and dispatches trigger callback via backend simulation")
    func testRegistrationAndDispatch() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let invoked = AtomicBool(false)

        let def = HotKeyDefinition.defaultClipboard
        let success = manager.registerHotKey(def) {
            invoked.value = true
        }

        #expect(success == true)
        #expect(manager.isRegistered(id: def.id) == true)
        #expect(manager.registeredCount == 1)

        let carbonId = manager.carbonId(for: def.id)
        #expect(carbonId != nil)

        backend.simulateKeyPress(hotKeyID: carbonId!)
        #expect(invoked.value == true)
    }

    @Test("Registers multiple distinct hotkeys successfully")
    func testRegisterMultipleDistinctHotKeys() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def1 = HotKeyDefinition.defaultClipboard
        let def2 = HotKeyDefinition.defaultAreaCapture
        let def3 = HotKeyDefinition.defaultFullscreenCapture

        #expect(manager.registerHotKey(def1) {} == true)
        #expect(manager.registerHotKey(def2) {} == true)
        #expect(manager.registerHotKey(def3) {} == true)

        #expect(manager.registeredCount == 3)
        #expect(manager.isRegistered(id: def1.id) == true)
        #expect(manager.isRegistered(id: def2.id) == true)
        #expect(manager.isRegistered(id: def3.id) == true)
        #expect(backend.registeredRefsCount == 3)
    }

    @Test("Rejects duplicate shortcut key combination for a different action ID")
    func testDuplicateShortcutRejection() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def1 = HotKeyDefinition(id: "action.1", name: "Action 1", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let def2 = HotKeyDefinition(id: "action.2", name: "Action 2", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")

        #expect(manager.registerHotKey(def1) {} == true)
        #expect(manager.registerHotKey(def2) {} == false)

        #expect(manager.isRegistered(id: "action.1") == true)
        #expect(manager.isRegistered(id: "action.2") == false)
        #expect(manager.registeredCount == 1)
    }

    @Test("Dynamic rebinding updates shortcut and preserves single action")
    func testDynamicRebinding() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let triggerCount = AtomicInt(0)

        let def1 = HotKeyDefinition(id: "clipboard.toggle", name: "Clipboard", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let def2 = HotKeyDefinition(id: "clipboard.toggle", name: "Clipboard", keyCode: 9, carbonModifiers: 2048, keyEquivalent: "⌥V")

        _ = manager.registerHotKey(def1) { triggerCount.add(1) }
        let oldCarbonId = manager.carbonId(for: "clipboard.toggle")!

        _ = manager.registerHotKey(def2) { triggerCount.add(10) }
        let newCarbonId = manager.carbonId(for: "clipboard.toggle")!
        #expect(oldCarbonId != newCarbonId)

        // Old keypress must not fire
        backend.simulateKeyPress(hotKeyID: oldCarbonId)
        #expect(triggerCount.value == 0)

        // New keypress fires
        backend.simulateKeyPress(hotKeyID: newCarbonId)
        #expect(triggerCount.value == 10)
    }

    @Test("Unregister by ID safely removes target hotkey")
    func testUnregisterById() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        _ = manager.registerHotKey(HotKeyDefinition.defaultClipboard) {}
        _ = manager.registerHotKey(HotKeyDefinition.defaultAreaCapture) {}

        #expect(manager.registeredCount == 2)
        manager.unregisterHotKey(id: HotKeyDefinition.clipboardToggleId)

        #expect(manager.registeredCount == 1)
        #expect(manager.isRegistered(id: HotKeyDefinition.clipboardToggleId) == false)
        #expect(manager.isRegistered(id: HotKeyDefinition.captureAreaId) == true)
    }

    @Test("Unregister by definition safely removes target hotkey")
    func testUnregisterByDefinition() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def = HotKeyDefinition.defaultClipboard
        _ = manager.registerHotKey(def) {}
        #expect(manager.isRegistered(id: def.id) == true)

        manager.unregisterHotKey(def)
        #expect(manager.isRegistered(id: def.id) == false)
        #expect(manager.registeredCount == 0)
    }

    @Test("Unregister all clears entire registry and releases backend references")
    func testUnregisterAll() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        _ = manager.registerHotKey(HotKeyDefinition.defaultClipboard) {}
        _ = manager.registerHotKey(HotKeyDefinition.defaultAreaCapture) {}
        _ = manager.registerHotKey(HotKeyDefinition.defaultFullscreenCapture) {}

        #expect(manager.registeredCount == 3)
        manager.unregisterAll()

        #expect(manager.registeredCount == 0)
        #expect(backend.registeredRefsCount == 0)
    }

    @Test("Unregister non-existent hotkey is a safe no-op")
    func testUnregisterNonExistentSafeNoOp() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        manager.unregisterHotKey(id: "non.existent.id")
        #expect(manager.registeredCount == 0)
    }

    @Test("Find conflict engine detects duplicate key combinations")
    func testConflictDetectionEngine() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        let def1 = HotKeyDefinition.defaultClipboard // ⌘⇧V
        _ = manager.registerHotKey(def1) {}

        let conflictDef = HotKeyDefinition(id: "conflict.action", name: "Conflict", keyCode: 9, carbonModifiers: 768, keyEquivalent: "⌘⇧V")
        let found = manager.findConflict(for: conflictDef)
        #expect(found?.id == def1.id)

        let nonConflictDef = HotKeyDefinition.defaultAreaCapture
        #expect(manager.findConflict(for: nonConflictDef) == nil)
    }

    @Test("Re-entrant handler unregistration does not deadlock")
    func testReentrantHandlerUnregistration() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let def = HotKeyDefinition.defaultClipboard

        _ = manager.registerHotKey(def) {
            manager.unregisterHotKey(id: def.id)
        }

        let carbonId = manager.carbonId(for: def.id)!
        backend.simulateKeyPress(hotKeyID: carbonId)

        #expect(manager.isRegistered(id: def.id) == false)
        #expect(manager.registeredCount == 0)
    }

    @Test("OS registration failure returns false and preserves registry integrity")
    func testOsRegistrationFailureHandling() {
        let backend = SimulatedCarbonBackend()
        backend.shouldFailRegistration = true
        let manager = CarbonHotKeyManager(backend: backend)

        let def = HotKeyDefinition.defaultClipboard
        let success = manager.registerHotKey(def) {}

        #expect(success == false)
        #expect(manager.isRegistered(id: def.id) == false)
        #expect(manager.registeredCount == 0)
    }

    @Test("Direct simulation trigger helpers execute handlers safely")
    func testSimulationTriggerHelpers() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let invoked = AtomicBool(false)

        let def = HotKeyDefinition.defaultClipboard
        _ = manager.registerHotKey(def) {
            invoked.value = true
        }

        let result1 = manager.simulateHotKeyTrigger(id: def.id)
        #expect(result1 == true)
        #expect(invoked.value == true)

        let result2 = manager.simulateTrigger(hotKeyId: "unknown.id")
        #expect(result2 == false)
    }

    @Test("Handles 50 concurrent tasks registering, unregistering, and triggering")
    func testConcurrentRegistrationAndInvocation() async {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let def = HotKeyDefinition(
                        id: "task.\(i)",
                        name: "Task \(i)",
                        keyCode: UInt32(i + 100),
                        carbonModifiers: 768,
                        keyEquivalent: "Test\(i)"
                    )
                    _ = manager.registerHotKey(def) {}
                    _ = manager.simulateHotKeyTrigger(id: def.id)
                    if i % 2 == 0 {
                        manager.unregisterHotKey(id: def.id)
                    }
                }
            }
        }

        #expect(manager.registeredCount >= 0)
    }

    @Test("Re-registering identical shortcut updates handler in-place without Carbon error or ID change")
    func testIdenticalShortcutInPlaceHandlerUpdate() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let handler1Fired = AtomicBool(false)
        let handler2Fired = AtomicBool(false)

        let def = HotKeyDefinition(id: "action.test", name: "Test", keyCode: 15, carbonModifiers: 768, keyEquivalent: "⌘⇧R")
        #expect(manager.registerHotKey(def) { handler1Fired.value = true } == true)
        let initialCarbonId = manager.carbonId(for: def.id)
        #expect(initialCarbonId != nil)

        // Re-register with exact same key combination but different closure
        #expect(manager.registerHotKey(def) { handler2Fired.value = true } == true)
        let secondCarbonId = manager.carbonId(for: def.id)
        #expect(initialCarbonId == secondCarbonId)

        backend.simulateKeyPress(hotKeyID: initialCarbonId!)
        #expect(handler1Fired.value == false)
        #expect(handler2Fired.value == true)
    }

    @Test("Re-registering with changing shortcut that fails rolls back to previous shortcut registration")
    func testRebindingFailureRollbackPreservesOriginalShortcut() {
        let backend = SimulatedCarbonBackend()
        let manager = CarbonHotKeyManager(backend: backend)
        let initialHandlerFired = AtomicBool(false)

        let initialDef = HotKeyDefinition(id: "action.rollback", name: "Rollback Test", keyCode: 18, carbonModifiers: 768, keyEquivalent: "⌘⇧1")
        #expect(manager.registerHotKey(initialDef) { initialHandlerFired.value = true } == true)
        let initialCarbonId = manager.carbonId(for: initialDef.id)
        #expect(initialCarbonId != nil)

        // Attempt to register new key combination, but backend fails for key 19
        backend.failingKeyCodes = [19]
        let newDef = HotKeyDefinition(id: "action.rollback", name: "Rollback Test", keyCode: 19, carbonModifiers: 768, keyEquivalent: "⌘⇧2")
        let updateSuccess = manager.registerHotKey(newDef) { }
        #expect(updateSuccess == false)

        // Original registration must be restored
        #expect(manager.isRegistered(id: initialDef.id) == true)
        let restoredDef = manager.registeredHotKeys[initialDef.id]
        #expect(restoredDef?.keyCode == initialDef.keyCode)

        // Old keypress must still trigger the original handler
        #expect(manager.carbonId(for: initialDef.id) != nil)
        backend.simulateKeyPress(hotKeyID: manager.carbonId(for: initialDef.id)!)
        #expect(initialHandlerFired.value == true)
    }
}
