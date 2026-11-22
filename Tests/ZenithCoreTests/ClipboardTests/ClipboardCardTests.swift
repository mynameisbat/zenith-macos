import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Clipboard cards: content, code detection, cache, source app and docked frame")
struct ClipboardCardTests {

    // MARK: Content per kind

    @Test("CARD-01: A link card shows host and the rest of the address, and the host as meta")
    func linkCard() {
        let card = ClipboardCardContent.make(for: ClipboardItem.text("https://example.com/docs/getting-started?x=1"))
        #expect(card.preview == .link(host: "example.com", path: "/docs/getting-started?x=1"))
        #expect(card.meta == "example.com")
        #expect(card.kindTitle == ClipboardContentKind.link.title)
        #expect(card.shortTitle == "example.com/docs/g…")

        let bare = ClipboardCardContent.make(for: ClipboardItem.text("https://example.com/"))
        #expect(bare.preview == .link(host: "example.com", path: ""))
        #expect(bare.shortTitle == "example.com")
    }

    @Test("CARD-01b: The Paste button names a multi-line text by its first line with words in it")
    func pasteTitleSkipsNoise() {
        #expect(ClipboardCardContent.titleLine(of: "- 6\n\n  •  \n12.50\nTotal due this month\nNext") == "Total due this month")
        #expect(ClipboardCardContent.titleLine(of: "  Meeting notes  \nmore") == "Meeting notes")
        // Nothing with a letter: the first line that is not empty.
        #expect(ClipboardCardContent.titleLine(of: "\n\n- 6\n12") == "- 6")
        #expect(ClipboardCardContent.titleLine(of: "   ") == "")

        let card = ClipboardCardContent.make(for: ClipboardItem.text("- 6\n\nQuarterly report: revenue and costs for all teams"))
        #expect(card.shortTitle == "Quarterly report:…")   // cut at a word, as before
        let plain = ClipboardCardContent.make(for: ClipboardItem.text("A short note"))
        #expect(plain.shortTitle == "A short note")
    }

    @Test("CARD-02: A color card carries its hex, components and an RGB line")
    func colorCard() {
        let card = ClipboardCardContent.make(for: ClipboardItem.text("#0F62FE"))
        guard case .color(let hex, let red, _, let blue, let alpha) = card.preview else {
            Issue.record("not a color preview"); return
        }
        #expect(hex == "#0F62FE")
        #expect(abs(red - 15.0 / 255) < 0.0001)
        #expect(abs(blue - 254.0 / 255) < 0.0001)
        #expect(alpha == 1)
        #expect(card.meta == "RGB 15 98 254")
        #expect(card.shortTitle == "#0F62FE")
        #expect(card.prefersDarkTextOnPreview == false)
        #expect(ClipboardCardContent.make(for: ClipboardItem.text("#FFEB3B")).prefersDarkTextOnPreview == true)
        #expect(ClipboardCardContent.make(for: ClipboardItem.text("#FFFFFF00")).prefersDarkTextOnPreview == false)
    }

    @Test("CARD-03: An image card has its dimensions and size")
    func imageCard() {
        let card = ClipboardCardContent.make(for: ClipboardItem.image(data: Data(count: 2_048), width: 1280, height: 720))
        #expect(card.preview == .image(width: 1280, height: 720))
        #expect(card.meta.hasPrefix("1280 × 720 · "))
        #expect(card.kindTitle == ClipboardContentKind.image.title)
        #expect(card.shortTitle.contains("1280") && card.shortTitle.contains("720"))
    }

    @Test("CARD-04: Text shows a snippet, a character count and a short first line")
    func textCard() {
        let card = ClipboardCardContent.make(for: ClipboardItem.text("Meeting notes: ship the island fix on Friday."))
        #expect(card.preview == .text("Meeting notes: ship the island fix on Friday."))
        #expect(card.kindTitle == ClipboardContentKind.text.title)
        #expect(card.meta.contains("45"))
        #expect(card.shortTitle == "Meeting notes:…")
        #expect(ClipboardCardContent.make(for: ClipboardItem.text("x")).meta.contains("1 "))

        let long = String(repeating: "word ", count: 500)
        guard case .text(let snippet) = ClipboardCardContent.make(for: ClipboardItem.text(long)).preview else {
            Issue.record("not text"); return
        }
        #expect(snippet.count <= ClipboardCardContent.maxSnippetCharacters)
    }

    @Test("CARD-05: A text over the statistics limit shows its size instead of counting it")
    func hugeTextCard() {
        let huge = String(repeating: "a", count: ClipboardItem.maxStatsByteCount + 10)
        let card = ClipboardCardContent.make(for: ClipboardItem.text(huge))
        #expect(!card.meta.contains("characters"))
        #expect(!card.meta.isEmpty)
    }

    // MARK: Code

    @Test("CARD-06: Commands and source read as Code; prose does not")
    func codeDetection() {
        #expect(ClipboardItem.text("swift build -c release\n./scripts/bundle_app.sh").looksLikeCode)
        #expect(ClipboardItem.text("brew install --cask example-app").looksLikeCode)
        #expect(ClipboardItem.text("func hello() { return 1; }").looksLikeCode)
        #expect(!ClipboardItem.text("Make sure to call me back tomorrow.").looksLikeCode)
        #expect(!ClipboardItem.text("Invoice 2026-114, due 30 November").looksLikeCode)
        #expect(!ClipboardItem.text("make it so").looksLikeCode)
        // Links, colors and images are never code.
        #expect(!ClipboardItem.text("https://example.com/a;b{c}").looksLikeCode)
        #expect(!ClipboardItem.image(data: Data([0]), width: 1, height: 1).looksLikeCode)

        let card = ClipboardCardContent.make(for: ClipboardItem.text("swift build -c release\n./scripts/bundle_app.sh"))
        #expect(card.preview == .code("swift build -c release\n./scripts/bundle_app.sh"))
        #expect(card.kindTitle == String(localized: "Code"))
        #expect(card.shortTitle == "swift build -c…")
    }

    // MARK: Cache

    @Test("CARD-07: The cache builds a card once per item id")
    func cacheKeepsContent() {
        let cache = ClipboardCardContentCache(countLimit: 10)
        let item = ClipboardItem.text("Hello")
        #expect(cache.cachedContent(for: item.id) == nil)
        let first = cache.content(for: item)
        #expect(cache.cachedContent(for: item.id) == first)
        #expect(cache.content(for: item) == first)
        cache.removeAll()
        #expect(cache.cachedContent(for: item.id) == nil)
    }

    // MARK: Time

    @Test("CARD-08: Relative time is never empty and never reads as the future")
    func relativeTime() {
        let now = Date()
        let justNow = ClipboardCardContent.relativeTime(of: now.addingTimeInterval(30), now: now)
        let earlier = ClipboardCardContent.relativeTime(of: now.addingTimeInterval(-3 * 3_600), now: now)
        #expect(!justNow.isEmpty)
        #expect(!earlier.isEmpty)
        #expect(justNow != earlier)
    }

    // MARK: Source app

    @Test("CARD-09: The source app survives pinning, a bump to the front and an encode/decode round trip")
    func sourceBundleIDSurvives() throws {
        let store = ClipboardStore(capacity: 10)
        store.add(ClipboardItem.text("one", sourceBundleID: "com.apple.Safari"))
        store.add(ClipboardItem.text("two", sourceBundleID: "com.apple.Notes"))
        let one = try #require(store.items.first { $0.plainTextContent == "one" })
        store.togglePin(id: one.id)
        store.selectAndRestoreItem(one)
        #expect(store.items.first?.sourceBundleID == "com.apple.Safari")
        #expect(store.items.first?.isPinned == true)

        // A re-copy from another app names that app; one with no known app keeps what was known.
        store.add(ClipboardItem.text("one", sourceBundleID: "com.apple.Terminal"))
        #expect(store.items.first { $0.plainTextContent == "one" }?.sourceBundleID == "com.apple.Terminal")
        store.add(ClipboardItem.text("one"))
        #expect(store.items.first { $0.plainTextContent == "one" }?.sourceBundleID == "com.apple.Terminal")

        let data = try JSONEncoder().encode(one)
        #expect(try JSONDecoder().decode(ClipboardItem.self, from: data).sourceBundleID == "com.apple.Safari")

        // An item saved before the field existed still decodes.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceBundleID")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ClipboardItem.self, from: legacy).sourceBundleID == nil)
    }

    // MARK: Docked frame

    @Test("CARD-10: The docked panel is centred, 32 pt above the visible frame's bottom, at its preferred size")
    func dockedFrameDefault() {
        let visible = NSRect(x: 0, y: 70, width: 1728, height: 1000)
        let frame = PanelPositioner.dockedFrame(preferredSize: CGSize(width: 1200, height: 368), visibleFrame: visible)
        #expect(frame.size == CGSize(width: 1200, height: 368))
        #expect(frame.midX == visible.midX)
        let expectedY: CGFloat = 70 + 32
        #expect(frame.minY == expectedY)
    }

    @Test("CARD-11: On a narrow or short screen the docked panel shrinks and stays on screen; a second display's origin is kept")
    func dockedFrameSmallScreens() {
        let narrow = NSRect(x: 0, y: 0, width: 1024, height: 700)
        let frame = PanelPositioner.dockedFrame(preferredSize: CGSize(width: 1200, height: 368), visibleFrame: narrow)
        let expectedWidth: CGFloat = 1024 - 80
        #expect(frame.width == expectedWidth)
        #expect(frame.minX >= narrow.minX && frame.maxX <= narrow.maxX)

        let tiny = NSRect(x: 0, y: 0, width: 500, height: 200)
        let squeezed = PanelPositioner.dockedFrame(preferredSize: CGSize(width: 1200, height: 368), visibleFrame: tiny)
        #expect(squeezed.width <= tiny.width)
        #expect(squeezed.maxY <= tiny.maxY)
        #expect(squeezed.height > 0)

        let second = NSRect(x: 1728, y: -200, width: 1920, height: 1055)
        let onSecond = PanelPositioner.dockedFrame(preferredSize: CGSize(width: 1200, height: 368), visibleFrame: second)
        #expect(onSecond.midX == second.midX)
        let expectedSecondY: CGFloat = second.minY + 32
        #expect(onSecond.minY == expectedSecondY)
    }

    @Test("CARD-12: The thumbnail service's byte limit is a parameter")
    func thumbnailServiceByteLimit() {
        let service = ImageThumbnailService(maxCacheCount: 4, defaultMaxPixelDimension: 64, maxCacheBytes: 1_000_000)
        #expect(service.defaultMaxPixelDimension == 64)
    }

    // MARK: Mouse wheel

    @Test("CARD-13: A vertical mouse wheel moves the row sideways; trackpad and horizontal events are left alone")
    func wheelMapping() {
        // Wheel down (negative) goes toward later cards, wheel up back.
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 0, scrollingDeltaY: -1, hasPreciseDeltas: false, hasPhase: false) == ClipboardWheelScroll.pointsPerWheelUnit)
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 0, scrollingDeltaY: 2, hasPreciseDeltas: false, hasPhase: false) == -2 * ClipboardWheelScroll.pointsPerWheelUnit)
        // Trackpad / Magic Mouse (precise or phased) and horizontal-dominant or empty events pass through.
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 0, scrollingDeltaY: -8, hasPreciseDeltas: true, hasPhase: false) == nil)
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 0, scrollingDeltaY: -8, hasPreciseDeltas: false, hasPhase: true) == nil)
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 3, scrollingDeltaY: -1, hasPreciseDeltas: false, hasPhase: false) == nil)
        #expect(ClipboardWheelScroll.offsetChange(scrollingDeltaX: 0, scrollingDeltaY: 0, hasPreciseDeltas: false, hasPhase: false) == nil)
    }

    @Test("CARD-14: The wheel offset stays inside the content")
    func wheelClamping() {
        #expect(ClipboardWheelScroll.clampedOffset(current: 10, change: -40, contentWidth: 2000, visibleWidth: 1000) == 0)
        #expect(ClipboardWheelScroll.clampedOffset(current: 990, change: 40, contentWidth: 2000, visibleWidth: 1000) == 1000)
        #expect(ClipboardWheelScroll.clampedOffset(current: 100, change: 40, contentWidth: 2000, visibleWidth: 1000) == 140)
        #expect(ClipboardWheelScroll.clampedOffset(current: 0, change: 40, contentWidth: 500, visibleWidth: 1000) == 0)
    }
}
