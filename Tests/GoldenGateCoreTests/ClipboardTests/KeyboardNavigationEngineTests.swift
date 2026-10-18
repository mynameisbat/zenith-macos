import Testing
import Foundation
import AppKit
@testable import GoldenGateCore

@MainActor
@Suite("KeyboardNavigationEngine Key Routing & State Machine Suite")
struct KeyboardNavigationEngineTests {

    private func makeEngineWithItems(count: Int = 10) -> (KeyboardNavigationEngine, ClipboardHistoryViewModel, MockPasteboardService, MockSoundService) {
        let mockPasteboard = MockPasteboardService()
        let mockSound = MockSoundService()
        var items: [ClipboardItem] = []
        for i in 1...count {
            items.append(ClipboardItem.text("Item \(i)"))
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
}
