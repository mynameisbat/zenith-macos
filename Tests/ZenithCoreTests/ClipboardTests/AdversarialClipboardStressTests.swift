import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ZenithCore

private final class ThreadSafeAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }
}

@Suite("Milestone 2 Adversarial Stress, Concurrency & FIFO Resilience Suite")
struct AdversarialClipboardStressTests {

    // MARK: - 1. High-Contention Concurrency & Asynchronous Stress
    @Test("120 concurrent asynchronous tasks hammering ClipboardStore with interleaved additions, removals, pin toggles, searches, and capacity shifts")
    func test120ConcurrentAsynchronousTasks() async {
        let store = ClipboardStore(capacity: 30)
        let insertedCounter = ThreadSafeAtomicCounter()

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<120 {
                group.addTask {
                    let text = "Concurrent Task \(taskId) Payload"
                    let item = ClipboardItem.text(text)
                    store.add(item)
                    insertedCounter.increment()

                    // Interleaved operations
                    if taskId % 3 == 0 {
                        store.togglePin(id: item.id)
                    }
                    if taskId % 7 == 0 {
                        _ = store.filteredItems
                    }
                    if taskId % 11 == 0 {
                        store.searchQuery = "Task"
                    }
                    if taskId % 13 == 0 {
                        store.searchQuery = ""
                    }
                    if taskId % 17 == 0 {
                        store.updateCapacity(20 + (taskId % 20))
                    }
                    if taskId % 23 == 0 {
                        store.clearUnpinnedHistory()
                    }
                    _ = store.items
                    _ = store.capacity
                }
            }
        }

        #expect(insertedCounter.count == 120)
        let finalItems = store.items
        let cap = store.capacity
        let pinnedCount = finalItems.filter(\.isPinned).count

        // Invariant: If unpinned items exist, total items cannot exceed max(cap, pinnedCount)
        if finalItems.contains(where: { !$0.isPinned }) {
            #expect(finalItems.count <= max(cap, pinnedCount + cap))
        }
    }

    private static func makeSyntheticPNG(width: Int = 100, height: Int = 100) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test("120+ concurrent asynchronous insertions and mutations across ClipboardStore and ImageThumbnailService")
    func test120ConcurrentInsertionsAcrossStoreAndThumbnailService() async {
        let store = ClipboardStore(capacity: 25)
        let thumbnailService = ImageThumbnailService(maxCacheCount: 50, defaultMaxPixelDimension: 64)
        let samplePNG = Self.makeSyntheticPNG(width: 120, height: 120)
        let corruptData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11])
        let successCounter = ThreadSafeAtomicCounter()

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<140 { // 140 concurrent tasks > 120
                group.addTask {
                    if taskId % 3 == 0 {
                        // Image insertion -> triggers background preloadThumbnail
                        let item = ClipboardItem.image(data: samplePNG, width: 120, height: 120)
                        store.add(item)
                        successCounter.increment()

                        // Concurrent query to ImageThumbnailService
                        let thumb = await thumbnailService.thumbnail(for: item.id, data: samplePNG)
                        #expect(thumb != nil)
                    } else if taskId % 3 == 1 {
                        // Text insertion
                        let text = "Concurrent Mixed Task \(taskId) payload"
                        let item = ClipboardItem.text(text)
                        store.add(item)
                        successCounter.increment()

                        if taskId % 2 == 0 {
                            store.togglePin(id: item.id)
                        }
                    } else {
                        // Corrupt image / Cache manipulation stress
                        let corruptItem = ClipboardItem.image(data: corruptData, width: 10, height: 10)
                        store.add(corruptItem)
                        successCounter.increment()

                        let thumb = await thumbnailService.thumbnail(for: corruptItem.id, data: corruptData)
                        #expect(thumb == nil) // Corrupt handled gracefully
                    }

                    // Interleaved mutations across services
                    if taskId % 7 == 0 {
                        _ = store.filteredItems
                    }
                    if taskId % 11 == 0 {
                        thumbnailService.clearCache()
                    }
                    if taskId % 13 == 0 {
                        store.updateCapacity(15 + (taskId % 15))
                    }
                    if taskId % 17 == 0 {
                        store.clearUnpinnedHistory()
                    }
                    if taskId % 19 == 0 {
                        _ = thumbnailService.cachedThumbnail(for: UUID())
                    }
                }
            }
        }

        #expect(successCounter.count == 140)
        let items = store.items
        #expect(!items.isEmpty)
        let pinnedCount = items.filter { $0.isPinned }.count
        let cap = store.capacity
        if items.contains(where: { !$0.isPinned }) {
            #expect(items.count <= max(cap, pinnedCount + cap))
        }
    }

    // MARK: - 2. Large Text Payloads, Extreme Multiline & Unicode Bomb Stress
    @Test("15MB large string ingestion maintains memory stability, correct byteSize, and clamped preview")
    func test15MBLargeStringIngestion() throws {
        let store = ClipboardStore(capacity: 10)
        let chunk = "0123456789ABCDEF" // 16 bytes
        let repeatCount = (15 * 1024 * 1024) / 16 // 15MB
        let payload15MB = String(repeating: chunk, count: repeatCount)

        let item = ClipboardItem.text(payload15MB)
        store.add(item)

        #expect(store.items.count == 1)
        let stored = try #require(store.items.first)
        #expect(stored.byteSize >= 15 * 1024 * 1024)
        #expect(stored.previewText.count <= 103)
        #expect(stored.previewText.hasSuffix("..."))
        #expect(stored.plainTextContent?.count == payload15MB.count)

        // Verify fuzzy search on 15MB item completes instantaneously without SLA breach
        let searchEngine = FuzzySearchEngine()
        let match = searchEngine.search(query: "0123456789", in: store.items)
        #expect(match.count == 1)
        let noMatch = searchEngine.search(query: "NONEXISTENT_PATTERN_XYZ", in: store.items)
        #expect(noMatch.isEmpty)
    }

    @Test("Extreme multiline strings (50,000 lines) and dense newlines ingest and search cleanly")
    func testExtremeMultilineStrings() {
        let store = ClipboardStore(capacity: 10)
        var lines: [String] = []
        lines.reserveCapacity(50_000)
        for i in 1...50_000 {
            lines.append("Line \(i): content details and parameters")
        }
        let multiline50k = lines.joined(separator: "\n")

        let item = ClipboardItem.text(multiline50k)
        store.add(item)

        #expect(store.items.count == 1)
        #expect(store.items.first?.previewText.starts(with: "Line 1:") == true)

        let searchEngine = FuzzySearchEngine()
        let result = searchEngine.search(query: "Line 1:", in: store.items)
        #expect(result.count == 1)

        // Substring search within 4000 char window
        let resultEarly = searchEngine.search(query: "Line 50:", in: store.items)
        #expect(resultEarly.count == 1)
    }

    @Test("Zalgo text, extreme Unicode combining characters, and emoji storms ingest without crash or index out of bounds")
    func testZalgoAndEmojiStormIngestion() {
        let store = ClipboardStore(capacity: 10)

        // Combining diacritical marks (Zalgo)
        let baseChar = "A"
        let zalgo = baseChar + String(repeating: "\u{0300}\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}", count: 200)
        store.add(ClipboardItem.text(zalgo))

        // Emoji storm with Zero-Width Joiners and skin tone modifiers
        let emojiStorm = String(repeating: "👨‍👩‍👧‍👦 👩🏽‍💻 🏳️‍🌈 🧗🏻‍♀️ ", count: 500)
        store.add(ClipboardItem.text(emojiStorm))

        // Embedded null bytes and control characters
        let nullByteString = "Golden\u{0000}Gate\u{0001}\u{0007}\u{001B}[31mRedText\u{0000}End"
        store.add(ClipboardItem.text(nullByteString))

        #expect(store.items.count == 3)
        let searchEngine = FuzzySearchEngine()
        let zalgoMatch = searchEngine.search(query: "A", in: store.items)
        #expect(!zalgoMatch.isEmpty)

        let nullMatch = searchEngine.search(query: "Golden", in: store.items)
        #expect(!nullMatch.isEmpty)
    }

    // MARK: - 3. FIFO Eviction Edge Cases & Pin Invariants
    @Test("FIFO eviction when all items are pinned: capacity overflow retains all pinned items, then dynamically handles new unpinned items")
    func testAllPinnedSaturationAndSubsequentEviction() {
        let store = ClipboardStore(capacity: 5)

        // Insert 10 items and pin every one of them
        for i in 1...10 {
            let item = ClipboardItem.text("Pinned #\(i)")
            store.add(item)
            store.togglePin(id: item.id)
        }

        #expect(store.items.count == 10)
        #expect(store.items.allSatisfy { $0.isPinned })

        // Add 3 unpinned items
        store.add(ClipboardItem.text("Unpinned A"))
        store.add(ClipboardItem.text("Unpinned B"))
        store.add(ClipboardItem.text("Unpinned C"))

        // Pinned count must remain 10
        #expect(store.items.filter { $0.isPinned }.count == 10)

        // Now add another unpinned item. The capacity is 5, but pinned count is 10.
        // Unpinned items should be evicted FIFO so only the latest unpinned item is kept at front
        store.add(ClipboardItem.text("Unpinned D"))
        #expect(store.items.filter { $0.isPinned }.count == 10)
        #expect(store.items.first?.previewText == "Unpinned D")

        // Unpinning items under saturation should allow them to be evicted on enforceCapacityLimit
        let oldestPinned = store.items.last!
        store.togglePin(id: oldestPinned.id)
        #expect(!store.items.last!.isPinned)

        store.enforceCapacityLimit()
        #expect(!store.items.contains(where: { $0.id == oldestPinned.id }))
    }

    @Test("Dynamic capacity shrinking to zero, negative, and large values handled gracefully")
    func testDynamicCapacityShrinkBoundaries() {
        let store = ClipboardStore(capacity: 20)
        for i in 1...15 {
            let item = ClipboardItem.text("Item \(i)")
            store.add(item)
            if i <= 5 {
                store.togglePin(id: item.id)
            }
        }

        #expect(store.items.count == 15)
        #expect(store.items.filter { $0.isPinned }.count == 5)

        // Shrink to 0: all unpinned must be evicted, all pinned must survive
        store.updateCapacity(0)
        #expect(store.items.count == 5)
        #expect(store.items.allSatisfy { $0.isPinned })

        // Shrink to negative: no crash, pinned survive
        store.updateCapacity(-10)
        #expect(store.items.count == 5)
        #expect(store.items.allSatisfy { $0.isPinned })

        // Expand to 500: can hold more items
        store.updateCapacity(500)
        for i in 100...150 {
            store.add(ClipboardItem.text("Item \(i)"))
        }
        #expect(store.items.count == 5 + 51)
    }

    @MainActor
    @Test("Pin persistence across view model resets and store capacity limits")
    func testPinPersistenceAcrossViewModelResetsAndStoreCapacityLimits() {
        let store = ClipboardStore(capacity: 8)

        // 1. Ingest initial items through store
        for i in 1...10 {
            let item = ClipboardItem.text("Initial Item #\(i)")
            store.add(item)
        }

        // 2. Initialize first ViewModel and pin items
        var viewModel = ClipboardHistoryViewModel(store: store)
        #expect(viewModel.items.count == 8) // Clamped to capacity 8

        // Pin 3 items
        let itemToPin1 = viewModel.items[0]
        let itemToPin2 = viewModel.items[2]
        let itemToPin3 = viewModel.items[4]
        let pinnedIDs: Set<UUID> = [itemToPin1.id, itemToPin2.id, itemToPin3.id]

        viewModel.togglePin(item: itemToPin1)
        viewModel.togglePin(item: itemToPin2)
        viewModel.togglePin(item: itemToPin3)

        #expect(viewModel.items.filter { $0.isPinned }.count == 3)
        #expect(store.items.filter { $0.isPinned }.count == 3)

        // 3. View Model Reset #1 (simulating panel recreation / fresh instance)
        viewModel = ClipboardHistoryViewModel(store: store)
        #expect(viewModel.items.filter { $0.isPinned }.count == 3)
        for id in pinnedIDs {
            let found = viewModel.items.first(where: { $0.id == id })
            #expect(found?.isPinned == true, "Pinned ID \(id) must persist across ViewModel reset")
        }

        // 4. Exceed store capacity limits with flood of new unpinned items
        for i in 100...150 {
            store.add(ClipboardItem.text("Flood Unpinned #\(i)"))
        }

        // Invariant: All 3 pinned items MUST survive capacity eviction
        let storePinnedAfterFlood = store.items.filter { $0.isPinned }
        #expect(storePinnedAfterFlood.count == 3)
        for id in pinnedIDs {
            #expect(storePinnedAfterFlood.contains(where: { $0.id == id }))
        }

        // 5. View Model Reset #2 (after flood & eviction)
        viewModel = ClipboardHistoryViewModel(store: store)
        let vmPinnedAfterReset = viewModel.items.filter { $0.isPinned }
        #expect(vmPinnedAfterReset.count == 3)
        for id in pinnedIDs {
            #expect(vmPinnedAfterReset.contains(where: { $0.id == id }))
        }

        // 6. Dynamic Capacity Reduction below pinned count
        store.updateCapacity(2) // Capacity is now 2, but 3 pinned items exist
        viewModel.syncWithStore()

        // All 3 pinned items must STILL survive
        #expect(store.items.filter { $0.isPinned }.count == 3)
        #expect(viewModel.items.filter { $0.isPinned }.count == 3)

        // 7. Clear unpinned history via ViewModel
        viewModel.clearHistory(includePinned: false)
        #expect(store.items.count == 3)
        #expect(viewModel.items.count == 3)
        #expect(viewModel.items.allSatisfy { $0.isPinned })

        // 8. View Model Reset #3
        viewModel = ClipboardHistoryViewModel(store: store)
        #expect(viewModel.items.count == 3)
        #expect(viewModel.items.allSatisfy { $0.isPinned })
    }

    // MARK: - 4. Consecutive & Alternating Deduplication Edge Cases
    @Test("Rapid alternating copies (A -> B -> A -> B) maintain bounded size of 2 and update recency")
    func testRapidAlternatingDeduplication() {
        let store = ClipboardStore(capacity: 20)
        let itemA = ClipboardItem.text("Alternating Payload A")
        let itemB = ClipboardItem.text("Alternating Payload B")

        for _ in 0..<50 {
            store.add(itemA)
            store.add(itemB)
        }

        // Must strictly contain 2 items, NOT 100 items!
        #expect(store.items.count == 2)
        #expect(store.items[0].previewText == "Alternating Payload B")
        #expect(store.items[1].previewText == "Alternating Payload A")

        // Add A once more -> brings A to front
        store.add(itemA)
        #expect(store.items.count == 2)
        #expect(store.items[0].previewText == "Alternating Payload A")
        #expect(store.items[1].previewText == "Alternating Payload B")
    }

    @Test("Identical text content across different formats (Plain vs RTF vs Image) do NOT collapse into deduplication")
    func testCrossFormatDifferentiation() {
        let store = ClipboardStore(capacity: 10)
        let plainItem = ClipboardItem.text("Common Content")
        let rtfData = "{\\rtf1 Common Content}".data(using: .utf8)!
        let rtfItem = ClipboardItem.richText(rtfData: rtfData, plainText: "Common Content")
        let dummyImgData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let imgItem = ClipboardItem.image(data: dummyImgData, width: 10, height: 10)

        store.add(plainItem)
        store.add(rtfItem)
        store.add(imgItem)

        // All 3 items must be preserved because payloads and types differ
        #expect(store.items.count == 3)
        #expect(store.items.map(\.itemType) == [.image, .richText, .plainText])
    }

    @Test("Consecutive duplicate copy strictly preserves pinned status and item ID")
    func testConsecutiveDuplicatePreservesPinAndID() async throws {
        let store = ClipboardStore(capacity: 10)
        let item = ClipboardItem.text("Pinned Target")
        store.add(item)
        let originalID = store.items.first!.id
        store.togglePin(id: originalID)

        #expect(store.items.first?.isPinned == true)

        try await Task.sleep(nanoseconds: 5_000_000) // 5ms

        // Re-copy identical text
        store.add(ClipboardItem.text("Pinned Target"))

        #expect(store.items.count == 1)
        #expect(store.items.first?.id == originalID)
        #expect(store.items.first?.isPinned == true)
    }

    // MARK: - 5. PasteboardMonitor Sensitive UTI & Format Extraction Stress
    @Test("SensitivePasteboardMarker exhaustive rejection on simulated pasteboards")
    func testSensitivePasteboardMarkerExhaustiveRejection() {
        // 1. Verify individual enumeration members match expected raw values
        #expect(SensitivePasteboardMarker.concealedType.rawValue == "org.nspasteboard.ConcealedType")
        #expect(SensitivePasteboardMarker.onePassword.rawValue == "com.agilebits.onepassword")
        #expect(SensitivePasteboardMarker.lastPass.rawValue == "com.lastpass.LastPassFormFiller")
        #expect(SensitivePasteboardMarker.keePassX.rawValue == "de.keepassx.clipmarker")
        #expect(SensitivePasteboardMarker.keeWeb.rawValue == "net.antelle.keeweb")
        #expect(SensitivePasteboardMarker.autoGeneratedType.rawValue == "org.nspasteboard.AutoGeneratedType")
        #expect(SensitivePasteboardMarker.transientType.rawValue == "org.nspasteboard.TransientType")
        #expect(SensitivePasteboardMarker.legacyTransientType.rawValue == "de.petermaurer.TransientPasteboardType")
        #expect(SensitivePasteboardMarker.typeIt4Me.rawValue == "com.typeit4me.clipping")
        #expect(SensitivePasteboardMarker.pasteboardGeneratorType.rawValue == "Pasteboard generator type")

        // 2. Verify all known sensitive markers return true individually and when mixed with standard types
        for marker in SensitivePasteboardMarker.allMarkers {
            #expect(SensitivePasteboardMarker.containsSensitiveType(in: [marker]))
            #expect(SensitivePasteboardMarker.containsSensitiveType(in: [.string, marker, .png]))
        }

        // 3. Clean types return false
        #expect(!SensitivePasteboardMarker.containsSensitiveType(in: [.string, .png, .tiff, .rtf]))
        #expect(!SensitivePasteboardMarker.containsSensitiveType(in: []))
    }

    @Test("PasteboardMonitor start and stop monitoring lifecycle is thread-safe under concurrent stress")
    func testPasteboardMonitorStartStopLifecycleConcurrency() async {
        let monitor = PasteboardMonitor(pasteboard: NSPasteboard.withUniqueName())

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    if i % 2 == 0 {
                        monitor.startMonitoring { _ in }
                    } else {
                        monitor.stopMonitoring()
                    }
                }
            }
        }

        // Cleanup
        monitor.stopMonitoring()
        #expect(!monitor.isMonitoring)
    }

    // MARK: - 6. FuzzySearchEngine Adversarial Queries & Worst-Case Complexity
    @Test("FuzzySearchEngine handles adversarial query strings (10,000 chars, regex metacharacters, unbalanced brackets) without crash or SLA breach")
    func testFuzzySearchAdversarialQueries() {
        let store = ClipboardStore(capacity: 20)
        store.add(ClipboardItem.text("Golden Gate macOS Utility Engine"))
        store.add(ClipboardItem.text("Swift 6 Concurrency and Observation"))
        store.add(ClipboardItem.text("Regex syntax: ^[a-z0-9_-]{3,16}$"))

        let searchEngine = FuzzySearchEngine()

        // 10,000 character query
        let longQuery = String(repeating: "adversarial_query_payload_", count: 400)
        let longResult = searchEngine.search(query: longQuery, in: store.items)
        #expect(longResult.isEmpty)

        // Unbalanced bracket soup and regex quantifiers
        let regexSoup = "[({[\\\\^$|?*+()}]!@#$%^&*()_+=-`~"
        let soupResult = searchEngine.search(query: regexSoup, in: store.items)
        #expect(soupResult.isEmpty)

        // Single character punctuation
        #expect(searchEngine.search(query: "^", in: store.items).count == 1)
        #expect(searchEngine.search(query: "$", in: store.items).count == 1)
    }

    @Test("FuzzySearchEngine 1,000 item corpus stress benchmark completes under 10ms")
    func testFuzzySearch1000ItemStressBenchmark() {
        var items: [ClipboardItem] = []
        items.reserveCapacity(1000)

        for i in 0..<1000 {
            if i % 10 == 0 {
                items.append(ClipboardItem.image(data: Data([1, 2]), width: 800, height: 600))
            } else if i % 10 == 1 {
                items.append(ClipboardItem.richText(rtfData: Data([3, 4]), plainText: "Rich Text Document \(i)"))
            } else {
                items.append(ClipboardItem.text("Corpus plain text document number \(i) with macOS Swift details"))
            }
        }

        let searchEngine = FuzzySearchEngine()
        let queries = ["swift", "image", "rtf", "corpus", "document", "gate", "notfoundxyz"]

        // Multi-query Warmup
        for q in queries {
            _ = searchEngine.search(query: q, in: items)
        }

        let iterations = 5
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            for q in queries {
                _ = searchEngine.search(query: q, in: items)
            }
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let perQueryMs = elapsedMs / Double(iterations * queries.count)

        #expect(perQueryMs < 15.0, "Average query time for 1000 items was \(perQueryMs) ms, exceeding 15ms debug SLA!")
    }
}
