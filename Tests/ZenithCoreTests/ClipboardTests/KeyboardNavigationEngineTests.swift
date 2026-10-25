import Testing
import Foundation
import AppKit
@testable import ZenithCore

@MainActor
@Suite("KeyboardNavigationEngine Key Routing & State Machine Suite")
struct KeyboardNavigationEngineTests {

    private func makeEngineWithItems(count: Int = 10) -> (KeyboardNavigationEngine, ClipboardHistoryViewModel, MockPasteboardService, MockSoundService) {
        let mockPasteboard = MockPasteboardService()
        let mockSound = MockSoundService()
        var items: [ClipboardItem] = []
        if count > 0 {
            for i in 1...count {
                items.append(ClipboardItem.text("Item \(i)"))
            }
        }

        let viewModel = ClipboardHistoryViewModel(
            items: items,
            pasteboardService: mockPasteboard,
            soundService: mockSound
        )

        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        return (engine, viewModel, mockPasteboard, mockSound)
    }

    @Test("Down arrow increments selectedIndex")
    func testDownArrowIncrementsSelectedIndex() {
        let (engine, viewModel, _, _) = makeEngineWithItems()
        #expect(viewModel.selectedIndex == 0)

        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(handled == true)
        #expect(viewModel.selectedIndex == 1)

        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(viewModel.selectedIndex == 2)
    }

    @Test("Up arrow decrements selectedIndex clamped to zero")
    func testUpArrowDecrementsClampedToZero() {
        let (engine, viewModel, _, _) = makeEngineWithItems()
        viewModel.selectedIndex = 2

        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        #expect(handled == true)
        #expect(viewModel.selectedIndex == 1)

        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        #expect(viewModel.selectedIndex == 0)

        // Further up arrow remains at 0
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Down arrow is clamped at list end")
    func testDownArrowClampedAtListEnd() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 3)
        viewModel.selectedIndex = 1

        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(viewModel.selectedIndex == 2)

        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(viewModel.selectedIndex == 2) // Clamped to count - 1
    }

    @Test("Return key copies selected item and triggers completion callback")
    func testReturnKeyTriggersSelection() {
        let (engine, viewModel, mockPasteboard, mockSound) = makeEngineWithItems()
        viewModel.selectedIndex = 3

        var actionCompleted = false
        viewModel.onActionCompleted = {
            actionCompleted = true
        }

        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [])
        #expect(handled == true)
        #expect(actionCompleted == true)
        #expect(mockPasteboard.copiedItems.count == 1)
        #expect(mockPasteboard.copiedItems.first?.previewText == "Item 4")
        #expect(mockSound.pasteSoundCount == 1)
    }

    @Test("Escape key triggers dismiss handler")
    func testEscapeKeyTriggersDismissal() {
        let (engine, viewModel, _, _) = makeEngineWithItems()
        var dismissed = false
        engine.dismissHandler = {
            dismissed = true
        }

        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey, modifiers: [])
        #expect(handled == true)
        #expect(dismissed == true)
        _ = viewModel
    }

    @Test("Command + number row keys (⌘1...⌘9) select exact index directly")
    func testCommandNumberRowQuickSelect() {
        let (engine, viewModel, mockPasteboard, mockSound) = makeEngineWithItems(count: 10)

        // ⌘1 (keyCode 18) -> Index 0 ("Item 1")
        let handled1 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: .command)
        #expect(handled1 == true)
        #expect(mockPasteboard.copiedItems.last?.previewText == "Item 1")

        // ⌘5 (keyCode 23) -> Index 4 ("Item 5")
        let handled5 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key5, modifiers: .command)
        #expect(handled5 == true)
        #expect(mockPasteboard.copiedItems.last?.previewText == "Item 5")

        // ⌘9 (keyCode 25) -> Index 8 ("Item 9")
        let handled9 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key9, modifiers: .command)
        #expect(handled9 == true)
        #expect(mockPasteboard.copiedItems.last?.previewText == "Item 9")

        #expect(mockSound.pasteSoundCount == 3)
        _ = viewModel
    }

    @Test("Command + number beyond bounds is swallowed safely without error")
    func testCommandNumberOutOfBoundsSwallowedSafely() {
        let (engine, viewModel, mockPasteboard, _) = makeEngineWithItems(count: 2) // Only 2 items

        // ⌘9 (keyCode 25) -> Index 8 is out of bounds
        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key9, modifiers: .command)
        #expect(handled == true) // Swallowed to prevent system beep
        #expect(mockPasteboard.copiedItems.isEmpty)
        _ = viewModel
    }

    @Test("Standard alphanumeric keys pass through for text search")
    func testStandardKeysPassThrough() {
        let (engine, viewModel, _, _) = makeEngineWithItems()

        // Key 'a' (keyCode 0) with zero modifiers
        let handledA = engine.handleKey(keyCode: 0, modifiers: [])
        #expect(handledA == false)

        // Spacebar (keyCode 49)
        let handledSpace = engine.handleKey(keyCode: 49, modifiers: [])
        #expect(handledSpace == false)
        _ = viewModel
    }

    @Test("Native macOS hardware arrow keys with .numericPad and .function flags navigate correctly")
    func testNativeHardwareArrowKeyNavigation() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 5)
        #expect(viewModel.selectedIndex == 0)

        // Native macOS Down Arrow event modifiers (rawValue: 10485760 -> .numericPad + .function)
        let downHandled = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.downArrow,
            modifiers: [.numericPad, .function]
        )
        #expect(downHandled == true)
        #expect(viewModel.selectedIndex == 1)

        // Native macOS Up Arrow event modifiers
        let upHandled = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.upArrow,
            modifiers: [.numericPad, .function]
        )
        #expect(upHandled == true)
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Keypad Enter (keyCode 76) copies item and triggers completion")
    func testKeypadEnterSelection() {
        let (engine, viewModel, mockPasteboard, mockSound) = makeEngineWithItems()
        viewModel.selectedIndex = 2

        var completed = false
        viewModel.onActionCompleted = { completed = true }

        let handled = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.keypadEnter,
            modifiers: [.numericPad, .function]
        )
        #expect(handled == true)
        #expect(completed == true)
        #expect(mockPasteboard.copiedItems.count == 1)
        #expect(mockSound.pasteSoundCount == 1)
    }

    @Test("Page navigation and Home/End keys jump accurately")
    func testPageAndBoundaryNavigation() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 20)
        #expect(viewModel.selectedIndex == 0)

        // Page Down (step 5)
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.pageDown, modifiers: [.function])
        #expect(viewModel.selectedIndex == 5)

        // End (jump to last item)
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.end, modifiers: [.function])
        #expect(viewModel.selectedIndex == 19)

        // Page Up (step 5)
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.pageUp, modifiers: [.function])
        #expect(viewModel.selectedIndex == 14)

        // Home (jump to first item)
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.home, modifiers: [.function])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Emacs shortcuts (Ctrl+N, Ctrl+P, Ctrl+J, Ctrl+K) navigate seamlessly")
    func testEmacsKeyNavigation() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 10)
        #expect(viewModel.selectedIndex == 0)

        // Ctrl+N -> Next
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyN, modifiers: [.control])
        #expect(viewModel.selectedIndex == 1)

        // Ctrl+J -> Next
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyJ, modifiers: [.control])
        #expect(viewModel.selectedIndex == 2)

        // Ctrl+P -> Prev
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.control])
        #expect(viewModel.selectedIndex == 1)

        // Ctrl+K -> Prev
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyK, modifiers: [.control])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Tab and Shift+Tab navigate forward and backward")
    func testTabNavigation() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 5)
        #expect(viewModel.selectedIndex == 0)

        // Tab -> Down
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.tab, modifiers: [])
        #expect(viewModel.selectedIndex == 1)

        // Shift+Tab -> Up
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.tab, modifiers: [.shift])
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Command + Down Arrow and Command + Up Arrow jump to End and Home")
    func testCommandArrowJumps() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 15)
        #expect(viewModel.selectedIndex == 0)

        // Command + Down Arrow -> Jump to end
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [.command, .function])
        #expect(viewModel.selectedIndex == 14)

        // Command + Up Arrow -> Jump to start
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [.command, .function])
        #expect(viewModel.selectedIndex == 0)
    }

    // MARK: - Deletion & Delete Shortcut Tests

    @Test("deleteItem and deleteSelectedItem remove items and maintain valid selectedIndex")
    func testDeleteOperations() {
        let (_, viewModel, _, _) = makeEngineWithItems(count: 3)
        #expect(viewModel.items.count == 3)
        #expect(viewModel.filteredItems.count == 3)

        // Select second item and delete
        viewModel.selectedIndex = 1
        let secondItem = viewModel.filteredItems[1]
        viewModel.deleteSelectedItem()

        #expect(viewModel.items.count == 2)
        #expect(!viewModel.items.contains(where: { $0.id == secondItem.id }))
        #expect(viewModel.selectedIndex == 1) // Clamped to new second item

        // Delete last item (index 1)
        viewModel.deleteSelectedItem()
        #expect(viewModel.items.count == 1)
        #expect(viewModel.selectedIndex == 0)

        // Delete remaining item
        viewModel.deleteSelectedItem()
        #expect(viewModel.items.isEmpty)
        #expect(viewModel.selectedIndex == 0)
    }

    @Test("Command + Delete (⌘⌫) and Forward Delete (⌦) trigger item deletion")
    func testCommandDeleteShortcut() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 4)
        #expect(viewModel.items.count == 4)

        // Command + Backspace (KeyCode 51)
        let handledCmdDelete = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.deleteKey, modifiers: [.command])
        #expect(handledCmdDelete == true)
        #expect(viewModel.items.count == 3)

        // Forward Delete (KeyCode 117)
        let handledForwardDelete = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.forwardDelete, modifiers: [])
        #expect(handledForwardDelete == true)
        #expect(viewModel.items.count == 2)
    }

    // MARK: - Pinning Shortcut Tests

    @Test("Command + P (⌘P) toggles pin status on selected item")
    func testCommandPTogglesPinStatus() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 3)
        #expect(viewModel.filteredItems[0].isPinned == false)

        // Press ⌘P to pin item at index 0
        let handled1 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled1 == true)
        #expect(viewModel.filteredItems[0].isPinned == true)

        // Press ⌘P again to unpin item at index 0
        let handled2 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled2 == true)
        #expect(viewModel.filteredItems[0].isPinned == false)

        // Move to index 1 and toggle pin
        viewModel.selectedIndex = 1
        #expect(viewModel.filteredItems[1].isPinned == false)
        let handled3 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled3 == true)
        #expect(viewModel.filteredItems[1].isPinned == true)
        #expect(viewModel.filteredItems[0].isPinned == false)
    }

    @Test("Command + P (⌘P) safe handling with empty list and store integration")
    func testCommandPSafeHandlingAndStoreIntegration() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 0)
        #expect(viewModel.filteredItems.isEmpty)

        // Should return true (consumed) safely without crash on empty list
        let handledEmpty = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handledEmpty == true)

        // Test with real store attached
        let store = ClipboardStore(capacity: 20)
        let itemA = ClipboardItem.text("Store Item A")
        let itemB = ClipboardItem.text("Store Item B")
        store.add(itemA)
        store.add(itemB)

        let storeViewModel = ClipboardHistoryViewModel(store: store)
        engine.activeViewModel = storeViewModel
        #expect(storeViewModel.filteredItems.count == 2)
        #expect(storeViewModel.filteredItems[0].isPinned == false)

        let handledStore = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handledStore == true)
        #expect(storeViewModel.filteredItems[0].isPinned == true)
        #expect(store.items[0].isPinned == true)

        let handledStoreUnpin = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handledStoreUnpin == true)
        #expect(storeViewModel.filteredItems[0].isPinned == false)
        #expect(store.items[0].isPinned == false)
    }

    @Test("togglePinSelectedItem safely guards against corrupted selectedIndex (-1, 999)")
    func testCorruptedSelectedIndexSafety() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 1)
        #expect(viewModel.filteredItems.count == 1)

        // Force out-of-bounds selectedIndex
        viewModel.selectedIndex = -1
        viewModel.togglePinSelectedItem()
        #expect(viewModel.filteredItems[0].isPinned == false)

        viewModel.selectedIndex = 999
        viewModel.togglePinSelectedItem()
        #expect(viewModel.filteredItems[0].isPinned == false)

        // Restore valid selectedIndex and verify normal toggle works
        viewModel.selectedIndex = 0
        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled == true)
        #expect(viewModel.filteredItems[0].isPinned == true)
    }

    @Test("Rapid 1,000 pin toggle cycles preserves exact toggle parity without latency spikes")
    func testRapidPinTogglingParity() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 1)
        #expect(viewModel.filteredItems[0].isPinned == false)

        let start = DispatchTime.now()
        let cycles = 1000
        for _ in 0..<cycles {
            let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
            #expect(handled == true)
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let totalMs = Double(elapsedNanos) / 1_000_000.0

        // 1000 even toggles should return to false
        #expect(viewModel.filteredItems[0].isPinned == false)
        #expect(totalMs < 500.0, "1,000 toggles took \(totalMs)ms, exceeding SLA")

        // 1 more toggle -> true
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(viewModel.filteredItems[0].isPinned == true)
    }

    @Test("⌘P with active search query targets filtered item at selectedIndex, not unfiltered index")
    func testPinningUnderActiveSearchQuery() {
        let store = ClipboardStore(capacity: 20)
        let item1 = ClipboardItem.text("Alpha target one")
        let item2 = ClipboardItem.text("Beta unrelated item")
        let item3 = ClipboardItem.text("Alpha target two")
        let item4 = ClipboardItem.text("Gamma unrelated item")

        store.add(item4)
        store.add(item3)
        store.add(item2)
        store.add(item1)

        let viewModel = ClipboardHistoryViewModel(store: store)
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        // Filter for "Alpha"
        viewModel.searchText = "Alpha"
        #expect(viewModel.filteredItems.count == 2)

        // Select first filtered item
        viewModel.selectedIndex = 0
        let targetItem = viewModel.filteredItems[0]

        // Press ⌘P
        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled == true)
        #expect(viewModel.filteredItems[0].id == targetItem.id)
        #expect(viewModel.filteredItems[0].isPinned == true)
        #expect(store.items.first(where: { $0.id == targetItem.id })?.isPinned == true)

        // Select second filtered item and pin it as well
        viewModel.selectedIndex = 1
        let secondTarget = viewModel.filteredItems[1]
        let handled2 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled2 == true)
        #expect(viewModel.filteredItems[1].isPinned == true)
        #expect(store.items.first(where: { $0.id == secondTarget.id })?.isPinned == true)

        // Clear search and verify pinning state persists across full list
        viewModel.searchText = ""
        #expect(viewModel.filteredItems.count == 4)
        #expect(viewModel.filteredItems.first(where: { $0.id == targetItem.id })?.isPinned == true)
        #expect(viewModel.filteredItems.first(where: { $0.id == secondTarget.id })?.isPinned == true)
    }

    @Test("Shortcut disambiguation: ⌘P vs Ctrl+P vs ⌘⇧P vs ⌘⌥P")
    func testShortcutDisambiguation() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 3)
        viewModel.selectedIndex = 1 // Start at Item 2

        // 1. Ctrl+P: Emacs navigation up (should decrement selectedIndex, NOT toggle pin)
        let handledCtrlP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.control])
        #expect(handledCtrlP == true)
        #expect(viewModel.selectedIndex == 0)
        #expect(viewModel.filteredItems[0].isPinned == false)
        #expect(viewModel.filteredItems[1].isPinned == false)

        // 2. ⌘⇧P: Command + Shift + P should be passed through (false) and NOT toggle pin
        let handledCmdShiftP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command, .shift])
        #expect(handledCmdShiftP == false)
        #expect(viewModel.filteredItems[0].isPinned == false)

        // 3. ⌘⌥P: Command + Option + P should be passed through (false)
        let handledCmdOptP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command, .option])
        #expect(handledCmdOptP == false)
        #expect(viewModel.filteredItems[0].isPinned == false)

        // 4. ⌘⌃P: Command + Control + P should be passed through (false)
        let handledCmdCtrlP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command, .control])
        #expect(handledCmdCtrlP == false)
        #expect(viewModel.filteredItems[0].isPinned == false)

        // 5. ⌘P with CapsLock flag: Should correctly toggle pin (CapsLock is stripped)
        let handledCmdCapsLockP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command, .capsLock])
        #expect(handledCmdCapsLockP == true)
        #expect(viewModel.filteredItems[0].isPinned == true)

        // 6. ⌘P with Function / NumericPad flags (hardware keyboard artifact)
        let handledCmdHardwareP = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command, .function, .numericPad])
        #expect(handledCmdHardwareP == true)
        #expect(viewModel.filteredItems[0].isPinned == false)
    }

    @Test("Pinned items are strictly protected against LRU/FIFO eviction")
    func testPinnedItemsSurviveEviction() {
        let store = ClipboardStore(capacity: 3)
        let item1 = ClipboardItem.text("First (to be pinned)")
        let item2 = ClipboardItem.text("Second")
        let item3 = ClipboardItem.text("Third")

        store.add(item1)
        store.add(item2)
        store.add(item3)

        let viewModel = ClipboardHistoryViewModel(store: store)
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        // Move to item1 (at index 2)
        viewModel.selectedIndex = 2
        #expect(viewModel.filteredItems[2].previewText == "First (to be pinned)")

        // Pin item1 via ⌘P
        let handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(handled == true)
        #expect(store.items.first(where: { $0.id == item1.id })?.isPinned == true)

        // Add 5 more items to overflow capacity (capacity = 3)
        for i in 4...8 {
            store.add(ClipboardItem.text("Overflow Item \(i)"))
        }

        viewModel.syncWithStore()

        // Pinned item1 MUST still be in store.items!
        let pinnedStillExists = store.items.contains(where: { $0.id == item1.id })
        #expect(pinnedStillExists == true, "Pinned item must survive store capacity eviction!")

        // Unpinned item2 must have been evicted
        let unpinnedEvicted = !store.items.contains(where: { $0.id == item2.id })
        #expect(unpinnedEvicted == true, "Unpinned old item must be evicted when capacity is reached")
    }

    @Test("clearUnpinnedHistory preserves ⌘P-pinned items and purges unpinned")
    func testClearUnpinnedHistoryPreservesPinned() {
        let store = ClipboardStore(capacity: 20)
        for i in 1...5 {
            store.add(ClipboardItem.text("Item \(i)"))
        }
        let viewModel = ClipboardHistoryViewModel(store: store)
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        #expect(viewModel.filteredItems.count == 5)

        // Pin Item at index 0 and index 2
        viewModel.selectedIndex = 0
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        viewModel.selectedIndex = 2
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])

        #expect(viewModel.filteredItems[0].isPinned == true)
        #expect(viewModel.filteredItems[2].isPinned == true)

        // Clear unpinned history via viewModel
        viewModel.clearHistory(includePinned: false)

        #expect(viewModel.filteredItems.count == 2)
        #expect(store.items.count == 2)
        #expect(viewModel.filteredItems.allSatisfy { $0.isPinned })
        #expect(store.items.allSatisfy { $0.isPinned })
    }

    @Test("Explicit user deletion (⌘⌫) deletes pinned item")
    func testExplicitDeletionOfPinnedItem() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 2)

        // Pin Item 1
        viewModel.selectedIndex = 0
        _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(viewModel.filteredItems[0].isPinned == true)

        // Explicitly delete selected item with ⌘⌫
        let deleteHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.deleteKey, modifiers: [.command])
        #expect(deleteHandled == true)

        #expect(viewModel.filteredItems.count == 1)
        #expect(viewModel.filteredItems[0].previewText == "Item 2")
    }

    @Test("Engine handleKey returns false when activeViewModel is nil")
    func testEngineWithoutViewModel() {
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = nil

        let pHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keyP, modifiers: [.command])
        #expect(pHandled == false)

        let downHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(downHandled == false)

        let enterHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [])
        #expect(enterHandled == false)
    }

    @Test("handleKeyEvent processes synthetic NSEvent with ⌘P properly")
    func testSyntheticNSEventHandling() {
        let (engine, viewModel, _, _) = makeEngineWithItems(count: 1)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: KeyboardNavigationEngine.KeyCodes.keyP
        )

        #expect(event != nil)
        if let event = event {
            let handled = engine.handleKeyEvent(event)
            #expect(handled == true)
            #expect(viewModel.filteredItems[0].isPinned == true)
        }
    }
}

