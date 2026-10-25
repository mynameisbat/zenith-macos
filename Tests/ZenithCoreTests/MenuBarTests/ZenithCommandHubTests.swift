import Testing
import Foundation
@testable import ZenithCore

@Suite("Zenith Command Hub State & Action Hub Test Suite")
struct ZenithCommandHubTests {

    @Test("HUB-01: ZenithHubAction has 2 quick actions with correct titles, icons, and shortcuts")
    func testZenithHubActionsExclusivity() {
        let allActions = ZenithHubAction.allCases
        #expect(allActions.count == 2)
        #expect(allActions.contains(.area))
        #expect(allActions.contains(.screen))

        // Verify Area action metadata
        let area = ZenithHubAction.area
        #expect(area.rawValue == "area")
        #expect(area.title == "Capture Area")
        #expect(area.icon == "crop")
        #expect(area.shortcut == "⌘⇧2")

        // Verify Screen action metadata
        let screen = ZenithHubAction.screen
        #expect(screen.rawValue == "screen")
        #expect(screen.title == "Capture Screen")
        #expect(screen.icon == "macwindow")
        #expect(screen.shortcut == "⌘⇧1")
    }

    @Test("HUB-02: Action query matching filters actions accurately")
    func testActionQueryMatching() {
        // Empty or whitespace matches all
        #expect(ZenithHubAction.area.matches(query: ""))
        #expect(ZenithHubAction.screen.matches(query: "   "))

        // "Capture" matches area and screen
        #expect(ZenithHubAction.area.matches(query: "capture"))
        #expect(ZenithHubAction.screen.matches(query: "CAPTURE"))

        // Specific titles or synonyms
        #expect(ZenithHubAction.area.matches(query: "area"))
        #expect(ZenithHubAction.screen.matches(query: "screen"))

        // Non-existent search query matches nothing
        #expect(!ZenithHubAction.area.matches(query: "nonexistent_query_xyz"))
        #expect(!ZenithHubAction.screen.matches(query: "nonexistent_query_xyz"))
    }

    @Test("HUB-03: ZenithCommandHubState initial values are cleanly nil and empty")
    @MainActor
    func testInitialState() {
        let state = ZenithCommandHubState()
        #expect(state.searchText.isEmpty)
        #expect(state.hoveredActionId == nil)
        #expect(state.hoveredClipId == nil)
        #expect(state.hoveredFooterId == nil)
    }

    @Test("HUB-04: Action hover race condition protection prevents premature hover clearing")
    @MainActor
    func testActionHoverRaceConditionProtection() {
        let state = ZenithCommandHubState()

        state.setHoveredAction("area")
        #expect(state.hoveredActionId == "area")

        // When pointer moves to "screen", enter event fires first
        state.setHoveredAction("screen")
        #expect(state.hoveredActionId == "screen")

        // Exit event from "area" arrives after enter into "screen"
        state.clearHoveredAction(ifCurrent: "area")
        #expect(state.hoveredActionId == "screen", "Exiting a previous tile must not cancel current tile hover!")

        // Normal exit when pointer leaves the row entirely
        state.clearHoveredAction(ifCurrent: "screen")
        #expect(state.hoveredActionId == nil)
    }

    @Test("HUB-05: Clip row hover race condition protection")
    @MainActor
    func testClipHoverRaceConditionProtection() {
        let state = ZenithCommandHubState()
        let clip1 = UUID()
        let clip2 = UUID()

        state.setHoveredClip(clip1)
        #expect(state.hoveredClipId == clip1)

        // Enter clip2
        state.setHoveredClip(clip2)
        #expect(state.hoveredClipId == clip2)

        // Delayed exit from clip1
        state.clearHoveredClip(ifCurrent: clip1)
        #expect(state.hoveredClipId == clip2)

        // Normal exit from clip2
        state.clearHoveredClip(ifCurrent: clip2)
        #expect(state.hoveredClipId == nil)
    }

    @Test("HUB-06: Footer hover race condition protection and full reset")
    @MainActor
    func testFooterHoverRaceConditionProtectionAndReset() {
        let state = ZenithCommandHubState()

        state.setHoveredFooter("doh")
        #expect(state.hoveredFooterId == "doh")

        // Rapid transition to "cleaner"
        state.setHoveredFooter("cleaner")
        state.clearHoveredFooter(ifCurrent: "doh")
        #expect(state.hoveredFooterId == "cleaner")

        // Transition to "settings"
        state.setHoveredFooter("settings")
        #expect(state.hoveredFooterId == "settings")

        // Transition to "quit"
        state.setHoveredFooter("quit")
        state.clearHoveredFooter(ifCurrent: "settings")
        #expect(state.hoveredFooterId == "quit")

        // Full state reset
        state.setSearchText("swift")
        state.setHoveredAction("area")
        state.setHoveredClip(UUID())
        state.reset()
        #expect(state.searchText.isEmpty)
        #expect(state.hoveredActionId == nil)
        #expect(state.hoveredClipId == nil)
        #expect(state.hoveredFooterId == nil)
    }

    @Test("HUB-07: Multi-word queries and specialized action keywords")
    func testMultiWordQueryMatching() {
        // Multi-word distinct matching
        #expect(ZenithHubAction.screen.matches(query: "screen capture"))
        #expect(!ZenithHubAction.area.matches(query: "screen capture"))

        #expect(ZenithHubAction.area.matches(query: "area capture"))
        #expect(!ZenithHubAction.screen.matches(query: "area capture"))

        // Specialized synonyms
        #expect(ZenithHubAction.screen.matches(query: "fullscreen"))
        #expect(ZenithHubAction.area.matches(query: "snip"))
    }

    @Test("HUB-08: Presentation ID regenerates on reset for reliable focus acquisition")
    @MainActor
    func testPresentationIDRegeneration() {
        let state = ZenithCommandHubState()
        let initialID = state.presentationID

        state.reset()
        #expect(state.presentationID != initialID)
    }
}
