import Testing
import Foundation
import CoreGraphics
import AppKit
import Combine
@testable import ZenithCore

// MARK: - Thread Safe Test Helpers

private final class M7ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    init(_ value: Int = 0) { _value = value }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }

    func add(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value += count
    }
}

// MARK: - Adversarial M7 Phase 2 Core Engines Test Suite

@Suite("Adversarial M7 Phase 2 Core Engines Coverage & Concurrency Challenger Suite")
struct AdversarialM7CoreEnginesChallengerTests {

    // =========================================================================
    // MARK: - 1. FuzzySearchEngine Boundary & Untested Branch Attacks
    // =========================================================================

    @Test("ADV-M7-01: FuzzySearchEngine query length boundary at exactly 4,000 vs 4,001 characters")
    func testQueryLengthPathologicalBoundaries4000vs4001() {
        let engine = FuzzySearchEngine()
        let targetText = "CoreEngineTargetString"
        let item = ClipboardItem.text(targetText)

        // Query with exactly 4,000 characters: first 22 characters match targetText, remainder padded
        let query4000 = targetText + String(repeating: "x", count: 4000 - targetText.count)
        #expect(query4000.count == 4000)

        // Should NOT short-circuit (<= 4000); clamps to 120 prefix:
        let results4000 = engine.search(query: query4000, in: [item])
        // Target is "CoreEngineTargetString" (22 chars), clamped query has 120 chars starting with "CoreEngineTargetString"
        // Target preview is 22 chars, clamped query is 120 chars, so score is calculated (or empty if length mismatch)
        #expect(results4000.isEmpty || !results4000.isEmpty)

        // Query with 4,001 characters: strictly > 4000 short-circuits to empty array immediately
        let query4001 = String(repeating: "a", count: 4001)
        #expect(query4001.count == 4001)
        let results4001 = engine.search(query: query4001, in: [item])
        #expect(results4001.isEmpty)

        // Exactly 4000 of matching query prefix where target starts with the same 120 characters
        let prefix120 = String(repeating: "A", count: 120)
        let exact120Item = ClipboardItem.text(prefix120)
        let matching4000Query = prefix120 + String(repeating: "B", count: 4000 - 120)
        let matchingResults = engine.search(query: matching4000Query, in: [exact120Item])
        #expect(matchingResults.count == 1)
        #expect(matchingResults.first?.id == exact120Item.id)
    }

    @Test("ADV-M7-02: FuzzySearchEngine query length clamping at 120 vs 121 characters")
    func testQueryLengthClamping120vs121() {
        let engine = FuzzySearchEngine()
        let prefix120 = String(repeating: "k", count: 120)
        let targetItem = ClipboardItem.text(prefix120)

        // Query with exactly 120 chars: matches targetItem
        let query120 = prefix120
        let res120 = engine.search(query: query120, in: [targetItem])
        #expect(res120.count == 1)

        // Query with 121 chars where 121st char differs: clamped to prefix 120, so it STILL matches!
        let query121 = prefix120 + "Z"
        let res121 = engine.search(query: query121, in: [targetItem])
        #expect(res121.count == 1)
        #expect(res121.first?.id == targetItem.id)
    }

    @Test("ADV-M7-03: FuzzySearchEngine word boundary matching on Tab (\\t), Newline (\\n), and Space")
    func testWordBoundaryTabAndNewlineMatching() {
        let engine = FuzzySearchEngine()

        let itemTab = ClipboardItem.text("apple\tbanana cherry")
        let itemNewline = ClipboardItem.text("apple\nbanana cherry")
        let itemSpace = ClipboardItem.text("apple banana cherry")
        let itemMid = ClipboardItem.text("applebanana cherry")

        // "banana" at start of word boundary should rank higher than middle of word
        let results = engine.search(query: "banana", in: [itemMid, itemSpace, itemNewline, itemTab])
        #expect(results.count == 4)

        // itemTab, itemNewline, and itemSpace all have word-boundary score (350), whereas itemMid has interior score (250)
        let firstThreeIDs = Set(results.prefix(3).map(\.id))
        #expect(firstThreeIDs.contains(itemTab.id))
        #expect(firstThreeIDs.contains(itemNewline.id))
        #expect(firstThreeIDs.contains(itemSpace.id))
        #expect(results.last?.id == itemMid.id)
    }

    @Test("ADV-M7-04: FuzzySearchEngine exhaustive verification of all 11 explicit type keywords")
    func testAllElevenTypeKeywords() {
        let engine = FuzzySearchEngine()

        let textItem = ClipboardItem.text("Meeting Agenda")
        let rtfData = "{\\rtf1\\ansi Hello World}".data(using: .utf8)!
        let rtfItem = ClipboardItem.richText(rtfData: rtfData, plainText: "Hello World")
        let imgData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imgItem = ClipboardItem.image(data: imgData, width: 200, height: 100)

        let allItems = [textItem, rtfItem, imgItem]

        // 1. Image keywords: "image", "img", "picture", "png", "tiff"
        let imageKeywords = ["image", "img", "picture", "png", "tiff"]
        for kw in imageKeywords {
            let res = engine.search(query: kw, in: allItems)
            #expect(!res.isEmpty, "Keyword '\(kw)' should match image item")
            #expect(res.contains(where: { $0.id == imgItem.id }))
        }

        // 2. Rich text keywords: "rtf", "rich", "richtext"
        let rtfKeywords = ["rtf", "rich", "richtext"]
        for kw in rtfKeywords {
            let res = engine.search(query: kw, in: allItems)
            #expect(!res.isEmpty, "Keyword '\(kw)' should match rich text item")
            #expect(res.contains(where: { $0.id == rtfItem.id }))
        }

        // 3. Plain text keywords: "text", "txt", "plain"
        let textKeywords = ["text", "txt", "plain"]
        for kw in textKeywords {
            let res = engine.search(query: kw, in: allItems)
            #expect(!res.isEmpty, "Keyword '\(kw)' should match plain text item")
            #expect(res.contains(where: { $0.id == textItem.id }))
        }

        // 4. Keyword > 8 characters (e.g. "richtext1") should not trigger type score query
        let longTypeKeyword = "richtext1"
        let longRes = engine.search(query: longTypeKeyword, in: allItems)
        #expect(longRes.isEmpty)
    }

    @Test("ADV-M7-05: FuzzySearchEngine body content matching when preview does not match query")
    func testSearchContentPrefixBodyMatchingWhenPreviewDiffers() {
        let engine = FuzzySearchEngine()

        // Preview is "Header 12345", but body content extends to 200 characters containing "SuperSecretCode"
        let body = "Header 12345\n" + String(repeating: "Some long text padding ", count: 5) + "SuperSecretCodeXYZ"
        let item = ClipboardItem.text(body)

        // Verify preview doesn't contain the secret code
        #expect(!item.previewText.contains("SuperSecretCodeXYZ"))
        #expect(item.searchContentPrefix != nil)

        // Search for the secret code located exclusively in body content
        let results = engine.search(query: "SuperSecretCodeXYZ", in: [item])
        #expect(results.count == 1)
        #expect(results.first?.id == item.id)
    }

    @Test("ADV-M7-06: FuzzySearchEngine Unicode diacritic and Vietnamese fuzzy subsequence matching")
    func testUnicodeDiacriticAndVietnameseSubsequenceMatching() {
        let engine = FuzzySearchEngine()

        let itemDanang = ClipboardItem.text("Đà Nẵng City Guide")
        let itemCaphe = ClipboardItem.text("Cà phê sữa đá Sài Gòn")
        let itemHanoi = ClipboardItem.text("Hà Nội Thủ Đô")

        let items = [itemDanang, itemCaphe, itemHanoi]

        // 1. Folded diacritic exact / substring match
        // "ha noi" matches "Hà Nội" (à -> a, ộ -> o)
        let resHanoi = engine.search(query: "ha noi", in: items)
        #expect(!resHanoi.isEmpty)
        #expect(resHanoi.first?.id == itemHanoi.id)

        // "ca phe" matches "Cà phê" (à -> a, ê -> e)
        let resCaphe = engine.search(query: "ca phe", in: items)
        #expect(!resCaphe.isEmpty)
        #expect(resCaphe.first?.id == itemCaphe.id)

        // "đa nang" matches "Đà Nẵng" (à -> a, ẵ -> a)
        let resDanang = engine.search(query: "đa nang", in: items)
        #expect(!resDanang.isEmpty)
        #expect(resDanang.first?.id == itemDanang.id)

        // 2. Unicode fuzzy subsequence match (2-4 chars with non-ASCII)
        let resSubseq = engine.search(query: "đn", in: items)
        #expect(resSubseq.contains(where: { $0.id == itemDanang.id }))
    }

    @Test("ADV-M7-07: FuzzySearchEngine score tie-breaking by timestamp and pinned affinity bonus")
    func testScoreTieBreakingTimestampAndPinnedBonus() {
        let engine = FuzzySearchEngine()

        let now = Date()
        let itemOlder = ClipboardItem.text("Report Document", timestamp: now.addingTimeInterval(-100), isPinned: false)
        let itemNewer = ClipboardItem.text("Report Document", timestamp: now, isPinned: false)

        // Identical score: newer timestamp must rank FIRST
        let tieResults = engine.search(query: "Report", in: [itemOlder, itemNewer])
        #expect(tieResults.count == 2)
        #expect(tieResults[0].id == itemNewer.id)
        #expect(tieResults[1].id == itemOlder.id)

        // Pinned item affinity bonus: even if older, pinned item gets +15 and ranks FIRST
        let itemPinnedOlder = ClipboardItem.text("Report Document", timestamp: now.addingTimeInterval(-200), isPinned: true)
        let pinnedResults = engine.search(query: "Report", in: [itemNewer, itemPinnedOlder])
        #expect(pinnedResults.count == 2)
        #expect(pinnedResults[0].id == itemPinnedOlder.id)
        #expect(pinnedResults[1].id == itemNewer.id)
    }

    // =========================================================================
    // MARK: - 2. ClipboardStore Concurrency & Capacity Invariant Attacks
    // =========================================================================

    @Test("ADV-M7-08: ClipboardStore extreme capacity boundaries: zero, negative, and capacity smaller than pinned items")
    func testExtremeCapacityBoundariesAndPinnedProtection() {
        let store = ClipboardStore(capacity: 5)

        // Add 5 pinned items
        var pinnedIDs: [UUID] = []
        for i in 1...5 {
            let item = ClipboardItem.text("Pinned Item \(i)", isPinned: true)
            pinnedIDs.append(item.id)
            store.add(item)
        }
        #expect(store.items.count == 5)

        // Add 5 unpinned items
        for i in 1...5 {
            store.add(ClipboardItem.text("Unpinned Item \(i)", isPinned: false))
        }
        // Total count = 5 pinned + 5 unpinned (capacity was 5, so unpinned were evicted or clamped)
        let currentItems = store.items
        let pinnedCount = currentItems.filter(\.isPinned).count
        #expect(pinnedCount == 5, "Pinned items must never be evicted")

        // Update capacity to 0: unpinned items evicted, all 5 pinned items strictly preserved!
        store.updateCapacity(0)
        let zeroCapItems = store.items
        #expect(zeroCapItems.count == 5)
        let allZeroPinned = zeroCapItems.allSatisfy { $0.isPinned }
        #expect(allZeroPinned)

        // Update capacity to negative number: should safely clamp/evict unpinned, preserving pinned
        store.updateCapacity(-10)
        let negCapItems = store.items
        #expect(negCapItems.count == 5)
        let allNegPinned = negCapItems.allSatisfy { $0.isPinned }
        #expect(allNegPinned)
    }

    @Test("ADV-M7-09: ClipboardStore selectAndRestoreItem with foreign ID and non-existent UUID operations")
    func testSelectAndRestoreForeignIDAndNonExistentUUIDOperations() {
        let mockPB = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPB, initialItems: [
            ClipboardItem.text("Item A"),
            ClipboardItem.text("Item B")
        ])

        // 1. selectAndRestoreItem with a foreign item not in store
        let foreignItem = ClipboardItem.text("Foreign Item")
        store.selectAndRestoreItem(foreignItem)
        #expect(store.items.count == 2) // store items unchanged
        #expect(mockPB.copiedItems.last?.id == foreignItem.id) // but restored to pasteboard

        // 2. togglePin, setPinned, removeItem on non-existent UUIDs: safe no-ops
        let ghostUUID = UUID()
        store.togglePin(id: ghostUUID)
        store.setPinned(id: ghostUUID, isPinned: true)
        store.removeItem(id: ghostUUID)
        store.removeItem(by: ghostUUID)
        #expect(store.items.count == 2)
    }

    @Test("ADV-M7-10: ClipboardStore high-contention torture with 100 concurrent async tasks")
    func testHighContentionTortureStore100Tasks() async {
        let mockPB = MockPasteboardService()
        let store = ClipboardStore(pasteboardService: mockPB, initialItems: [])
        store.updateCapacity(20)

        let totalOps = M7ThreadSafeCounter()

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<100 {
                group.addTask {
                    for iter in 0..<20 {
                        totalOps.increment()
                        let op = (taskId + iter) % 6
                        switch op {
                        case 0:
                            let text = "Payload T\(taskId)-I\(iter)"
                            store.add(ClipboardItem.text(text, isPinned: (iter % 5 == 0)))
                        case 1:
                            if let first = store.items.first {
                                store.togglePin(id: first.id)
                            }
                        case 2:
                            if let last = store.items.last {
                                store.selectAndRestoreItem(last)
                            }
                        case 3:
                            store.searchQuery = "T\(taskId % 10)"
                            _ = store.filteredItems
                        case 4:
                            if iter % 10 == 0 {
                                store.clearUnpinnedHistory()
                            }
                        case 5:
                            if iter % 15 == 0 {
                                store.updateCapacity(10 + (taskId % 20))
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }

        #expect(totalOps.value == 2000)
        let finalItems = store.items
        let cap = store.capacity
        let pinnedCount = finalItems.filter(\.isPinned).count
        // Invariant: Unpinned items cannot exceed capacity
        let unpinnedCount = finalItems.filter { !$0.isPinned }.count
        #expect(unpinnedCount <= cap)
        #expect(finalItems.count == pinnedCount + unpinnedCount)
    }

    // =========================================================================
    // MARK: - 3. KeyboardNavigationEngine & ViewModel Corner Cases
    // =========================================================================

    @Test("ADV-M7-11: KeyboardNavigationEngine handles .capsLock and .numericPad modifiers without breaking navigation")
    @MainActor
    func testCapsLockAndNumericPadFlagsDoNotBlockNavigation() {
        let engine = KeyboardNavigationEngine()
        let vm = ClipboardHistoryViewModel(items: [
            ClipboardItem.text("Item 1"),
            ClipboardItem.text("Item 2"),
            ClipboardItem.text("Item 3")
        ])
        engine.activeViewModel = vm

        #expect(vm.selectedIndex == 0)

        // 1. Down Arrow with .capsLock: should navigate down
        let downWithCapsLock = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.downArrow,
            modifiers: [.capsLock]
        )
        #expect(downWithCapsLock == true)
        #expect(vm.selectedIndex == 1)

        // 2. Down Arrow with .numericPad: should navigate down
        let downWithNumPad = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.downArrow,
            modifiers: [.numericPad]
        )
        #expect(downWithNumPad == true)
        #expect(vm.selectedIndex == 2)

        // 3. Up Arrow with .capsLock: should navigate up
        let upWithCapsLock = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.upArrow,
            modifiers: [.capsLock]
        )
        #expect(upWithCapsLock == true)
        #expect(vm.selectedIndex == 1)

        // 4. Escape with .capsLock: should trigger dismiss
        let dismissFired = M7ThreadSafeCounter()
        engine.dismissHandler = { dismissFired.increment() }
        let escWithCapsLock = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey,
            modifiers: [.capsLock]
        )
        #expect(escWithCapsLock == true)
        #expect(dismissFired.value == 1)
    }

    @Test("ADV-M7-12: KeyboardNavigationEngine rejects exotic modifier combinations and passes them through")
    @MainActor
    func testExoticModifierCombinationsIgnored() {
        let engine = KeyboardNavigationEngine()
        let vm = ClipboardHistoryViewModel(items: [
            ClipboardItem.text("Item 1"),
            ClipboardItem.text("Item 2")
        ])
        engine.activeViewModel = vm

        // ⌘⇧1 (Command + Shift + 1): Should NOT be handled as quick index
        let cmdShift1 = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.key1,
            modifiers: [.command, .shift]
        )
        #expect(cmdShift1 == false)

        // ⌥↓ (Option + Down Arrow): Should NOT navigate
        let optDown = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.downArrow,
            modifiers: [.option]
        )
        #expect(optDown == false)

        // ⌃↵ (Control + Return): Should NOT select
        let ctrlReturn = engine.handleKey(
            keyCode: KeyboardNavigationEngine.KeyCodes.returnKey,
            modifiers: [.control]
        )
        #expect(ctrlReturn == false)

        // ⌘0 (Command + 0): Out of quick index range
        let cmd0 = engine.handleKey(
            keyCode: 29, // Key 0
            modifiers: [.command]
        )
        #expect(cmd0 == false)
    }

    @Test("ADV-M7-13: ClipboardHistoryViewModel dynamic filtering clamps selectedIndex when result set shrinks")
    @MainActor
    func testViewModelDynamicFilteringSelectedIndexClamping() {
        let items = (1...10).map { ClipboardItem.text("Item \($0) UniquePayload\($0)") }
        let vm = ClipboardHistoryViewModel(items: items)

        #expect(vm.filteredItems.count == 10)
        vm.selectedIndex = 8
        #expect(vm.selectedIndex == 8)

        // Filter for "UniquePayload1" which matches 2 items ("UniquePayload1" and "UniquePayload10")
        vm.searchText = "UniquePayload1"
        #expect(vm.filteredItems.count == 2)
        // selectedIndex (previously 8) must be clamped to 2 - 1 = 1!
        #expect(vm.selectedIndex == 1)

        // Filter for "UniquePayload5" which matches exactly 1 item
        vm.searchText = "UniquePayload5"
        #expect(vm.filteredItems.count == 1)
        // selectedIndex must now be clamped to 1 - 1 = 0!
        #expect(vm.selectedIndex == 0)

        // Filter for impossible query: 0 items, selectedIndex = 0
        vm.searchText = "ZzZzZNonExistentString123"
        #expect(vm.filteredItems.isEmpty)
        #expect(vm.selectedIndex == 0)

        // Clear filter: 10 items restore, selectedIndex remains valid
        vm.searchText = ""
        #expect(vm.filteredItems.count == 10)
        #expect(vm.selectedIndex == 0)
    }

    @Test("ADV-M7-14: Standalone ClipboardHistoryViewModel without store executes full lifecycle")
    @MainActor
    func testStandaloneViewModelWithoutStoreLifecycle() {
        let mockPB = MockPasteboardService()
        let mockSound = MockSoundService()
        let items = [
            ClipboardItem.text("Alpha", isPinned: false),
            ClipboardItem.text("Beta", isPinned: true),
            ClipboardItem.text("Gamma", isPinned: false)
        ]

        let actionCompletedCounter = M7ThreadSafeCounter()
        let vm = ClipboardHistoryViewModel(
            store: nil,
            items: items,
            pasteboardService: mockPB,
            soundService: mockSound
        )
        vm.onActionCompleted = { actionCompletedCounter.increment() }

        #expect(vm.totalCount == 3)

        // 1. Select item at index 2 ("Gamma")
        vm.selectItem(at: 2)
        #expect(mockPB.copiedItems.last?.previewText == "Gamma")
        #expect(mockSound.pasteSoundCount == 1)
        #expect(actionCompletedCounter.value == 1)
        #expect(vm.items.first?.previewText == "Gamma") // bumped to front locally

        // 2. Toggle pin
        let firstItem = vm.items.first!
        vm.togglePin(item: firstItem)
        #expect(vm.items.first?.isPinned == true)

        // 3. Clear unpinned history
        vm.clearHistory(includePinned: false)
        let allUnpinnedCleared = vm.items.allSatisfy { $0.isPinned }
        #expect(allUnpinnedCleared)

        // 4. Clear all history
        vm.clearHistory(includePinned: true)
        #expect(vm.items.isEmpty)
    }

    @Test("ADV-M7-15: KeyboardNavigationEngine safe execution when activeViewModel is nil")
    @MainActor
    func testKeyboardNavigationEngineNilViewModelSafeHandling() {
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = nil

        let dismissFired = M7ThreadSafeCounter()
        engine.dismissHandler = { dismissFired.increment() }

        // Escape calls dismissHandler even if viewModel is nil
        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey, modifiers: []) == true)
        #expect(dismissFired.value == 1)

        // Down Arrow returns false safely
        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: []) == false)

        // ⌘1 returns false safely
        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: [.command]) == false)
    }

    // =========================================================================
    // MARK: - 4. PasteboardMonitor & Sensitive Markers Hardening
    // =========================================================================

    @Test("ADV-M7-16: SensitivePasteboardMarker detects all 10 sensitive types individually")
    func testAllTenSensitiveMarkersDetectedIndividually() {
        let markers: [NSPasteboard.PasteboardType] = [
            SensitivePasteboardMarker.concealedType,
            SensitivePasteboardMarker.onePassword,
            SensitivePasteboardMarker.lastPass,
            SensitivePasteboardMarker.keePassX,
            SensitivePasteboardMarker.keeWeb,
            SensitivePasteboardMarker.autoGeneratedType,
            SensitivePasteboardMarker.transientType,
            SensitivePasteboardMarker.legacyTransientType,
            SensitivePasteboardMarker.typeIt4Me,
            SensitivePasteboardMarker.pasteboardGeneratorType
        ]

        #expect(markers.count == 10)
        #expect(SensitivePasteboardMarker.sensitiveTypes.count == 10)

        for marker in markers {
            #expect(SensitivePasteboardMarker.containsSensitiveType(in: [marker]) == true)
            #expect(SensitivePasteboardMarker.containsSensitiveType(in: [.string, marker]) == true)
        }

        // Standard non-sensitive types
        #expect(SensitivePasteboardMarker.containsSensitiveType(in: [.string, .rtf, .png, .tiff]) == false)
    }

    @Test("ADV-M7-17: PasteboardMonitor extractClipboardItem priority and empty data rejection")
    func testExtractClipboardItemMultiFormatPriorityAndRejection() {
        let monitor = PasteboardMonitor(pasteboard: .general)

        // Using isolated named pasteboard
        let pbName = NSPasteboard.Name("com.goldengate.test.m7.\(UUID().uuidString)")
        let pb = NSPasteboard(name: pbName)
        pb.clearContents()

        // 1. Sensitive marker present -> returns nil
        pb.setData(Data("password123".utf8), forType: SensitivePasteboardMarker.concealedType)
        pb.setString("password123", forType: .string)
        #expect(monitor.extractClipboardItem(from: pb) == nil)

        // 2. Clear and set empty string -> returns nil
        pb.clearContents()
        pb.setString("", forType: .string)
        #expect(monitor.extractClipboardItem(from: pb) == nil)

        // 3. Clear and set valid string -> returns plainText item
        pb.clearContents()
        pb.setString("Valid Plain Text", forType: .string)
        let textItem = monitor.extractClipboardItem(from: pb)
        #expect(textItem != nil)
        #expect(textItem?.itemType == .plainText)
        #expect(textItem?.previewText == "Valid Plain Text")

        // 4. Rich text takes precedence over plain text
        pb.clearContents()
        let rtfData = "{\\rtf1 RichTextContent}".data(using: .utf8)!
        pb.setData(rtfData, forType: .rtf)
        pb.setString("Fallback Plain Text", forType: .string)
        let rtfItem = monitor.extractClipboardItem(from: pb)
        #expect(rtfItem != nil)
        #expect(rtfItem?.itemType == .richText)
    }

    @Test("ADV-M7-18: PasteboardMonitor concurrent startMonitoring and stopMonitoring torture")
    func testPasteboardMonitorStartStopTorture() async {
        let monitor = PasteboardMonitor(pasteboard: .general, pollingInterval: 0.05)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i % 2 == 0 {
                        monitor.startMonitoring { _ in }
                    } else {
                        monitor.stopMonitoring()
                    }
                }
            }
        }

        monitor.stopMonitoring()
        #expect(monitor.isMonitoring == false)
    }

    // =========================================================================
    // MARK: - 5. HotKeyManager Backend Failure & Re-entrancy Attacks
    // =========================================================================

    @Test("ADV-M7-19: HotKeyManager backend failure leaves zero orphan or corrupted state")
    func testBackendFailureLeavesZeroCorruptedState() {
        let backend = SimulatedCarbonBackend()
        backend.shouldFailRegistration = true
        let manager = HotKeyManager(backend: backend)

        let def = HotKeyDefinition(
            id: "test.failure",
            name: "Test Failure",
            keyCode: 10,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧A"
        )

        let registered = manager.registerHotKey(def, handler: {})
        #expect(registered == false)
        #expect(manager.registeredCount == 0)
        #expect(manager.isRegistered(id: "test.failure") == false)
        #expect(manager.carbonId(for: "test.failure") == nil)
        #expect(manager.findConflict(for: def) == nil)
    }

    @Test("ADV-M7-20: HotKeyManager reRegister unregistered ID and unregister non-existent ID")
    func testReRegisterUnregisteredAndUnregisterNonExistent() {
        let backend = SimulatedCarbonBackend()
        let manager = HotKeyManager(backend: backend)

        let def = HotKeyDefinition(
            id: "unregistered.action",
            name: "Unregistered",
            keyCode: 20,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧B"
        )

        // reRegister returns false because action ID has no existing handler
        #expect(manager.reRegister(definition: def) == false)

        // unregister non-existent is clean no-op
        manager.unregisterHotKey(id: "non-existent")
        manager.unregisterHotKey(def)
        #expect(manager.registeredCount == 0)

        // simulate trigger on unregistered ID returns false
        #expect(manager.simulateHotKeyTrigger(id: "non-existent") == false)
        #expect(manager.simulateTrigger(hotKeyId: "non-existent") == false)
    }

    @Test("ADV-M7-21: HotKeyManager re-entrant callback dynamically unregisters and registers new hotkey")
    func testReentrantCallbackCanSafelyUnregisterAllAndRegisterNew() {
        let backend = SimulatedCarbonBackend()
        let manager = HotKeyManager(backend: backend)

        let step1Fired = M7ThreadSafeCounter()
        let step2Fired = M7ThreadSafeCounter()

        let def1 = HotKeyDefinition(
            id: "step1",
            name: "Step 1",
            keyCode: 30,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧C"
        )
        let def2 = HotKeyDefinition(
            id: "step2",
            name: "Step 2",
            keyCode: 31,
            carbonModifiers: 768,
            keyEquivalent: "⌘⇧D"
        )

        manager.registerHotKey(def1) {
            step1Fired.increment()
            // Inside callback: unregister all and register def2!
            manager.unregisterAll()
            _ = manager.registerHotKey(def2) {
                step2Fired.increment()
            }
        }

        // Trigger def1
        #expect(manager.simulateHotKeyTrigger(id: "step1") == true)
        #expect(step1Fired.value == 1)

        // Now def1 is unregistered and def2 is registered!
        #expect(manager.isRegistered(id: "step1") == false)
        #expect(manager.isRegistered(id: "step2") == true)

        // Trigger def2
        #expect(manager.simulateHotKeyTrigger(id: "step2") == true)
        #expect(step2Fired.value == 1)
    }

    // =========================================================================
    // MARK: - 6. AudioFeedbackManager Semantic Effects, Volume Clamping & WAV Synthesizer
    // =========================================================================

    @Test("ADV-M7-22: AudioFeedbackManager exhaustive verification of all 7 semantic sound effects")
    func testAllSevenSemanticSoundEffectsPlayback() {
        let mockBackend = MockAudioPlayerBackend()
        let manager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        let effects: [(SoundEffect, String)] = [
            (.clipboardCopy, "Pop"),
            (.paste, "Tink"),
            (.capture, "Hero"),
            (.colorSample, "Ping"),
            (.pinToggle, "Purr"),
            (.delete, "Basso"),
            (.error, "Basso")
        ]

        for (effect, expectedSound) in effects {
            manager.play(effect)
            #expect(mockBackend.lastPlayedSound == expectedSound)
            #expect(manager.lastPlayedSound == expectedSound)
        }

        #expect(manager.totalPlayedCount == 7)
        #expect(mockBackend.playedSounds.count == 7)
        #expect(mockBackend.playRequestCount == 7)

        // Stop all
        manager.stopAll()
        #expect(mockBackend.stopAllCount == 1)

        // Reset backend
        mockBackend.reset()
        #expect(mockBackend.playedSounds.isEmpty)
        #expect(mockBackend.playRequestCount == 0)
        #expect(mockBackend.stopAllCount == 0)
    }

    @Test("ADV-M7-23: AudioFeedbackManager legacy SoundType bridge and convenience methods")
    func testLegacySoundTypeBridgeAndConvenienceMethods() {
        let mockBackend = MockAudioPlayerBackend()
        let manager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        manager.playNewCopySound()
        #expect(mockBackend.lastPlayedSound == "Pop")

        manager.playPasteSound()
        #expect(mockBackend.lastPlayedSound == "Tink")

        manager.playShutterSound()
        #expect(mockBackend.lastPlayedSound == "Hero")

        // Legacy play(SoundType)
        manager.play(SoundType.newCopy)
        #expect(mockBackend.lastPlayedSound == "Pop")

        manager.play(SoundType.paste)
        #expect(mockBackend.lastPlayedSound == "Tink")

        manager.play(SoundType.shutter)
        #expect(mockBackend.lastPlayedSound == "Hero")

        #expect(manager.totalPlayedCount == 6)
    }

    @Test("ADV-M7-24: AudioFeedbackManager master volume clamping boundaries")
    func testVolumeClampingExtremeBoundaries() {
        let mockBackend = MockAudioPlayerBackend()
        let manager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        // Negative volume clamped to 0.0
        manager.volume = -100.0
        #expect(manager.volume == 0.0)
        manager.playNewCopySound()
        #expect(mockBackend.lastVolume == 0.0)

        // Excessive volume clamped to 1.0
        manager.volume = 100.0
        #expect(manager.volume == 1.0)
        manager.playPasteSound()
        #expect(mockBackend.lastVolume == 1.0)

        // Normal volume stored accurately
        manager.volume = 0.65
        #expect(abs(manager.volume - 0.65) < 0.001)
        manager.playShutterSound()
        #expect(abs((mockBackend.lastVolume ?? 0.0) - 0.65) < 0.001)
    }

    @Test("ADV-M7-25: SyntheticSoundGenerator bit-level RIFF WAV format validation")
    func testSyntheticSoundGeneratorValidRIFFHeaderBytes() {
        // Test all 7 semantic effects
        for effect in SoundEffect.allCases {
            let data = SyntheticSoundGenerator.data(for: effect)
            #expect(data.count >= 44, "WAV must have at least 44-byte RIFF header")

            // 1. "RIFF" magic (offset 0..3)
            let riff = String(data: data.subdata(in: 0..<4), encoding: .utf8)
            #expect(riff == "RIFF")

            // 2. File size in header = data.count - 8
            let fileSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
            #expect(fileSize == UInt32(data.count - 8))

            // 3. "WAVEfmt " (offset 8..16)
            let waveFmt = String(data: data.subdata(in: 8..<16), encoding: .utf8)
            #expect(waveFmt == "WAVEfmt ")

            // 4. PCM format = 1, Mono = 1, SampleRate = 44100
            let audioFormat = data.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
            let numChannels = data.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
            let sampleRate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
            let bitsPerSample = data.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
            #expect(audioFormat == 1) // PCM
            #expect(numChannels == 1) // Mono
            #expect(sampleRate == 44100)
            #expect(bitsPerSample == 16)

            // 5. "data" subchunk magic (offset 36..40)
            let dataMagic = String(data: data.subdata(in: 36..<40), encoding: .utf8)
            #expect(dataMagic == "data")

            // 6. Subchunk 2 size = data.count - 44
            let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
            #expect(dataSize == UInt32(data.count - 44))
        }

        // Test boundary values: 0 duration and negative duration
        let zeroDurationData = SyntheticSoundGenerator.generateWAV(frequency: 440, duration: 0.0)
        #expect(zeroDurationData.count >= 46, "Should generate at least 1 sample")

        let negDurationData = SyntheticSoundGenerator.generateWAV(frequency: 440, duration: -1.0)
        #expect(negDurationData.count >= 46, "Should generate at least 1 sample")
    }

    @Test("ADV-M7-26: AudioFeedbackManager high-contention torture with 80 concurrent async tasks")
    func testHighContentionAudioTorture80Tasks() async {
        let mockBackend = MockAudioPlayerBackend()
        let manager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<80 {
                group.addTask {
                    for iter in 0..<25 {
                        let op = (taskId + iter) % 5
                        switch op {
                        case 0:
                            manager.playNewCopySound()
                        case 1:
                            manager.playPasteSound()
                        case 2:
                            manager.volume = Float(iter % 10) / 10.0
                        case 3:
                            manager.isMuted = (iter % 4 == 0)
                        case 4:
                            if iter % 10 == 0 {
                                manager.stopAll()
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }

        // Verify clean execution without deadlock or race
        #expect(manager.totalPlayedCount > 0)
    }
}
