import Testing
import Foundation
import AppKit
@testable import ZenithCore

@Suite("Clipboard Memory Limit Suite")
struct ClipboardMemoryLimitTests {

    private func text(_ marker: String, bytes: Int) -> ClipboardItem {
        .text(marker + String(repeating: "x", count: max(0, bytes - marker.utf8.count)))
    }

    @Test("CLIP-MEM-01: The oldest unpinned items are dropped once the history exceeds its memory budget")
    func testTotalBudgetEvictsOldestFirst() {
        let store = ClipboardStore(capacity: 100, maxTotalBytes: 2_500)
        for marker in ["A", "B", "C", "D"] {
            store.add(text(marker, bytes: 1_000))
        }
        // 4 × 1000 bytes > 2500: only the two newest fit.
        #expect(store.items.map { $0.previewText.prefix(1) } == ["D", "C"])
    }

    @Test("CLIP-MEM-02: Pinned items and the newest item survive the budget")
    func testPinnedAndNewestAreKept() {
        let store = ClipboardStore(capacity: 100, maxTotalBytes: 2_500)
        store.add(text("P", bytes: 1_000))
        store.togglePin(id: store.items[0].id)
        for marker in ["B", "C", "D"] {
            store.add(text(marker, bytes: 1_000))
        }
        let kept = store.items.map { String($0.previewText.prefix(1)) }
        #expect(kept.contains("P"))
        #expect(kept.first == "D")

        // A single item larger than the whole budget is still kept as the newest entry.
        let tiny = ClipboardStore(capacity: 100, maxTotalBytes: 500)
        tiny.add(text("Z", bytes: 5_000))
        #expect(tiny.items.count == 1)
    }

    @Test("CLIP-MEM-04: Restoring an item from a test store never touches the user's real clipboard")
    @MainActor
    func testCapacityStoreIsIsolatedFromRealClipboard() {
        let realChangeCount = NSPasteboard.general.changeCount
        let store = ClipboardStore(capacity: 10)
        store.add(.text("old"))
        store.add(.text("new"))
        store.selectAndRestoreItem(store.items[1])
        #expect(NSPasteboard.general.changeCount == realChangeCount)
    }

    @Test("CLIP-MEM-03: Copies above the per-item limit are not taken into history; ordinary ones are")
    func testOversizedPasteboardContentIsSkipped() {
        let pasteboard = NSPasteboard.withUniqueName()      // not the user's clipboard
        defer { pasteboard.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "a", count: ClipboardLimits.maxItemBytes + 1), forType: .string)
        #expect(monitor.extractClipboardItem(from: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "a", count: 1_000_000), forType: .string)
        #expect(monitor.extractClipboardItem(from: pasteboard)?.byteSize == 1_000_000)

        pasteboard.clearContents()
        pasteboard.setData(Data(count: ClipboardLimits.maxItemBytes + 1), forType: .png)
        #expect(monitor.extractClipboardItem(from: pasteboard) == nil)
    }
}
