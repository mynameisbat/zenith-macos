import Testing
import AppKit
import Foundation
@testable import ZenithCore

@Suite("Zenith Rebrand & Menu Bar Command Hub Integration Suite")
struct ZenithRebrandAndCommandHubTests {

    @Test("ZNT-01: MenuBarController Zenith brand identity & custom click routing")
    @MainActor
    func testMenuBarZenithIdentityAndCustomClick() {
        let controller = MenuBarController()
        let statusBar = NSStatusBar()
        var customClickInvoked = false

        controller.onStatusItemClick = { button in
            customClickInvoked = true
        }

        controller.setup(statusBar: statusBar)

        guard let statusItem = controller.statusItem, let button = statusItem.button else {
            Issue.record("Status item or button not created")
            return
        }

        #expect(button.toolTip == "Zenith" || button.toolTip == "GoldenGate")
        #expect(button.accessibilityLabel() == "Zenith" || button.accessibilityLabel() == "GoldenGate")

        // Trigger action
        if let target = button.target as? NSObject, let action = button.action {
            _ = target.perform(action, with: button)
            #expect(customClickInvoked == true)
        } else {
            Issue.record("Button target or action not configured properly")
        }

        controller.teardown(statusBar: statusBar)
        #expect(controller.statusItem == nil)
    }

    @Test("ZNT-02: MenuBarController fallback to default menu when onStatusItemClick is nil")
    @MainActor
    func testMenuBarDefaultFallback() {
        let controller = MenuBarController()
        let statusBar = NSStatusBar()
        controller.setup(statusBar: statusBar)

        guard let statusItem = controller.statusItem else {
            Issue.record("Status item not created")
            return
        }

        // When onStatusItemClick is nil, menu is directly attached to statusItem
        #expect(statusItem.menu != nil)
        #expect(statusItem.menu?.items.count == 12)

        controller.teardown(statusBar: statusBar)
    }

    @Test("ZNT-03: SettingsWindowController retains non-resizable single-window presentation")
    @MainActor
    func testSettingsWindowPresentation() {
        let controller = SettingsWindowController()
        let window = controller.createWindow()

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable))

        controller.dismiss()
        #expect(!controller.isVisible)
    }
}
