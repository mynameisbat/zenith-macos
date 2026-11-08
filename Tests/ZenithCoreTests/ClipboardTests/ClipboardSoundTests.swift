import Testing
import Foundation
@testable import ZenithCore

@Suite("Clipboard copy and paste sounds")
@MainActor
struct ClipboardSoundTests {

    @Test("CSND-01: Something copied plays the copy sound; adding in code does not")
    func testCopySound() {
        let store = ClipboardStore(capacity: 10)
        let sound = MockSoundService()
        store.soundService = sound

        store.ingest(.text("copied by the user"))
        #expect(sound.newCopySoundCount == 1)

        store.add(.text("added by code"))
        #expect(sound.newCopySoundCount == 1)
        #expect(sound.pasteSoundCount == 0)
    }

    @Test("CSND-02: Without a sound service (tests, previews) nothing plays")
    func testSilentByDefault() {
        let store = ClipboardStore(capacity: 10)
        #expect(store.soundService == nil)
        store.ingest(.text("quiet"))
        #expect(store.items.count == 1)
    }

    @Test("CSND-03: Pasting from the history plays the paste sound")
    func testPasteSound() {
        let store = ClipboardStore(capacity: 10)
        store.add(.text("first"))
        let sound = MockSoundService()
        let viewModel = ClipboardHistoryViewModel(store: store, pasteboardService: MockPasteboardService(), soundService: sound)
        viewModel.selectItem(at: 0)
        #expect(sound.pasteSoundCount == 1)
        #expect(sound.newCopySoundCount == 0)
    }
}
