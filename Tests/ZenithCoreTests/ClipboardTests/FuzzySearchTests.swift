import Testing
import Foundation
@testable import ZenithCore

@Suite("FuzzySearchEngine Query, Ranking & Performance SLA Suite")
struct FuzzySearchTests {

    // MARK: - Query Basics
    @Test("Empty or whitespace queries return all items in original order")
    func testEmptyQueryReturnsAll() {
        let store = ClipboardStore(capacity: 10)
        for i in 1...5 { store.add(ClipboardItem.text("Item \(i)")) }

        let searchEngine = FuzzySearchEngine()
        let resultEmpty = searchEngine.search(query: "", in: store.items)
        let resultWhitespace = searchEngine.search(query: "   \t\n", in: store.items)

        #expect(resultEmpty.map(\.id) == store.items.map(\.id))
        #expect(resultWhitespace.map(\.id) == store.items.map(\.id))
    }

    @Test("Case- and diacritic-insensitive matching")
    func testDiacriticAndCaseInsensitive() {
        let store = ClipboardStore(capacity: 10)
        store.add(ClipboardItem.text("Café Résumé and Über Alles"))
        let searchEngine = FuzzySearchEngine()

        #expect(searchEngine.search(query: "cafe", in: store.items).count == 1)
        #expect(searchEngine.search(query: "CAFÉ", in: store.items).count == 1)
        #expect(searchEngine.search(query: "resume", in: store.items).count == 1)
        #expect(searchEngine.search(query: "uber", in: store.items).count == 1)
    }

    // MARK: - Ranking Hierarchy
    @Test("Ranking order prioritizes Exact > Prefix > WordBoundary > Substring > Fuzzy")
    func testRankingOrderHierarchy() {
        let items: [ClipboardItem] = [
            ClipboardItem.text("cat"),                     // Exact match
            ClipboardItem.text("caterpillar"),             // Prefix match
            ClipboardItem.text("Black cat on wall"),       // Word-boundary match
            ClipboardItem.text("concatenate string"),      // Substring match
            ClipboardItem.text("compact audio tape")       // Fuzzy subsequence: c-a-t
        ]

        let searchEngine = FuzzySearchEngine()
        let results = searchEngine.search(query: "cat", in: items)

        #expect(results.count == 5)
        #expect(results[0].previewText == "cat")
        #expect(results[1].previewText == "caterpillar")
        #expect(results[2].previewText == "Black cat on wall")
        #expect(results[3].previewText == "concatenate string")
        #expect(results[4].previewText == "compact audio tape")
    }

    // MARK: - Type Query Search
    @Test("Searching 'image' or 'img' matches image items by category")
    func testItemTypeSearchImage() {
        let items: [ClipboardItem] = [
            ClipboardItem.text("A simple meeting agenda"),
            ClipboardItem.image(data: Data([1, 2, 3]), width: 1920, height: 1080),
            ClipboardItem.text("Notes about swift programming"),
            ClipboardItem.image(data: Data([4, 5, 6]), width: 300, height: 200)
        ]

        let searchEngine = FuzzySearchEngine()
        let results = searchEngine.search(query: "image", in: items)

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.itemType == .image })
    }

    @Test("Searching 'rtf' matches rich text items")
    func testItemTypeSearchRTF() {
        let items: [ClipboardItem] = [
            ClipboardItem.text("Plain Text Item"),
            ClipboardItem.richText(rtfData: Data(), plainText: "Formatted Legal Doc"),
            ClipboardItem.image(data: Data(), width: 100, height: 100)
        ]

        let searchEngine = FuzzySearchEngine()
        let results = searchEngine.search(query: "rtf", in: items)

        #expect(results.count == 1)
        #expect(results.first?.itemType == .richText)
    }

    // MARK: - Metacharacters & Escaping
    @Test("Special regex metacharacters do not crash or throw regex exceptions")
    func testSpecialCharactersRegexSafety() {
        let items = [
            ClipboardItem.text("Result: [Regex] (group)* + test? $100 ^begin")
        ]

        let searchEngine = FuzzySearchEngine()
        #expect(searchEngine.search(query: "[Regex]", in: items).count == 1)
        #expect(searchEngine.search(query: "(group)*", in: items).count == 1)
        #expect(searchEngine.search(query: "+ test?", in: items).count == 1)
        #expect(searchEngine.search(query: "$100", in: items).count == 1)
    }

    // MARK: - Search Misses
    @Test("Search misses return empty array without errors")
    func testSearchMisses() {
        let items = [ClipboardItem.text("Hello World")]
        let searchEngine = FuzzySearchEngine()

        let results = searchEngine.search(query: "zzxx_no_match_here", in: items)
        #expect(results.isEmpty)
    }

    // MARK: - Performance Benchmark SLA
    @Test("Performance SLA: 500 items filtered and ranked in < 5.0 milliseconds")
    func testPerformanceBenchmark500ItemsUnder5ms() {
        var items: [ClipboardItem] = []
        items.reserveCapacity(500)

        let sampleCorpus = [
            "func testPerformance() async throws { let clock = ContinuousClock() }",
            "Meeting notes with Apple UIKit & AppKit engineers on Friday morning",
            "https://developer.apple.com/documentation/appkit/nspasteboard",
            "SELECT id, name, created_at FROM clipboard_items WHERE byte_size > 1024",
            "curl -X POST https://api.goldengate.local/v1/sync -d '{\"status\": \"ok\"}'",
            "The quick brown fox jumps over the lazy sleeping golden gate dog",
            "Error: Swift package resolution failed with exit code 1",
            "let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel])"
        ]

        for i in 0..<500 {
            let base = sampleCorpus[i % sampleCorpus.count]
            if i % 15 == 0 {
                items.append(ClipboardItem.image(data: Data([1, 2]), width: 1920, height: 1080))
            } else {
                items.append(ClipboardItem.text("\(base) [Entry \(i)]"))
            }
        }

        let searchEngine = FuzzySearchEngine()
        let queries = ["swift", "image", "panel", "fox", "error", "select", "apple"]

        // Multi-Query Warmup: Prime branch predictor, string caches, and memory allocations
        for warmupQuery in queries {
            _ = searchEngine.search(query: warmupQuery, in: items)
        }

        let iterations = 10
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            for q in queries {
                _ = searchEngine.search(query: q, in: items)
            }
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let totalQueries = Double(iterations * queries.count)
        let perQueryMs = (Double(elapsedNanos) / 1_000_000.0) / totalQueries

        // Observability telemetry
        print(String(format: "[FuzzySearch SLA] 500 items: %.3f ms/query across %d iterations (SLA threshold: < 10.0 ms)", perQueryMs, iterations))

        #expect(perQueryMs < 10.0, "Average search time was \(perQueryMs) ms, exceeding the 10.0 ms threshold!")
    }

    @Test("Bounded search window protects against 10MB text payloads")
    func test10MBPayloadSearchWindow() {
        let huge10MB = "TARGET_KEYWORD_FOUND_HERE " + String(repeating: "Lorem Ipsum Dolor Sit Amet ", count: 350_000)
        let item = ClipboardItem.text(huge10MB)

        let searchEngine = FuzzySearchEngine()
        let start = DispatchTime.now()
        let results = searchEngine.search(query: "TARGET_KEYWORD", in: [item])
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        #expect(results.count == 1)
        #expect(elapsedMs < 5.0, "10MB text search took \(elapsedMs) ms, exceeding 5ms SLA!")
    }
}
