import Testing
import Foundation
import AppKit
@testable import ZenithCore

@Suite("Adversarial Empirical Latency & Panel Geometry Stress Challenger")
struct AdversarialSearchLatencyChallengerTests {

    private func createCorpus500() -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        items.reserveCapacity(500)

        let multilingualSeeds = [
            "Swift 6.0 Concurrency and Actor isolation with TaskGroup and ContinuousClock",
            "Café crème brûlée au chocolat noir à Zürich et Genève avec reçu fiscal",
            "Быстрый буфер обмена: Привет мир, тестирование кириллицы и поиск подстрок",
            "Ελληνικά δεδομένα: Καλημέρα κόσμε, ανάλυση κειμένου και ταχύτητα αναζήτησης",
            "日本語テキスト: クリップボード履歴の高速検索エンジンとマルチバイト文字",
            "한국어 테스트: 빠른 클립보드 검색 엔진 및 유니코드 자모 결합 테스트",
            "中文测试: 快速剪贴板历史记录模糊搜索与高并发多语言支持",
            "العربية: محرك بحث متقدم للنصوص متعددة اللغات مع دعم اليونيكود",
            "🚀🔥🎉🌟💡 Extreme emoji storm: 👨‍👩‍👧‍👦 👩🏽‍💻 🏳️‍🌈 🇺🇸 🇻🇳 with complex grapheme clusters",
            "JSON payload: {\"event\": \"pasteboard_change\", \"uuid\": \"9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d\", \"count\": 500}",
            "SQL query: SELECT id, preview, timestamp FROM items WHERE pinned = 1 ORDER BY recency DESC LIMIT 50",
            "Shell cmd: curl -sSL https://get.goldengate.app | bash -s -- --channel=canary --verbose"
        ]

        for i in 0..<500 {
            let seed = multilingualSeeds[i % multilingualSeeds.count]
            if i % 8 == 0 {
                items.append(ClipboardItem.image(data: Data([UInt8](repeating: UInt8(i % 255), count: 64)), width: 3840, height: 2160))
            } else if i % 8 == 1 {
                items.append(ClipboardItem.richText(rtfData: Data("{\\rtf1 \(seed)}".utf8), plainText: "\(seed) — RTF Format [Record \(i)]"))
            } else {
                items.append(ClipboardItem.text("\(seed) — Plain Text Entry [Item #\(i)]"))
            }
        }
        return items
    }

    @Test("Challenger Latency SLA: 100 Diverse Multilingual, CJK, RTL, Emoji & Pathological Queries Across 500 Items")
    func test100DiverseQueriesLatencySLA() {
        let items = createCorpus500()
        let engine = FuzzySearchEngine()

        let queries = [
            // Latin & Accented
            "swift", "concurrency", "actor", "cafe", "crème", "brûlée", "chocolat", "zurich", "geneve",
            // Cyrillic
            "Привет", "мир", "буфер", "обмена", "тестирование", "кириллицы", "поиск", "подстрок",
            // Greek
            "Καλημέρα", "κόσμε", "ανάλυση", "κειμένου", "ταχύτητα", "αναζήτησης",
            // CJK
            "クリップボード", "履歴", "検索", "클립보드", "유니코드", "剪贴板", "多语言",
            // RTL (Arabic)
            "محرك", "بحث", "اليونيكود",
            // Emoji storms & ZWJ
            "🚀", "🔥", "🎉", "🌟", "💡", "👨‍👩‍👧‍👦", "👩🏽‍💻", "🏳️‍🌈", "🇻🇳",
            // Code & Metacharacters
            "curl -sSL", "SELECT id", "ORDER BY", "WHERE pinned", "uuid", "event", "{\"", "9b1deb4d",
            "TaskGroup", "ContinuousClock", "limit 50",
            // Types
            "image", "img", "rtf", "rich", "text", "plain",
            // Short Subsequences
            "sw", "cr", "bf", "kl", "jp", "sql", "sh", "em", "js",
            // Pure Misses
            "zzzz_nonexistent_term_9999", "random_junk_query_not_found", "xyz123456789",
            // Whitespace & Special punctuation
            "   ", "\t\t", "[Item #", "—", "#", "::", "@", "$", "%", "^", "&", "*", "(", ")",
            // Pathological lengths
            String(repeating: "A", count: 120),
            String(repeating: "B", count: 250),
            String(repeating: "C", count: 500),
            String(repeating: "D", count: 1000),
            String(repeating: "E", count: 2000),
            String(repeating: "F", count: 3999),
            String(repeating: "G", count: 4000),
            String(repeating: "H", count: 4001),
            String(repeating: "I", count: 8000)
        ]

        #expect(queries.count >= 70)

        // Warmup engine
        for q in queries {
            _ = engine.search(query: q, in: items)
        }

        var perQueryAverages: [Double] = []
        perQueryAverages.reserveCapacity(queries.count)

        for query in queries {
            let iterations = 3
            let start = DispatchTime.now()
            for _ in 0..<iterations {
                _ = engine.search(query: query, in: items)
            }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let ms = (Double(elapsedNanos) / 1_000_000.0) / Double(iterations)
            perQueryAverages.append(ms)
        }

        let overallAvg = perQueryAverages.reduce(0.0, +) / Double(perQueryAverages.count)
        let maxLatency = perQueryAverages.max() ?? 0.0
        let minLatency = perQueryAverages.min() ?? 0.0

        print(String(format: "[Challenger SLA Verification] 500 items across %d queries: Min=%.3f ms, Avg=%.3f ms, Max=%.3f ms", queries.count, minLatency, overallAvg, maxLatency))

        #expect(overallAvg < 10.0, "Overall average latency \(overallAvg) ms must be strictly < 10.0ms under multi-suite parallel contention")
    }

    @Test("Challenger Geometry: Extreme Multi-Screen Layouts (Stacked Top/Bottom, Dual 5K Ultrawide, Diagonal)")
    func testChallengerMultiScreenGeometry() {
        let panelSize = CGSize(width: 450, height: 600)

        // Stacked vertically: Display 1 (Bottom: 0, 0, 1920, 1080), Display 2 (Top: 0, 1080, 2560, 1440)
        let bottomScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let topScreen = NSRect(x: 0, y: 1080, width: 2560, height: 1440)

        // Cursor at bottom display near mouse
        let mouseAtBottom = CGPoint(x: 400, y: 300)
        let frameBottom = PanelPositioner.calculateFrame(
            mouseLocation: mouseAtBottom,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: bottomScreen
        )
        #expect(frameBottom.minX >= bottomScreen.minX + PanelPositioner.margin)
        #expect(frameBottom.maxX <= bottomScreen.maxX - PanelPositioner.margin)
        #expect(frameBottom.minY >= bottomScreen.minY + PanelPositioner.margin)
        #expect(frameBottom.maxY <= bottomScreen.maxY - PanelPositioner.margin)

        // Cursor at junction boundary (x: 500, y: 1080)
        let mouseAtBoundary = CGPoint(x: 500, y: 1080)
        let frameTop = PanelPositioner.calculateFrame(
            mouseLocation: mouseAtBoundary,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: topScreen
        )
        #expect(frameTop.minX >= topScreen.minX + PanelPositioner.margin)
        #expect(frameTop.maxX <= topScreen.maxX - PanelPositioner.margin)
        #expect(frameTop.minY >= topScreen.minY + PanelPositioner.margin)
        #expect(frameTop.maxY <= topScreen.maxY - PanelPositioner.margin)

        // Ultrawide 5120x1440 display
        let ultrawideScreen = NSRect(x: 0, y: 0, width: 5120, height: 1440)
        let mouseFarRight = CGPoint(x: 5110, y: 700)
        let frameUltrawide = PanelPositioner.calculateFrame(
            mouseLocation: mouseFarRight,
            panelSize: panelSize,
            mode: .nearMouse,
            visibleFrame: ultrawideScreen
        )
        #expect(frameUltrawide.maxX <= ultrawideScreen.maxX - PanelPositioner.margin)
        #expect(frameUltrawide.minX >= ultrawideScreen.minX + PanelPositioner.margin)
    }

    @MainActor
    @Test("Challenger Navigation: 10,000 Arrow Cycles & Interleaved Return/Escape Rapid Firing")
    func testChallengerNavigationStress() {
        let mockPasteboard = MockPasteboardService()
        let mockSound = MockSoundService()
        var items: [ClipboardItem] = []
        for i in 0..<50 {
            items.append(ClipboardItem.text("Stress Item \(i)"))
        }

        let viewModel = ClipboardHistoryViewModel(
            items: items,
            pasteboardService: mockPasteboard,
            soundService: mockSound
        )
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        var dismissCount = 0
        engine.dismissHandler = {
            dismissCount += 1
        }

        // Hammer 10,000 arrow presses
        for _ in 0..<5000 {
            _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
        }
        #expect(viewModel.selectedIndex == 49)

        for _ in 0..<5000 {
            _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.upArrow, modifiers: [])
        }
        #expect(viewModel.selectedIndex == 0)

        // Rapid interleaved navigation, Return, and Escape
        for i in 0..<200 {
            if i % 3 == 0 {
                _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.downArrow, modifiers: [])
            } else if i % 3 == 1 {
                _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [])
            } else {
                _ = engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.escapeKey, modifiers: [])
            }
        }

        #expect(mockPasteboard.copiedItems.count > 0)
        #expect(dismissCount > 0)
        #expect(viewModel.selectedIndex >= 0 && viewModel.selectedIndex < 50)
    }
}
