import Testing
import Foundation
@testable import GoldenGateCore

@Suite("ClipboardStore Core Functionality & Thread Safety")
struct ClipboardStoreTests {

    // MARK: - Ingestion
    @Test("Ingests plain text item with accurate byte size and preview")
    func testIngestPlainText() {
        let store = ClipboardStore(capacity: 20)
        let text = "Hello, Golden Gate Desktop Utility!"
        let item = ClipboardItem.text(text)

        store.add(item)

        #expect(store.items.count == 1)
        #expect(store.items.first?.itemType == .plainText)
        #expect(store.items.first?.previewText == text)
        #expect(store.items.first?.byteSize == text.utf8.count)
        #expect(store.items.first?.isPinned == false)
    }

    @Test("Ingests rich text item extracting plain text for preview and search")
    func testIngestRichText() {
        let store = ClipboardStore(capacity: 20)
        let rtfData = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Courier;}}\\f0\\fs24 Rich Document Text}".data(using: .utf8)!
        let plainText = "Rich Document Text"
        let item = ClipboardItem.richText(rtfData: rtfData, plainText: plainText)

        store.add(item)

        #expect(store.items.count == 1)
        #expect(store.items.first?.itemType == .richText)
        #expect(store.items.first?.previewText == plainText)
        #expect(store.items.first?.plainTextContent == plainText)
    }

    @Test("Ingests image item recording dimensions and raw data")
    func testIngestImageItem() {
        let store = ClipboardStore(capacity: 20)
        let dummyData = Data(repeating: 0xFF, count: 1024)
        let item = ClipboardItem.image(data: dummyData, width: 800, height: 600)

        store.add(item)

        #expect(store.items.count == 1)
        #expect(store.items.first?.itemType == .image)
        #expect(store.items.first?.previewText == "Image (800 × 600)")
        #expect(store.items.first?.byteSize == 1024)
    }

    // MARK: - Deduplication & Ordering
    @Test("Consecutive identical items do not duplicate and update timestamp")
    func testConsecutiveDeduplication() async throws {
        let store = ClipboardStore(capacity: 20)
        let item1 = ClipboardItem.text("Identical Text")
        store.add(item1)
        let initialTimestamp = store.items.first!.timestamp

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        let item2 = ClipboardItem.text("Identical Text")
        store.add(item2)

        #expect(store.items.count == 1)
        #expect(store.items.first!.timestamp > initialTimestamp)
    }

    @Test("Non-consecutive duplicate item promotes existing entry to front")
    func testNonConsecutiveDuplicatePromotesToFront() {
        let store = ClipboardStore(capacity: 20)
        store.add(ClipboardItem.text("Item A"))
        store.add(ClipboardItem.text("Item B"))
        store.add(ClipboardItem.text("Item C"))

        #expect(store.items.map(\.previewText) == ["Item C", "Item B", "Item A"])

        // Re-add Item A
        store.add(ClipboardItem.text("Item A"))

        #expect(store.items.count == 3)
        #expect(store.items.map(\.previewText) == ["Item A", "Item C", "Item B"])
    }

    // MARK: - Pin State & Toggling
    @Test("Pin toggle updates item and preserves pinned status on re-copy")
    func testPinTogglePreservesOnRecopy() {
        let store = ClipboardStore(capacity: 20)
        let item = ClipboardItem.text("Pin Me")
        store.add(item)

        let itemId = store.items.first!.id
        store.togglePin(id: itemId)
        #expect(store.items.first?.isPinned == true)

        // Add other items
        store.add(ClipboardItem.text("Other 1"))
        store.add(ClipboardItem.text("Other 2"))

        // Re-add "Pin Me"
        store.add(ClipboardItem.text("Pin Me"))

        #expect(store.items.first?.previewText == "Pin Me")
        #expect(store.items.first?.isPinned == true)
    }

    // MARK: - Clear History
    @Test("clearUnpinned removes all unpinned items while preserving pinned items")
    func testClearUnpinnedPreservesPinned() {
        let store = ClipboardStore(capacity: 20)
        for i in 1...6 {
            let item = ClipboardItem.text("Item \(i)")
            store.add(item)
            if i == 2 || i == 5 {
                store.togglePin(id: store.items.first!.id)
            }
        }

        #expect(store.items.count == 6)
        #expect(store.items.filter(\.isPinned).count == 2)

        store.clearUnpinnedHistory()

        #expect(store.items.count == 2)
        #expect(store.items.allSatisfy { $0.isPinned })
        #expect(store.items.map(\.previewText).sorted() == ["Item 2", "Item 5"])
    }

    @Test("clearAllHistory removes all items including pinned")
    func testClearAllHistoryRemovesEverything() {
        let store = ClipboardStore(capacity: 20)
        let item1 = ClipboardItem.text("Item 1")
        store.add(item1)
        store.togglePin(id: item1.id)
        store.add(ClipboardItem.text("Item 2"))

        store.clearAllHistory()

        #expect(store.items.isEmpty)
    }

    // MARK: - Edge Cases
    @Test("Empty and whitespace-only text items are normalized safely without crash")
    func testEmptyAndWhitespaceStrings() {
        let store = ClipboardStore(capacity: 20)
        store.add(ClipboardItem.text(""))
        #expect(store.items.first?.previewText == "(Empty Text)")

        store.add(ClipboardItem.text("   \n\t  \r  "))
        #expect(store.items.first?.previewText == "(Empty Text)")
    }

    @Test("Huge 10MB text payload ingests cleanly with clamped preview")
    func testHuge10MBTextPayload() throws {
        let store = ClipboardStore(capacity: 20)
        let huge10MB = String(repeating: "GoldenGate-Desktop-Utility-macOS-", count: 320_000)

        let item = ClipboardItem.text(huge10MB)
        store.add(item)

        #expect(store.items.count == 1)
        let first = try #require(store.items.first)
        #expect(first.byteSize > 10_000_000)
        #expect(first.previewText.count <= 103)
        #expect(first.previewText.hasSuffix("..."))
    }

    @Test("Large 4000x3000 image payload stores dimensions without crashing")
    func testLargeImagePayload() {
        let store = ClipboardStore(capacity: 20)
        let data48MB = Data(repeating: 0x7F, count: 4_000 * 3_000 * 4) // 48MB raw buffer
        let item = ClipboardItem.image(data: data48MB, width: 4000, height: 3000)

        store.add(item)

        #expect(store.items.count == 1)
        #expect(store.items.first?.previewText == "Image (4000 × 3000)")
        #expect(store.items.first?.byteSize == data48MB.count)
    }

    @Test("100 concurrent pasteboard additions do not cause data races or deadlocks")
    func testRapidConcurrentAdditions() async {
        let store = ClipboardStore(capacity: 50)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let item = ClipboardItem.text("Concurrent Event \(i)")
                    store.add(item)
                    if i % 5 == 0 {
                        store.togglePin(id: item.id)
                    }
                }
            }
        }

        #expect(store.items.count <= 50)
        #expect(store.items.count >= 20)
    }

    @Test("Concurrent mixed store mutations (remove, clear, restore, capacity) do not crash or race")
    func testConcurrentMixedStoreMutations() async {
        let store = ClipboardStore(capacity: 30)
        let count = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let item = ClipboardItem.text("Item \(i)")
                    store.add(item)
                    if i % 3 == 0 {
                        store.togglePin(id: item.id)
                    }
                    if i % 7 == 0 {
                        store.selectAndRestoreItem(item)
                    }
                    if i % 11 == 0 {
                        store.removeItem(id: item.id)
                    }
                    if i % 15 == 0 {
                        store.clearUnpinnedHistory()
                    }
                    if i % 20 == 0 {
                        store.updateCapacity(25)
                    }
                }
            }
        }

        #expect(store.items.count <= 30)
    }

    // MARK: - Image Thumbnail & Command Hub Preview State
    @Test("ImageThumbnailService defaults to 128px for sharp Retina thumbnails")
    func testImageThumbnailServiceDefaultMaxDimension() {
        let service = ImageThumbnailService.shared
        #expect(service.defaultMaxPixelDimension == 128)
    }

    @Test("ZenithCommandHubState quickLookItem can be set and is cleared on reset")
    @MainActor
    func testZenithCommandHubStateQuickLookItem() {
        let state = ZenithCommandHubState.shared
        state.reset()
        #expect(state.quickLookItem == nil)

        let dummyItem = ClipboardItem.image(data: Data([0x01, 0x02]), width: 100, height: 100)
        state.quickLookItem = dummyItem
        #expect(state.quickLookItem?.id == dummyItem.id)

        state.reset()
        #expect(state.quickLookItem == nil)
    }
}
