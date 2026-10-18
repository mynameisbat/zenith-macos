import Testing
import Foundation
import AppKit
@testable import GoldenGateCore

@Suite("Adversarial M7 Controllers & System Services Hardening Suite")
struct AdversarialM7ControllersAndSystemHardeningTests {

    // MARK: - 1. MenuBarController Lifecycle & Dynamic Menu Hardening

    @Test("ADV-M7-MB-01: Double setup idempotence & double teardown safety")
    @MainActor
    func testMenuBarControllerSetupTeardownIdempotence() {
        let controller = MenuBarController()
        let statusBar = NSStatusBar()

        // 1. Initial setup allocates status item
        controller.setup(statusBar: statusBar)
        guard let firstItem = controller.statusItem else {
            Issue.record("Status item not allocated")
            return
        }

        // 2. Second setup call must be idempotent and preserve existing status item
        controller.setup(statusBar: statusBar)
        #expect(controller.statusItem === firstItem)

        // 3. First teardown deallocates status item
        controller.teardown(statusBar: statusBar)
        #expect(controller.statusItem == nil)
        #expect(controller.menu == nil)

        // 4. Second teardown call must be safe no-op without crash
        controller.teardown(statusBar: statusBar)
        #expect(controller.statusItem == nil)
    }

    @Test("ADV-M7-MB-02: updateDynamicItems resilience against arbitrary external NSMenus missing standard tags")
    @MainActor
    func testMenuBarControllerUpdateDynamicItemsWithArbitraryMenu() {
        let controller = MenuBarController()
        let emptyMenu = NSMenu(title: "EmptyTestMenu")

        // Calling updateDynamicItems on menu with NO matching tags must be safe no-op
        controller.updateDynamicItems(in: emptyMenu)
        #expect(emptyMenu.items.isEmpty)

        // Menu with only non-matching items
        emptyMenu.addItem(withTitle: "Unrelated Item", action: nil, keyEquivalent: "")
        controller.updateDynamicItems(in: emptyMenu)
        #expect(emptyMenu.items.count == 1)
    }

    @Test("ADV-M7-MB-03: clearHistoryAction default execution clears store directly when onClearHistory is nil")
    @MainActor
    func testMenuBarControllerClearHistoryDefaultBehavior() {
        let mockPasteboard = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPasteboard, initialItems: [
            ClipboardItem.text("Item A"),
            ClipboardItem.text("Item B")
        ])
        let controller = MenuBarController(clipboardStore: store)
        let statusBar = NSStatusBar()
        controller.setup(statusBar: statusBar)
        guard let menu = controller.menu else {
            Issue.record("Menu not allocated in controller.setup")
            return
        }

        #expect(store.items.count == 2)
        controller.onClearHistory = nil // Ensure default branch is taken

        controller.clearHistoryAction(nil)
        #expect(store.items.isEmpty)

        // Verify dynamic items updated
        let statsItem = menu.item(withTag: MenuBarItemTag.liveStatistics.rawValue)!
        let clearItem = menu.item(withTag: MenuBarItemTag.clearHistory.rawValue)!
        #expect(statsItem.title == "Clipboard: Empty")
        #expect(clearItem.isEnabled == false)

        controller.teardown(statusBar: statusBar)
    }

    @Test("ADV-M7-MB-04: Extreme item counts in statistics title formatter")
    @MainActor
    func testMenuBarStatisticsTitleExtremeFormatting() {
        let controller = MenuBarController()
        #expect(controller.statisticsTitle(for: 0) == "Clipboard: Empty")
        #expect(controller.statisticsTitle(for: 1) == "Clipboard: 1 item")
        #expect(controller.statisticsTitle(for: 2) == "Clipboard: 2 items")
        #expect(controller.statisticsTitle(for: 1_000_000) == "Clipboard: 1000000 items")
        // Negative count fallback treats as plural
        #expect(controller.statisticsTitle(for: -5) == "Clipboard: -5 items")
    }

    // MARK: - 2. SettingsWindowController Presentation & Deminiaturize Invariants

    @Test("ADV-M7-SW-01: createWindow singleton idempotency & deminiaturize verification")
    @MainActor
    func testSettingsWindowControllerIdempotencyAndDeminiaturize() {
        let controller = SettingsWindowController()

        // 1. First createWindow
        let win1 = controller.createWindow()
        #expect(controller.window === win1)

        // 2. Second createWindow returns exact same instance without recreating
        let win2 = controller.createWindow()
        #expect(win1 === win2)

        // 3. Miniaturized presentation
        win1.miniaturize(nil)
        controller.show()
        #expect(!win1.isMiniaturized)
        #expect(controller.isVisible)

        // 4. Repeated show / dismiss / close
        controller.dismiss()
        #expect(!controller.isVisible)
        controller.show()
        #expect(controller.isVisible)
        controller.close()
        #expect(!controller.isVisible)
    }

    // MARK: - 3. LaunchAtLogin Protocols, Statuses & Error Diagnostics

    @Test("ADV-M7-LAL-01: LaunchAtLoginStatus Codable roundtrip & hashability across all cases")
    func testLaunchAtLoginStatusCodableAndHashability() throws {
        let allStatuses: [LaunchAtLoginStatus] = [
            .enabled,
            .notRegistered,
            .requiresApproval,
            .notFound
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for st in allStatuses {
            let data = try encoder.encode(st)
            let decoded = try decoder.decode(LaunchAtLoginStatus.self, from: data)
            #expect(decoded == st)
            #expect(decoded.rawValue == st.rawValue)
        }

        let statusSet = Set(allStatuses)
        #expect(statusSet.count == 4)
    }

    @Test("ADV-M7-LAL-02: LaunchAtLoginError descriptions across all enum branches")
    func testLaunchAtLoginErrorDescriptions() {
        let errors: [LaunchAtLoginError] = [
            .requiresApproval,
            .notFound,
            .systemError("I/O error 14"),
            .registrationFailed("Authorization revoked"),
            .unsupportedOS
        ]

        for err in errors {
            guard let desc = err.errorDescription else {
                Issue.record("Error description was nil for \(err)")
                continue
            }
            #expect(!desc.isEmpty)
        }

        #expect(LaunchAtLoginError.requiresApproval.errorDescription?.contains("System Settings") == true)
        #expect(LaunchAtLoginError.notFound.errorDescription?.contains("bundle") == true)
        #expect(LaunchAtLoginError.systemError("I/O error 14").errorDescription?.contains("I/O error 14") == true)
        #expect(LaunchAtLoginError.registrationFailed("Auth revoked").errorDescription?.contains("Auth revoked") == true)
        #expect(LaunchAtLoginError.unsupportedOS.errorDescription?.contains("macOS 13") == true)
    }

    @Test("ADV-M7-LAL-03: SimulatedLaunchAtLoginService selective error injection & call count reset")
    func testSimulatedLaunchAtLoginServiceDetailedErrors() throws {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)

        // 1. shouldThrowOnEnable injection
        service.shouldThrowOnEnable = LaunchAtLoginError.requiresApproval
        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try service.enable()
        }
        #expect(service.enableCallCount == 1)
        #expect(!service.isEnabled)

        // Clear enable error
        service.shouldThrowOnEnable = nil
        try service.enable()
        #expect(service.enableCallCount == 2)
        #expect(service.isEnabled)

        // 2. shouldThrowOnDisable injection
        service.shouldThrowOnDisable = LaunchAtLoginError.systemError("Sandbox denial")
        #expect(throws: LaunchAtLoginError.systemError("Sandbox denial")) {
            try service.disable()
        }
        #expect(service.disableCallCount == 1)
        #expect(service.isEnabled)

        // Clear disable error
        service.shouldThrowOnDisable = nil
        try service.disable()
        #expect(service.disableCallCount == 2)
        #expect(!service.isEnabled)

        // 3. Reset call counts
        service.resetCallCounts()
        #expect(service.enableCallCount == 0)
        #expect(service.disableCallCount == 0)
    }

    @Test("ADV-M7-LAL-04: SystemLaunchAtLoginService status enum conformance smoke test")
    func testSystemLaunchAtLoginStatusCheck() {
        let systemService = SystemLaunchAtLoginService.shared
        let st = systemService.status
        #expect([LaunchAtLoginStatus.enabled, .notRegistered, .requiresApproval, .notFound].contains(st))
        #expect(systemService.isEnabled == (st == .enabled))
    }
}
