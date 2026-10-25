import Foundation
import AppKit
import Combine

// MARK: - Clipboard History View Model

@MainActor
public final class ClipboardHistoryViewModel: ObservableObject {
    @Published public var searchText: String = "" {
        didSet {
            filterItems()
        }
    }

    @Published public var items: [ClipboardItem] = [] {
        didSet {
            filterItems()
        }
    }

    @Published public private(set) var filteredItems: [ClipboardItem] = []
    @Published public var selectedIndex: Int = 0

    public var totalCount: Int {
        items.count
    }

    public private(set) var store: ClipboardStore?
    private let pasteboardService: PasteboardServiceProtocol
    private let soundService: SoundServiceProtocol?
    private var cancellables = Set<AnyCancellable>()

    public var onActionCompleted: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public init(
        store: ClipboardStore? = nil,
        items: [ClipboardItem]? = nil,
        pasteboardService: PasteboardServiceProtocol = PasteboardMonitor.shared,
        soundService: SoundServiceProtocol? = nil
    ) {
        self.store = store
        self.pasteboardService = pasteboardService
        self.soundService = soundService
        self.items = items ?? store?.items ?? []
        filterItems()

        if let store = store {
            subscribe(to: store)
        }
    }

    // MARK: - Store Binding & Synchronization

    /// Attaches an authoritative ClipboardStore and establishes live subscription.
    public func attachStore(_ newStore: ClipboardStore) {
        self.store = newStore
        subscribe(to: newStore)
        syncWithStore()
    }

    /// Pulls current items from store and re-filters if items changed.
    public func syncWithStore() {
        guard let store = store else { return }
        if self.items != store.items {
            self.items = store.items
        }
    }

    private func subscribe(to store: ClipboardStore) {
        cancellables.removeAll()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, let store = self.store else { return }
                if self.items != store.items {
                    self.items = store.items
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Navigation

    public func navigateDown() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
    }

    public func navigateUp() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    public func navigatePageDown(step: Int = 5) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + step)
    }

    public func navigatePageUp(step: Int = 5) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - step)
    }

    public func navigateHome() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = 0
    }

    public func navigateEnd() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = filteredItems.count - 1
    }

    // MARK: - Selection & Paste Action

    public func selectItem(at index: Int) {
        guard index >= 0, index < filteredItems.count else { return }
        selectItem(filteredItems[index])
    }

    public func selectItem(item: ClipboardItem) {
        selectItem(item)
    }

    public func selectItem(_ item: ClipboardItem) {
        if let store = store {
            // 1. Authoritative store bumps item to index 0 with new timestamp and copies to pasteboard
            store.selectAndRestoreItem(item)
            // 2. Immediately reflect updated recency ordering locally
            self.items = store.items
        } else {
            // Standalone fallback: copy to pasteboard and bump locally
            pasteboardService.copyItemToPasteboard(item)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                let existing = items.remove(at: idx)
                let bumped = ClipboardItem(
                    id: existing.id,
                    timestamp: Date(),
                    itemType: existing.itemType,
                    payload: existing.payload,
                    previewText: existing.previewText,
                    byteSize: existing.byteSize,
                    isPinned: existing.isPinned
                )
                items.insert(bumped, at: 0)
                filterItems()
            }
        }

        // 3. Play acoustic tactile feedback
        soundService?.playPasteSound()

        // 4. Trigger completion callback
        onActionCompleted?()
    }

    // MARK: - Pinning

    public func togglePin(for item: ClipboardItem) {
        togglePin(item: item)
    }

    public func togglePin(item: ClipboardItem) {
        if let store = store {
            // 1. Authoritative store updates item pin state and protects from eviction
            store.togglePin(id: item.id)
            // 2. Immediately reflect in local items array
            self.items = store.items
        } else {
            // Standalone fallback
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].isPinned.toggle()
                filterItems()
            }
        }
    }

    public func togglePinSelectedItem() {
        guard !filteredItems.isEmpty, selectedIndex >= 0, selectedIndex < filteredItems.count else { return }
        togglePin(item: filteredItems[selectedIndex])
    }

    // MARK: - Deletion

    public func deleteItem(_ item: ClipboardItem) {
        deleteItem(item: item)
    }

    public func deleteItem(item: ClipboardItem) {
        if let store = store {
            store.removeItem(id: item.id)
            self.items = store.items
        } else {
            items.removeAll(where: { $0.id == item.id })
            filterItems()
        }
    }

    public func deleteSelectedItem() {
        guard !filteredItems.isEmpty, selectedIndex >= 0, selectedIndex < filteredItems.count else { return }
        deleteItem(item: filteredItems[selectedIndex])
    }

    // MARK: - Clear History

    public func clearHistory(includePinned: Bool = false) {
        if let store = store {
            store.clearHistory(includePinned: includePinned)
            self.items = store.items
        } else {
            if includePinned {
                items.removeAll()
            } else {
                items.removeAll(where: { !$0.isPinned })
            }
            filterItems()
        }
    }

    // MARK: - Filtering Logic

    public func filterItems() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredItems = items
        } else {
            filteredItems = FuzzySearchEngine().search(query: trimmed, in: items)
        }

        if filteredItems.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, selectedIndex), filteredItems.count - 1)
        }
    }
}

// MARK: - Keyboard Navigation Engine

@MainActor
public final class KeyboardNavigationEngine {
    public static let shared = KeyboardNavigationEngine()

    public weak var activeViewModel: ClipboardHistoryViewModel?
    public var dismissHandler: (() -> Void)?

    public init() {}

    /// Key code constants for macOS virtual keys
    public enum KeyCodes {
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let escapeKey: UInt16 = 53
        public static let deleteKey: UInt16 = 51 // Backspace / Delete (⌫)
        public static let forwardDelete: UInt16 = 117 // Forward Delete (⌦)
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126
        public static let pageDown: UInt16 = 121
        public static let pageUp: UInt16 = 116
        public static let home: UInt16 = 115
        public static let end: UInt16 = 119
        public static let tab: UInt16 = 48

        // Emacs / Terminal navigation shortcuts
        public static let keyN: UInt16 = 45
        public static let keyP: UInt16 = 35
        public static let keyJ: UInt16 = 38
        public static let keyK: UInt16 = 40

        // System & Menu shortcuts
        public static let keyQ: UInt16 = 12
        public static let keyW: UInt16 = 13
        public static let comma: UInt16 = 43

        // Number row keys 1...9
        public static let key1: UInt16 = 18
        public static let key2: UInt16 = 19
        public static let key3: UInt16 = 20
        public static let key4: UInt16 = 21
        public static let key5: UInt16 = 23
        public static let key6: UInt16 = 22
        public static let key7: UInt16 = 26
        public static let key8: UInt16 = 28
        public static let key9: UInt16 = 25
    }

    /// Evaluates key event. Returns true if consumed, false to pass through to search field.
    public func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return handleKey(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Evaluates raw keyCode and modifiers. Returns true if consumed, false otherwise.
    public func handleKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Note: macOS hardware keyboards set .numericPad and .function on arrow keys, home, end, pageUp, pageDown
        let relevantModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])

        // 1. Check Escape or ⌘W dismissal
        if relevantModifiers.isEmpty && keyCode == KeyCodes.escapeKey {
            if let dismiss = dismissHandler {
                dismiss()
            } else {
                activeViewModel?.onDismiss?()
            }
            return true
        }

        if relevantModifiers == [.command] && keyCode == KeyCodes.keyW {
            if let dismiss = dismissHandler {
                dismiss()
            } else {
                activeViewModel?.onDismiss?()
            }
            return true
        }

        // 1a. Check ⌘Q: terminate application immediately
        if relevantModifiers == [.command] && keyCode == KeyCodes.keyQ {
            NSApp.terminate(nil)
            return true
        }

        // 1b. Check ⌘,: open Settings window
        if relevantModifiers == [.command] && keyCode == KeyCodes.comma {
            if let dismiss = dismissHandler {
                dismiss()
            } else {
                activeViewModel?.onDismiss?()
            }
            SettingsWindowController.shared.show()
            return true
        }

        guard let viewModel = activeViewModel else { return false }

        // 2. Check Command + Number (⌘1...⌘9)
        if modifiers.contains(.command) && !modifiers.contains(.shift) && !modifiers.contains(.control) && !modifiers.contains(.option) {
            if let quickIdx = quickIndex(for: keyCode) {
                if quickIdx < viewModel.filteredItems.count {
                    viewModel.selectItem(at: quickIdx)
                }
                return true // Swallow key even if index out of bounds to avoid error beeps
            }
        }

        // 3. Command + Backspace (⌘⌫) or Command + Forward Delete: Delete selected item
        if relevantModifiers == [.command] && (keyCode == KeyCodes.deleteKey || keyCode == KeyCodes.forwardDelete) {
            viewModel.deleteSelectedItem()
            return true
        }

        // 3a. Command + P: Toggle pin status on selected item
        if relevantModifiers == [.command] && keyCode == KeyCodes.keyP {
            viewModel.togglePinSelectedItem()
            return true
        }

        // 3b. Forward Delete (⌦) without modifiers
        if relevantModifiers.isEmpty && keyCode == KeyCodes.forwardDelete {
            viewModel.deleteSelectedItem()
            return true
        }

        // 4. Command + Up/Down/Home/End: Jump to top/bottom
        if relevantModifiers == [.command] {
            switch keyCode {
            case KeyCodes.upArrow, KeyCodes.home:
                viewModel.navigateHome()
                return true
            case KeyCodes.downArrow, KeyCodes.end:
                viewModel.navigateEnd()
                return true
            default:
                break
            }
        }

        // 4. Emacs / Terminal navigation shortcuts: Ctrl+N / Ctrl+J (down), Ctrl+P / Ctrl+K (up)
        if relevantModifiers == [.control] {
            switch keyCode {
            case KeyCodes.keyN, KeyCodes.keyJ:
                viewModel.navigateDown()
                return true
            case KeyCodes.keyP, KeyCodes.keyK:
                viewModel.navigateUp()
                return true
            default:
                break
            }
        }

        // 5. Tab navigation: Tab (down), Shift+Tab (up)
        if keyCode == KeyCodes.tab {
            if relevantModifiers.isEmpty {
                viewModel.navigateDown()
                return true
            } else if relevantModifiers == [.shift] {
                viewModel.navigateUp()
                return true
            }
        }

        // 6. Check Navigation & Selection (Zero modifiers)
        if relevantModifiers.isEmpty {
            switch keyCode {
            case KeyCodes.downArrow:
                viewModel.navigateDown()
                return true

            case KeyCodes.upArrow:
                viewModel.navigateUp()
                return true

            case KeyCodes.pageDown:
                viewModel.navigatePageDown()
                return true

            case KeyCodes.pageUp:
                viewModel.navigatePageUp()
                return true

            case KeyCodes.home:
                viewModel.navigateHome()
                return true

            case KeyCodes.end:
                viewModel.navigateEnd()
                return true

            case KeyCodes.returnKey, KeyCodes.keypadEnter:
                if !viewModel.filteredItems.isEmpty {
                    viewModel.selectItem(at: viewModel.selectedIndex)
                }
                return true

            case KeyCodes.escapeKey:
                if let dismiss = dismissHandler {
                    dismiss()
                } else {
                    viewModel.onDismiss?()
                }
                return true

            default:
                break
            }
        }

        // Pass through to search text field
        return false
    }

    public func quickIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case KeyCodes.key1: return 0
        case KeyCodes.key2: return 1
        case KeyCodes.key3: return 2
        case KeyCodes.key4: return 3
        case KeyCodes.key5: return 4
        case KeyCodes.key6: return 5
        case KeyCodes.key7: return 6
        case KeyCodes.key8: return 7
        case KeyCodes.key9: return 8
        default: return nil
        }
    }
}
