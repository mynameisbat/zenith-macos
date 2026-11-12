import Testing
import Foundation
import AppKit
@testable import ZenithCore

@MainActor
@Suite("Clipboard paste variants: plain text and clean links")
struct ClipboardPasteVariantTests {

    private let rtf = Data("{\\rtf1\\ansi {\\b Bold} text}".utf8)

    @Test("Plain text of rich text drops the formatting; plain text and images are handled")
    func testPlainTextVariant() {
        let rich = ClipboardItem.richText(rtfData: rtf, plainText: "Bold text")
        let plain = rich.pasteboardItem(for: .plainText)
        #expect(plain?.payload == .plainText("Bold text"))
        #expect(rich.offersPasteVariant(.plainText))

        let text = ClipboardItem.text("already plain")
        #expect(text.pasteboardItem(for: .plainText) == text)
        #expect(!text.offersPasteVariant(.plainText))

        let image = ClipboardItem.image(data: Data([1, 2, 3]), width: 1, height: 1)
        #expect(image.pasteboardItem(for: .plainText) == nil)
        #expect(image.pasteboardItem(for: .original) == image)
    }

    @Test("Clean link applies only to a link with tracking parameters")
    func testCleanedLinkVariant() {
        let tracked = ClipboardItem.text("https://example.com/a?id=1&utm_source=x\n")
        #expect(tracked.cleanedLinkText == "https://example.com/a?id=1")
        #expect(tracked.offersPasteVariant(.cleanedLink))
        #expect(tracked.pasteboardItem(for: .cleanedLink)?.payload == .plainText("https://example.com/a?id=1"))

        let clean = ClipboardItem.text("https://example.com/a?id=1")
        #expect(clean.cleanedLinkText == nil)
        #expect(!clean.offersPasteVariant(.cleanedLink))
        #expect(ClipboardItem.text("not a link utm_source=x").pasteboardItem(for: .cleanedLink) == nil)
    }

    @Test("Store: pasting as plain text writes text only and keeps the formatted item in history")
    func testStorePastesPlainText() {
        let pasteboard = MockPasteboardService()
        let rich = ClipboardItem.richText(rtfData: rtf, plainText: "Bold text")
        let store = ClipboardStore(pasteboardService: pasteboard, initialItems: [.text("newer"), rich])

        store.selectAndRestoreItem(rich, variant: .plainText)

        #expect(pasteboard.copiedItems.last?.payload == .plainText("Bold text"))
        #expect(store.items.first?.id == rich.id)
        #expect(store.items.first?.payload == rich.payload)
        #expect(store.items.count == 2)
    }

    @Test("Store: pasting a clean link keeps the original link in history")
    func testStorePastesCleanLink() {
        let pasteboard = MockPasteboardService()
        let link = ClipboardItem.text("https://shop.example.com/p?id=9&gclid=abc")
        let store = ClipboardStore(pasteboardService: pasteboard, initialItems: [link])

        store.selectAndRestoreItem(link, variant: .cleanedLink)

        #expect(pasteboard.copiedItems.last?.plainTextContent == "https://shop.example.com/p?id=9")
        #expect(store.items.first?.plainTextContent == "https://shop.example.com/p?id=9&gclid=abc")
    }

    @Test("Shift-Return pastes the selection as plain text; Return still pastes it as it is")
    func testShiftReturn() {
        let pasteboard = MockPasteboardService()
        let rich = ClipboardItem.richText(rtfData: rtf, plainText: "Bold text")
        let viewModel = ClipboardHistoryViewModel(items: [rich], pasteboardService: pasteboard)
        var completed = 0
        viewModel.onActionCompleted = { completed += 1 }
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel

        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [.shift]))
        #expect(pasteboard.copiedItems.last?.payload == .plainText("Bold text"))
        #expect(completed == 1)

        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.keypadEnter, modifiers: [.shift, .numericPad]))
        #expect(pasteboard.copiedItems.last?.payload == .plainText("Bold text"))

        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: []))
        #expect(pasteboard.copiedItems.last?.payload == rich.payload)
        #expect(completed == 3)
    }

    @Test("Shift-Return on an image pastes the image (there is no text to paste)")
    func testShiftReturnOnImage() {
        let pasteboard = MockPasteboardService()
        let image = ClipboardItem.image(data: Data([9, 9]), width: 1, height: 1)
        let viewModel = ClipboardHistoryViewModel(items: [image], pasteboardService: pasteboard)
        let engine = KeyboardNavigationEngine()
        engine.activeViewModel = viewModel
        #expect(engine.handleKey(keyCode: KeyboardNavigationEngine.KeyCodes.returnKey, modifiers: [.shift]))
        #expect(pasteboard.copiedItems.last == image)
    }

    @Test("The real monitor writes plain text only for the plain-text variant (private pasteboard)")
    func testMonitorWritesNoRTF() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: board)
        let rich = ClipboardItem.richText(rtfData: rtf, plainText: "Bold text")
        let store = ClipboardStore(pasteboardService: monitor, initialItems: [rich])
        store.selectAndRestoreItem(rich, variant: .plainText)
        #expect(board.string(forType: .string) == "Bold text")
        #expect(board.data(forType: .rtf) == nil)
    }
}
