import Testing
import Foundation
@testable import ZenithCore

/// The island's tools: the dock under the open island, the Tools page, the pages the island grows into, and when the
/// Command Hub and the menu bar icon step aside because the island has it all.
@Suite("Island Tools Suite")
@MainActor
struct IslandToolsTests {
    private typealias S = ZenithIslandState

    // MARK: Tools

    @Test("IT-01: Every tool is in exactly one place, named in full, and every hub action and page can be reached")
    func testToolCatalogue() {
        let grouped = IslandTool.groups.flatMap(\.tools)
        #expect(Set(grouped).count == grouped.count, "a tool is in two groups")
        // Settings, Quit and the button that opens the page itself are deliberately outside the groups.
        #expect(Set(grouped) == Set(IslandTool.allCases).subtracting([.settings, .quit, .allTools]))
        #expect(IslandTool.groups.allSatisfy { !$0.title.isEmpty && (3...4).contains($0.tools.count) })
        #expect(Set(IslandTool.groups.map(\.id)).count == IslandTool.groups.count)

        #expect(Set(grouped.compactMap(\.hubAction)) == Set(ZenithHubAction.allCases))
        let reachable = Set(grouped.compactMap(\.page)).union([IslandTool.settings.page, IslandTool.allTools.page].compactMap { $0 })
        #expect(reachable == Set(IslandPage.allCases))

        for tool in IslandTool.allCases {
            #expect(!tool.title.isEmpty && !tool.detail.isEmpty && !tool.icon.isEmpty)
            // An action, a page, a switch or Quit: never two of them.
            let roles = [tool.hubAction != nil, tool.page != nil, tool.isToggle].filter { $0 }.count
            #expect(roles <= 1, "\(tool.rawValue) has \(roles) roles")
            #expect(tool.hotKeyId == tool.hubAction?.hotKeyId)
        }
        // The names are the full ones, not abbreviations.
        #expect(IslandTool.area.title == ZenithHubAction.area.title)
        #expect(IslandTool.uninstall.page == .cleaner)
        #expect(IslandTool.privacyShield.isToggle && IslandTool.keepAwake.isToggle && !IslandTool.clean.isToggle)
    }

    @Test("IT-02: The default dock has six tools and All Tools last, and never offers Quit")
    func testDefaultDock() {
        let dock = IslandDockLayout()
        #expect(dock.pinned == IslandDockLayout.defaultPinned)
        #expect(dock.tools.count == 7)
        #expect(Set(dock.tools).count == 7)
        #expect(dock.tools.last == .allTools)
        #expect(!dock.tools.contains(.quit))
        #expect(dock.isFull)
        #expect(IslandTool.allTools.page == .tools)
    }

    @Test("IT-03: The tools are not a tab: the tabs are what is going on, and an idle island shows the shelf")
    func testTabsAreWhatIsGoingOn() {
        #expect(S.availableTabs(hasTrack: true, hasShelfItems: true, showsWidgets: true, showsAIAgents: true)
                == [.nowPlaying, .widgets, .aiAgents, .shelf])
        #expect(S.availableTabs(hasTrack: false, hasShelfItems: false, showsWidgets: false) == [])
        #expect(S.resolvedTab(active: .nowPlaying, hasTrack: false, hasShelfItems: false, showsWidgets: false, isDropTargeted: false) == .shelf)

        let island = ZenithIslandState()
        island.showsToolsTab = true
        #expect(island.currentTab == .shelf)
    }

    @Test("IT-04: The dock switch is on by default, saved, and passed to the island")
    func testDockSetting() {
        let defaults = TestDefaults.make("IslandToolsTests_\(UUID().uuidString)")!
        let island = ZenithIslandState()
        #expect(!island.showsToolsTab)

        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(settings.showTools)
        #expect(island.showsToolsTab)

        settings.showTools = false
        #expect(!island.showsToolsTab)

        let otherIsland = ZenithIslandState()
        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: otherIsland)
        #expect(!reloaded.showTools)
        #expect(!otherIsland.showsToolsTab)

        reloaded.resetToDefaults()
        #expect(reloaded.showTools)
        #expect(otherIsland.showsToolsTab)
    }

    @Test("IT-05: The hub leaves its launch buttons to the island only while the island can show them")
    func testHubButtonPlacement() {
        typealias Hub = ZenithCommandHubState
        #expect(Hub.launchButtonsAreOnIsland(isEnabled: true, showsToolsTab: true, isHiddenForFullscreen: false))
        #expect(!Hub.launchButtonsAreOnIsland(isEnabled: false, showsToolsTab: true, isHiddenForFullscreen: false))
        #expect(!Hub.launchButtonsAreOnIsland(isEnabled: true, showsToolsTab: false, isHiddenForFullscreen: false))
        // A full-screen app has hidden the island: the hub is the only place left.
        #expect(!Hub.launchButtonsAreOnIsland(isEnabled: true, showsToolsTab: true, isHiddenForFullscreen: true))

        let hub = ZenithCommandHubState()
        let island = ZenithIslandState()
        #expect(!hub.launchButtonsOnIsland)
        #expect(hub.showsActionGrid(query: ""))

        island.showsToolsTab = true
        hub.refreshLaunchButtonPlacement(island: island)
        #expect(hub.launchButtonsOnIsland)
        #expect(!hub.showsActionGrid(query: ""))
        #expect(!hub.showsActionGrid(query: "   "))
        // Typing still finds an action, so Return can run it.
        #expect(hub.showsActionGrid(query: "clip"))

        island.showsToolsTab = false
        hub.refreshLaunchButtonPlacement(island: island)
        #expect(!hub.launchButtonsOnIsland)
        #expect(hub.showsActionGrid(query: ""))
    }

    // MARK: Sizes

    private func geometry(width: CGFloat = 1512, height: CGFloat = 982) -> ZenithIslandGeometry {
        ZenithIslandGeometry(screenFrame: CGRect(x: 0, y: 0, width: width, height: height), notch: nil)
    }

    @Test("IT-06: The open island is 380 × 96, taller by the dock, and a page gets its own size under the top edge")
    func testExpandedSizes() {
        let plain = geometry()
        #expect(plain.expandedSize(page: nil, showsDock: false) == CGSize(width: 380, height: 96))
        #expect(plain.expandedSize(page: nil, showsDock: true) == CGSize(width: 380, height: 96 + ZenithIslandGeometry.dockHeight))

        for page in IslandPage.allCases {
            let size = plain.expandedSize(page: page, showsDock: true)
            #expect(size.width == page.contentSize.width)
            #expect(size.height == page.contentSize.height + plain.pageHeaderHeight)
            // A page has no dock, so the switch does not change its size.
            #expect(plain.expandedSize(page: page, showsDock: false) == size)
            // Wide enough for a back button on one side of a notch and the title and close button on the other.
            #expect(size.width >= 420)

            let frame = plain.expandedFrame(page: page, showsDock: true)
            #expect(frame.midX == plain.notchRect.midX)
            #expect(frame.maxY == plain.screenFrame.maxY)
            #expect(plain.canvasFrame(page: page) == frame)
        }
        // With no page the window is as large as the island with its dock, and no larger.
        #expect(plain.canvasFrame(page: nil).size == plain.expandedSize(page: nil, showsDock: true))

        // Beside a notch the page's strip is the notch's own row.
        let notched = ZenithIslandGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notch: CGRect(x: 663, y: 950, width: 186, height: 32)
        )
        let expectedHeader: CGFloat = 36
        #expect(notched.pageHeaderHeight == expectedHeader)
        #expect(notched.hasNotch)
    }

    @Test("IT-07: A page never outgrows a small display")
    func testPagesFitSmallDisplays() {
        let small = geometry(width: 1024, height: 600)
        for page in IslandPage.allCases {
            let frame = small.expandedFrame(page: page, showsDock: true)
            #expect(frame.height <= 600 - 80)
            #expect(frame.width <= 1024 - 40)
            #expect(frame.minY >= 0 && frame.minX >= 0)
        }
    }

    // MARK: Pages

    @Test("IT-08: A page opens the island and stays when the pointer leaves; closing it returns to the island")
    func testPageLifecycle() async {
        let island = ZenithIslandState()
        island.hoverOpenDelay = 0
        island.showsToolsTab = true
        #expect(island.page == nil)
        #expect(island.showsNotices)

        island.openPage(.cleaner)
        #expect(island.page == .cleaner)
        #expect(island.backPage == nil)
        #expect(island.isExpanded)
        #expect(!island.showsNotices)

        // The pointer goes away (to a confirmation, to another window): the page is still there afterwards.
        island.onMouseLeave()
        try? await Task.sleep(nanoseconds: 450_000_000)
        #expect(island.isExpanded && island.page == .cleaner)

        // A notice does not take the page's place.
        island.triggerAlert(icon: "sparkles", title: "Freed 1 GB")
        island.showLevel(.volume, level: 0.5)
        #expect(island.activeAlert == nil)

        // Back: the island as it opens; with the pointer away it then closes as after any hover.
        island.closePage()
        #expect(island.page == nil)
        try? await Task.sleep(nanoseconds: 450_000_000)
        #expect(!island.isExpanded)

        // Closing the island closes the page with it.
        island.openPage(.settings)
        island.close()
        #expect(!island.isExpanded && island.page == nil)
    }

    @Test("IT-09: Back from a page opened on the Tools page returns there, then to the island")
    func testBackGoesThroughTheToolsPage() {
        let island = ZenithIslandState()
        island.openPage(.tools)
        #expect(island.page == .tools && island.backPage == nil)

        island.openPage(.ports)
        #expect(island.page == .ports && island.backPage == .tools)

        island.closePage()
        #expect(island.page == .tools && island.backPage == nil)
        #expect(island.isExpanded)

        island.closePage()
        #expect(island.page == nil)

        // Opened straight from the dock, a page goes back to the island, not through the Tools page.
        island.openPage(.cleaner)
        #expect(island.backPage == nil)
        // A page opened from another page (Ports from System) goes back to that page, and opening the page that
        // is already showing changes nothing.
        island.openPage(.system)
        #expect(island.backPage == .cleaner)
        island.openPage(.ports)
        island.openPage(.ports)
        #expect(island.page == .ports && island.backPage == .system)
        island.closePage()
        #expect(island.page == .system && island.backPage == nil)
        island.closePage()
        #expect(island.page == nil)
        // Closing everything forgets where back would have led.
        island.openPage(.tools)
        island.openPage(.system)
        island.close()
        #expect(island.page == nil && island.backPage == nil)
    }

    @Test("IT-10: A full-screen app takes the page away with the island, and no page opens while it is hidden")
    func testPagesAndFullscreen() {
        let island = ZenithIslandState()
        island.openPage(.tools)
        island.openPage(.system)
        island.setHiddenForFullscreen(true)
        #expect(island.page == nil && island.backPage == nil && !island.isExpanded)

        island.openPage(.ports)
        #expect(island.page == nil && !island.isExpanded)

        island.setHiddenForFullscreen(false)
        island.openPage(.ports)
        #expect(island.page == .ports)
    }

    // MARK: Menu bar icon and Settings

    @Test("IT-11: The menu bar icon is off by default and comes back when asked for or when the island has no tools")
    func testMenuBarIconRule() {
        #expect(!IslandWidgetSettings.needsMenuBarIcon(wantsIcon: false, showsTools: true))
        #expect(IslandWidgetSettings.needsMenuBarIcon(wantsIcon: true, showsTools: true))
        // Without the dock the icon is the only way left to the tools and the settings.
        #expect(IslandWidgetSettings.needsMenuBarIcon(wantsIcon: false, showsTools: false))

        let defaults = TestDefaults.make("IslandToolsTests_icon_\(UUID().uuidString)")!
        let settings = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(!settings.showMenuBarIcon && !settings.needsMenuBarIcon)
        settings.showTools = false
        #expect(settings.needsMenuBarIcon)
        settings.showTools = true
        settings.showMenuBarIcon = true
        #expect(settings.needsMenuBarIcon)

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(reloaded.showMenuBarIcon)
        reloaded.resetToDefaults()
        #expect(!reloaded.showMenuBarIcon && !reloaded.needsMenuBarIcon)
    }

    @Test("IT-12: Showing the settings asks the override first and opens no window when it takes over")
    func testSettingsPresentationOverride() {
        let controller = SettingsWindowController()
        var asked = 0
        controller.presentationOverride = {
            asked += 1
            return true
        }
        controller.show()
        #expect(asked == 1)
        #expect(controller.window == nil)
        #expect(!controller.isVisible)
    }

    @Test("IT-16: Turning Keep Awake on from the island offers the preset times, then until turned off")
    func testKeepAwakeQuickChoices() {
        let choices = KeepAwakeMode.quickChoices
        #expect(choices.last == .indefinite)
        #expect(choices.dropLast() == KeepAwakeMode.presetDurations.map { KeepAwakeMode.duration($0) }[...])
        #expect(choices.count == 5)
        #expect(choices.allSatisfy { !$0.title.isEmpty })
        // Short enough to stand side by side on the dock.
        #expect(choices.dropLast().allSatisfy { $0.title.count <= 6 })
    }

    // MARK: Arranging the dock

    @Test("IT-13: The dock takes up to six different tools that have a tile; All Tools is always last and stays")
    func testDockRules() {
        var dock = IslandDockLayout(pinned: [])
        #expect(dock.tools == [.allTools])

        let result1 = dock.pin(.ports)
        #expect(result1)
        let result2 = dock.pin(.ports)
        #expect(!result2, "a tool is on the dock once")
        // Quit must not sit one click from a capture button; Settings and All Tools have no tile either.
        let result3 = dock.pin(.quit)
        #expect(!result3)
        let result4 = dock.pin(.settings)
        #expect(!result4)
        let result5 = dock.pin(.allTools)
        #expect(!result5)
        #expect(!IslandDockLayout.canPin(.quit) && IslandDockLayout.canPin(.homebrew))

        for tool in [IslandTool.area, .screen, .record, .ocr, .clipboard] {
            let added = dock.pin(tool)
            #expect(added)
        }
        #expect(dock.isFull)
        let result6 = dock.pin(.boost)
        #expect(!result6, "a full dock takes no more")
        let result7 = dock.toggle(.boost)
        #expect(!result7)
        #expect(dock.pinned == [.ports, .area, .screen, .record, .ocr, .clipboard])

        let result8 = dock.toggle(.area)
        #expect(result8)
        #expect(!dock.contains(.area))
        let result9 = dock.toggle(.boost)
        #expect(result9)
        #expect(dock.pinned.last == .boost)
        dock.unpin(.allTools)
        #expect(dock.tools.last == .allTools)

        // Whatever a list holds, what comes out obeys the rules.
        let messy = IslandDockLayout(pinned: [.quit, .area, .area, .allTools, .screen, .record, .ocr, .clipboard, .cleaning, .boost])
        #expect(messy.pinned == [.area, .screen, .record, .ocr, .clipboard, .cleaning])
    }

    @Test("IT-14: Tools move one step, to a place, and by dragging, and never past the ends")
    func testDockReordering() {
        var dock = IslandDockLayout(pinned: [.area, .clipboard, .clean, .uninstall])
        #expect(!dock.canMove(.area, by: -1))
        #expect(dock.canMove(.area, by: 1))
        #expect(!dock.canMove(.uninstall, by: 1))
        #expect(!dock.canMove(.boost, by: 1), "not on the dock")

        dock.move(.area, by: -1)
        #expect(dock.pinned == [.area, .clipboard, .clean, .uninstall])
        dock.move(.area, by: 1)
        #expect(dock.pinned == [.clipboard, .area, .clean, .uninstall])
        dock.move(.uninstall, to: 0)
        #expect(dock.pinned == [.uninstall, .clipboard, .area, .clean])
        dock.move(.uninstall, to: 99)
        #expect(dock.pinned == [.clipboard, .area, .clean, .uninstall])
        dock.move(.boost, to: 0)
        #expect(dock.pinned.count == 4)

        // Dragging: half a slot changes places, and the ends hold.
        let slot: CGFloat = 40
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: 0, slotWidth: slot, count: 4) == 1)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: 19, slotWidth: slot, count: 4) == 1)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: 21, slotWidth: slot, count: 4) == 2)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: -30, slotWidth: slot, count: 4) == 0)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: 900, slotWidth: slot, count: 4) == 3)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 1, translation: -900, slotWidth: slot, count: 4) == 0)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 0, translation: .nan, slotWidth: slot, count: 4) == 0)
        #expect(IslandDockLayout.dragTargetIndex(startIndex: 0, translation: 50, slotWidth: 0, count: 4) == 0)

        // A whole drag, as the pointer reports it: the translation is from where the drag began and does not
        // depend on where the icon is now, so the icon changes slot once per slot crossed and never goes back
        // while the pointer keeps moving the same way.
        var dragged = IslandDockLayout(pinned: [.area, .clipboard, .clean, .uninstall])
        var visited: [Int] = []
        for step in stride(from: 0, through: 130, by: 5) {
            let target = IslandDockLayout.dragTargetIndex(startIndex: 0, translation: CGFloat(step), slotWidth: slot, count: 4)
            dragged.move(.area, to: target)
            let index = dragged.pinned.firstIndex(of: .area)!
            if visited.last != index { visited.append(index) }
        }
        #expect(visited == [0, 1, 2, 3])
        #expect(dragged.pinned == [.clipboard, .clean, .uninstall, .area])

        // The dragged icon is drawn under the pointer, and only a little past either end of the row.
        let ghost = { (translation: CGFloat) in
            IslandDockLayout.dragGhostOffset(startIndex: 1, translation: translation, slotWidth: slot, count: 4)
        }
        #expect(ghost(0) == 40)
        #expect(ghost(17) == 57)
        #expect(ghost(-25) == 15)
        #expect(ghost(500) == 128)
        #expect(ghost(-500) == -8)
    }

    @Test("IT-15: The arrangement is saved as it changes, survives a restart, and Reset brings the default back")
    func testDockIsSaved() {
        let defaults = TestDefaults.make("IslandToolsTests_dock_\(UUID().uuidString)")!
        let settings = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(settings.dockLayout == IslandDockLayout())
        #expect(defaults.object(forKey: IslandWidgetSettings.Keys.dockTools) == nil, "nothing is written until something changes")

        settings.dockLayout.unpin(.clean)
        settings.dockLayout.move(.keepAwake, to: 0)
        #expect(defaults.stringArray(forKey: IslandWidgetSettings.Keys.dockTools) == ["keepAwake", "area", "clipboard", "uninstall", "privacyShield"])

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(reloaded.dockLayout.pinned == [.keepAwake, .area, .clipboard, .uninstall, .privacyShield])

        // A dock emptied on purpose stays empty; it is not mistaken for "never saved".
        reloaded.dockLayout = IslandDockLayout(pinned: [])
        #expect(IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState()).dockLayout.tools == [.allTools])

        // A name from another version of Zenith is ignored, the rest is kept.
        defaults.set(["area", "teleport", "boost"], forKey: IslandWidgetSettings.Keys.dockTools)
        #expect(IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState()).dockLayout.pinned == [.area, .boost])

        reloaded.resetToDefaults()
        #expect(reloaded.dockLayout == IslandDockLayout())
        #expect(IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState()).dockLayout == IslandDockLayout())
    }
}
