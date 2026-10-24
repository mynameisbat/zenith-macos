import Testing
import Foundation
@testable import GoldenGateCore

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

    private func textItem(_ text: String) -> ClipboardItem {
        ClipboardItem(itemType: .plainText, payload: .plainText(text), previewText: text, byteSize: text.utf8.count)
    }

    @Test("HUB-09: Arrow-key selection starts at the ends and wraps around")
    @MainActor
    func testKeyboardSelectionWrapping() {
        let state = ZenithCommandHubState()
        #expect(state.selectedEntryIndex == nil)

        state.moveSelection(by: 1, entryCount: 3)
        #expect(state.selectedEntryIndex == 0)
        state.moveSelection(by: 1, entryCount: 3)
        state.moveSelection(by: 1, entryCount: 3)
        #expect(state.selectedEntryIndex == 2)
        state.moveSelection(by: 1, entryCount: 3)
        #expect(state.selectedEntryIndex == 0)
        state.moveSelection(by: -1, entryCount: 3)
        #expect(state.selectedEntryIndex == 2)

        state.clearSelection()
        state.moveSelection(by: -1, entryCount: 3)
        #expect(state.selectedEntryIndex == 2)

        // A stale index past the end restarts from the edge; empty lists clear selection
        state.moveSelection(by: 1, entryCount: 2)
        #expect(state.selectedEntryIndex == 0)
        state.moveSelection(by: 1, entryCount: 0)
        #expect(state.selectedEntryIndex == nil)
    }

    @Test("HUB-10: Entries list actions first, then the visible clips")
    @MainActor
    func testEntriesOrdering() {
        let state = ZenithCommandHubState()
        let items = (1...6).map { textItem("clip \($0)") }

        let entries = state.entries(in: items)
        #expect(entries.count == ZenithHubAction.allCases.count + 4)
        #expect(entries.first == .action(.area))
        #expect(entries[ZenithHubAction.allCases.count] == .clip(items[0]))

        state.setSearchText("nonexistent_query_xyz")
        #expect(state.entries(in: items).isEmpty)
    }

    @Test("HUB-11: Changing the query or resetting clears selection and pending confirmation")
    @MainActor
    func testSelectionAndConfirmationReset() {
        let state = ZenithCommandHubState()
        state.moveSelection(by: 1, entryCount: 3)
        state.setSearchText("cap")
        #expect(state.selectedEntryIndex == nil)

        state.requestConfirmation(.optimizeSystem)
        #expect(state.pendingConfirmation == .optimizeSystem)
        state.cancelConfirmation()
        #expect(state.pendingConfirmation == nil)

        state.moveSelection(by: 1, entryCount: 3)
        state.requestConfirmation(.terminateProcess(pid: 42, name: "Xcode"))
        state.reset()
        #expect(state.selectedEntryIndex == nil)
        #expect(state.pendingConfirmation == nil)
    }

    @Test("HUB-12: Confirmation copy describes the action and flags destructive ones")
    func testConfirmationCopy() {
        let clean = ZenithHubConfirmation.cleanJunk(formattedSize: "1.2 GB")
        #expect(clean.title == "Clean 1.2 GB of junk?")
        #expect(clean.isDestructive)

        let kill = ZenithHubConfirmation.terminateProcess(pid: 42, name: "Xcode")
        #expect(kill.title == "Quit Xcode?")
        #expect(kill.message.contains("42"))
        #expect(kill.isDestructive)

        #expect(ZenithHubConfirmation.purgeZombies(count: 1).title == "Purge 1 zombie process?")
        #expect(ZenithHubConfirmation.purgeZombies(count: 3).title == "Purge 3 zombie processes?")
        #expect(!ZenithHubConfirmation.optimizeSystem.isDestructive)
    }
}
