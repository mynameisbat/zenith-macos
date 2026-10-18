import Testing
import Foundation
@testable import GoldenGateCore

@Suite("Clipboard History FIFO & Pin-Exempt Eviction Suite")
struct EvictionTests {

    // MARK: - Capacities Parameterized Testing
    @Test(
        "FIFO eviction bounds total count to capacity when all items are unpinned",
        arguments: [5, 20, 50, 500]
    )
    func testFIFOEvictionAtVariousCapacities(capacity: Int) {
        let store = ClipboardStore(capacity: capacity)
        let overflow = capacity + 10

        for i in 1...overflow {
            store.add(ClipboardItem.text("Item \(i)"))
        }

        #expect(store.items.count == capacity)
        // Verify newest items retained
        #expect(store.items.first?.previewText == "Item \(overflow)")
        #expect(store.items.last?.previewText == "Item 11")
    }

    // MARK: - Pinned Exemption
    @Test("Pinned items are strictly immune from FIFO capacity eviction")
    func testPinnedItemImmuneToFIFO() {
        let store = ClipboardStore(capacity: 5)

        // Add Item 1 and pin it
        let pinnedItem = ClipboardItem.text("Critical Pinned Item")
        store.add(pinnedItem)
        store.togglePin(id: pinnedItem.id)

        // Add 10 unpinned items (exceeding capacity 5)
        for i in 1...10 {
            store.add(ClipboardItem.text("Unpinned \(i)"))
        }

        #expect(store.items.count == 5)
        #expect(store.items.contains(where: { $0.id == pinnedItem.id }))
        #expect(store.items.last?.previewText == "Critical Pinned Item")
        #expect(store.items.first?.previewText == "Unpinned 10")
    }

    @Test("Multiple pinned items remain immune while oldest unpinned items are evicted")
    func testMultiplePinnedItemsImmunity() {
        let store = ClipboardStore(capacity: 4)

        let pin1 = ClipboardItem.text("Pin 1")
        let pin2 = ClipboardItem.text("Pin 2")
        store.add(pin1)
        store.togglePin(id: pin1.id)
        store.add(pin2)
        store.togglePin(id: pin2.id)

        store.add(ClipboardItem.text("Unpinned A"))
        store.add(ClipboardItem.text("Unpinned B"))
        #expect(store.items.count == 4)

        // Add Unpinned C -> Unpinned A should be evicted, Pin 1 & Pin 2 preserved
        store.add(ClipboardItem.text("Unpinned C"))

        #expect(store.items.count == 4)
        #expect(store.items.contains(where: { $0.id == pin1.id }))
        #expect(store.items.contains(where: { $0.id == pin2.id }))
        #expect(store.items.contains(where: { $0.previewText == "Unpinned B" }))
        #expect(store.items.contains(where: { $0.previewText == "Unpinned C" }))
        #expect(!store.items.contains(where: { $0.previewText == "Unpinned A" }))
    }

    @Test("All-pinned saturation: pinned items never evicted even if count exceeds capacity")
    func testAllPinnedSaturationGracefulHandling() {
        let store = ClipboardStore(capacity: 3)

        // Pin 3 items (capacity full of pins)
        for i in 1...3 {
            let item = ClipboardItem.text("Pin \(i)")
            store.add(item)
            store.togglePin(id: item.id)
        }

        #expect(store.items.count == 3)

        // Add a 4th pinned item
        let pin4 = ClipboardItem.text("Pin 4")
        store.add(pin4)
        store.togglePin(id: pin4.id)

        // All 4 pinned items must be preserved!
        #expect(store.items.count == 4)
        #expect(store.items.allSatisfy { $0.isPinned })

        // Add an unpinned item
        store.add(ClipboardItem.text("Unpinned 1"))
        // If another unpinned arrives, only unpinned items get evicted
        store.add(ClipboardItem.text("Unpinned 2"))

        #expect(store.items.filter(\.isPinned).count == 4)
    }

    // MARK: - Dynamic Capacity Reduction
    @Test("Reducing historyLimit in SettingsStore triggers eviction of excess unpinned items only")
    func testDynamicCapacityReduction() {
        let store = ClipboardStore(capacity: 20)

        // Add 5 pinned items
        for i in 1...5 {
            let item = ClipboardItem.text("Pin \(i)")
            store.add(item)
            store.togglePin(id: item.id)
        }

        // Add 15 unpinned items
        for i in 1...15 {
            store.add(ClipboardItem.text("Unpinned \(i)"))
        }

        #expect(store.items.count == 20)

        // Reduce capacity down to 10
        store.updateCapacity(10)

        #expect(store.items.count == 10)
        // All 5 pinned items preserved!
        #expect(store.items.filter(\.isPinned).count == 5)
        // 5 newest unpinned items preserved
        #expect(store.items.filter { !$0.isPinned }.count == 5)
    }

    @Test("Dynamic capacity reduction below pinned count spares all pinned items")
    func testDynamicCapacityReductionBelowPinnedCount() {
        let store = ClipboardStore(capacity: 20)

        // Add 8 pinned items
        for i in 1...8 {
            let item = ClipboardItem.text("Pin \(i)")
            store.add(item)
            store.togglePin(id: item.id)
        }

        // Add 4 unpinned items (total = 12)
        for i in 1...4 {
            store.add(ClipboardItem.text("Unpinned \(i)"))
        }

        #expect(store.items.count == 12)

        // Shrink capacity down to 5 (which is below the 8 pinned items)
        store.updateCapacity(5)

        // All 4 unpinned items evicted, all 8 pinned items kept!
        #expect(store.items.count == 8)
        #expect(store.items.allSatisfy { $0.isPinned })
    }
}
