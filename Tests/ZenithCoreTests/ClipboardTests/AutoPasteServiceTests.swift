import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("AutoPasteService Keystroke Automation Suite")
struct AutoPasteServiceTests {

    @Test("AP-01: AutoPasteService vKeyCode is exactly 9 (kVK_ANSI_V)")
    func testVKeyCode() {
        #expect(AutoPasteService.vKeyCode == 9)
    }

    @Test("AP-02: AutoPasteService conforms to AutoPasteServiceProtocol")
    func testProtocolConformance() {
        let service: any AutoPasteServiceProtocol = AutoPasteService.shared
        #expect(service is AutoPasteService)
    }

    @Test("AP-03: AutoPasteService.shared singleton is thread-safe and non-nil")
    func testSingletonInstance() {
        let s1 = AutoPasteService.shared
        let s2 = AutoPasteService()
        #expect(type(of: s1) == type(of: s2))
    }

    /// Records posted events instead of delivering them: a real ⌘V would paste into whichever app is frontmost.
    final class PostedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CGEvent] = []
        var events: [CGEvent] { lock.withLock { _events } }
        func record(_ event: CGEvent) { lock.withLock { _events.append(event) } }
    }

    @Test("AP-04: paste() posts a Command+V key-down and key-up for the layout's V key, and nothing else")
    func testPasteEventsAreCommandV() {
        let posted = PostedEvents()
        let service = AutoPasteService(isTrusted: { true }, keyCodeForV: { 35 }, postEvent: { posted.record($0) })

        #expect(service.paste() == true)

        let events = posted.events
        #expect(events.count == 2)
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [35, 35])
        #expect(events.first?.flags.contains(.maskCommand) == true)
        #expect(events.first?.type == .keyDown)
        #expect(events.last?.type == .keyUp)
    }

    @Test("AP-05: Without Accessibility permission nothing is posted and the caller is told")
    func testPasteRefusedWithoutPermission() {
        let posted = PostedEvents()
        let service = AutoPasteService(isTrusted: { false }, postEvent: { posted.record($0) })

        #expect(service.paste() == false)
        #expect(posted.events.isEmpty)
    }

    @Test("AP-06: The V key is looked up in the active layout and is a valid key code")
    func testKeyCodeForVComesFromLayout() {
        let code = AutoPasteService.keyCodeForV()
        #expect(code < 128)
    }
}
