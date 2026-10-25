import Testing
import Foundation
import AppKit
@testable import ZenithCore

@Suite("Adversarial M2 Challenger: Fuzzy Search, Navigation & Geometry Suite")
struct AdversarialM2ChallengerTests {

    // MARK: - 1. Fuzzy Search Engine Empirical SLA & Stress Verification

    private func create500ItemCorpus() -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        items.reserveCapacity(500)

        let corpusSeeds = [
            "func testPerformance() async throws { let clock = ContinuousClock() }",
            "Café Résumé with Crème Brûlée and Zürich chocolate receipts",
            "Привет мир! Тестирование буфера обмена на русском языке",
            "Ελληνικό κείμενο: Καλημέρα κόσμε και έλεγχος απόδοσης",
            "🚀 Quick launch emoji test with multiple glyphs 🌟🔥🎉💡 and family 👨‍👩‍👧‍👦",
            "SQL: SELECT id, name, created_at FROM clipboard WHERE size > 1024 AND type = 'text'",
            "Regex payload: ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$ and $100.00 / 20%",
            "URL: https://developer.apple.com/documentation/appkit/nspasteboard?query=changeCount#ref",
            "JSON: {\"id\": \"c11f41a4\", \"status\": \"ACTIVE\", \"tokens\": [1, 2, 3], \"valid\": true}",
            "Terminal: curl -X POST https://api.goldengate.local/v1/sync -H 'Authorization: Bearer test'"
        ]

        for i in 0..<500 {
            let seed = corpusSeeds[i % corpusSeeds.count]
            if i % 10 == 0 {
                // Image item
                items.append(ClipboardItem.image(data: Data([UInt8](repeating: UInt8(i % 256), count: 50)), width: 1920, height: 1080))
            } else if i % 10 == 1 {
                // Rich text item
                items.append(ClipboardItem.richText(rtfData: Data("{\\rtf1 \(seed)}".utf8), plainText: "\(seed) [RTF \(i)]"))
            } else {
                // Plain text item
                items.append(ClipboardItem.text("\(seed) [Index \(i)]"))
            }
        }
        return items
    }

    @Test("Adversarial Fuzzy Search: Multi-lingual, Diacritics, Emoji & Punctuation Correctness")
    func testAdversarialSearchAccuracy() {
        let items = create500ItemCorpus()
        let engine = FuzzySearchEngine()

        // Diacritics
        let cafeResults = engine.search(query: "cafe", in: items)
        #expect(!cafeResults.isEmpty, "Diacritic-insensitive search for 'cafe' should match Café")
        let resumeResults = engine.search(query: "resume", in: items)
        #expect(!resumeResults.isEmpty, "Diacritic-insensitive search for 'resume' should match Résumé")
        let zurichResults = engine.search(query: "zurich", in: items)
        #expect(!zurichResults.isEmpty, "Diacritic-insensitive search for 'zurich' should match Zürich")

        // Cyrillic
        let cyrillicResults = engine.search(query: "Привет", in: items)
        #expect(!cyrillicResults.isEmpty, "Cyrillic search for 'Привет' should match")

        // Greek
        let greekResults = engine.search(query: "Καλημέρα", in: items)
        #expect(!greekResults.isEmpty, "Greek search for 'Καλημέρα' should match")

        // Emoji
        let emojiResults = engine.search(query: "🚀", in: items)
        #expect(!emojiResults.isEmpty, "Emoji search for '🚀' should match")

        // Punctuation & Metacharacters
        let regexResults = engine.search(query: "^[a-zA-Z0-9", in: items)
        #expect(!regexResults.isEmpty, "Regex metacharacters query should match safely")
        let dollarResults = engine.search(query: "$100.00", in: items)
        #expect(!dollarResults.isEmpty, "Dollar sign query should match safely")

        // Type queries
        let imageResults = engine.search(query: "image", in: items)
        #expect(imageResults.count >= 50, "Searching 'image' should match all 50 image items")
        let rtfResults = engine.search(query: "rtf", in: items)
        #expect(rtfResults.count >= 50, "Searching 'rtf' should match rich text items")
    }

    @Test("Adversarial Fuzzy Search: 500-Item Latency SLA Measurement under Diverse Query Sets")
    func testAdversarialSearchLatencySLA() {
        let items = create500ItemCorpus()
        let engine = FuzzySearchEngine()

        let adversarialQueries = [
            "cafe", "resume", "zurich", "brulee",             // Diacritic variations
            "Привет", "буфера", "обмена",                      // Cyrillic
            "Καλημέρα", "κόσμε",                              // Greek
            "🚀", "🌟", "👨‍👩‍👧‍👦",                                // Emojis
            "^[a-z", "$100.00", "SELECT *", "curl -X",        // Code & symbols
            "image", "img", "rtf", "text",                    // Type triggers
            "swift", "clock", "json", "token",                // ASCII terms
            "nonexistent_token_xyz_404_no_match",             // Pure misses
            "gg", "cb", "sql", "rt"                           // Subsequence triggers (<= 4 chars)
        ]

        // Warmup
        // Thorough Warmup: Warm up all query categories before measurement
        for warmupQuery in adversarialQueries {
            _ = engine.search(query: warmupQuery, in: items)
        }

        var queryTimesMs: [Double] = []
        queryTimesMs.reserveCapacity(adversarialQueries.count)

        for query in adversarialQueries {
            let start = DispatchTime.now()
            let iterations = 5
            for _ in 0..<iterations {
                _ = engine.search(query: query, in: items)
            }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let msPerQuery = (Double(elapsedNanos) / 1_000_000.0) / Double(iterations)
            queryTimesMs.append(msPerQuery)
        }

        let avgMs = queryTimesMs.reduce(0.0, +) / Double(queryTimesMs.count)
        let maxMs = queryTimesMs.max() ?? 0.0
        let minMs = queryTimesMs.min() ?? 0.0

        print("[Challenger Latency Benchmark] 500 items across \(adversarialQueries.count) diverse queries:")
        print("  - Min: \(String(format: "%.3f", minMs)) ms")
        print("  - Avg: \(String(format: "%.3f", avgMs)) ms")
        print("  - Max: \(String(format: "%.3f", maxMs)) ms")

        #expect(avgMs < 10.0, "Average latency across diverse queries must be strictly < 10.0ms under multi-suite parallel contention (was \(avgMs) ms)")
    }

    @Test("Adversarial Fuzzy Search: Long String and Pathological Queries")
    func testPathologicalSearchQueries() {
        let items = create500ItemCorpus()
        let engine = FuzzySearchEngine()

        // 500-character long query with warmup and 5-iteration averaging
        let long500 = String(repeating: "ab_cd_12 ", count: 55)
        _ = engine.search(query: long500, in: items) // Warmup
        let iterations = 5
        let start500 = DispatchTime.now()
        var results500: [ClipboardItem] = []
        for _ in 0..<iterations {
            results500 = engine.search(query: long500, in: items)
        }
        let elapsed500Nanos = DispatchTime.now().uptimeNanoseconds - start500.uptimeNanoseconds
        let avgMs500 = (Double(elapsed500Nanos) / 1_000_000.0) / Double(iterations)
        #expect(results500.isEmpty)
        #expect(avgMs500 < 5.0, "500-char query averaged \(avgMs500) ms, exceeding 5.0ms SLA")

        // 4000-character query with warmup and 5-iteration averaging
        let long4000 = String(repeating: "X", count: 4000)
        _ = engine.search(query: long4000, in: items) // Warmup
        let start4000 = DispatchTime.now()
        var results4000: [ClipboardItem] = []
        for _ in 0..<iterations {
            results4000 = engine.search(query: long4000, in: items)
        }
        let elapsed4000Nanos = DispatchTime.now().uptimeNanoseconds - start4000.uptimeNanoseconds
        let avgMs4000 = (Double(elapsed4000Nanos) / 1_000_000.0) / Double(iterations)
        #expect(results4000.isEmpty)
        #expect(avgMs4000 < 5.0, "4000-char query averaged \(avgMs4000) ms, exceeding 5.0ms SLA")

        // Repeated spaces & tabs query
        let whitespaceOnly = " \t \n \r \t "
        let resultsWs = engine.search(query: whitespaceOnly, in: items)
        #expect(resultsWs.count == items.count, "Whitespace query should preserve all items")
    }

    // MARK: - 2. PanelPositioner Geometry & Edge Case Stress Testing

    @Test("PanelPositioner: Extreme Multi-Monitor and Negative Origin Displays")
    func testExtremeMultiMonitorGeometries() {
        let panelSize = CGSize(width: 420, height: 520)

        // Triple monitor setup: Monitor 1 (Left, negative), Monitor 2 (Center, primary), Monitor 3 (Right)
        let leftScreen = NSRect(x: -2560, y: 0, width: 2560, height: 1440)
        let centerScreen = NSRect(x: 0, y: 25, width: 1920, height: 1055)
        _ = centerScreen
        let rightScreen = NSRect(x: 1920, y: 0, width: 3840, height: 2160) // 4K display on right

        // Test near-mouse on center display
        let mouseOnCenter = CGPoint(x: 960, y: 500)
        let frameCenter = PanelPositioner.calculateFrame(
            mouseLocation: mouseOnCenter,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: centerScreen
        )
        #expect(frameCenter.minX >= centerScreen.minX + PanelPositioner.margin)
        #expect(frameCenter.maxX <= centerScreen.maxX - PanelPositioner.margin)
        #expect(frameCenter.minY >= centerScreen.minY + PanelPositioner.margin)
        #expect(frameCenter.maxY <= centerScreen.maxY - PanelPositioner.margin)

        // Test center mode on center display (completing test coverage and anchoring usage)
        let frameCenterCenter = PanelPositioner.calculateFrame(
            mouseLocation: mouseOnCenter,
            panelSize: panelSize,
            mode: .screenCenter,
            visibleFrame: centerScreen
        )
        #expect(frameCenterCenter.origin.x == centerScreen.midX - panelSize.width / 2)

        // Test near-mouse on left display with negative coordinates
        let mouseOnLeft = CGPoint(x: -1280, y: 720)
        let frameLeft = PanelPositioner.calculateFrame(
            mouseLocation: mouseOnLeft,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: leftScreen
        )
        #expect(frameLeft.minX >= leftScreen.minX + PanelPositioner.margin)
        #expect(frameLeft.maxX <= leftScreen.maxX - PanelPositioner.margin)
        #expect(frameLeft.minY >= leftScreen.minY + PanelPositioner.margin)
        #expect(frameLeft.maxY <= leftScreen.maxY - PanelPositioner.margin)

        // Test near-mouse on 4K right display
        let mouseOnRight = CGPoint(x: 3000, y: 1500)
        let frameRight = PanelPositioner.calculateFrame(
            mouseLocation: mouseOnRight,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: rightScreen
        )
        #expect(frameRight.minX >= rightScreen.minX + PanelPositioner.margin)
        #expect(frameRight.maxX <= rightScreen.maxX - PanelPositioner.margin)

        // Test center mode on left display
        let frameCenterLeft = PanelPositioner.calculateFrame(
            mouseLocation: mouseOnLeft,
            panelSize: panelSize,
            mode: .screenCenter,
            visibleFrame: leftScreen
        )
        #expect(frameCenterLeft.origin.x == leftScreen.midX - panelSize.width / 2)
    }

    @Test("PanelPositioner: Off-Screen Mouse Locations and Outer Bounds Clamping")
    func testOffScreenMouseCoordinates() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let panelSize = CGSize(width: 420, height: 520)

        // Cursor far off to the right & top: (99999, 99999)
        let farTopRight = CGPoint(x: 99999, y: 99999)
        let frameTopRight = PanelPositioner.calculateFrame(
            mouseLocation: farTopRight,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: visibleFrame
        )
        #expect(frameTopRight.maxX <= visibleFrame.maxX - PanelPositioner.margin)
        #expect(frameTopRight.maxY <= visibleFrame.maxY - PanelPositioner.margin)
        #expect(frameTopRight.minX >= visibleFrame.minX + PanelPositioner.margin)
        #expect(frameTopRight.minY >= visibleFrame.minY + PanelPositioner.margin)

        // Cursor far off to the bottom-left: (-99999, -99999)
        let farBottomLeft = CGPoint(x: -99999, y: -99999)
        let frameBottomLeft = PanelPositioner.calculateFrame(
            mouseLocation: farBottomLeft,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: visibleFrame
        )
        #expect(frameBottomLeft.minX >= visibleFrame.minX + PanelPositioner.margin)
        #expect(frameBottomLeft.minY >= visibleFrame.minY + PanelPositioner.margin)
        #expect(frameBottomLeft.maxX <= visibleFrame.maxX - PanelPositioner.margin)
        #expect(frameBottomLeft.maxY <= visibleFrame.maxY - PanelPositioner.margin)
    }

    @Test("PanelPositioner: Zero-Size, Inverted or Degenerate Visible Frames Fallback")
    func testDegenerateVisibleFramesFallback() {
        let panelSize = CGSize(width: 420, height: 520)
        let mouseLocation = CGPoint(x: 500, y: 500)

        // Zero-sized visible frame
        let zeroFrame = NSRect(x: 0, y: 0, width: 0, height: 0)
        let frameZero = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: panelSize,
            mode: .screenCenter,
            visibleFrame: zeroFrame
        )
        // Should fallback to default 1920x1080 safely without crashing or NaN
        #expect(frameZero.width == panelSize.width)
        #expect(frameZero.height == panelSize.height)
        #expect(frameZero.origin.x.isFinite)
        #expect(frameZero.origin.y.isFinite)

        // Inverted / negative-dimension frame
        let negativeFrame = NSRect(x: 100, y: 100, width: -500, height: -500)
        let frameNeg = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: negativeFrame
        )
        #expect(frameNeg.width == panelSize.width)
        #expect(frameNeg.height == panelSize.height)
        #expect(frameNeg.origin.x.isFinite)
        #expect(frameNeg.origin.y.isFinite)
    }

    @Test("PanelPositioner: Exact Margin Boundary Collisions and Flip Behavior")
    func testExactMarginCollisions() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let panelSize = CGSize(width: 400, height: 400)

        // Test cursor exactly at (0, 0): flips above cursor to y = 16
        let frameAtOrigin = PanelPositioner.calculateFrame(
            mouseLocation: .zero,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: visibleFrame
        )
        #expect(frameAtOrigin.minX == PanelPositioner.margin)
        #expect(frameAtOrigin.minY == 16.0)

        // Test cursor at bottom edge: should flip above cursor (+16)
        let frameAtBottom = PanelPositioner.calculateFrame(
            mouseLocation: CGPoint(x: 500, y: 50),
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: visibleFrame
        )
        #expect(frameAtBottom.origin.y == 66.0)

        // Test cursor at top right edge
        let frameAtTopRight = PanelPositioner.calculateFrame(
            mouseLocation: CGPoint(x: 1000, y: 1000),
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: visibleFrame
        )
        #expect(frameAtTopRight.maxX <= visibleFrame.maxX - PanelPositioner.margin)
        #expect(frameAtTopRight.maxY <= visibleFrame.maxY - PanelPositioner.margin)
    }

    // MARK: - 3. KeyboardNavigationEngine Boundary & Stress Testing

    @MainActor
    private func makeEngineHarness(count: Int) -> (KeyboardNavigationEngine, ClipboardHistoryViewModel, MockPasteboardService, MockSoundService) {
        let mockPasteboard = MockPasteboardService()
        let mockSound = MockSoundService()
        var items: [ClipboardItem] = []
        for i in 0..<count {
            items.append(ClipboardItem.text("Test Item \(i + 1)"))
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

    @MainActor
    @Test("KeyboardNavigationEngine: 1000 Rapid Arrow Cycles Under Stress")
    func testRapidArrowCycles() {
        let (engine, viewModel, _, _) = makeEngineHarness(count: 20)

        #expect(viewModel.selectedIndex == 0)

        // 1000 down-arrows: must clamp at index 19 without crashing
        for _ in 0..<1000 {
            _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        }
        #expect(viewModel.selectedIndex == 19)

        // 1000 up-arrows: must clamp at index 0 without crashing
        for _ in 0..<1000 {
            _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        }
        #expect(viewModel.selectedIndex == 0)

        // Rapid alternating up/down cycles
        for i in 0..<500 {
            let keyCode = (i % 2 == 0) ? KeyboardNavigationEngine.KeyCodes.downArrow : KeyboardNavigationEngine.KeyCodes.upArrow
            _ = engine.handleKey(keyCode: keyCode, modifiers: [])
        }
        #expect(viewModel.selectedIndex >= 0 && viewModel.selectedIndex < 20)
    }

    @MainActor
    @Test("KeyboardNavigationEngine: Empty List Handling (Zero Items)")
    func testEmptyListHandling() {
        let (engine, viewModel, mockPasteboard, mockSound) = makeEngineHarness(count: 0)

        #expect(viewModel.filteredItems.isEmpty)
        #expect(viewModel.selectedIndex == 0)

        // Down and Up arrows on empty list should be safe no-ops
        let downHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        #expect(downHandled == true)
        #expect(viewModel.selectedIndex == 0)

        let upHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        #expect(upHandled == true)
        #expect(viewModel.selectedIndex == 0)

        // Return key on empty list: should consume event but not copy or play sound
        let returnHandled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [])
        #expect(returnHandled == true)
        #expect(mockPasteboard.copiedItems.isEmpty)
        #expect(mockSound.pasteSoundCount == 0)

        // ⌘1 on empty list: consumed safely to avoid error beep, but no action
        let cmd1Handled = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: .command)
        #expect(cmd1Handled == true)
        #expect(mockPasteboard.copiedItems.isEmpty)
    }

    @MainActor
    @Test("KeyboardNavigationEngine: ⌘1..⌘9 All Number Keys and Boundary Filtering")
    func testAllCommandNumberShortcuts() {
        let (engine, viewModel, mockPasteboard, mockSound) = makeEngineHarness(count: 9)

        let numberKeyCodes: [(UInt16, Int)] = [
            (KeyboardNavigationEngine.KeyCodes.key1, 0),
            (KeyboardNavigationEngine.KeyCodes.key2, 1),
            (KeyboardNavigationEngine.KeyCodes.key3, 2),
            (KeyboardNavigationEngine.KeyCodes.key4, 3),
            (KeyboardNavigationEngine.KeyCodes.key5, 4),
            (KeyboardNavigationEngine.KeyCodes.key6, 5),
            (KeyboardNavigationEngine.KeyCodes.key7, 6),
            (KeyboardNavigationEngine.KeyCodes.key8, 7),
            (KeyboardNavigationEngine.KeyCodes.key9, 8)
        ]

        for (keyCode, expectedIndex) in numberKeyCodes {
            let handled = engine.handleKey(keyCode: keyCode, modifiers: .command)
            #expect(handled == true)
            #expect(mockPasteboard.copiedItems.last?.previewText == "Test Item \(expectedIndex + 1)")
        }
        #expect(mockSound.pasteSoundCount == 9)
        _ = viewModel
    }

    @MainActor
    @Test("KeyboardNavigationEngine: Modifiers Exclusion (Shift, Option, Control) Prevents False Triggers")
    func testModifierExclusions() {
        let (engine, viewModel, mockPasteboard, _) = makeEngineHarness(count: 5)

        // ⌘ + Shift + 1 -> Should NOT trigger quick select
        let shiftCmd = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: [.command, .shift])
        #expect(shiftCmd == false)
        #expect(mockPasteboard.copiedItems.isEmpty)

        // ⌘ + Option + 1 -> Should NOT trigger quick select
        let optCmd = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: [.command, .option])
        #expect(optCmd == false)
        #expect(mockPasteboard.copiedItems.isEmpty)

        // ⌘ + Control + 1 -> Should NOT trigger quick select
        let ctrlCmd = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.key1, modifiers: [.command, .control])
        #expect(ctrlCmd == false)
        #expect(mockPasteboard.copiedItems.isEmpty)

        _ = viewModel
    }

    @MainActor
    @Test("KeyboardNavigationEngine: Escape Handler Routing with Fallback")
    func testEscapeHandlerRouting() {
        let (engine, viewModel, _, _) = makeEngineHarness(count: 3)

        // 1. Direct dismissHandler on engine
        var engineDismissed = false
        engine.dismissHandler = {
            engineDismissed = true
        }
        let handled1 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey, modifiers: [])
        #expect(handled1 == true)
        #expect(engineDismissed == true)

        // 2. Fallback to activeViewModel.onDismiss when engine.dismissHandler is nil
        engine.dismissHandler = nil
        var vmDismissed = false
        viewModel.onDismiss = {
            vmDismissed = true
        }
        let handled2 = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey, modifiers: [])
        #expect(handled2 == true)
        #expect(vmDismissed == true)
    }

    @MainActor
    @Test("KeyboardNavigationEngine: Dynamic Filter Typing Updates Selection Bounds")
    func testDynamicFilterTypingUpdatesBounds() {
        let (engine, viewModel, _, _) = makeEngineHarness(count: 10)

        // User navigates to index 8
        viewModel.selectedIndex = 8

        // User types a query that only matches 2 items
        viewModel.searchText = "Item 1" // matches "Test Item 1" and "Test Item 10"
        #expect(viewModel.filteredItems.count == 2)

        // selectedIndex must clamp to valid index within filteredItems (i.e. <= 1)
        #expect(viewModel.selectedIndex <= 1)

        // Clear search restores all 10 items
        viewModel.searchText = ""
        #expect(viewModel.filteredItems.count == 10)
        #expect(viewModel.selectedIndex >= 0 && viewModel.selectedIndex < 10)
        _ = engine
    }

    // MARK: - 4. ViewModel & Store State Synchronization Tests

    @MainActor
    @Test("UIStateSynchronization: togglePin propagates to store and survives syncWithStore")
    func testTogglePinPropagatesToStore() {
        let store = ClipboardStore(capacity: 20)
        let item1 = ClipboardItem.text("Item A")
        let item2 = ClipboardItem.text("Item B")
        store.add(item1)
        store.add(item2)

        let viewModel = ClipboardHistoryViewModel(store: store)
        #expect(viewModel.items.count == 2)
        #expect(!viewModel.items[0].isPinned)

        // Toggle pin via viewModel
        viewModel.togglePin(for: viewModel.items[0])
        #expect(viewModel.items[0].isPinned)
        #expect(store.items.first(where: { $0.id == viewModel.items[0].id })?.isPinned == true)

        // Simulate panel reopen with syncWithStore
        viewModel.syncWithStore()
        #expect(viewModel.items[0].isPinned)
    }

    @MainActor
    @Test("UIStateSynchronization: selectItem promotes recency in store and copies to pasteboard")
    func testSelectItemPromotesRecencyInStore() {
        let store = ClipboardStore(capacity: 20)
        let itemOld = ClipboardItem.text("Old Item")
        let itemNew = ClipboardItem.text("New Item")
        store.add(itemOld)
        store.add(itemNew)

        let viewModel = ClipboardHistoryViewModel(store: store)
        #expect(viewModel.items.first?.previewText == "New Item")

        // Select the older item (at index 1)
        viewModel.selectItem(at: 1)

        // Store must have promoted Old Item to index 0
        #expect(store.items.first?.previewText == "Old Item")
        #expect(viewModel.items.first?.previewText == "Old Item")
    }

    // MARK: - 5. ImageThumbnailService Tests

    @Test("ImageThumbnailService: Downsampling and Caching")
    func testImageThumbnailServiceDownsampleAndCache() async {
        let service = ImageThumbnailService(maxCacheCount: 50, defaultMaxPixelDimension: 64)
        service.clearCache()

        // Create synthetic RGBA bitmap 200x200
        let width = 200
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let rep = NSBitmapImageRep(cgImage: cgImage)
        let pngData = rep.representation(using: .png, properties: [:])!

        let itemId = UUID()

        // 1. Generate thumbnail
        let thumb = await service.thumbnail(for: itemId, data: pngData)
        #expect(thumb != nil)
        if let thumb = thumb {
            #expect(thumb.width <= 64)
            #expect(thumb.height <= 64)
        }

        // 2. Synchronous cache hit
        let cached = service.cachedThumbnail(for: itemId)
        #expect(cached != nil)
        #expect(cached === thumb)

        // 3. Corrupt data handling
        let corruptId = UUID()
        let corruptThumb = await service.thumbnail(for: corruptId, data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(corruptThumb == nil)

        // 4. Clear cache
        service.clearCache()
        #expect(service.cachedThumbnail(for: itemId) == nil)
    }
}
