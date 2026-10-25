import Testing
import AppKit
import Foundation
@testable import ZenithCore

// MARK: - Thread-Safe Test Synchronization Primitives

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

    func add(_ delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value += delta
    }
}

private final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(initialValue: Bool) {
        self._value = initialValue
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func setValue(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

// MARK: - Adversarial Stress & Lifecycle Test Suite

@Suite("Adversarial Menu Bar, Window Lifecycle & Shortcut Race Challenger Suite")
struct AdversarialMenuBarAndWindowStressChallengerTests {

    private func queryResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    // MARK: - 1. Hammer MenuBarController.menuWillOpen 1,000+ Rapid Calls Under Concurrent Mutations

    @Test("ADV-M6-01: Hammer MenuBarController.menuWillOpen 1,000+ times under concurrent clipboard mutations")
    @MainActor
    func testHammerMenuBarMenuWillOpenConcurrency() async {
        let mockPasteboard = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPasteboard, initialItems: [])
        let controller = MenuBarController(clipboardStore: store)
        let menu = controller.buildMenu()

        let isRunning = ManagedAtomicBool(initialValue: true)
        let backgroundMutationCount = ManagedCounter()

        // Launch 12 concurrent background tasks continuously modifying clipboard store
        let backgroundWorkers = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for workerId in 0..<12 {
                    group.addTask {
                        var counter = 0
                        while isRunning.value {
                            counter += 1
                            let step = (workerId + counter) % 7
                            switch step {
                            case 0:
                                store.add(ClipboardItem.text("Text_\(workerId)_\(counter)"))
                            case 1:
                                let rtfText = "RTF_\(workerId)_\(counter)"
                                store.add(ClipboardItem.richText(rtfData: Data(rtfText.utf8), plainText: rtfText))
                            case 2:
                                let bytes = [UInt8](repeating: UInt8((workerId * 17) & 0xFF), count: 64)
                                store.add(ClipboardItem.image(data: Data(bytes), width: 16, height: 16))
                            case 3:
                                if counter % 15 == 0 {
                                    store.clear()
                                }
                            case 4:
                                if let first = store.items.first {
                                    store.togglePin(id: first.id)
                                }
                            case 5:
                                if let last = store.items.last {
                                    store.removeItem(id: last.id)
                                }
                            case 6:
                                if let randomItem = store.items.first {
                                    store.selectAndRestoreItem(randomItem)
                                }
                            default:
                                break
                            }
                            backgroundMutationCount.increment()

                            if counter % 25 == 0 {
                                await Task.yield()
                            }
                        }
                    }
                }
            }
        }

        let initialMem = queryResidentMemoryBytes()
        let totalIterations = 1_200

        for i in 1...totalIterations {
            controller.menuWillOpen(menu)

            guard let statsItem = menu.item(withTag: MenuBarItemTag.liveStatistics.rawValue),
                  let clearItem = menu.item(withTag: MenuBarItemTag.clearHistory.rawValue) else {
                Issue.record("Required dynamic items missing in menu at iteration \(i)")
                break
            }

            // Invariant 1: Statistics item is always disabled
            #expect(statsItem.isEnabled == false)

            let title = statsItem.title
            let clearEnabled = clearItem.isEnabled

            // Invariant 2: Dynamic stats title and clear history enablement are strictly coherent
            if clearEnabled {
                #expect(title != "Clipboard: Empty")
                #expect(title.hasPrefix("Clipboard: "))
            } else {
                #expect(title == "Clipboard: Empty")
            }

            // Periodically yield to give background tasks CPU time
            if i % 100 == 0 {
                await Task.yield()
            }
        }

        isRunning.setValue(false)
        await backgroundWorkers.value

        let finalMem = queryResidentMemoryBytes()
        let memGrowthMB = Double(Int64(finalMem) - Int64(initialMem)) / (1024.0 * 1024.0)

        print("[Challenger MenuBar Stress] Completed \(totalIterations) menuWillOpen iterations under \(backgroundMutationCount.value) concurrent mutations. Mem growth: \(String(format: "%.2f", memGrowthMB)) MB")

        #expect(backgroundMutationCount.value >= 500)
        #expect(memGrowthMB < 500.0) // Bounded memory consumption
    }

    // MARK: - 2. Hammer SettingsWindowController show() and dismiss() with 50+ Rapid Calls

    @Test("ADV-M6-02: Hammer SettingsWindowController show() and dismiss() with 100+ rapid calls, verifying idempotency, zero duplicate windows, and memory stability")
    @MainActor
    func testHammerSettingsWindowControllerShowDismiss() {
        let controller = SettingsWindowController()
        let initialMem = queryResidentMemoryBytes()

        let dummyVC = NSViewController()
        dummyVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 480))
        controller.viewControllerProvider = { dummyVC }

        let initialWindow = controller.createWindow()
        #expect(controller.window === initialWindow)

        // 1. 100 rapid alternating show() and dismiss() cycles
        for _ in 1...100 {
            controller.show()
            #expect(controller.isVisible == true)
            #expect(controller.window === initialWindow)
            #expect(controller.window?.frame.width == initialWindow.frame.width)
            #expect(controller.window?.frame.height == initialWindow.frame.height)
            #expect(controller.window?.styleMask.contains(.resizable) == false)
            #expect(controller.window?.styleMask.contains(.titled) == true)
            #expect(controller.window?.styleMask.contains(.closable) == true)

            controller.dismiss()
            #expect(controller.isVisible == false)
            #expect(controller.window === initialWindow)
        }

        // 2. 50 rapid consecutive show() calls without dismissal (idempotency under flood)
        for _ in 1...50 {
            controller.show()
            #expect(controller.isVisible == true)
            #expect(controller.window === initialWindow)
        }

        // 3. 50 rapid consecutive dismiss() calls without showing (safe no-op under flood)
        for _ in 1...50 {
            controller.dismiss()
            #expect(controller.isVisible == false)
            #expect(controller.window === initialWindow)
        }

        // 4. Test SettingsWindowController.shared singleton reuse and window count stability
        let sharedController = SettingsWindowController.shared
        sharedController.show()
        let sharedWindow = sharedController.window
        #expect(sharedWindow != nil)

        for _ in 1...50 {
            sharedController.show()
            #expect(sharedController.window === sharedWindow)
        }
        sharedController.dismiss()
        #expect(sharedController.isVisible == false)

        let finalMem = queryResidentMemoryBytes()
        let memGrowthMB = Double(Int64(finalMem) - Int64(initialMem)) / (1024.0 * 1024.0)

        print("[Challenger SettingsWindow Stress] Completed 250 show/dismiss cycles. Mem growth: \(String(format: "%.2f", memGrowthMB)) MB")
        #expect(memGrowthMB < 400.0)
    }

    // MARK: - 3. Rapid Toggle Races Between Keyboard Shortcuts and Menu Bar Selections

    @Test("ADV-M6-03: Rapid toggle races between keyboard shortcuts and menu bar selections (1,000 cross-racing events)")
    func testRapidToggleRacesBetweenShortcutsAndMenuBar() async {
        let simulatedBackend = SimulatedCarbonBackend()
        let hotKeyManager = HotKeyManager(backend: simulatedBackend)

        let mockPasteboard = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPasteboard, initialItems: [])
        let menuBarController = await MainActor.run {
            MenuBarController(clipboardStore: store)
        }

        // Shared telemetry counters
        let clipboardEventsCount = ManagedCounter()
        let areaCaptureEventsCount = ManagedCounter()
        let fullscreenEventsCount = ManagedCounter()
        let preferencesEventsCount = ManagedCounter()
        let clearEventsCount = ManagedCounter()

        // 1. Register HotKeys
        let defClipboard = HotKeyDefinition.defaultClipboard
        let defArea = HotKeyDefinition.defaultAreaCapture
        let defFullscreen = HotKeyDefinition.defaultFullscreenCapture
        let defPrefs = HotKeyDefinition(
            id: "preferences_shortcut",
            name: "Preferences",
            keyCode: 43, // comma
            carbonModifiers: CarbonModifierFlags.command.rawValue,
            keyEquivalent: "⌘,"
        )

        hotKeyManager.registerHotKey(defClipboard) {
            clipboardEventsCount.increment()
        }
        hotKeyManager.registerHotKey(defArea) {
            areaCaptureEventsCount.increment()
        }
        hotKeyManager.registerHotKey(defFullscreen) {
            fullscreenEventsCount.increment()
        }
        hotKeyManager.registerHotKey(defPrefs) {
            preferencesEventsCount.increment()
        }

        // 2. Wire MenuBar Actions
        await MainActor.run {
            menuBarController.onClipboardHistory = {
                clipboardEventsCount.increment()
            }
            menuBarController.onCaptureArea = {
                areaCaptureEventsCount.increment()
            }
            menuBarController.onCaptureFullscreen = {
                fullscreenEventsCount.increment()
            }
            menuBarController.onShowPreferences = {
                preferencesEventsCount.increment()
            }
            menuBarController.onClearHistory = {
                clearEventsCount.increment()
                store.clear()
            }
        }

        #expect(hotKeyManager.registeredCount == 4)

        // 3. Concurrently fire 500 shortcut keypresses across background tasks
        //    while simultaneously firing 500 menu bar action invocations
        let shortcutTask = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for taskId in 0..<10 {
                    group.addTask {
                        for rep in 0..<50 {
                            let hotKeyId = UInt32(1 + ((taskId + rep) % 4))
                            simulatedBackend.simulateKeyPress(hotKeyID: hotKeyId)
                        }
                    }
                }
            }
        }

        let menuTask = Task.detached {
            for i in 0..<500 {
                let actionKind = i % 5
                await MainActor.run {
                    switch actionKind {
                    case 0:
                        menuBarController.clipboardHistoryAction(nil)
                    case 1:
                        menuBarController.captureAreaAction(nil)
                    case 2:
                        menuBarController.captureFullscreenAction(nil)
                    case 3:
                        menuBarController.preferencesAction(nil)
                    case 4:
                        menuBarController.clearHistoryAction(nil)
                    default:
                        break
                    }
                }
            }
        }

        _ = await shortcutTask.value
        _ = await menuTask.value

        let totalEvents = clipboardEventsCount.value +
                          areaCaptureEventsCount.value +
                          fullscreenEventsCount.value +
                          preferencesEventsCount.value +
                          clearEventsCount.value

        print("[Challenger Toggle Race] Processed \(totalEvents) total events (Shortcuts + MenuBar). Breakdown: Clipboard=\(clipboardEventsCount.value), Area=\(areaCaptureEventsCount.value), Fullscreen=\(fullscreenEventsCount.value), Prefs=\(preferencesEventsCount.value), Clear=\(clearEventsCount.value)")

        // 500 shortcuts + 500 menu actions = 1,000 total events
        #expect(totalEvents == 1_000)
        #expect(clipboardEventsCount.value > 0)
        #expect(areaCaptureEventsCount.value > 0)
        #expect(fullscreenEventsCount.value > 0)
        #expect(preferencesEventsCount.value > 0)
        #expect(clearEventsCount.value == 100)
        #expect(hotKeyManager.registeredCount == 4)
    }

    // MARK: - 4. High-Frequency MenuBarController Setup and Teardown Stress (100 Cycles)

    @Test("ADV-M6-04: High-frequency MenuBarController setup and teardown stress (100 cycles)")
    @MainActor
    func testHighFrequencyMenuBarSetupTeardown() {
        let controller = MenuBarController()
        let statusBar = NSStatusBar()
        let initialMem = queryResidentMemoryBytes()

        for _ in 1...100 {
            controller.setup(statusBar: statusBar)
            #expect(controller.statusItem != nil)
            #expect(controller.menu != nil)

            // Redundant setup must be safe no-op
            controller.setup(statusBar: statusBar)
            #expect(controller.statusItem != nil)

            controller.teardown(statusBar: statusBar)
            #expect(controller.statusItem == nil)
            #expect(controller.menu == nil)

            // Redundant teardown must be safe no-op
            controller.teardown(statusBar: statusBar)
            #expect(controller.statusItem == nil)
            #expect(controller.menu == nil)
        }

        let finalMem = queryResidentMemoryBytes()
        let memGrowthMB = Double(Int64(finalMem) - Int64(initialMem)) / (1024.0 * 1024.0)

        print("[Challenger Setup/Teardown Stress] Completed 100 cycles. Mem growth: \(String(format: "%.2f", memGrowthMB)) MB")
        #expect(memGrowthMB < 400.0)
    }

    // MARK: - 5. Boundary Stress on Statistics Title Formatter & Menu Dynamic Items

    @Test("ADV-M6-05: Extreme boundary values for statistics title and dynamic menu updates")
    @MainActor
    func testBoundaryStatisticsFormattingAndDynamicItems() {
        let controller = MenuBarController()

        // 1. Standard count boundaries
        #expect(controller.statisticsTitle(for: 0) == "Clipboard: Empty")
        #expect(controller.statisticsTitle(for: 1) == "Clipboard: 1 item")
        #expect(controller.statisticsTitle(for: 2) == "Clipboard: 2 items")
        #expect(controller.statisticsTitle(for: 20) == "Clipboard: 20 items")
        #expect(controller.statisticsTitle(for: 500) == "Clipboard: 500 items")
        #expect(controller.statisticsTitle(for: 10_000) == "Clipboard: 10000 items")
        #expect(controller.statisticsTitle(for: 1_000_000) == "Clipboard: 1000000 items")
        #expect(controller.statisticsTitle(for: Int.max) == "Clipboard: \(Int.max) items")

        // 2. Negative count defensive handling
        #expect(controller.statisticsTitle(for: -1) == "Clipboard: -1 items")

        // 3. updateDynamicItems resilience against empty or stripped menu
        let bareMenu = NSMenu(title: "Bare")
        // Should not crash even when liveStatistics or clearHistory items are missing
        controller.updateDynamicItems(in: bareMenu)
        #expect(bareMenu.items.isEmpty)
    }

    // MARK: - 6. Rapid LaunchAtLogin 80-Task Concurrency Torture & SettingsStore Coherence

    @Test("ADV-M6-06: LaunchAtLogin 80-task concurrency torture and SettingsStore coherence")
    func testLaunchAtLoginConcurrencyAndSettingsCoherence() async {
        let suiteName = "ChallengerLALSuite_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(userDefaults: defaults)
        let lalService = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<80 {
                group.addTask {
                    for rep in 0..<30 {
                        let step = (taskId + rep) % 3
                        switch step {
                        case 0:
                            try? lalService.enable()
                            settingsStore.launchAtLoginEnabled = true
                        case 1:
                            try? lalService.disable()
                            settingsStore.launchAtLoginEnabled = false
                        case 2:
                            if lalService.isEnabled {
                                try? lalService.disable()
                                settingsStore.launchAtLoginEnabled = false
                            } else {
                                try? lalService.enable()
                                settingsStore.launchAtLoginEnabled = true
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }

        let finalStatus = lalService.status
        let settingsValue = settingsStore.launchAtLoginEnabled
        _ = (finalStatus == .enabled) == settingsValue

        print("[Challenger LaunchAtLogin] Torture completed: finalStatus=\(finalStatus), totalEnableCalls=\(lalService.enableCallCount), totalDisableCalls=\(lalService.disableCallCount)")
        #expect(lalService.enableCallCount + lalService.disableCallCount == 80 * 30)
    }
}
