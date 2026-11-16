import Testing
import Foundation
@testable import ZenithCore

/// How the island behaves around the rest of the desktop: stepping aside for a full-screen app, and its behaviour
/// switches. (The island no longer shows volume and brightness: macOS's own indicator does.)
@Suite("Island Behavior Suite")
struct IslandBehaviorTests {

    // MARK: - Full-screen Spaces

    private func display(_ identifier: String, currentType: Int) -> [String: Any] {
        ["Display Identifier": identifier, "Current Space": ["type": currentType, "id64": 1], "Spaces": []]
    }

    @Test("FSP-01: A display counts as full screen only when its own current Space is a full-screen one")
    func testFullscreenPerDisplay() {
        let displays = [display("AAAA", currentType: 4), display("BBBB", currentType: 0)]
        #expect(FullscreenSpaceProbe.isFullscreen(displayUUID: "AAAA", in: displays))
        #expect(!FullscreenSpaceProbe.isFullscreen(displayUUID: "BBBB", in: displays))
        #expect(!FullscreenSpaceProbe.isFullscreen(displayUUID: "CCCC", in: displays))     // unknown display
        #expect(!FullscreenSpaceProbe.isFullscreen(displayUUID: "AAAA", in: []))
    }

    @Test("FSP-02: With one shared set of Spaces, the single entry speaks for every display")
    func testSharedSpaces() {
        #expect(FullscreenSpaceProbe.isFullscreen(displayUUID: "AAAA", in: [display("Main", currentType: 4)]))
        #expect(!FullscreenSpaceProbe.isFullscreen(displayUUID: "AAAA", in: [display("Main", currentType: 0)]))
        #expect(FullscreenSpaceProbe.isFullscreen(displayUUID: nil, in: [display("XXXX", currentType: 4)]))
    }

    @Test("FSP-03: Hiding for full screen closes the island and blocks hover; coming back restores it")
    @MainActor
    func testHiddenIslandIgnoresHover() async {
        let island = ZenithIslandState()
        island.hoverOpenDelay = 0.01
        island.open()
        island.setHiddenForFullscreen(true)
        #expect(island.isHiddenForFullscreen && !island.isExpanded && !island.isHovered)

        island.onMouseEnter()
        await island.waitForHoverOpening()
        #expect(!island.isExpanded && !island.isHoverEmphasized)

        island.setHiddenForFullscreen(false)
        island.onMouseEnter()
        await island.waitForHoverOpening()
        #expect(island.isExpanded)
    }

    @Test("FSP-04: The behaviour switches are saved, reach the island, and reset to on")
    @MainActor
    func testBehaviourSettings() throws {
        let suite = "zenith.tests.island-behaviour.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let island = ZenithIslandState()

        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(settings.hideInFullscreen && settings.scrollGestures)

        settings.hideInFullscreen = false
        settings.scrollGestures = false
        #expect(!island.hidesInFullscreen && !island.allowsScrollGestures)

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(!reloaded.hideInFullscreen && !reloaded.scrollGestures)

        settings.resetToDefaults()
        #expect(island.hidesInFullscreen && island.allowsScrollGestures)
    }

    @Test("FSP-05: The hover delay is saved, kept within 0.1-1 s on a 0.05 s step, reaches the island and resets to 0.25 s")
    @MainActor
    func testHoverDelaySetting() throws {
        let suite = "zenith.tests.island-hover-delay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let island = ZenithIslandState()

        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(settings.hoverOpenDelay == 0.25 && island.hoverOpenDelay == 0.25)

        settings.hoverOpenDelay = 0.6
        #expect(island.hoverOpenDelay == 0.6)
        #expect(defaults.double(forKey: IslandWidgetSettings.Keys.hoverOpenDelay) == 0.6)
        #expect(IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState()).hoverOpenDelay == 0.6)

        settings.hoverOpenDelay = 5
        #expect(settings.hoverOpenDelay == 1.0 && island.hoverOpenDelay == 1.0)
        settings.hoverOpenDelay = 0
        #expect(settings.hoverOpenDelay == 0.1 && island.hoverOpenDelay == 0.1)
        settings.hoverOpenDelay = 0.33
        #expect(settings.hoverOpenDelay == 0.35)
        settings.hoverOpenDelay = 0.1 + 0.05      // 0.15000000000000002
        #expect(settings.hoverOpenDelay == 0.15)
        settings.hoverOpenDelay = .nan
        #expect(settings.hoverOpenDelay == 0.25)

        defaults.set(42.0, forKey: IslandWidgetSettings.Keys.hoverOpenDelay)    // written by hand or an older build
        #expect(IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState()).hoverOpenDelay == 1.0)

        settings.hoverOpenDelay = 0.8
        settings.resetToDefaults()
        #expect(settings.hoverOpenDelay == 0.25 && island.hoverOpenDelay == 0.25)
    }
}
