import Testing
@testable import ZenithCore

@Suite("Island notices fit the capsule")
struct IslandNoticeTextTests {
    @Test("NOTICE-01: A long message is split after its first sentence; the rest becomes the subtitle")
    func longMessageIsSplit() {
        let text = IslandNoticeText.split(title: "Cleaning Mode off. The keyboard and trackpad work again.", subtitle: nil)
        #expect(text.title == "Cleaning Mode off")
        #expect(text.subtitle == "The keyboard and trackpad work again.")
    }

    @Test("NOTICE-02: A label before a colon becomes the title")
    func labelIsTheTitle() {
        let text = IslandNoticeText.split(title: "Cleaning Mode off: time is up. The keyboard and trackpad work again.", subtitle: nil)
        #expect(text.title == "Cleaning Mode off: time is up")
        #expect(text.subtitle == "The keyboard and trackpad work again.")
    }

    @Test("NOTICE-03: Short messages, messages that have a subtitle and ones with nowhere to split stay as they are")
    func otherMessagesStay() {
        #expect(IslandNoticeText.split(title: "Text Copied to Clipboard", subtitle: nil) == ("Text Copied to Clipboard", nil))
        let withSubtitle = IslandNoticeText.split(title: "Uninstalled Example. It is in the Trash now, really", subtitle: "Freed 12 MB")
        #expect(withSubtitle.title == "Uninstalled Example. It is in the Trash now, really")
        #expect(withSubtitle.subtitle == "Freed 12 MB")
        let unsplittable = "Supercalifragilisticexpialidocious-and-more-words"
        #expect(IslandNoticeText.split(title: unsplittable, subtitle: nil).title == unsplittable)
    }

    @Test("NOTICE-04: The Boost notices fit on one line")
    func boostFits() {
        for result in [BoostResult(flushedDNS: true), BoostResult(flushedDNS: false)] {
            #expect(result.message.count <= IslandNoticeText.titleLimit + 4, "\(result.message)")
        }
    }
}
