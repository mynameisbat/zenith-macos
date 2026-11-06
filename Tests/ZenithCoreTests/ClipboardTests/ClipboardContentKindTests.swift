import Testing
import Foundation
@testable import ZenithCore

@Suite("Clipboard content kinds, filters and day groups")
struct ClipboardContentKindTests {

    @Test("CCK-01: A lone http(s) URL is a link; anything else is not")
    func testLinkDetection() {
        #expect(ClipboardItem.text("https://example.com/docs?a=1").contentKind == .link)
        #expect(ClipboardItem.text("  http://example.com  \n").linkURL?.host == "example.com")
        #expect(ClipboardItem.text("see https://example.com").contentKind == .text)
        #expect(ClipboardItem.text("ftp://example.com").contentKind == .text)
        #expect(ClipboardItem.text("https://").contentKind == .text)
        #expect(ClipboardItem.text("example.com").contentKind == .text)
        let long = "https://example.com/" + String(repeating: "a", count: ClipboardItem.maxDetectableLength)
        #expect(ClipboardItem.text(long).contentKind == .text)
        let rich = ClipboardItem.richText(rtfData: Data([1]), plainText: "https://example.com")
        #expect(rich.contentKind == .link)
        #expect(ClipboardItem.richText(rtfData: Data([1]), plainText: "Hello").contentKind == .richText)
    }

    @Test("CCK-02: Hex color codes with a # are colors, with their components")
    func testColorDetection() throws {
        let blue = ClipboardItem.text("#0F62FE")
        #expect(blue.contentKind == .color)
        #expect(blue.colorHex == "#0F62FE")
        let components = try #require(blue.colorComponents)
        #expect(abs(components.red - 15.0 / 255) < 0.0001)
        #expect(abs(components.blue - 254.0 / 255) < 0.0001)
        #expect(components.alpha == 1)

        #expect(ClipboardItem.text("#abc").colorHex == "#AABBCC")
        #expect(ClipboardItem.text("#11223380").colorComponents?.alpha == Double(0x80) / 255)
        #expect(ClipboardItem.text("0F62FE").contentKind == .text)
        #expect(ClipboardItem.text("#12345").contentKind == .text)
        #expect(ClipboardItem.text("#GGGGGG").contentKind == .text)
        #expect(ClipboardItem.image(data: Data([0]), width: 1, height: 1).contentKind == .image)
    }

    @Test("CCK-03: Text stats count characters, words and lines, and skip huge items")
    func testTextStats() {
        let stats = ClipboardItem.text("Hello world\nsecond line here").textStats
        #expect(stats == ClipboardTextStats(characters: 28, words: 5, lines: 2))
        #expect(ClipboardItem.text("").textStats == ClipboardTextStats(characters: 0, words: 0, lines: 0))
        let huge = String(repeating: "a ", count: ClipboardItem.maxStatsByteCount)
        #expect(ClipboardItem.text(huge).textStats == nil)
        #expect(ClipboardItem.image(data: Data([0]), width: 1, height: 1).textStats == nil)
    }

    @Test("CCK-04: Day groups are Today, Yesterday and Earlier")
    func testDateBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        #expect(ClipboardDateBucket.bucket(for: now.addingTimeInterval(-3_600), now: now, calendar: calendar) == .today)
        #expect(ClipboardDateBucket.bucket(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar) == .yesterday)
        #expect(ClipboardDateBucket.bucket(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == .earlier)
        #expect(ClipboardDateBucket.today < .earlier)
    }

    @Test("CCK-05: The kind filter narrows the list and works together with search")
    @MainActor
    func testKindFilterInViewModel() {
        let items = [
            ClipboardItem.text("https://example.com/a"),
            ClipboardItem.text("Meeting notes"),
            ClipboardItem.text("#0F62FE", isPinned: true),
            ClipboardItem.image(data: Data([0]), width: 2, height: 2),
            ClipboardItem.text("https://example.org/notes")
        ]
        let viewModel = ClipboardHistoryViewModel(items: items, pasteboardService: MockPasteboardService())
        #expect(viewModel.filteredItems.count == 5)

        viewModel.selectedIndex = 3
        viewModel.kindFilter = .links
        #expect(viewModel.filteredItems.map(\.previewText) == ["https://example.com/a", "https://example.org/notes"])
        #expect(viewModel.selectedIndex == 0)
        #expect(viewModel.selectedItem?.previewText == "https://example.com/a")

        viewModel.searchText = "notes"
        #expect(viewModel.filteredItems.map(\.previewText) == ["https://example.org/notes"])

        viewModel.searchText = ""
        viewModel.kindFilter = .text
        #expect(viewModel.filteredItems.map(\.previewText) == ["Meeting notes", "#0F62FE"])
        viewModel.kindFilter = .images
        #expect(viewModel.filteredItems.count == 1)
        viewModel.kindFilter = .pinned
        #expect(viewModel.filteredItems.map(\.previewText) == ["#0F62FE"])
        viewModel.kindFilter = .all
        #expect(viewModel.filteredItems.count == 5)

        viewModel.kindFilter = .links
        viewModel.searchText = "zzz-nothing"
        #expect(viewModel.selectedItem == nil)
    }
}
