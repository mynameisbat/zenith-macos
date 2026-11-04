import Testing
import Foundation
import Carbon
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
}
