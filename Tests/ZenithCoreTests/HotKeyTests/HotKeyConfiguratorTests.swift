import Testing
import Foundation
import Carbon
import AppKit
@testable import ZenithCore

@Suite("HotKey Configurator Suite")
struct HotKeyConfiguratorTests {

    private struct Fixture {
        let backend = SimulatedCarbonBackend()
        let manager: HotKeyManager
        let store: SettingsStore
        let defaults: UserDefaults
        let configurator: HotKeyConfigurator

        init() throws {
            defaults = try #require(TestDefaults.make("hotkeys_\(UUID().uuidString)"))
            store = SettingsStore(userDefaults: defaults)
            manager = HotKeyManager(backend: backend)
            configurator = HotKeyConfigurator(store: store, manager: manager)
        }
    }

    private let ocr = HotKeyDefinition(
        id: "capture.ocr", name: "Screen OCR", keyCode: 20,
        carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue, keyEquivalent: "⌘⇧3"
    )

    /// Clipboard, area capture, full screen and OCR, as the app registers them.
    private func actions(_ counter: Counter = Counter()) -> [(definition: HotKeyDefinition, handler: () -> Void)] {
        [
            (HotKeyDefinition.defaultClipboard, { counter.hit("clipboard") }),
            (HotKeyDefinition.defaultAreaCapture, { counter.hit("area") }),
            (HotKeyDefinition.defaultFullscreenCapture, { counter.hit("full") }),
            (ocr, { counter.hit("ocr") })
        ]
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _hits: [String] = []
        var hits: [String] { lock.withLock { _hits } }
        func hit(_ name: String) { lock.withLock { _hits.append(name) } }
    }

    private func custom(id: String, keyCode: UInt32, key: String) -> HotKeyDefinition {
        HotKeyDefinition(
            id: id, name: "Custom", keyCode: keyCode,
            carbonModifiers: CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue, keyEquivalent: key
        )
    }

    @Test("HKC-01: With nothing saved, every action gets its built-in shortcut")
    func testDefaultsWhenNothingSaved() throws {
        let f = try Fixture()
        let failed = f.configurator.registerAll(actions())
        #expect(failed.isEmpty)
        #expect(f.manager.registeredCount == 4)
        #expect(f.manager.registeredHotKeys[HotKeyDefinition.clipboardToggleId]?.keyCode == 9)
        #expect(f.manager.registeredHotKeys["capture.ocr"]?.keyCode == 20)
    }

    @Test("HKC-02: A shortcut saved in Settings is the one registered at launch")
    func testSavedShortcutIsRegistered() throws {
        let f = try Fixture()
        f.store.updateHotkey(custom(id: HotKeyDefinition.clipboardToggleId, keyCode: 8, key: "⌃⌥C"))   // C

        let counter = Counter()
        f.configurator.registerAll(actions(counter))

        #expect(f.manager.registeredHotKeys[HotKeyDefinition.clipboardToggleId]?.keyCode == 8)
        f.manager.simulateHotKeyTrigger(id: HotKeyDefinition.clipboardToggleId)
        #expect(counter.hits == ["clipboard"])
    }

    @Test("HKC-03: A saved shortcut the system refuses falls back to the built-in one, and that is saved")
    func testRefusedSavedShortcutFallsBack() throws {
        let f = try Fixture()
        f.store.updateHotkey(custom(id: HotKeyDefinition.clipboardToggleId, keyCode: 8, key: "⌃⌥C"))
        f.backend.failingKeyCodes = [8]

        let failed = f.configurator.registerAll(actions())

        #expect(failed.isEmpty)
        #expect(f.manager.registeredHotKeys[HotKeyDefinition.clipboardToggleId] == HotKeyDefinition.defaultClipboard)
        #expect(f.store.hotkey(for: HotKeyDefinition.clipboardToggleId) == HotKeyDefinition.defaultClipboard)
    }

    @Test("HKC-04: A shortcut that cannot be registered at all is reported, the others still work")
    func testUnregisterableIsReported() throws {
        let f = try Fixture()
        f.backend.failingKeyCodes = [9]                    // V: the clipboard shortcut
        let failed = f.configurator.registerAll(actions())
        #expect(failed.map(\.id) == [HotKeyDefinition.clipboardToggleId])
        #expect(f.manager.registeredCount == 3)
    }

    @Test("HKC-05: A change takes effect at once, is saved, and survives a restart")
    func testChangeIsAppliedAndSaved() throws {
        let f = try Fixture()
        let counter = Counter()
        f.configurator.registerAll(actions(counter))

        let new = custom(id: HotKeyDefinition.captureAreaId, keyCode: 6, key: "⌃⌥Z")                  // Z
        #expect(f.configurator.change(new) == .applied)

        #expect(f.manager.registeredHotKeys[HotKeyDefinition.captureAreaId]?.keyCode == 6)
        f.manager.simulateHotKeyTrigger(id: HotKeyDefinition.captureAreaId)
        #expect(counter.hits == ["area"])                                                             // same handler
        #expect(SettingsStore(userDefaults: f.defaults).hotkey(for: HotKeyDefinition.captureAreaId)?.keyCode == 6)
    }

    @Test("HKC-06: A combination another Zenith action uses is a conflict, and nothing changes")
    func testConflict() throws {
        let f = try Fixture()
        f.configurator.registerAll(actions())

        // The OCR shortcut is not in the settings dictionary; the manager still knows it.
        let clash = HotKeyDefinition(
            id: HotKeyDefinition.captureAreaId, name: "Area", keyCode: 20,
            carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue, keyEquivalent: "⌘⇧3"
        )
        #expect(f.configurator.change(clash) == .conflict(with: "Screen OCR"))
        #expect(f.manager.registeredHotKeys[HotKeyDefinition.captureAreaId]?.keyCode == 19)
        #expect(f.store.hotkey(for: HotKeyDefinition.captureAreaId) == HotKeyDefinition.defaultAreaCapture)
    }

    @Test("HKC-07: A combination the system refuses is reported; the old shortcut keeps working and nothing is saved")
    func testSystemRefusal() throws {
        let f = try Fixture()
        let counter = Counter()
        f.configurator.registerAll(actions(counter))
        f.backend.failingKeyCodes = [6]

        let result = f.configurator.change(custom(id: HotKeyDefinition.captureAreaId, keyCode: 6, key: "⌃⌥Z"))

        #expect(result == .unavailable)
        #expect(f.manager.registeredHotKeys[HotKeyDefinition.captureAreaId]?.keyCode == 19)
        f.manager.simulateHotKeyTrigger(id: HotKeyDefinition.captureAreaId)
        #expect(counter.hits == ["area"])
        #expect(f.store.hotkey(for: HotKeyDefinition.captureAreaId) == HotKeyDefinition.defaultAreaCapture)
    }

    @Test("HKC-08: An unknown action, and reset to the built-in shortcut (OCR included)")
    func testUnknownAndReset() throws {
        let f = try Fixture()
        #expect(f.configurator.change(custom(id: "nope", keyCode: 6, key: "⌃⌥Z")) == .unknownAction)

        f.configurator.registerAll(actions())
        #expect(f.configurator.change(custom(id: "capture.ocr", keyCode: 6, key: "⌃⌥Z")) == .applied)
        #expect(f.manager.registeredHotKeys["capture.ocr"]?.keyCode == 6)

        #expect(f.configurator.resetToDefault(id: "capture.ocr") == .applied)
        #expect(f.manager.registeredHotKeys["capture.ocr"]?.keyCode == 20)
    }

    // MARK: - Against the real Carbon hot key service

    /// Registers real global hot keys for a moment, so it only runs on request: `ZENITH_E2E_SYSTEM=1`.
    /// The combinations (⌃⌥⇧⌘ plus F18/F19) are ones nobody uses. Pressing is simulated by sending the event the
    /// system sends, since a test process may not post keystrokes.
    @Test(
        "HKC-E2E: With the real Carbon backend a change moves the system registration and the handler still fires",
        .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_SYSTEM"] == "1", "Registers real global hot keys; set ZENITH_E2E_SYSTEM=1 to run")
    )
    @MainActor
    func testRealCarbonRegistration() async throws {
        _ = NSApplication.shared
        let defaults = try #require(TestDefaults.make("hotkeys_e2e_\(UUID().uuidString)"))
        let backend = SystemCarbonBackend()
        let manager = HotKeyManager(backend: backend)
        let configurator = HotKeyConfigurator(store: SettingsStore(userDefaults: defaults), manager: manager)
        defer {
            manager.unregisterAll()
            _ = backend.removeHandler()
        }

        let all = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let first = HotKeyDefinition(id: "e2e.action", name: "E2E", keyCode: 79, carbonModifiers: all, keyEquivalent: "⌃⌥⇧⌘F18")
        let second = HotKeyDefinition(id: "e2e.action", name: "E2E", keyCode: 80, carbonModifiers: all, keyEquivalent: "⌃⌥⇧⌘F19")
        let counter = Counter()

        func rawRegister(_ definition: HotKeyDefinition) -> OSStatus {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                definition.keyCode, definition.carbonModifiers, EventHotKeyID(signature: 0x45324532, id: 999),
                GetApplicationEventTarget(), 0, &ref
            )
            if let ref { UnregisterEventHotKey(ref) }
            return status
        }
        func press(_ definition: HotKeyDefinition) async throws {
            var hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: try #require(manager.carbonId(for: definition.id)))
            var event: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
            let created = try #require(event)
            SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &hotKeyID)
            SendEventToEventTarget(created, GetApplicationEventTarget())
            ReleaseEvent(created)
            try await Task.sleep(nanoseconds: 100_000_000)   // the handler hops to the main queue
        }

        // 1. Registered for real: another registration of the same combination is refused by the system.
        #expect(configurator.registerAll([(first, { counter.hit("handler") })]).isEmpty)
        #expect(rawRegister(first) == OSStatus(eventHotKeyExistsErr))
        try await press(first)
        #expect(counter.hits == ["handler"])

        // 2. After a change the old combination is free again, the new one is taken, and the same handler fires.
        #expect(configurator.change(second) == .applied)
        #expect(rawRegister(first) == noErr)
        #expect(rawRegister(second) == OSStatus(eventHotKeyExistsErr))
        try await press(second)
        #expect(counter.hits == ["handler", "handler"])

        // 3. The change was saved.
        #expect(SettingsStore(userDefaults: defaults).hotkey(for: "e2e.action")?.keyCode == 80)
    }
}

@Suite("Built-in Shortcut Lookup Suite")
struct BuiltInShortcutTests {
    @Test("HKC-09: Every action the app registers has a built-in shortcut to reset to, OCR included")
    func testBuiltInLookup() {
        #expect(HotKeyDefinition.builtIn(for: HotKeyDefinition.clipboardToggleId) == HotKeyDefinition.defaultClipboard)
        #expect(HotKeyDefinition.builtIn(for: HotKeyDefinition.captureOCRId) == HotKeyDefinition.defaultOCR)
        #expect(HotKeyDefinition.builtIn(for: "nope") == nil)
        #expect(HotKeyDefinition.defaultOCR.keyCode == 17)
        #expect(HotKeyDefinition.defaultOCR.keyEquivalent == "⌃⌥T")
        // The settings dictionary keeps its three entries: older saved settings know only those.
        #expect(HotKeyDefinition.defaultDictionary.count == 3)
    }
}

@Suite("macOS Screenshot Shortcut Clash Suite")
struct ScreenshotShortcutClashTests {
    @Test("HKC-10: No built-in Zenith shortcut is also one of macOS's screenshot shortcuts")
    func testNoBuiltInClashesWithMacOS() {
        let builtIns: [HotKeyDefinition] = Array(HotKeyDefinition.defaultDictionary.values) + [
            HotKeyDefinition.defaultOCR,
            HotKeyDefinition.alternativeClipboardOptionV,
            HotKeyDefinition.alternativeAreaCaptureX
        ]
        for definition in builtIns {
            #expect(!definition.clashesWithMacOSScreenshot, "\(definition.keyEquivalent) (\(definition.name)) is a macOS screenshot shortcut")
        }
    }

    @Test("HKC-11: The clash check knows the system's shortcuts, and only those")
    func testClashCheck() {
        let cmdShift = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        func definition(_ keyCode: UInt32, _ modifiers: UInt32) -> HotKeyDefinition {
            HotKeyDefinition(id: "x", name: "X", keyCode: keyCode, carbonModifiers: modifiers, keyEquivalent: "?")
        }
        #expect(definition(20, cmdShift).clashesWithMacOSScreenshot)        // ⌘⇧3
        #expect(definition(21, cmdShift).clashesWithMacOSScreenshot)        // ⌘⇧4
        #expect(definition(23, cmdShift).clashesWithMacOSScreenshot)        // ⌘⇧5
        #expect(!definition(19, cmdShift).clashesWithMacOSScreenshot)       // ⌘⇧2 is free
        #expect(!definition(20, CarbonModifierFlags.control.rawValue).clashesWithMacOSScreenshot)
    }
}
