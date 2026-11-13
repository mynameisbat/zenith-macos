import Testing
import Foundation
@testable import ZenithCore

@Suite("Island Level HUD Suite")
struct IslandLevelHUDTests {

    @Test("LVL-01: A volume change shows a level alert, and the next one moves the same alert instead of replacing it")
    @MainActor
    func testVolumeUpdatesInPlace() {
        let island = ZenithIslandState()
        let service = IslandLevelHUDService(island: island, brightnessReader: { nil })

        service.volumeChanged(level: 0.5, isMuted: false)
        let first = island.activeAlert
        #expect(first?.levelKind == .volume && first?.level == 0.5)
        #expect(first?.icon == "speaker.wave.2.fill")

        service.volumeChanged(level: 0.9, isMuted: false)
        #expect(island.activeAlert?.id == first?.id)
        #expect(island.activeAlert?.level == 0.9)
        #expect(island.activeAlert?.icon == "speaker.wave.3.fill")
    }

    @Test("LVL-02: Mute draws an empty bar with the slashed speaker; out-of-range levels are clamped")
    @MainActor
    func testMuteAndClamping() {
        let island = ZenithIslandState()
        island.showLevel(.volume, level: 0.7, isMuted: true)
        #expect(island.activeAlert?.level == 0 && island.activeAlert?.icon == "speaker.slash.fill")

        island.showLevel(.volume, level: 1.4)
        #expect(island.activeAlert?.level == 1)
        island.showLevel(.volume, level: -1)
        #expect(island.activeAlert?.level == 0 && island.activeAlert?.icon == "speaker.slash.fill")
        island.showLevel(.volume, level: .nan)
        #expect(island.activeAlert?.level == 0)             // ignored: still the previous reading
    }

    @Test("LVL-03: A level replaces another kind of alert and gets a new identity")
    @MainActor
    func testLevelReplacesOtherAlerts() {
        let island = ZenithIslandState()
        island.triggerAlert(icon: "bolt.fill", title: "Charging")
        let charging = island.activeAlert
        island.showLevel(.brightness, level: 0.3)
        #expect(island.activeAlert?.levelKind == .brightness)
        #expect(island.activeAlert?.id != charging?.id)
        #expect(island.activeAlert?.icon == "sun.min.fill")

        island.showLevel(.volume, level: 0.2)
        #expect(island.activeAlert?.levelKind == .volume && island.activeAlert?.icon == "speaker.wave.1.fill")
    }

    @Test("LVL-04: Nothing shows when the setting is off, the island is off, or a full-screen app has the display")
    @MainActor
    func testLevelIsSuppressed() {
        let off = ZenithIslandState()
        off.showsLevelHUD = false
        off.showLevel(.volume, level: 0.5)
        #expect(off.activeAlert == nil)

        let disabled = ZenithIslandState()
        disabled.isEnabled = false
        disabled.showLevel(.volume, level: 0.5)
        #expect(disabled.activeAlert == nil)

        let hidden = ZenithIslandState()
        hidden.setHiddenForFullscreen(true)
        hidden.showLevel(.volume, level: 0.5)
        #expect(hidden.activeAlert == nil)
    }

    @Test("LVL-05: Only a brightness key going down reads the display; other keys and key-ups do not")
    @MainActor
    func testBrightnessKeys() async {
        let island = ZenithIslandState()
        let service = IslandLevelHUDService(island: island, brightnessReader: { 0.8 })
        func data(_ key: HardwareKey, down: Bool) -> Int { (key.rawValue << 16) | ((down ? 0x0A : 0x0B) << 8) }

        service.hardwareKeyEvent(subtype: 8, data1: data(.soundUp, down: true))
        service.hardwareKeyEvent(subtype: 8, data1: data(.brightnessUp, down: false))
        service.hardwareKeyEvent(subtype: 7, data1: data(.brightnessUp, down: true))
        await service.waitForBrightnessRead()
        #expect(island.activeAlert == nil)

        service.hardwareKeyEvent(subtype: 8, data1: data(.brightnessDown, down: true))
        await service.waitForBrightnessRead()
        #expect(island.activeAlert?.levelKind == .brightness && island.activeAlert?.level == 0.8)
        #expect(island.activeAlert?.icon == "sun.max.fill")
    }

    @Test("LVL-06: A display with no brightness to report shows nothing")
    @MainActor
    func testUnreadableBrightness() {
        let island = ZenithIslandState()
        IslandLevelHUDService(island: island, brightnessReader: { nil }).showBrightness()
        #expect(island.activeAlert == nil)
    }

    @Test("LVL-07: Hardware key events are decoded; unknown keys and subtypes are not")
    func testHardwareKeyParsing() {
        let down = HardwareKey.parse(subtype: 8, data1: (2 << 16) | (0x0A << 8))
        #expect(down?.key == .brightnessUp && down?.isDown == true)
        let up = HardwareKey.parse(subtype: 8, data1: (7 << 16) | (0x0B << 8))
        #expect(up?.key == .mute && up?.isDown == false)
        #expect(HardwareKey.parse(subtype: 8, data1: 16 << 16) == nil)          // play/pause is not ours
        #expect(HardwareKey.parse(subtype: 1, data1: 2 << 16) == nil)
    }

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

    @Test("FSP-04: The three behaviour switches are saved, reach the island, and reset to on")
    @MainActor
    func testBehaviourSettings() throws {
        let suite = "zenith.tests.island-behaviour.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let island = ZenithIslandState()

        let settings = IslandWidgetSettings(userDefaults: defaults, island: island)
        #expect(settings.showLevelHUD && settings.hideInFullscreen && settings.scrollGestures)

        settings.showLevelHUD = false
        settings.hideInFullscreen = false
        settings.scrollGestures = false
        #expect(!island.showsLevelHUD && !island.hidesInFullscreen && !island.allowsScrollGestures)

        let reloaded = IslandWidgetSettings(userDefaults: defaults, island: ZenithIslandState())
        #expect(!reloaded.showLevelHUD && !reloaded.hideInFullscreen && !reloaded.scrollGestures)

        settings.resetToDefaults()
        #expect(island.showsLevelHUD && island.hidesInFullscreen && island.allowsScrollGestures)
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
