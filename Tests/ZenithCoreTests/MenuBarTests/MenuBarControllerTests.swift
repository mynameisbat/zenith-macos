import Testing
import AppKit
import Foundation
@testable import ZenithCore

@Suite("MenuBarController Status Item & Dropdown Menu Suite")
struct MenuBarControllerTests {

    @Test("MB-01: Status Item Allocation and Template Icon Configuration")
    @MainActor
    func testStatusItemAllocation() {
        let controller = MenuBarController()
        let statusBar = NSStatusBar()
        controller.setup(statusBar: statusBar)

        guard let statusItem = controller.statusItem else {
            Issue.record("Status item was not allocated.")
            return
        }

        #expect(statusItem.length == NSStatusItem.variableLength)

        if let button = statusItem.button {
            #expect(button.image != nil)
            #expect(button.image?.isTemplate == true)
            #expect(button.toolTip == "Zenith" || button.toolTip == "GoldenGate")
            #expect(button.accessibilityLabel() == "Zenith" || button.accessibilityLabel() == "GoldenGate")
            #expect(button.accessibilityTitle() == "Zenith" || button.accessibilityTitle() == "GoldenGate")
        }

        controller.teardown(statusBar: statusBar)
        #expect(controller.statusItem == nil)
        #expect(controller.menu == nil)
    }

    @Test("MB-02: 12-Item Menu Hierarchy and Identifiers")
    @MainActor
    func testMenuHierarchy() {
        let controller = MenuBarController()
        let menu = controller.buildMenu()

        #expect(menu.items.count == 12)

        // Item 0: Clipboard History
        let item0 = menu.items[0]
        #expect(item0.title == "Clipboard History")
        #expect(item0.tag == MenuBarItemTag.clipboardHistory.rawValue)
        #expect(item0.identifier == MenuBarItemIdentifier.clipboardHistory)

        // Item 1: Capture Area
        let item1 = menu.items[1]
        #expect(item1.title == "Capture Area")
        #expect(item1.tag == MenuBarItemTag.captureArea.rawValue)
        #expect(item1.identifier == MenuBarItemIdentifier.captureArea)

        // Item 2: Capture Fullscreen
        let item2 = menu.items[2]
        #expect(item2.title == "Capture Fullscreen")
        #expect(item2.tag == MenuBarItemTag.captureFullscreen.rawValue)
        #expect(item2.identifier == MenuBarItemIdentifier.captureFullscreen)

        // Item 3: Separator
        #expect(menu.items[3].isSeparatorItem == true)

        // Item 4: Live Statistics
        let item4 = menu.items[4]
        #expect(item4.tag == MenuBarItemTag.liveStatistics.rawValue)
        #expect(item4.identifier == MenuBarItemIdentifier.liveStatistics)
        #expect(item4.isEnabled == false)

        // Item 5: Clear History
        let item5 = menu.items[5]
        #expect(item5.title == "Clear History")
        #expect(item5.tag == MenuBarItemTag.clearHistory.rawValue)
        #expect(item5.identifier == MenuBarItemIdentifier.clearHistory)

        // Item 6: Separator
        #expect(menu.items[6].isSeparatorItem == true)

        // Item 7: Privacy Shield Toggle
        let item7 = menu.items[7]
        #expect(item7.tag == MenuBarItemTag.privacyShieldToggle.rawValue)
        #expect(item7.identifier == MenuBarItemIdentifier.privacyShieldToggle)

        // Item 8: Privacy Shield Dynamic Telemetry Row
        let item8 = menu.items[8]
        #expect(item8.tag == MenuBarItemTag.privacyShieldStats.rawValue)
        #expect(item8.identifier == MenuBarItemIdentifier.privacyShieldStats)
        #expect(item8.isEnabled == false)

        // Item 9: Separator
        #expect(menu.items[9].isSeparatorItem == true)

        // Item 10: Preferences...
        let item10 = menu.items[10]
        #expect(item10.title == "Preferences...")
        #expect(item10.tag == MenuBarItemTag.preferences.rawValue)
        #expect(item10.identifier == MenuBarItemIdentifier.preferences)

        // Item 11: Quit Zenith
        let item11 = menu.items[11]
        #expect(item11.title == "Quit Zenith")
        #expect(item11.tag == MenuBarItemTag.quit.rawValue)
        #expect(item11.identifier == MenuBarItemIdentifier.quit)
    }

    @Test("MB-03: Key Equivalents and Modifier Masks")
    @MainActor
    func testKeyEquivalents() {
        let controller = MenuBarController()
        let menu = controller.buildMenu()

        // ⌘⇧V
        let clipboardItem = menu.items[0]
        #expect(clipboardItem.keyEquivalent == "v")
        #expect(clipboardItem.keyEquivalentModifierMask == [.command, .shift])

        // ⌘⇧2
        let captureAreaItem = menu.items[1]
        #expect(captureAreaItem.keyEquivalent == "2")
        #expect(captureAreaItem.keyEquivalentModifierMask == [.command, .shift])

        // ⌘⇧1
        let captureFullscreenItem = menu.items[2]
        #expect(captureFullscreenItem.keyEquivalent == "1")
        #expect(captureFullscreenItem.keyEquivalentModifierMask == [.command, .shift])

        // ⌘⌥P
        let privacyShieldItem = menu.items[7]
        #expect(privacyShieldItem.keyEquivalent == "p")
        #expect(privacyShieldItem.keyEquivalentModifierMask == [.command, .option])

        // ⌘,
        let preferencesItem = menu.items[10]
        #expect(preferencesItem.keyEquivalent == ",")
        #expect(preferencesItem.keyEquivalentModifierMask == [.command])

        // ⌘Q
        let quitItem = menu.items[11]
        #expect(quitItem.keyEquivalent == "q")
        #expect(quitItem.keyEquivalentModifierMask == [.command])
    }

    @Test("MB-04: Dynamic Statistics and Clear History Updates on menuWillOpen")
    @MainActor
    func testDynamicMenuUpdates() {
        let mockPasteboard = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPasteboard, initialItems: [])

        let controller = MenuBarController(clipboardStore: store)
        let menu = controller.buildMenu()

        // 1. Initial empty state
        controller.menuWillOpen(menu)
        let statsItem = menu.item(withTag: MenuBarItemTag.liveStatistics.rawValue)!
        let clearItem = menu.item(withTag: MenuBarItemTag.clearHistory.rawValue)!

        #expect(statsItem.title == "Clipboard: Empty")
        #expect(statsItem.isEnabled == false)
        #expect(clearItem.isEnabled == false)

        // 2. Add 1 item
        store.add(ClipboardItem.text("Item 1"))
        controller.menuWillOpen(menu)

        #expect(statsItem.title == "Clipboard: 1 item")
        #expect(statsItem.isEnabled == false)
        #expect(clearItem.isEnabled == true)

        // 3. Add 4 more items (total 5)
        for i in 2...5 {
            store.add(ClipboardItem.text("Item \(i)"))
        }
        controller.menuWillOpen(menu)

        #expect(statsItem.title == "Clipboard: 5 items")
        #expect(statsItem.isEnabled == false)
        #expect(clearItem.isEnabled == true)

        // 4. Clear unpinned history
        store.clear()
        controller.menuWillOpen(menu)

        #expect(statsItem.title == "Clipboard: Empty")
        #expect(clearItem.isEnabled == false)
    }

    @Test("MB-05: Action Routing Selectors and Handlers")
    @MainActor
    func testActionRouting() {
        let controller = MenuBarController()

        var clipboardInvoked = false
        var captureAreaInvoked = false
        var captureFullscreenInvoked = false
        var clearHistoryInvoked = false
        var privacyShieldInvoked = false
        var preferencesInvoked = false
        var quitInvoked = false

        controller.onClipboardHistory = { clipboardInvoked = true }
        controller.onCaptureArea = { captureAreaInvoked = true }
        controller.onCaptureFullscreen = { captureFullscreenInvoked = true }
        controller.onClearHistory = { clearHistoryInvoked = true }
        controller.onTogglePrivacyShield = { privacyShieldInvoked = true }
        controller.onShowPreferences = { preferencesInvoked = true }
        controller.onQuit = { quitInvoked = true }

        controller.clipboardHistoryAction(nil)
        #expect(clipboardInvoked == true)

        controller.captureAreaAction(nil)
        #expect(captureAreaInvoked == true)

        controller.captureFullscreenAction(nil)
        #expect(captureFullscreenInvoked == true)

        controller.clearHistoryAction(nil)
        #expect(clearHistoryInvoked == true)

        controller.privacyShieldToggleAction(nil)
        #expect(privacyShieldInvoked == true)

        controller.preferencesAction(nil)
        #expect(preferencesInvoked == true)

        controller.quitAction(nil)
        #expect(quitInvoked == true)
    }

    @Test("MB-06: Statistics Title Formatter Compliance")
    @MainActor
    func testStatisticsTitleFormatter() {
        let controller = MenuBarController()
        #expect(controller.statisticsTitle(for: 0) == "Clipboard: Empty")
        #expect(controller.statisticsTitle(for: 1) == "Clipboard: 1 item")
        #expect(controller.statisticsTitle(for: 2) == "Clipboard: 2 items")
        #expect(controller.statisticsTitle(for: 100) == "Clipboard: 100 items")
    }
}
